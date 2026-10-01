// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {Test, console2} from "forge-std/Test.sol";

import {AMMSystem} from "./AMMSystem.sol";

/// @notice Foundry handler: the shared system with its actions as fuzz targets.
contract AMMHandler is AMMSystem {
    constructor() {
        _deploySystem();
    }
}

/// @notice Stateful invariants of the hardened AMM (the same checks run under Medusa, see test/medusa).
contract AMMInvariantTest is Test {
    /// @dev Attempts after which a run must have at least one success (see afterInvariant).
    uint256 internal constant MIN_ATTEMPTS = 8;

    AMMHandler internal handler;

    function setUp() public {
        handler = new AMMHandler();
        targetContract(address(handler));
    }

    /// @dev I-1: k = reserve0 * reserve1 never decreases, except on burn.
    function invariant_kNeverDecreasesExceptOnBurn() public view {
        assertTrue(handler.checkKNeverDecreasesExceptOnBurn());
    }

    /// @dev I-2: the LP supply only drops on burn.
    function invariant_lpSupplyOnlyDropsOnBurn() public view {
        assertTrue(handler.checkLpSupplyOnlyDropsOnBurn());
    }

    /// @dev I-3: reserves never exceed the pair's token balances.
    function invariant_reservesNeverExceedBalances() public view {
        assertTrue(handler.checkReservesNeverExceedBalances());
    }

    /// @dev I-4: swapping A -> B -> A through the same pair never returns more than was put in.
    function invariant_roundTripSwapsNeverProfit() public view {
        assertTrue(handler.checkRoundTripNeverProfits());
    }

    /// @dev I-5: sqrt(k) per LP share never decreases, except for the protocol-fee mint.
    function invariant_lpShareValueNeverDecreases() public view {
        assertTrue(handler.checkShareValueNeverDecreases());
    }

    /// @dev I-6: MINIMUM_LIQUIDITY stays locked at address(0) in every pair.
    function invariant_minimumLiquidityLockedForever() public view {
        assertTrue(handler.checkMinimumLiquidityLockedForever());
    }

    /// @dev I-7: the router never holds tokens or LP tokens between transactions.
    function invariant_routerHoldsNothing() public view {
        assertTrue(handler.checkRouterHoldsNothing());
    }

    /// @dev I-8: LP totalSupply equals the sum of all holder balances.
    function invariant_lpSupplyEqualsSumOfHolders() public view {
        assertTrue(handler.checkLpSupplyEqualsSumOfHolders());
    }

    /// @dev I-9: the transient reentrancy lock is never left held.
    function invariant_lockReleasedBetweenTransactions() public view {
        assertTrue(handler.checkLockReleasedBetweenTransactions());
    }

    /// @dev Non-vacuity guard, checked at the end of every run. The handler swallows expected reverts (dust that rounds
    ///      to zero, an exact output above the reserve, ...), so a regression that made every swap or every burn
    ///      revert with one of those errors would leave I-1 to I-9 green. A run that attempted an operation
    ///      MIN_ATTEMPTS times must have executed it at least once. (Measured success rates with the fixed seed:
    ///      about 90 % for swaps, 80 % for exact-output swaps, 96 % for burns, so a false alarm needs 8 expected
    ///      reverts in a row: below 1e-5 per run.)
    function afterInvariant() external view {
        console2.log("swaps executed / attempted:", handler.swapsExecuted(), handler.swapAttempts());
        console2.log("exact-out swaps executed / attempted:", handler.exactOutExecuted(), handler.exactOutAttempts());
        console2.log("burns executed / attempted:", handler.burnsExecuted(), handler.burnAttempts());
        console2.log("round trips:", handler.roundTrips());
        assertTrue(
            handler.checkNotVacuous(MIN_ATTEMPTS), "an operation was attempted MIN_ATTEMPTS times, none succeeded"
        );
    }
}
