// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Namespace probes for the layout gate.
//
// `forge inspect <C> storageLayout` lists sequential state variables only: ERC-7201 namespaced structs are
// invisible to it. Each probe below declares ONE state variable of a namespace struct and pins it, with
// Solidity's `layout at` specifier (0.8.29+), at the slot ERC-7201 assigns to its id. `forge inspect` on the
// probe then reports the struct at its absolute slot, member by member. scripts/check-layouts.mjs discovers
// which namespaces a contract's code declares or reaches (from the `@custom:storage-location` annotations in the
// AST, libraries included), looks up the probe of each struct, and also resolves from the AST the slot every
// production accessor assigns (`$.slot := ...`). layout-diff recomputes the ERC-7201 formula for the id and checks
// both the probe and every accessor against it, so a probe only supplies the member layout: a wrong accessor is
// caught even though its probe is right.
//
// Probes of the lab's own namespaces reuse the production location constants. OpenZeppelin keeps its constants
// private, so its probes use the `erc7201` builtin on the id; the gate reads OpenZeppelin's real constants from
// the AST of the dependency (they are the accessors' slots), and Erc7201Formula.t.sol observes the slots the
// OpenZeppelin parents actually write.
//
// Probes are never deployed.

import {DIAMOND_STORAGE_LOCATION, LibDiamond} from "../../src/diamond/libraries/LibDiamond.sol";
import {LibOwnership, OWNERSHIP_STORAGE_LOCATION} from "../../src/diamond/libraries/LibOwnership.sol";
import {
    DIAMOND_REGISTRY_STORAGE_LOCATION,
    LibRegistryDiamond
} from "../../src/diamond/libraries/LibRegistryDiamond.sol";
import {
    REGISTRY_STORAGE_LOCATION,
    RegistryNamespaceV2,
    RegistryNamespaceV3
} from "../../src/uups/RegistryNamespace.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

// ---------------------------------------------------------------- OpenZeppelin 5.7.0

contract OzInitializableProbe layout at erc7201("openzeppelin.storage.Initializable") {
    Initializable.InitializableStorage internal $;
}

contract OzOwnableProbe layout at erc7201("openzeppelin.storage.Ownable") {
    OwnableUpgradeable.OwnableStorage internal $;
}

contract OzOwnable2StepProbe layout at erc7201("openzeppelin.storage.Ownable2Step") {
    Ownable2StepUpgradeable.Ownable2StepStorage internal $;
}

contract OzPausableProbe layout at erc7201("openzeppelin.storage.Pausable") {
    PausableUpgradeable.PausableStorage internal $;
}

contract OzAccessManagedProbe layout at erc7201("openzeppelin.storage.AccessManaged") {
    AccessManagedUpgradeable.AccessManagedStorage internal $;
}

// ---------------------------------------------------------------- UUPS lineage

contract RegistryV2NamespaceProbe layout at REGISTRY_STORAGE_LOCATION {
    RegistryNamespaceV2.RegistryStorage internal $;
}

contract RegistryV3NamespaceProbe layout at REGISTRY_STORAGE_LOCATION {
    RegistryNamespaceV3.RegistryStorage internal $;
}

// ---------------------------------------------------------------- Diamond

contract DiamondTableProbe layout at DIAMOND_STORAGE_LOCATION {
    LibDiamond.DiamondStorage internal $;
}

contract DiamondOwnershipProbe layout at OWNERSHIP_STORAGE_LOCATION {
    LibOwnership.OwnershipStorage internal $;
}

contract DiamondRegistryProbe layout at DIAMOND_REGISTRY_STORAGE_LOCATION {
    LibRegistryDiamond.RegistryStorage internal $;
}
