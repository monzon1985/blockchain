// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Makes `forge build` emit the eth-infinitism v0.9 artifacts that bundler-lite and the local devnet use:
// - EntryPoint: deployed on anvil by bundler/src/devnet/deploy.ts.
// - EntryPointSimulations: never deployed; bundler-lite passes its runtime code as an eth_call state override at the
//   EntryPoint address (the documented simulation pattern for EntryPoint v0.7+).
// - Simple7702Account: baseline in the gas benchmark and a benign sample of the classifier corpus.
import {Simple7702Account} from "account-abstraction/accounts/Simple7702Account.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {EntryPointSimulations} from "account-abstraction/core/EntryPointSimulations.sol";

/// @notice Anchor declaration so this import-only unit has an AST node of its own.
abstract contract DevnetArtifacts {}
