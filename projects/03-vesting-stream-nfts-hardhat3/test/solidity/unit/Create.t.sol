// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";

import {IVestingStreams} from "../../../contracts/interfaces/IVestingStreams.sol";
import {FeeOnTransferToken} from "../../../contracts/mocks/FeeOnTransferToken.sol";
import {NoReturnToken} from "../../../contracts/mocks/NoReturnToken.sol";
import {ShareRebasingToken} from "../../../contracts/mocks/ShareRebasingToken.sol";
import {CreateParams, Milestone, Shape, Status, Stream} from "../../../contracts/types/StreamTypes.sol";
import {BaseTest} from "../utils/BaseTest.sol";

/// @notice `create` / `createBatch`: happy paths for every shape and every validation revert.
contract CreateTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
                               HAPPY PATHS
    //////////////////////////////////////////////////////////////*/

    function test_create_linear_storesStreamMintsNftAndPullsDeposit() public {
        CreateParams memory p = _linear(alice, uint128(1200 * E18), T0, T0 + 3 * MONTH, T0 + 12 * MONTH);
        uint256 senderBefore = token.balanceOf(sender);

        vm.expectEmit(address(vesting));
        emit IVestingStreams.StreamCreated(
            1, sender, alice, token, Shape.LinearCliff, uint128(1200 * E18), T0, T0 + 12 * MONTH, true
        );
        vm.expectEmit(address(vesting));
        emit IERC4906.MetadataUpdate(1);
        uint256 id = _create(p);

        assertEq(id, 1);
        assertEq(vesting.nextStreamId(), 2);
        assertEq(vesting.ownerOf(id), alice);
        assertEq(token.balanceOf(address(vesting)), 1200 * E18);
        assertEq(senderBefore - token.balanceOf(sender), 1200 * E18);

        Stream memory s = vesting.getStream(id);
        assertEq(s.sender, sender);
        assertEq(address(s.token), address(token));
        assertEq(uint8(s.shape), uint8(Shape.LinearCliff));
        assertEq(s.startTime, T0);
        assertEq(s.cliffTime, T0 + 3 * MONTH);
        assertEq(s.endTime, T0 + 12 * MONTH);
        assertEq(s.depositAmount, 1200 * E18);
        assertTrue(s.cancelable);
        assertFalse(s.canceled);
        assertEq(s.milestoneCount, 0);
        assertEq(vesting.getMilestones(id).length, 0);
        assertEq(uint8(vesting.statusOf(id)), uint8(Status.Pending));
    }

    function test_create_tranched_storesMilestonesViaSSTORE2() public {
        uint256 id = _createDefaultTranched();
        Stream memory s = vesting.getStream(id);
        assertEq(s.milestoneCount, 12);
        assertEq(s.endTime, T0 + 12 * MONTH);
        assertEq(s.depositAmount, 1200 * E18);
        Milestone[] memory m = vesting.getMilestones(id);
        assertEq(m.length, 12);
        for (uint256 i; i < 12; ++i) {
            assertEq(m[i].amount, 100 * E18);
            assertEq(m[i].timestamp, T0 + MONTH * uint40(i + 1));
        }
    }

    function test_create_segmented_maxSegments() public {
        uint256 id = _create(_withMilestones(alice, Shape.Segmented, T0, _even(16, 1, T0, DAY)));
        assertEq(vesting.getMilestones(id).length, 16);
    }

    function test_create_tranched_maxTranches() public {
        uint256 id = _create(_withMilestones(alice, Shape.Tranched, T0, _even(32, 1, T0, DAY)));
        assertEq(vesting.getMilestones(id).length, 32);
    }

    function test_create_allowsBackdatedStart() public {
        uint256 id = _create(_linear(alice, 1000, T0 - 10 * DAY, 0, T0 + 10 * DAY));
        vm.warp(T0);
        assertEq(vesting.streamedAmountOf(id), 500);
    }

    function test_create_supportsTokensWithoutReturnValues() public {
        NoReturnToken usdt = new NoReturnToken();
        usdt.mint(sender, 1e12);
        vm.startPrank(sender);
        usdt.approve(address(vesting), 1e12);
        uint256 id = vesting.create(IERC20(address(usdt)), _linear(alice, 1e9, T0, 0, T0 + MONTH));
        vm.stopPrank();
        assertEq(usdt.balanceOf(address(vesting)), 1e9);
        vm.warp(T0 + MONTH);
        vm.prank(alice);
        vesting.withdrawMax(id, alice);
        assertEq(usdt.balanceOf(alice), 1e9);
    }

    function test_createBatch_singleTransferForAllStreams() public {
        CreateParams[] memory batch = new CreateParams[](3);
        batch[0] = _linear(alice, 100, T0, 0, T0 + MONTH);
        batch[1] = _withMilestones(bob, Shape.Tranched, T0, _even(3, 10, T0, DAY));
        batch[2] = _withMilestones(eve, Shape.Segmented, T0, _even(2, 7, T0, DAY));

        vm.expectCall(address(token), abi.encodeCall(IERC20.transferFrom, (sender, address(vesting), 144)), 1);
        vm.prank(sender);
        uint256[] memory ids = vesting.createBatch(token, batch);

        assertEq(ids.length, 3);
        assertEq(ids[0], 1);
        assertEq(ids[2], 3);
        assertEq(vesting.ownerOf(2), bob);
        assertEq(token.balanceOf(address(vesting)), 144);
    }

    function test_create_nonCancelable() public {
        CreateParams memory p = _linear(alice, 100, T0, 0, T0 + MONTH);
        p.cancelable = false;
        uint256 id = _create(p);
        assertFalse(vesting.getStream(id).cancelable);
        assertEq(vesting.refundableAmountOf(id), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          ADVERSARIAL TOKENS
    //////////////////////////////////////////////////////////////*/

    function test_create_revertsForFeeOnTransferToken() public {
        FeeOnTransferToken fot = new FeeOnTransferToken(100); // 1 %
        fot.mint(sender, 1e24);
        vm.startPrank(sender);
        fot.approve(address(vesting), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.UnsupportedToken.selector, fot, 1000, 990));
        vesting.create(fot, _linear(alice, 1000, T0, 0, T0 + MONTH));
        vm.stopPrank();
    }

    function test_createBatch_revertsForFeeOnTransferToken() public {
        FeeOnTransferToken fot = new FeeOnTransferToken(1);
        fot.mint(sender, 1e24);
        CreateParams[] memory batch = new CreateParams[](2);
        batch[0] = _linear(alice, 1e18, T0, 0, T0 + MONTH);
        batch[1] = _linear(bob, 1e18, T0, 0, T0 + MONTH);
        vm.startPrank(sender);
        fot.approve(address(vesting), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.UnsupportedToken.selector, fot, 2e18, 2e18 - 2e14));
        vesting.createBatch(fot, batch);
        vm.stopPrank();
    }

    /// A share-based rebasing token that loses a wei to share rounding is rejected.
    function test_create_revertsWhenRebasingTokenDeliversLess() public {
        ShareRebasingToken steth = new ShareRebasingToken();
        steth.mint(sender, 3e18);
        steth.rebase(1); // 3e18 shares now back 3e18 + 1 tokens: transfers round down by one wei
        vm.startPrank(sender);
        steth.approve(address(vesting), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.UnsupportedToken.selector, steth, 1e18, 1e18 - 1));
        vesting.create(IERC20(address(steth)), _linear(alice, 1e18, T0, 0, T0 + MONTH));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_revert_invalidRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.InvalidRecipient.selector, address(0)));
        _create(_linear(address(0), 100, T0, 0, T0 + MONTH));
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.InvalidRecipient.selector, address(vesting)));
        _create(_linear(address(vesting), 100, T0, 0, T0 + MONTH));
    }

    function test_revert_zeroDeposit() public {
        vm.expectRevert(IVestingStreams.ZeroDepositAmount.selector);
        _create(_linear(alice, 0, T0, 0, T0 + MONTH));
    }

    function test_revert_zeroStartTime() public {
        vm.expectRevert(IVestingStreams.ZeroStartTime.selector);
        _create(_linear(alice, 100, 0, 0, T0 + MONTH));
    }

    function test_revert_endTimeNotInFuture() public {
        uint40 nowTs = uint40(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.EndTimeNotInFuture.selector, nowTs, nowTs));
        _create(_linear(alice, 100, nowTs - 10, 0, nowTs));
        Milestone[] memory m = _even(2, 50, nowTs - 100, 50); // last milestone == now
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.EndTimeNotInFuture.selector, nowTs, nowTs));
        _create(_withMilestones(alice, Shape.Tranched, nowTs - 100, m));
    }

    function test_revert_invalidLinearSchedule() public {
        _expectInvalidLinear(T0, 0, T0); // start == end
        _expectInvalidLinear(T0 + 1, 0, T0); // start > end
        _expectInvalidLinear(T0, T0, T0 + MONTH); // cliff == start
        _expectInvalidLinear(T0, T0 + MONTH, T0 + MONTH); // cliff == end
        _expectInvalidLinear(T0, T0 + 2 * MONTH, T0 + MONTH); // cliff after end
    }

    function test_revert_unexpectedMilestonesOnLinear() public {
        CreateParams memory p = _linear(alice, 100, T0, 0, T0 + MONTH);
        p.milestones = _even(1, 100, T0, DAY);
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.UnexpectedMilestones.selector, 1));
        _create(p);
    }

    function test_revert_unexpectedLinearFieldsOnMilestoneShapes() public {
        CreateParams memory p = _withMilestones(alice, Shape.Tranched, T0, _even(2, 50, T0, DAY));
        p.cliffTime = T0 + 1;
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.UnexpectedLinearFields.selector, T0 + 1, 0));
        _create(p);
        p.cliffTime = 0;
        p.endTime = T0 + 2 * DAY;
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.UnexpectedLinearFields.selector, 0, T0 + 2 * DAY));
        _create(p);
    }

    function test_revert_milestoneCountOutOfRange() public {
        _expectCount(Shape.Tranched, 0, 32);
        _expectCount(Shape.Tranched, 33, 32);
        _expectCount(Shape.Segmented, 0, 16);
        _expectCount(Shape.Segmented, 17, 16);
    }

    function test_revert_milestoneNotAfterPrevious() public {
        Milestone[] memory m = _even(3, 10, T0, DAY);
        m[0].timestamp = T0; // not after start
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.MilestoneNotAfterPrevious.selector, 0, T0, T0));
        _create(_withMilestones(alice, Shape.Tranched, T0, m));

        m = _even(3, 10, T0, DAY);
        m[2].timestamp = m[1].timestamp; // not strictly increasing
        vm.expectRevert(
            abi.encodeWithSelector(IVestingStreams.MilestoneNotAfterPrevious.selector, 2, T0 + 2 * DAY, T0 + 2 * DAY)
        );
        _create(_withMilestones(alice, Shape.Segmented, T0, m));
    }

    function test_revert_depositMismatch() public {
        CreateParams memory p = _withMilestones(alice, Shape.Tranched, T0, _even(3, 10, T0, DAY));
        p.depositAmount = 31;
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.DepositMismatch.selector, 31, 30));
        _create(p);
    }

    function test_revert_emptyBatch() public {
        vm.prank(sender);
        vm.expectRevert(IVestingStreams.EmptyBatch.selector);
        vesting.createBatch(token, new CreateParams[](0));
    }

    function test_revert_batchValidatesEveryStream() public {
        CreateParams[] memory batch = new CreateParams[](2);
        batch[0] = _linear(alice, 100, T0, 0, T0 + MONTH);
        batch[1] = _linear(bob, 0, T0, 0, T0 + MONTH);
        vm.prank(sender);
        vm.expectRevert(IVestingStreams.ZeroDepositAmount.selector);
        vesting.createBatch(token, batch);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _expectInvalidLinear(uint40 start, uint40 cliff, uint40 end) internal {
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.InvalidLinearSchedule.selector, start, cliff, end));
        _create(_linear(alice, 100, start, cliff, end));
    }

    function _expectCount(Shape shape, uint256 count, uint256 maxCount) internal {
        CreateParams memory p = _withMilestones(alice, shape, T0, _even(count, 1, T0, DAY));
        if (count == 0) p.depositAmount = 1;
        vm.expectRevert(
            abi.encodeWithSelector(IVestingStreams.MilestoneCountOutOfRange.selector, shape, count, maxCount)
        );
        _create(p);
    }
}
