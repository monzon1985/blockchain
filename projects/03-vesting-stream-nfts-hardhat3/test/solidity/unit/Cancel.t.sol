// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";

import {IVestingStreams} from "../../../contracts/interfaces/IVestingStreams.sol";
import {HookedToken} from "../../../contracts/mocks/HookedToken.sol";
import {
    GasGuzzlerRecipient,
    RecordingRecipient,
    ReentrantActor,
    ReturnBombRecipient,
    RevertingRecipient
} from "../../../contracts/mocks/RecipientMocks.sol";
import {CreateParams, Status, Stream} from "../../../contracts/types/StreamTypes.sol";
import {BaseTest} from "../utils/BaseTest.sol";

/// @notice `cancel` and `renounceCancelability`, including hostile recipient hooks and re-entrancy.
contract CancelTest is BaseTest {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _createDefaultLinear(); // 1,200 over 12 months, 3-month cliff, to alice
    }

    function test_cancel_refundsUnvestedAndFreezesStreamed() public {
        vm.warp(T0 + 4 * MONTH); // 400 vested
        uint256 senderBefore = token.balanceOf(sender);

        vm.expectEmit(address(vesting));
        emit IVestingStreams.Canceled(id, sender, alice, uint128(800 * E18), uint128(400 * E18));
        vm.expectEmit(address(vesting));
        emit IERC4906.MetadataUpdate(id);
        vm.prank(sender);
        uint128 refunded = vesting.cancel(id);

        assertEq(refunded, 800 * E18);
        assertEq(token.balanceOf(sender) - senderBefore, 800 * E18);
        Stream memory s = vesting.getStream(id);
        assertTrue(s.canceled);
        assertFalse(s.cancelable);
        assertEq(s.canceledAt, T0 + 4 * MONTH);
        assertEq(s.refundedAmount, 800 * E18);
        assertEq(uint8(vesting.statusOf(id)), uint8(Status.Canceled));

        // The streamed amount stays frozen and the recipient keeps what had vested.
        vm.warp(T0 + 12 * MONTH);
        assertEq(vesting.streamedAmountOf(id), 400 * E18);
        assertEq(vesting.refundableAmountOf(id), 0);
        vm.prank(alice);
        vesting.withdrawMax(id, alice);
        assertEq(token.balanceOf(alice), 400 * E18);
        assertEq(uint8(vesting.statusOf(id)), uint8(Status.Depleted));
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function test_cancel_beforeStartRefundsEverything() public {
        vm.prank(sender);
        assertEq(vesting.cancel(id), 1200 * E18);
        assertEq(uint8(vesting.statusOf(id)), uint8(Status.Depleted));
    }

    function test_cancel_roundingFavoursTheRefund() public {
        uint256 odd = _create(_linear(alice, 10, T0, 0, T0 + 3));
        vm.warp(T0 + 1); // exact vested = 3.33..
        vm.prank(sender);
        assertEq(vesting.cancel(odd), 7); // recipient keeps floor = 3, sender gets 7
    }

    function test_revert_cancel_notSender() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.NotStreamSender.selector, id, alice));
        vesting.cancel(id);
    }

    function test_revert_cancel_twice() public {
        vm.startPrank(sender);
        vesting.cancel(id);
        vm.expectRevert(_err(IVestingStreams.StreamNotCancelable.selector, id));
        vesting.cancel(id);
        vm.stopPrank();
    }

    function test_revert_cancel_nonCancelable() public {
        CreateParams memory p = _linear(alice, 100, T0, 0, T0 + MONTH);
        p.cancelable = false;
        uint256 locked = _create(p);
        vm.prank(sender);
        vm.expectRevert(_err(IVestingStreams.StreamNotCancelable.selector, locked));
        vesting.cancel(locked);
    }

    function test_revert_cancel_settled() public {
        vm.warp(T0 + 12 * MONTH);
        vm.prank(sender);
        vm.expectRevert(_err(IVestingStreams.StreamSettled.selector, id));
        vesting.cancel(id);
    }

    function test_revert_cancel_unknownStream() public {
        vm.prank(sender);
        vm.expectRevert(_err(IVestingStreams.StreamNotFound.selector, 7));
        vesting.cancel(7);
    }

    /*//////////////////////////////////////////////////////////////
                         RENOUNCE CANCELABILITY
    //////////////////////////////////////////////////////////////*/

    function test_renounce_isIrreversible() public {
        vm.expectEmit(address(vesting));
        emit IVestingStreams.CancelabilityRenounced(id);
        vm.expectEmit(address(vesting));
        emit IERC4906.MetadataUpdate(id);
        vm.prank(sender);
        vesting.renounceCancelability(id);

        assertFalse(vesting.getStream(id).cancelable);
        assertEq(vesting.refundableAmountOf(id), 0);
        vm.startPrank(sender);
        vm.expectRevert(_err(IVestingStreams.StreamNotCancelable.selector, id));
        vesting.cancel(id);
        vm.expectRevert(_err(IVestingStreams.StreamNotCancelable.selector, id));
        vesting.renounceCancelability(id);
        vm.stopPrank();
    }

    function test_revert_renounce_notSender() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.NotStreamSender.selector, id, alice));
        vesting.renounceCancelability(id);
    }

    /*//////////////////////////////////////////////////////////////
                             RECIPIENT HOOK
    //////////////////////////////////////////////////////////////*/

    function test_hook_calledWithArgumentsAndFullStipend() public {
        RecordingRecipient recipient = new RecordingRecipient();
        uint256 streamId = _create(_linear(address(recipient), 1000, T0, 0, T0 + 10 * DAY));
        vm.warp(T0 + 3 * DAY);
        vm.prank(sender);
        vesting.cancel(streamId);

        assertEq(recipient.calls(), 1);
        assertEq(recipient.lastStreamId(), streamId);
        assertEq(recipient.lastSender(), sender);
        assertEq(recipient.lastRefunded(), 700);
        assertEq(recipient.lastWithdrawable(), 300);
        // The hook got the whole stipend (minus the few hundred gas its own prologue burns before `gasleft()`).
        assertGt(recipient.gasAtEntry(), vesting.RECIPIENT_HOOK_GAS() - 1000);
        assertLe(recipient.gasAtEntry(), vesting.RECIPIENT_HOOK_GAS());
    }

    function test_hook_revertingHookCannotBlockCancel() public {
        _assertHookFailureIsIgnored(address(new RevertingRecipient()));
    }

    function test_hook_gasGuzzlerCannotBlockCancel() public {
        _assertHookFailureIsIgnored(address(new GasGuzzlerRecipient()));
    }

    function test_hook_returnBombCannotBlockCancel() public {
        _assertHookFailureIsIgnored(address(new ReturnBombRecipient()));
    }

    /// The 150 kB revert payload is never copied: canceling costs about the same as with a plain reverting hook.
    function test_hook_returnBombIsNotCopied() public {
        uint256 plain = _cancelGas(address(new RevertingRecipient()));
        uint256 bomb = _cancelGas(address(new ReturnBombRecipient()));
        // The bomb's own memory expansion is paid inside its 100k stipend; copying 150 kB into the caller's
        // memory would add well over 100k gas on top.
        assertLt(bomb, plain + vesting.RECIPIENT_HOOK_GAS());
    }

    function test_hook_notCalledForEoaRecipients() public {
        vm.warp(T0 + 4 * MONTH);
        vm.prank(sender);
        vm.recordLogs();
        vesting.cancel(id);
        assertEq(vm.getRecordedLogs().length, 3); // ERC-20 Transfer, Canceled, MetadataUpdate
    }

    /// The sender cannot starve the hook on purpose: with too little gas the whole cancel reverts instead.
    function test_revert_insufficientGasForHook() public {
        RecordingRecipient recipient = new RecordingRecipient();
        uint256 streamId = _create(_linear(address(recipient), 1000, T0, 0, T0 + 10 * DAY));
        vm.warp(T0 + 3 * DAY);
        vm.prank(sender);
        vm.expectPartialRevert(IVestingStreams.InsufficientGasForHook.selector);
        vesting.cancel{gas: 100_000}(streamId);
        assertEq(recipient.calls(), 0);
    }

    /// The reservation at its boundary: binary-search the smallest gas limit with which `cancel` succeeds. With that
    /// limit the hook must still get exactly the gas it gets from an unlimited budget (its full stipend), and one
    /// unit less must make `cancel` revert with `InsufficientGasForHook` rather than run the hook short of gas.
    function test_hook_fullStipendAtTheMinimumGasThatLetsCancelSucceed() public {
        RecordingRecipient recipient = new RecordingRecipient();
        uint256 streamId = _create(_linear(address(recipient), 1000, T0, 0, T0 + 10 * DAY));
        vm.warp(T0 + 3 * DAY);

        (bool ok, uint64 fullStipendEntry,) = _cancelWithGasLimit(recipient, streamId, 10_000_000);
        assertTrue(ok, "cancel with an unlimited budget");
        uint256 low = vesting.RECIPIENT_HOOK_GAS(); // cannot succeed: the hook alone gets this much
        (ok,,) = _cancelWithGasLimit(recipient, streamId, low);
        assertFalse(ok, "lower bound of the search");
        uint256 high = 10_000_000;
        while (high - low > 1) {
            uint256 mid = (low + high) / 2;
            (ok,,) = _cancelWithGasLimit(recipient, streamId, mid);
            if (ok) high = mid;
            else low = mid;
        }

        (bool okAtMin, uint64 entryAtMin,) = _cancelWithGasLimit(recipient, streamId, high);
        assertTrue(okAtMin);
        assertEq(entryAtMin, fullStipendEntry, "the hook ran with less than its full stipend");
        assertGt(entryAtMin, vesting.RECIPIENT_HOOK_GAS() - 1000, "hook prologue allowance");

        (bool okBelow, uint64 entryBelow, bytes memory revertData) = _cancelWithGasLimit(recipient, streamId, high - 1);
        assertFalse(okBelow);
        assertEq(entryBelow, 0, "the hook ran although cancel reverted");
        assertEq(bytes4(revertData), IVestingStreams.InsufficientGasForHook.selector, "binding constraint");
    }

    /*//////////////////////////////////////////////////////////////
                              RE-ENTRANCY
    //////////////////////////////////////////////////////////////*/

    /// A contract recipient re-entering from the cancel hook cannot withdraw or cancel again.
    function test_reentrancy_fromHookIsBlocked() public {
        ReentrantActor actor = new ReentrantActor(vesting);
        uint256 streamId = _create(_linear(address(actor), 1000, T0, 0, T0 + 10 * DAY));
        actor.setTarget(streamId);
        vm.warp(T0 + 3 * DAY);
        vm.prank(sender);
        vesting.cancel(streamId);
        assertEq(actor.attempts(), 1);
        assertEq(actor.successes(), 0);
        assertEq(vesting.getStream(streamId).withdrawnAmount, 0);
    }

    /// With a callback token, both the recipient (on withdraw) and the sender (on refund) get control flow in the
    /// middle of the operation; every re-entrant call is rejected by the guard.
    function test_reentrancy_fromTokenCallbacksIsBlocked() public {
        HookedToken hooked = new HookedToken();
        ReentrantActor actor = new ReentrantActor(vesting);
        hooked.mint(address(actor), 1e24);
        vm.prank(address(actor));
        hooked.approve(address(vesting), type(uint256).max);

        // The actor is both sender and recipient of its own stream.
        vm.prank(address(actor));
        uint256 streamId = vesting.create(IERC20(address(hooked)), _linear(address(actor), 1000, T0, 0, T0 + 10 * DAY));
        actor.setTarget(streamId);

        vm.warp(T0 + 5 * DAY);
        vm.prank(address(actor));
        vesting.withdraw(streamId, address(actor), 100); // token callback -> re-entry attempts
        vm.prank(address(actor));
        vesting.cancel(streamId); // refund callback + cancel hook -> re-entry attempts

        assertEq(actor.attempts(), 3);
        assertEq(actor.successes(), 0);
        Stream memory s = vesting.getStream(streamId);
        assertEq(s.withdrawnAmount, 100);
        assertEq(s.refundedAmount, 500);
        assertEq(hooked.balanceOf(address(vesting)), 400);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _assertHookFailureIsIgnored(address recipient) internal {
        uint256 streamId = _create(_linear(recipient, 1000, T0, 0, T0 + 10 * DAY));
        vm.warp(T0 + 3 * DAY);
        vm.expectEmit(address(vesting));
        emit IVestingStreams.RecipientHookFailed(streamId, recipient);
        vm.prank(sender);
        assertEq(vesting.cancel(streamId), 700);
        assertTrue(vesting.getStream(streamId).canceled);
        assertEq(vesting.withdrawableAmountOf(streamId), 300);
    }

    /// @dev Cancels `streamId` as the sender with exactly `gasLimit` gas, records what the hook saw, then rolls the
    /// whole attempt back so the next one starts from the same state.
    function _cancelWithGasLimit(RecordingRecipient recipient, uint256 streamId, uint256 gasLimit)
        internal
        returns (bool ok, uint64 hookGasAtEntry, bytes memory revertData)
    {
        uint256 snapshot = vm.snapshotState();
        vm.prank(sender);
        (ok, revertData) = address(vesting).call{gas: gasLimit}(abi.encodeCall(vesting.cancel, (streamId)));
        hookGasAtEntry = recipient.gasAtEntry();
        vm.revertToState(snapshot);
    }

    function _cancelGas(address recipient) internal returns (uint256 used) {
        uint256 snapshot = vm.snapshotState();
        uint256 streamId = _create(_linear(recipient, 1000, T0, 0, T0 + 10 * DAY));
        vm.warp(T0 + 3 * DAY);
        vm.prank(sender);
        uint256 before = gasleft();
        vesting.cancel(streamId);
        used = before - gasleft();
        vm.revertToState(snapshot);
    }
}
