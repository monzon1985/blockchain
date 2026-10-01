// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {StreamRenderer} from "../../../contracts/StreamRenderer.sol";
import {VestingStreams} from "../../../contracts/VestingStreams.sol";
import {Status, Stream} from "../../../contracts/types/StreamTypes.sol";
import {VestingHandler} from "./VestingHandler.sol";

/// @notice Stateful value-conservation suite. Each invariant is listed, in plain English, in the README.
contract VestingInvariantsTest is Test {
    VestingStreams internal vesting;
    VestingHandler internal handler;

    function setUp() public {
        vm.warp(1_772_323_200); // 2026-03-01
        vesting = new VestingStreams(new StreamRenderer(), address(this));
        handler = new VestingHandler(vesting);

        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = VestingHandler.create.selector;
        selectors[1] = VestingHandler.createBatch.selector;
        selectors[2] = VestingHandler.createWithUnsupportedToken.selector;
        selectors[3] = VestingHandler.withdraw.selector;
        selectors[4] = VestingHandler.withdrawMax.selector;
        selectors[5] = VestingHandler.operatorWithdraw.selector;
        selectors[6] = VestingHandler.strangerWithdraw.selector;
        selectors[7] = VestingHandler.cancel.selector;
        selectors[8] = VestingHandler.renounce.selector;
        selectors[9] = VestingHandler.transferNft.selector;
        selectors[10] = VestingHandler.armReentrancy.selector;
        selectors[11] = VestingHandler.donate.selector;
        selectors[12] = VestingHandler.warp.selector;
        selectors[13] = VestingHandler.warp.selector; // time moves twice as often as any other action
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// INV-1 Per stream, the recorded deposit, withdrawals and refund equal the token amounts that actually moved,
    /// and `deposited == withdrawn + refunded + remaining` with `remaining >= 0`.
    function invariant_perStreamConservation() public view {
        uint256 count = handler.streamCount();
        for (uint256 i; i < count; ++i) {
            uint256 id = handler.streamIds(i);
            Stream memory s = vesting.getStream(id);
            assertEq(s.depositAmount, handler.ghostDeposited(id), "deposit != tokens received");
            assertEq(s.withdrawnAmount, handler.ghostWithdrawn(id), "withdrawn != tokens paid out");
            assertEq(s.refundedAmount, handler.ghostRefunded(id), "refunded != tokens returned");
            assertLe(uint256(s.withdrawnAmount) + s.refundedAmount, s.depositAmount, "negative remaining");
        }
        assertEq(handler.ghostBalanceDeltaMismatches(), 0, "a transfer moved a different amount than accounted");
    }

    /// INV-2 For every token, the contract balance equals the sum of what every stream still holds plus plain
    /// donations: no token is created, lost or silently kept.
    function invariant_solvencyPerToken() public view {
        uint256 tokenCount = handler.tokenCount();
        uint256 count = handler.streamCount();
        for (uint256 t; t < tokenCount; ++t) {
            address token = handler.tokens(t);
            uint256 remaining;
            for (uint256 i; i < count; ++i) {
                Stream memory s = vesting.getStream(handler.streamIds(i));
                if (address(s.token) == token) remaining += s.depositAmount - s.withdrawnAmount - s.refundedAmount;
            }
            assertEq(IERC20(token).balanceOf(address(vesting)), remaining + handler.ghostDonated(token), "insolvent");
        }
    }

    /// INV-3 withdrawn <= streamed <= deposit, withdrawable == streamed - withdrawn, and a canceled stream's
    /// streamed amount is frozen at deposit - refunded.
    function invariant_streamedBounds() public view {
        uint256 count = handler.streamCount();
        for (uint256 i; i < count; ++i) {
            uint256 id = handler.streamIds(i);
            Stream memory s = vesting.getStream(id);
            uint128 streamed = vesting.streamedAmountOf(id);
            assertLe(s.withdrawnAmount, streamed, "withdrew more than streamed");
            assertLe(streamed, s.depositAmount, "streamed more than deposited");
            assertEq(vesting.withdrawableAmountOf(id), streamed - s.withdrawnAmount);
            if (s.canceled) assertEq(streamed, s.depositAmount - s.refundedAmount, "cancel did not freeze");
            else assertEq(s.refundedAmount, 0, "refund without cancel");
        }
    }

    /// INV-4 The streamed amount of every stream never decreases as time moves forward, across cancellations.
    function invariant_streamedNonDecreasing() public view {
        assertEq(handler.ghostMonotonicityViolations(), 0);
    }

    /// INV-5 No stream is ever credited with more tokens than the contract received (fee-on-transfer and
    /// share-rounding rebasing tokens are rejected).
    function invariant_noShortDeliveryAccepted() public view {
        assertEq(handler.ghostShortDeliveryAccepted(), 0);
    }

    /// INV-6 Only the NFT owner or an approved operator can withdraw; the right moves with the NFT.
    function invariant_noUnauthorizedWithdrawal() public view {
        assertEq(handler.ghostUnauthorizedWithdrawals(), 0);
    }

    /// INV-7 No re-entrant call from a token callback or a cancel hook ever succeeds.
    function invariant_noReentrancy() public view {
        assertEq(handler.reentrant().successes(), 0);
    }

    /// INV-8 Nothing is ever stranded: once every schedule has ended, the NFT owners can drain every stream and the
    /// contract is left holding exactly the donations. Checked at the end of every run.
    function afterInvariant() public {
        uint256 count = handler.streamCount();
        uint256 latestEnd = block.timestamp;
        for (uint256 i; i < count; ++i) {
            uint256 end = vesting.getStream(handler.streamIds(i)).endTime;
            if (end > latestEnd) latestEnd = end;
        }
        vm.warp(latestEnd + 1);
        for (uint256 i; i < count; ++i) {
            uint256 id = handler.streamIds(i);
            if (vesting.withdrawableAmountOf(id) == 0) continue;
            address holder = vesting.ownerOf(id);
            vm.prank(holder);
            vesting.withdrawMax(id, holder);
        }
        for (uint256 i; i < count; ++i) {
            assertEq(uint8(vesting.statusOf(handler.streamIds(i))), uint8(Status.Depleted), "stream not depleted");
        }
        for (uint256 t; t < handler.tokenCount(); ++t) {
            address token = handler.tokens(t);
            assertEq(IERC20(token).balanceOf(address(vesting)), handler.ghostDonated(token), "tokens stranded");
        }
    }
}
