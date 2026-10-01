// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {VolatilityFeeHook} from "../../../src/VolatilityFeeHook.sol";

/// @notice The same hook with one permission bit missing from its declaration (and therefore from its mined
/// address): it still returns a surcharge delta from afterSwap, but without AFTER_SWAP_RETURNS_DELTA the PoolManager
/// ignores that delta. This is the class of bug Trail of Bits reports for Sorella's Angstrom (a missing
/// afterSwapReturnDelta permission made swaps revert).
contract MissingReturnDeltaHook is VolatilityFeeHook {
    constructor(IPoolManager manager, address initialOwner, FeeConfig memory config)
        VolatilityFeeHook(manager, initialOwner, config)
    {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions = super.getHookPermissions();
        permissions.afterSwapReturnDelta = false;
    }
}
