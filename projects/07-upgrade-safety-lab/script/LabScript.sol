// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {UpgradeGovernance} from "./UpgradeGovernance.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Script} from "forge-std/Script.sol";

/// @notice The UUPS upgrade entry point (OZ 4.9.6 and 5.7.0 share it).
interface IUUPS {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @notice The read API every stage of the UUPS lineage serves (V1, bridge, V2, V3).
interface IRegistryRead {
    function version() external view returns (string memory);
    function owner() external view returns (address);
    function planCount() external view returns (uint256);
    function plan(uint256 planId) external view returns (uint64 duration, bool active);
    function subscriptionOf(address subscriber) external view returns (uint256 planId, uint64 expiresAt);
    function totalSubscriptions() external view returns (uint64);
}

/// @title LabScript
/// @notice Shared plumbing of the deployment scripts: per-chain deployment records under `deployments/<chainId>/`
///         and the post-upgrade checks (ERC-1967 implementation slot, empty admin slot, version, owner and the
///         storage sentinels written at V1 time).
/// @dev Scripts sign with a keystore (`--keystore <file> --password-file <file> --sender <address>`); no raw
///      private key ever appears in a command line or a file of this repository.
abstract contract LabScript is Script {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant LEGACY_INITIALIZABLE_SLOT = bytes32(uint256(0));
    bytes32 internal constant LEGACY_OWNER_SLOT = bytes32(uint256(51));
    bytes32 internal constant OZ_INITIALIZABLE_SLOT = bytes32(erc7201("openzeppelin.storage.Initializable"));
    bytes32 internal constant OZ_OWNABLE_SLOT = bytes32(erc7201("openzeppelin.storage.Ownable"));

    uint32 internal constant UPGRADE_DELAY = UpgradeGovernance.UPGRADE_DELAY;

    error ImplementationSlotMismatch(address expected, address actual);
    error AdminSlotNotEmpty(bytes32 value);
    error VersionMismatch(string expected, string actual);
    error OwnerMismatch(address expected, address actual);
    error SentinelMismatch(string what, uint256 expected, uint256 actual);
    error LegacySlotNotZero(bytes32 slot, bytes32 value);
    error InitializedVersionMismatch(uint64 expected, uint64 actual);
    error GovernanceMismatch(string what);

    function _dir() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid));
    }

    function _file(string memory name) internal view returns (string memory) {
        return string.concat(_dir(), "/", name, ".json");
    }

    function _json(string memory name) internal view returns (string memory) {
        return vm.readFile(_file(name));
    }

    function _address(string memory name, string memory key) internal view returns (address) {
        return vm.parseJsonAddress(_json(name), string.concat(".", key));
    }

    function _uint(string memory name, string memory key) internal view returns (uint256) {
        return vm.parseJsonUint(_json(name), string.concat(".", key));
    }

    /// @notice Checks what an upgrade must never break, against whatever state the script sees (the simulated
    ///         state during a broadcast run, the live chain during `VerifyDeployment`).
    function _verify(address proxy, address expectedImpl, string memory expectedVersion, bool legacyZeroed)
        internal
        view
    {
        _verifyProxySlots(proxy, expectedImpl);
        _verifyIdentity(proxy, expectedVersion);
        _verifySentinels(proxy);
        if (legacyZeroed) _verifyLegacySlotsZeroed(proxy);
    }

    /// @dev ERC-1967: the implementation slot holds the expected logic; a UUPS proxy has no admin.
    function _verifyProxySlots(address proxy, address expectedImpl) private view {
        address impl = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        if (impl != expectedImpl) revert ImplementationSlotMismatch(expectedImpl, impl);
        bytes32 admin = vm.load(proxy, ADMIN_SLOT);
        if (admin != bytes32(0)) revert AdminSlotNotEmpty(admin);
    }

    /// @dev `version()` of the live logic and the owner recorded at deployment.
    function _verifyIdentity(address proxy, string memory expectedVersion) private view {
        IRegistryRead r = IRegistryRead(proxy);
        string memory version = r.version();
        if (keccak256(bytes(version)) != keccak256(bytes(expectedVersion))) {
            revert VersionMismatch(expectedVersion, version);
        }
        address expectedOwner = _address("v1", "owner");
        if (r.owner() != expectedOwner) revert OwnerMismatch(expectedOwner, r.owner());
    }

    /// @dev Storage sentinels read from the chain right after DeployV1 (RecordSentinels), compared field by field
    ///      through the current implementation's API and as raw slots.
    function _verifySentinels(address proxy) private view {
        IRegistryRead r = IRegistryRead(proxy);
        address owner = _address("v1", "owner");
        _check("planCount", _uint("sentinels", "planCount"), r.planCount());
        (uint64 duration, bool active) = r.plan(2);
        _check("plan(2).duration", _uint("sentinels", "plan2Duration"), duration);
        _check("plan(2).active", _uint("sentinels", "plan2Active"), active ? 1 : 0);
        (uint256 planId, uint64 expiresAt) = r.subscriptionOf(owner);
        _check("subscription.planId", _uint("sentinels", "subscriptionPlanId"), planId);
        _check("subscription.expiresAt", _uint("sentinels", "subscriptionExpiresAt"), expiresAt);
        _check("totalSubscriptions", _uint("sentinels", "totalSubscriptions"), r.totalSubscriptions());
        _checkSlot("raw slot 201", "slot201", proxy, bytes32(uint256(201)));
        _checkSlot("raw subscription slot", "subscriptionSlot", proxy, keccak256(abi.encode(owner, uint256(203))));
    }

    /// @dev The OZ 5.x `Initializable` namespace holds `expected` (2 after the bridge, 3 at V2, 4 at V3) and, from the
    ///      bridge on, the owner sits in the OZ 5.x `Ownable` namespace (raw slot read, not only through `owner()`).
    function _verifyNamespaces(address proxy, uint64 expected) internal view {
        uint64 version = uint64(uint256(vm.load(proxy, OZ_INITIALIZABLE_SLOT)));
        if (version != expected) revert InitializedVersionMismatch(expected, version);
        address expectedOwner = _address("v1", "owner");
        address stored = address(uint160(uint256(vm.load(proxy, OZ_OWNABLE_SLOT))));
        if (stored != expectedOwner) revert OwnerMismatch(expectedOwner, stored);
    }

    /// @dev The AccessManager is configured as `UpgradeGovernance.configure` leaves it: `upgradeToAndCall` restricted
    ///      to UPGRADER, UPGRADER and ADMIN both behind `UPGRADE_DELAY`, GUARDIAN able to cancel upgrades and ADMIN
    ///      operations.
    function _verifyGovernance(AccessManager manager, address target, address admin) internal view {
        if (manager.getTargetFunctionRole(target, IUUPS.upgradeToAndCall.selector) != UpgradeGovernance.UPGRADER_ROLE) {
            revert GovernanceMismatch("upgradeToAndCall is not restricted to UPGRADER");
        }
        (bool isAdmin, uint32 adminDelay) = manager.hasRole(UpgradeGovernance.ADMIN_ROLE, admin);
        if (!isAdmin || adminDelay != UPGRADE_DELAY) revert GovernanceMismatch("ADMIN is not delayed");
        (bool isUpgrader, uint32 upgraderDelay) = manager.hasRole(UpgradeGovernance.UPGRADER_ROLE, admin);
        if (!isUpgrader || upgraderDelay != UPGRADE_DELAY) revert GovernanceMismatch("UPGRADER is not delayed");
        if (manager.getRoleGuardian(UpgradeGovernance.UPGRADER_ROLE) != UpgradeGovernance.GUARDIAN_ROLE) {
            revert GovernanceMismatch("GUARDIAN cannot cancel upgrades");
        }
        if (manager.getRoleGuardian(UpgradeGovernance.ADMIN_OPERATIONS_ROLE) != UpgradeGovernance.GUARDIAN_ROLE) {
            revert GovernanceMismatch("GUARDIAN cannot cancel ADMIN operations");
        }
        bytes4[] memory ops = UpgradeGovernance.adminOperations();
        for (uint256 i; i < ops.length; ++i) {
            if (manager.getTargetFunctionRole(address(manager), ops[i]) != UpgradeGovernance.ADMIN_OPERATIONS_ROLE) {
                revert GovernanceMismatch("an ADMIN operation is not cancellable by GUARDIAN");
            }
        }
    }

    /// @dev After the bridge, the OZ 4.x slots 0 and 51 must be empty.
    function _verifyLegacySlotsZeroed(address proxy) private view {
        bytes32 s0 = vm.load(proxy, LEGACY_INITIALIZABLE_SLOT);
        if (s0 != bytes32(0)) revert LegacySlotNotZero(LEGACY_INITIALIZABLE_SLOT, s0);
        bytes32 s51 = vm.load(proxy, LEGACY_OWNER_SLOT);
        if (s51 != bytes32(0)) revert LegacySlotNotZero(LEGACY_OWNER_SLOT, s51);
    }

    function _checkSlot(string memory what, string memory key, address proxy, bytes32 slot) private view {
        _check(what, _uint("sentinels", key), uint256(vm.load(proxy, slot)));
    }

    function _check(string memory what, uint256 expected, uint256 actual) private pure {
        if (expected != actual) revert SentinelMismatch(what, expected, actual);
    }
}
