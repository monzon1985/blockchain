// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DiamondSelectors} from "../../script/DiamondSelectors.sol";
import {UpgradeGovernance} from "../../script/UpgradeGovernance.sol";
import {DiamondInit} from "../../src/diamond/DiamondInit.sol";
import {RegistryDiamond} from "../../src/diamond/RegistryDiamond.sol";
import {AdminFacet} from "../../src/diamond/facets/AdminFacet.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {PlanFacet} from "../../src/diamond/facets/PlanFacet.sol";
import {SubscriptionFacet} from "../../src/diamond/facets/SubscriptionFacet.sol";
import {IDiamondCut} from "../../src/diamond/interfaces/IDiamond.sol";
import {SubscriptionRegistryBridge} from "../../src/uups/bridge/SubscriptionRegistryBridge.sol";
import {SubscriptionRegistryV1} from "../../src/uups/v1/SubscriptionRegistryV1.sol";
import {SubscriptionRegistryV2} from "../../src/uups/v2/SubscriptionRegistryV2.sol";
import {SubscriptionRegistryV3} from "../../src/uups/v3/SubscriptionRegistryV3.sol";
import {MockERC20} from "./Mocks.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The UUPS entry points shared by OZ 4.9.6 and 5.7.0 implementations.
interface IUUPS {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
    function proxiableUUID() external view returns (bytes32);
}

