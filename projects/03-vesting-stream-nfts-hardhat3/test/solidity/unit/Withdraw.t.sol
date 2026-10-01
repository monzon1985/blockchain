// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";

import {IVestingStreams} from "../../../contracts/interfaces/IVestingStreams.sol";
import {Status} from "../../../contracts/types/StreamTypes.sol";
import {BaseTest} from "../utils/BaseTest.sol";

/// @notice `withdraw` / `withdrawMax`: authorization through ERC-721 ownership and approvals, amounts, targets.
contract WithdrawTest is BaseTest {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _createDefaultLinear(); // 1,200 over 12 months, 3-month cliff, to alice
    }

    function test_withdraw_paysOwnerAndUpdatesAccounting() public {
        vm.warp(T0 + 6 * MONTH); // 600 vested
        assertEq(vesting.withdrawableAmountOf(id), 600 * E18);

        vm.expectEmit(address(vesting));
        emit IVestingStreams.Withdrawn(id, alice, bob, uint128(250 * E18));
        vm.expectEmit(address(vesting));
        emit IERC4906.MetadataUpdate(id);
        vm.prank(alice);
        vesting.withdraw(id, bob, uint128(250 * E18));

        assertEq(token.balanceOf(bob), 250 * E18);
        assertEq(vesting.getStream(id).withdrawnAmount, 250 * E18);
        assertEq(vesting.withdrawableAmountOf(id), 350 * E18);
    }

    function test_withdrawMax_returnsAndPaysEverythingVested() public {
        vm.warp(T0 + 9 * MONTH);
        vm.prank(alice);
        uint128 amount = vesting.withdrawMax(id, alice);
        assertEq(amount, 900 * E18);
        assertEq(token.balanceOf(alice), 900 * E18);
        assertEq(vesting.withdrawableAmountOf(id), 0);
    }

    function test_withdraw_fullyDepletesAfterEnd() public {
        vm.warp(T0 + 12 * MONTH);
        vm.prank(alice);
        vesting.withdrawMax(id, alice);
        assertEq(uint8(vesting.statusOf(id)), uint8(Status.Depleted));
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function test_withdraw_byApprovedOperator() public {
        vm.warp(T0 + 6 * MONTH);
        vm.prank(alice);
        vesting.approve(bob, id);
        vm.prank(bob);
        vesting.withdraw(id, bob, uint128(100 * E18));
        assertEq(token.balanceOf(bob), 100 * E18);
    }

    function test_withdraw_byOperatorForAll() public {
        vm.warp(T0 + 6 * MONTH);
        vm.prank(alice);
        vesting.setApprovalForAll(bob, true);
        vm.prank(bob);
        vesting.withdrawMax(id, eve);
        assertEq(token.balanceOf(eve), 600 * E18);
    }

    function test_withdrawalRightFollowsTheNft() public {
        vm.warp(T0 + 6 * MONTH);
        vm.prank(alice);
        vesting.transferFrom(alice, bob, id);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.NotAuthorizedToWithdraw.selector, id, alice));
        vesting.withdrawMax(id, alice);

        vm.prank(bob);
        vesting.withdrawMax(id, bob);
        assertEq(token.balanceOf(bob), 600 * E18);
    }

    function test_revert_notAuthorized() public {
        vm.warp(T0 + 6 * MONTH);
        vm.prank(sender); // the sender has no withdrawal right
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.NotAuthorizedToWithdraw.selector, id, sender));
        vesting.withdraw(id, sender, 1);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.NotAuthorizedToWithdraw.selector, id, eve));
        vesting.withdrawMax(id, eve);
    }

    function test_revert_invalidTarget() public {
        vm.warp(T0 + 6 * MONTH);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.InvalidWithdrawalTarget.selector, address(0)));
        vesting.withdraw(id, address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.InvalidWithdrawalTarget.selector, address(vesting)));
        vesting.withdrawMax(id, address(vesting));
        vm.stopPrank();
    }

    function test_revert_zeroAmount() public {
        vm.warp(T0 + 6 * MONTH);
        vm.prank(alice);
        vm.expectRevert(_err(IVestingStreams.ZeroWithdrawAmount.selector, id));
        vesting.withdraw(id, alice, 0);
    }

    function test_revert_exceedsWithdrawable() public {
        vm.warp(T0 + 6 * MONTH);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVestingStreams.WithdrawAmountExceedsWithdrawable.selector,
                id,
                uint128(600 * E18 + 1),
                uint128(600 * E18)
            )
        );
        vesting.withdraw(id, alice, uint128(600 * E18 + 1));
    }

    function test_revert_nothingToWithdrawBeforeCliff() public {
        vm.warp(T0 + 3 * MONTH - 1);
        vm.prank(alice);
        vm.expectRevert(_err(IVestingStreams.NothingToWithdraw.selector, id));
        vesting.withdrawMax(id, alice);
    }

    function test_revert_unknownStream() public {
        vm.prank(alice);
        vm.expectRevert(_err(IVestingStreams.StreamNotFound.selector, 99));
        vesting.withdraw(99, alice, 1);
        vm.expectRevert(_err(IVestingStreams.StreamNotFound.selector, 0));
        vesting.withdrawMax(0, alice);
    }

    function test_revert_nftCannotBeSentToTheVestingContract() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.InvalidRecipient.selector, address(vesting)));
        vesting.transferFrom(alice, address(vesting), id);
    }

    /// Withdrawing in any number of arbitrary chunks never lets the owner take more than what vested.
    function testFuzz_withdraw_chunksNeverExceedStreamed(uint256[8] memory chunks, uint256[8] memory gaps) public {
        uint256 total;
        uint40 t = T0;
        for (uint256 i; i < 8; ++i) {
            t += uint40(bound(gaps[i], 0, 3 * MONTH));
            vm.warp(t);
            uint128 withdrawable = vesting.withdrawableAmountOf(id);
            if (withdrawable == 0) continue;
            uint128 amount = uint128(bound(chunks[i], 1, withdrawable));
            vm.prank(alice);
            vesting.withdraw(id, alice, amount);
            total += amount;
            assertLe(total, vesting.streamedAmountOf(id));
        }
        assertEq(token.balanceOf(alice), total);
        assertEq(vesting.getStream(id).withdrawnAmount, total);
    }
}
