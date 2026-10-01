// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LendingSystem} from "../invariant/LendingSystem.sol";

/// @notice Medusa target. It inherits the Foundry invariant handler unchanged, so both fuzzers explore the same
///         action space (three token-sharing markets, price shocks, time jumps, liquidations, flash loans) and check
///         the same `property_*` functions. Medusa additionally randomizes block timestamps between calls.
contract LendingProperties is LendingSystem {
    /// @notice Gives this contract bytecode distinct from `LendingSystem`. Medusa matches deployed code to contract
    ///         definitions by bytecode; with two identical definitions it could attribute the deployment to
    ///         `LendingSystem`, which is not a target, and silently never run the property tests.
    string public constant FUZZ_TARGET = "medusa:LendingProperties";
}