/// @notice Shared deployment and upgrade helpers for the whole lab.
abstract contract LabBase is Test {
    // ERC-1967 slots.
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // OZ 5.x namespaces (the same slots OZ hard-codes; `Erc7201Formula.t.sol` cross-checks them).
    bytes32 internal constant OZ_INITIALIZABLE_SLOT = bytes32(erc7201("openzeppelin.storage.Initializable"));
    bytes32 internal constant OZ_OWNABLE_SLOT = bytes32(erc7201("openzeppelin.storage.Ownable"));
    bytes32 internal constant OZ_ACCESS_MANAGED_SLOT = bytes32(erc7201("openzeppelin.storage.AccessManaged"));

    // OZ 4.9.6 sequential slots that V1 uses for its parents.
    bytes32 internal constant LEGACY_INITIALIZABLE_SLOT = bytes32(uint256(0));
    bytes32 internal constant LEGACY_OWNER_SLOT = bytes32(uint256(51));
    /// @dev Slot of `_planCount` (low 8 bytes) and `_totalSubscriptions` (next 8 bytes).
    bytes32 internal constant APP_COUNTERS_SLOT = bytes32(uint256(201));
    uint256 internal constant PLANS_MAPPING_SLOT = 202;
    uint256 internal constant SUBSCRIPTIONS_MAPPING_SLOT = 203;

    // AccessManager roles (the configuration the deployment scripts apply, `script/UpgradeGovernance.sol`).
    uint64 internal constant ADMIN_ROLE = UpgradeGovernance.ADMIN_ROLE;
    uint64 internal constant UPGRADER_ROLE = UpgradeGovernance.UPGRADER_ROLE;
    uint64 internal constant GUARDIAN_ROLE = UpgradeGovernance.GUARDIAN_ROLE;
    uint64 internal constant ADMIN_OPERATIONS_ROLE = UpgradeGovernance.ADMIN_OPERATIONS_ROLE;
    uint32 internal constant UPGRADE_DELAY = UpgradeGovernance.UPGRADE_DELAY;

    /// @dev The AccessManager's ADMIN in most tests: a governance account distinct from the plan owner, as in
    ///      production. `OwnerIsAdminTimelockTest` covers the demo's configuration, where the owner is the ADMIN.
    address internal governance = makeAddr("governance");
    address internal owner = makeAddr("owner");
    address internal upgrader = makeAddr("upgrader");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");

    // ------------------------------------------------------------------ UUPS lineage

    function _deployV1(address initialOwner) internal returns (address proxy) {
        SubscriptionRegistryV1 impl = new SubscriptionRegistryV1();
        proxy =
            address(new ERC1967Proxy(address(impl), abi.encodeCall(SubscriptionRegistryV1.initialize, (initialOwner))));
    }

    /// @notice AccessManager configured exactly as the deployment scripts configure it (`UpgradeGovernance`): an
    ///         UPGRADER role (delayed) on `upgradeToAndCall` of `target`, a GUARDIAN that can cancel scheduled
    ///         upgrades and scheduled ADMIN operations, and `admin` holding ADMIN behind the same delay.
    function _deployManager(address admin, address target) internal returns (AccessManager manager) {
        manager = new AccessManager(admin);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IUUPS.upgradeToAndCall.selector;
        vm.startPrank(admin);
        UpgradeGovernance.configure(manager, target, selectors, upgrader, guardian, admin);
        vm.stopPrank();
    }

    /// @notice The safe two-step migration: V1 -> bridge (migrateFromV4) -> V2 (initializeV2).
    function _migrateToV2(address proxy, AccessManager manager) internal {
        SubscriptionRegistryBridge bridge = new SubscriptionRegistryBridge();
        SubscriptionRegistryV2 v2 = new SubscriptionRegistryV2();
        vm.prank(owner);
        SubscriptionRegistryV1(proxy)
            .upgradeToAndCall(address(bridge), abi.encodeCall(SubscriptionRegistryBridge.migrateFromV4, ()));
        vm.prank(owner);
        SubscriptionRegistryBridge(proxy)
            .upgradeToAndCall(address(v2), abi.encodeCall(SubscriptionRegistryV2.initializeV2, (address(manager))));
    }

    /// @notice The timelocked V2 -> V3 upgrade through the AccessManager, then the owner enables payments.
    function _upgradeToV3(address proxy, AccessManager manager, IERC20 token) internal {
        SubscriptionRegistryV3 v3 = new SubscriptionRegistryV3();
        bytes memory call = abi.encodeCall(IUUPS.upgradeToAndCall, (address(v3), ""));
        vm.prank(upgrader);
        manager.schedule(proxy, call, 0);
        vm.warp(vm.getBlockTimestamp() + UPGRADE_DELAY);
        vm.prank(upgrader);
        manager.execute(proxy, call);
        vm.prank(owner);
        SubscriptionRegistryV3(proxy).initializeV3(token, treasury);
    }

    /// @notice Full lineage: V1 -> bridge -> V2 -> V3 with payments enabled.
    function _deployV3ThroughChain(IERC20 token) internal returns (address proxy, AccessManager manager) {
        proxy = _deployV1(owner);
        manager = _deployManager(governance, proxy);
        _migrateToV2(proxy, manager);
        _upgradeToV3(proxy, manager, token);
    }

    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    // ------------------------------------------------------------------ Diamond

    struct DiamondFacets {
        DiamondCutFacet cut;
        DiamondLoupeFacet loupe;
        OwnershipFacet ownership;
        PlanFacet plan;
        SubscriptionFacet subscription;
        AdminFacet admin;
        DiamondInit init;
    }

    function _deployFacets() internal returns (DiamondFacets memory f) {
        f.cut = new DiamondCutFacet();
        f.loupe = new DiamondLoupeFacet();
        f.ownership = new OwnershipFacet();
        f.plan = new PlanFacet();
        f.subscription = new SubscriptionFacet();
        f.admin = new AdminFacet();
        f.init = new DiamondInit();
    }

    function _cutSelectors() internal pure returns (bytes4[] memory) {
        return DiamondSelectors.cutSelectors();
    }

    function _loupeSelectors() internal pure returns (bytes4[] memory) {
        return DiamondSelectors.loupeSelectors();
    }

    function _ownershipSelectors() internal pure returns (bytes4[] memory) {
        return DiamondSelectors.ownershipSelectors();
    }

    function _planSelectors() internal pure returns (bytes4[] memory) {
        return DiamondSelectors.planSelectors();
    }

    function _subscriptionSelectors() internal pure returns (bytes4[] memory) {
        return DiamondSelectors.subscriptionSelectors();
    }

    function _adminSelectors() internal pure returns (bytes4[] memory) {
        return DiamondSelectors.adminSelectors();
    }

    /// @notice The routing table the deployment script cuts (`DiamondSelectors.facetCuts`).
    function _facetCuts(DiamondFacets memory f) internal pure returns (IDiamondCut.FacetCut[] memory) {
        return DiamondSelectors.facetCuts(
            address(f.cut),
            address(f.loupe),
            address(f.ownership),
            address(f.plan),
            address(f.subscription),
            address(f.admin)
        );
    }

    function _deployDiamond(address initialOwner, IERC20 token, address initialTreasury)
        internal
        returns (RegistryDiamond diamond, DiamondFacets memory f)
    {
        f = _deployFacets();
        diamond = new RegistryDiamond(
            initialOwner, _facetCuts(f), address(f.init), abi.encodeCall(DiamondInit.init, (token, initialTreasury))
        );
    }

    function _newToken() internal returns (MockERC20) {
        return new MockERC20("Test USD", "TUSD");
    }
}
