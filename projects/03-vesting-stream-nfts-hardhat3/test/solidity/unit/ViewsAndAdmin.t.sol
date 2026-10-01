// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {StreamRenderer} from "../../../contracts/StreamRenderer.sol";
import {VestingStreams} from "../../../contracts/VestingStreams.sol";
import {IStreamRenderer} from "../../../contracts/interfaces/IStreamRenderer.sol";
import {IVestingStreams} from "../../../contracts/interfaces/IVestingStreams.sol";
import {Milestone, Shape, Status} from "../../../contracts/types/StreamTypes.sol";
import {BaseTest} from "../utils/BaseTest.sol";

/// @notice Status machine, view functions, ERC-165 and the owner-only renderer switch.
contract ViewsAndAdminTest is BaseTest {
    function test_status_lifecycleOfALinearStream() public {
        uint256 id = _createDefaultLinear();
        assertEq(uint8(vesting.statusOf(id)), uint8(Status.Pending));
        vm.warp(T0);
        assertEq(uint8(vesting.statusOf(id)), uint8(Status.Streaming));
        vm.warp(T0 + 12 * MONTH);
        assertEq(uint8(vesting.statusOf(id)), uint8(Status.Settled));
        vm.prank(alice);
        vesting.withdrawMax(id, alice);
        assertEq(uint8(vesting.statusOf(id)), uint8(Status.Depleted));
    }

    function test_status_settledAsSoonAsEverythingVested() public {
        // The last tranche is empty: everything has vested one month before the end time.
        Milestone[] memory m = new Milestone[](2);
        m[0] = Milestone({amount: 100, timestamp: T0 + MONTH});
        m[1] = Milestone({amount: 0, timestamp: T0 + 2 * MONTH});
        uint256 id = _create(_withMilestones(alice, Shape.Tranched, T0, m));
        vm.warp(T0 + MONTH);
        assertEq(uint8(vesting.statusOf(id)), uint8(Status.Settled));
    }

    function test_status_canceledThenDepleted() public {
        uint256 id = _createDefaultLinear();
        vm.warp(T0 + 6 * MONTH);
        vm.prank(sender);
        vesting.cancel(id);
        assertEq(uint8(vesting.statusOf(id)), uint8(Status.Canceled));
        vm.prank(alice);
        vesting.withdrawMax(id, alice);
        assertEq(uint8(vesting.statusOf(id)), uint8(Status.Depleted));
    }

    function test_scheduledAmountAt_tracksTheCurveForEveryShape() public {
        uint256 linearId = _createDefaultLinear();
        uint256 tranchedId = _createDefaultTranched();
        uint256 segmentedId = _createDefaultSegmented();

        assertEq(vesting.scheduledAmountAt(linearId, T0 + 3 * MONTH - 1), 0);
        assertEq(vesting.scheduledAmountAt(linearId, T0 + 3 * MONTH), 300 * E18);
        assertEq(vesting.scheduledAmountAt(tranchedId, T0 + 5 * MONTH - 1), 400 * E18);
        assertEq(vesting.scheduledAmountAt(tranchedId, T0 + 5 * MONTH), 500 * E18);
        assertEq(vesting.scheduledAmountAt(segmentedId, T0), 0);
        assertEq(vesting.scheduledAmountAt(segmentedId, T0 + MONTH), 500 * E18);
        assertEq(vesting.scheduledAmountAt(segmentedId, T0 + 3 * MONTH), 1000 * E18);
        assertEq(vesting.scheduledAmountAt(segmentedId, T0 + 7 * MONTH), 2500 * E18);
        assertEq(vesting.scheduledAmountAt(segmentedId, T0 + 10 * MONTH), 4000 * E18);
    }

    function test_scheduledAmountAt_ignoresCancellation() public {
        uint256 id = _createDefaultLinear();
        vm.warp(T0 + 6 * MONTH);
        vm.prank(sender);
        vesting.cancel(id);
        assertEq(vesting.streamedAmountOf(id), 600 * E18);
        assertEq(vesting.scheduledAmountAt(id, T0 + 12 * MONTH), 1200 * E18);
    }

    function test_refundableAmountOf() public {
        uint256 id = _createDefaultLinear();
        vm.warp(T0 + 6 * MONTH);
        assertEq(vesting.refundableAmountOf(id), 600 * E18);
    }

    function test_revert_viewsOnUnknownStream() public {
        vm.expectRevert(_err(IVestingStreams.StreamNotFound.selector, 1));
        vesting.getStream(1);
        vm.expectRevert(_err(IVestingStreams.StreamNotFound.selector, 1));
        vesting.getMilestones(1);
        vm.expectRevert(_err(IVestingStreams.StreamNotFound.selector, 1));
        vesting.streamedAmountOf(1);
        vm.expectRevert(_err(IVestingStreams.StreamNotFound.selector, 1));
        vesting.withdrawableAmountOf(1);
        vm.expectRevert(_err(IVestingStreams.StreamNotFound.selector, 1));
        vesting.refundableAmountOf(1);
        vm.expectRevert(_err(IVestingStreams.StreamNotFound.selector, 1));
        vesting.statusOf(1);
        vm.expectRevert(_err(IVestingStreams.StreamNotFound.selector, 1));
        vesting.scheduledAmountAt(1, T0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        vesting.tokenURI(1);
    }

    function test_supportsInterface() public view {
        assertTrue(vesting.supportsInterface(0x49064906)); // ERC-4906
        assertTrue(vesting.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(vesting.supportsInterface(0x5b5e139f)); // ERC-721 Metadata
        assertTrue(vesting.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(vesting.supportsInterface(0xffffffff));
    }

    function test_metadataConstants() public view {
        assertEq(vesting.name(), "Vesting Streams");
        assertEq(vesting.symbol(), "VEST");
        assertEq(vesting.RECIPIENT_HOOK_GAS(), 100_000);
        assertEq(vesting.MAX_TRANCHES(), 32);
        assertEq(vesting.MAX_SEGMENTS(), 16);
        assertEq(address(vesting.renderer()), address(renderer));
        assertEq(vesting.owner(), owner);
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_setRenderer_refreshesAllMetadata() public {
        _createDefaultLinear();
        _createDefaultTranched();
        StreamRenderer next = new StreamRenderer();
        vm.expectEmit(address(vesting));
        emit IVestingStreams.RendererUpdated(renderer, next);
        vm.expectEmit(address(vesting));
        emit IERC4906.BatchMetadataUpdate(1, 2);
        vm.prank(owner);
        vesting.setRenderer(next);
        assertEq(address(vesting.renderer()), address(next));
    }

    function test_setRenderer_noBatchEventWithoutStreams() public {
        StreamRenderer next = new StreamRenderer();
        vm.recordLogs();
        vm.prank(owner);
        vesting.setRenderer(next);
        assertEq(vm.getRecordedLogs().length, 1); // RendererUpdated only
    }

    function test_revert_setRenderer_onlyOwner() public {
        StreamRenderer next = new StreamRenderer();
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        vesting.setRenderer(next);
    }

    function test_revert_setRenderer_mustBeContract() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.InvalidRenderer.selector, eve));
        vesting.setRenderer(IStreamRenderer(eve));
    }

    function test_revert_constructor_rendererMustBeContract() public {
        vm.expectRevert(abi.encodeWithSelector(IVestingStreams.InvalidRenderer.selector, address(0)));
        new VestingStreams(IStreamRenderer(address(0)), owner);
    }

    function test_ownership_isTwoStep() public {
        vm.prank(owner);
        vesting.transferOwnership(alice);
        assertEq(vesting.owner(), owner);
        assertEq(vesting.pendingOwner(), alice);
        vm.prank(alice);
        vesting.acceptOwnership();
        assertEq(vesting.owner(), alice);
    }
}
