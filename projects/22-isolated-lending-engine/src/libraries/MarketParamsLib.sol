// SPDX-License-Identifier: GPL-2.0-or-later
// Adapted from Morpho Blue by Morpho Labs, https://github.com/morpho-org/morpho-blue (GPL-2.0-or-later),
// src/libraries/MarketParamsLib.sol: the id derivation follows the original; the NatSpec is new. Modified for this
// project in 2026; see the README's License section.
pragma solidity 0.8.37;

import {Id, MarketParams} from "../interfaces/ILendingEngine.sol";

/// @title MarketParamsLib
/// @notice Derives the market id from its parameters.
library MarketParamsLib {
    /// @dev `MarketParams` is five static words, so its ABI encoding is exactly 160 bytes.
    uint256 internal constant MARKET_PARAMS_BYTES_LENGTH = 5 * 32;

    /// @notice `keccak256(abi.encode(loanToken, collateralToken, oracle, irm, lltv))`.
    /// @param marketParams The market definition.
    /// @return marketParamsId The market id.
    function id(MarketParams memory marketParams) internal pure returns (Id marketParamsId) {
        // Safe: the struct is five static 32-byte words laid out contiguously in memory, so hashing
        // `MARKET_PARAMS_BYTES_LENGTH` bytes from its pointer equals `keccak256(abi.encode(marketParams))`
        // without copying. The block only reads memory.
        assembly ("memory-safe") {
            marketParamsId := keccak256(marketParams, MARKET_PARAMS_BYTES_LENGTH)
        }
    }
}
