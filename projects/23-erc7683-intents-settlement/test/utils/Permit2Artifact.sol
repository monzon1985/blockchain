// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

// Pulls Permit2 into the build with its own pinned compiler (0.8.17, via-IR, 1M runs; see foundry.toml), so tests
// can `deployCode("Permit2.sol:Permit2")` and the TypeScript e2e can deploy the same artifact on anvil.
import {Permit2} from "permit2/src/Permit2.sol";

/// @notice Anchor contract; exists only so this compilation unit has a definition of its own.
abstract contract Permit2Artifact is Permit2 {}
