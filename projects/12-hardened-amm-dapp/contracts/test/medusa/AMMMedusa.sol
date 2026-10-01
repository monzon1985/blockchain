// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {AMMSystem} from "../invariant/AMMSystem.sol";

/// @notice Medusa harness: the same system, actions and invariants as the Foundry invariant suite
///         (test/invariant/AMMSystem.sol). The nine invariants are `property_*` functions; the 13 actions are
///         assertion tests (each `assert`s its own postconditions and fails on any unexpected revert).
/// @dev Run with `medusa fuzz --config medusa.json --timeout 300`. `testViewMethods` is off, so view functions
///      (getters, `check*`) are not counted as assertion tests: they cannot fail.
contract AMMMedusa is AMMSystem {
    /// @notice Emitted right before the assertion failure, so the failing sequence shows the original revert data.
    /// @param reason Revert data of the router or pair call.
    event UnexpectedRevert(bytes reason);

    constructor() {
        _deploySystem();
    }

    /// @dev A plain revert is not a Medusa failure: turn an unexpected one into an assertion failure.
    function _onUnexpectedRevert(bytes memory reason) internal override {
        emit UnexpectedRevert(reason);
        assert(false);
    }

    function property_kNeverDecreasesExceptOnBurn() external view returns (bool) {
        return checkKNeverDecreasesExceptOnBurn();
    }

    function property_lpSupplyOnlyDropsOnBurn() external view returns (bool) {
        return checkLpSupplyOnlyDropsOnBurn();
    }

    function property_reservesNeverExceedBalances() external view returns (bool) {
        return checkReservesNeverExceedBalances();
    }

    function property_roundTripSwapsNeverProfit() external view returns (bool) {
        return checkRoundTripNeverProfits();
    }

    function property_lpShareValueNeverDecreases() external view returns (bool) {
        return checkShareValueNeverDecreases();
    }

    function property_minimumLiquidityLockedForever() external view returns (bool) {
        return checkMinimumLiquidityLockedForever();
    }

    function property_routerHoldsNothing() external view returns (bool) {
        return checkRouterHoldsNothing();
    }

    function property_lpSupplyEqualsSumOfHolders() external view returns (bool) {
        return checkLpSupplyEqualsSumOfHolders();
    }

    function property_lockReleasedBetweenTransactions() external view returns (bool) {
        return checkLockReleasedBetweenTransactions();
    }
}
