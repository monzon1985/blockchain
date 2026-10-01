// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CumulativeMerkleDistributor} from "../../src/CumulativeMerkleDistributor.sol";
import {DistributorHandler} from "./DistributorHandler.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Stateful invariants of the distributor. Each invariant is listed, in plain English, in the README.
contract DistributorInvariants is Test {
    CumulativeMerkleDistributor internal distributor;
    DistributorHandler internal handler;

    function setUp() public {
        vm.warp(1_750_000_000);
        address updater = makeAddr("updater");
        address guardian = makeAddr("guardian");
        distributor = new CumulativeMerkleDistributor(makeAddr("owner"), updater, guardian);
        handler = new DistributorHandler(distributor, updater, guardian);

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = DistributorHandler.proposeRoot.selector;
        selectors[1] = DistributorHandler.proposeRoot.selector; // weighted: roots drive everything else
        selectors[2] = DistributorHandler.revokePendingRoot.selector;
        selectors[3] = DistributorHandler.acceptRoot.selector;
        selectors[4] = DistributorHandler.acceptRoot.selector;
        selectors[5] = DistributorHandler.warp.selector;
        selectors[6] = DistributorHandler.claim.selector;
        selectors[7] = DistributorHandler.claimFor.selector;
        selectors[8] = DistributorHandler.claimMany.selector;
        selectors[9] = DistributorHandler.invalidateNonce.selector;
        selectors[10] = DistributorHandler.claimInflated.selector;
        selectors[11] = DistributorHandler.claimStale.selector;
        selectors[12] = DistributorHandler.claimForWithReplayedSignature.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice The campaign is not vacuous: a fixed 400-step pseudo-random walk over the same handler reaches every
    ///         action, accepts several roots (corrective ones that lower pairs below what they claimed included), has
    ///         early accepts rejected, pays through all three claim paths and sees every hostile action rejected.
    function test_handlerWalkReachesEveryAction() public {
        for (uint256 i; i < 400; ++i) {
            uint256 r = uint256(keccak256(abi.encode("walk", i)));
            uint256 a = uint256(keccak256(abi.encode(r)));
            uint256 b = uint256(keccak256(abi.encode(a)));
            uint256 action = r % 12;
            if (action < 2) handler.proposeRoot(a);
            else if (action == 2) handler.acceptRoot(a, b);
            else if (action == 3) handler.warp(a);
            else if (action == 4) handler.claim(a, b);
            else if (action == 5) handler.claimFor(a, b, r);
            else if (action == 6) handler.claimMany(a, b);
            else if (action == 7) handler.invalidateNonce(a);
            else if (action == 8) handler.claimInflated(a, b);
            else if (action == 9) handler.claimStale(a);
            else if (action == 10) handler.claimForWithReplayedSignature(a);
            else if (b % 4 == 0) handler.revokePendingRoot();
            else handler.acceptRoot(a, b);
        }
        string[11] memory actions = [
            "proposeRoot",
            "revokePendingRoot",
            "acceptRoot",
            "warp",
            "claim",
            "claimFor",
            "claimMany",
            "invalidateNonce",
            "claimInflated",
            "claimStale",
            "claimForReplay"
        ];
        for (uint256 i; i < actions.length; ++i) {
            assertGt(handler.calls(actions[i]), 0, actions[i]);
        }
        assertGe(handler.ghostAccepted(), 5, "several root rotations");
        assertGt(handler.ghostEarlyAcceptsRejected(), 0, "acceptRoot tried inside the timelock");
        assertGt(handler.ghostLoweringAccepted(), 0, "a corrective root that lowers pairs went live");
        assertGt(handler.ghostPairsLoweredBelowClaimed(), 0, "a pair was lowered below what it had claimed");
        assertGt(handler.ghostSignedClaims(), 0, "claimFor paid");
        assertGt(handler.ghostHostileRejected(), 0, "hostile actions rejected");
        assertGt(handler.sumClaimed(0) + handler.sumClaimed(1), 0, "tokens paid out");
        invariant_balanceEqualsFundedMinusClaimed();
        invariant_claimedNeverExceedsFunded();
        invariant_claimedWithinActiveRoot();
        invariant_claimedOnlyIncreases();
        invariant_claimedEqualsReportedPayouts();
        invariant_rootOnlyThroughTimelock();
        invariant_pendingRootMatchesModel();
        invariant_noncesCountAuthorizations();
    }

    /// I-1 Solvency, exact: the vault holds precisely what was funded minus what was claimed, per token.
    function invariant_balanceEqualsFundedMinusClaimed() public view {
        for (uint256 t; t < 2; ++t) {
            address token = address(handler.tokens(t));
            assertEq(
                handler.tokens(t).balanceOf(address(distributor)),
                handler.ghostFunded(token) - handler.sumClaimed(t),
                "balance != funded - claimed"
            );
        }
    }

    /// I-2 Sum of claimed per token never exceeds what was funded.
    function invariant_claimedNeverExceedsFunded() public view {
        for (uint256 t; t < 2; ++t) {
            assertLe(handler.sumClaimed(t), handler.ghostFunded(address(handler.tokens(t))));
        }
    }

    /// I-3 Claims stay inside the active root: since it was accepted, a pair has been paid at most up to its leaf, so
    ///     claimed <= max(leaf, claimed when the root was accepted), per pair and summed per token. With monotonic roots
    ///     (what tree-builder produces) this is claimed <= leaf; a corrective root that lowers a pair below what it
    ///     already claimed pays that pair nothing (claimed stays above the leaf, see I-4).
    function invariant_claimedWithinActiveRoot() public view {
        for (uint256 t; t < 2; ++t) {
            assertLe(handler.sumClaimed(t), handler.sumCeiling(t), "sum claimed > sum of active ceilings");
        }
        for (uint256 p; p < handler.PAIRS(); ++p) {
            assertLe(
                distributor.claimed(handler.pairAccount(p), handler.pairToken(p)),
                handler.claimCeiling(p),
                "pair paid beyond its leaf under the active root"
            );
        }
    }

    /// I-4 claimed[account][token] only increases, across claims and across root rotations, lowering roots included
    ///     (also asserted after every handler action).
    function invariant_claimedOnlyIncreases() public view {
        for (uint256 p; p < handler.PAIRS(); ++p) {
            assertGe(distributor.claimed(handler.pairAccount(p), handler.pairToken(p)), handler.ghostClaimedSnapshot(p));
        }
    }

    /// I-5 Every unit recorded as claimed was transferred by a claim that reported it (no silent accounting).
    function invariant_claimedEqualsReportedPayouts() public view {
        for (uint256 t; t < 2; ++t) {
            assertEq(handler.sumClaimed(t), handler.ghostPaid(address(handler.tokens(t))));
        }
    }

    /// I-6 The active root only changes through acceptRoot, at least ROOT_TIMELOCK after it was proposed, and the epoch
    ///     counter counts exactly the accepted roots. The handler attempts acceptRoot at arbitrary times (now, one
    ///     second before the deadline, at it, after it), so the minimum delay below is whatever the contract allowed;
    ///     the handler also requires success exactly when the model says the timelock has elapsed.
    function invariant_rootOnlyThroughTimelock() public view {
        assertEq(distributor.root(), handler.activeRoot());
        assertEq(distributor.epoch(), handler.ghostAccepted());
        if (handler.ghostAccepted() > 0) assertGe(handler.ghostMinAcceptDelay(), distributor.ROOT_TIMELOCK());
    }

    /// I-7 The pending root on-chain is exactly the last proposal that was neither revoked nor accepted, with
    ///     validAt = proposal time + ROOT_TIMELOCK.
    function invariant_pendingRootMatchesModel() public view {
        (bytes32 pending,, uint64 validAt) = distributor.pendingRoot();
        if (handler.hasPending()) {
            assertEq(pending, handler.pendingRoot());
            assertEq(validAt, handler.pendingProposedAt() + distributor.ROOT_TIMELOCK());
        } else {
            assertEq(pending, bytes32(0));
            assertEq(validAt, 0);
        }
    }

    /// I-8 Nonces advance by exactly one per successful claimFor or invalidateNonce, so a signature is usable once.
    function invariant_noncesCountAuthorizations() public view {
        assertEq(handler.sumNonces(), handler.ghostSignedClaims() + handler.ghostInvalidations());
    }
}
