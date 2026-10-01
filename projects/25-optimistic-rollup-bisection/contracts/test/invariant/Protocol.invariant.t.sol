// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console2} from "forge-std/console2.sol";
import {SystemFixture} from "../utils/SystemFixture.sol";
import {ProtocolHandler} from "./ProtocolHandler.sol";
import {DisputeGame} from "../../src/DisputeGame.sol";
import {IDisputeGame} from "../../src/interfaces/IDisputeGame.sol";
import {IOutputOracle} from "../../src/interfaces/IOutputOracle.sol";

/// @notice Stateful invariants of the bond vault and the dispute game (README section "Invariants").
contract ProtocolInvariantTest is SystemFixture {
    ProtocolHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new ProtocolHandler(osvm, inbox, oracle, game, sequencer);
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = ProtocolHandler.propose.selector;
        selectors[1] = ProtocolHandler.challenge.selector;
        selectors[2] = ProtocolHandler.move.selector;
        selectors[3] = ProtocolHandler.playOut.selector;
        selectors[4] = ProtocolHandler.playOut.selector; // weighted: games should often reach their leaves
        selectors[5] = ProtocolHandler.warp.selector;
        selectors[6] = ProtocolHandler.warpPastWindow.selector;
        selectors[7] = ProtocolHandler.timeout.selector;
        selectors[8] = ProtocolHandler.cancel.selector;
        selectors[9] = ProtocolHandler.finalize.selector;
        selectors[10] = ProtocolHandler.reclaim.selector;
        selectors[11] = ProtocolHandler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice I1: the oracle's ETH balance always equals locked bonds + unclaimed credit + burned amount.
    function invariant_I1_vaultIsFullyBacked() public view {
        assertEq(address(oracle).balance, oracle.lockedBonds() + oracle.totalCredit() + oracle.totalBurned());
    }

    /// @notice I2: no wei is created or lost: everything bonded is either still held or was paid out.
    function invariant_I2_bondConservation() public view {
        assertEq(handler.ghostDeposited(), address(oracle).balance + handler.ghostPaidOut());
        assertEq(address(game).balance, 0, "the game never holds ETH");
    }

    /// @notice I3: the burn is exactly 10% of every forfeited bond.
    function invariant_I3_burnIsTenPercentOfForfeits() public view {
        uint256 forfeited;
        for (uint256 i = 0; i < handler.gameCount(); ++i) {
            DisputeGame.Game memory g = game.getGame(handler.gameIds(i));
            if (g.outcome == IOutputOracle.Outcome.ChallengerWins) forfeited += PROPOSER_BOND;
            if (g.outcome == IOutputOracle.Outcome.DefenderWins) forfeited += CHALLENGER_BOND;
        }
        assertEq(oracle.totalBurned(), forfeited / 10);
    }

    /// @notice I4: a game never takes more than 2 * MAX_DEPTH + 2 moves.
    function invariant_I4_movesBoundedByDepth() public view {
        for (uint256 i = 0; i < handler.gameCount(); ++i) {
            assertLe(game.getGame(handler.gameIds(i)).moves, 2 * uint256(MAX_DEPTH) + 2);
        }
    }

    /// @notice I5: every open game can be timed out no later than createdAt + 2 * CLOCK (chess clocks).
    function invariant_I5_gameTerminatesWithinTwoClocks() public view {
        for (uint256 i = 0; i < handler.gameCount(); ++i) {
            uint256 id = handler.gameIds(i);
            DisputeGame.Game memory g = game.getGame(id);
            if (g.phase == IDisputeGame.Phase.Resolved) continue;
            assertLe(game.deadline(id), uint256(g.createdAt) + 2 * uint256(CLOCK));
            assertLe(g.hi - g.lo, uint64(1) << MAX_DEPTH);
        }
    }

    /// @notice I6: finalization is contiguous, never passes the canonical head, and finalized outputs stay final.
    function invariant_I6_finalizedPrefix() public view {
        uint64 last = oracle.lastFinalizedEpoch();
        assertLt(last, oracle.nextEpoch());
        for (uint64 e = 1; e <= last; ++e) {
            assertEq(
                uint8(oracle.getProposal(oracle.proposalIdAt(e)).status), uint8(IOutputOracle.ProposalStatus.Finalized)
            );
        }
    }

    /// @notice Reports how the run ended (visible with -vv): games resolved by one-step proof vs. timeout.
    function afterInvariant() public view {
        console2.log("games", handler.gameCount(), "one-step proofs", handler.ghostStepsExecuted());
        console2.log("timeouts", handler.ghostTimeouts(), "finalized", handler.ghostFinalized());
    }
}
