// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {UpgradeGovernance} from "../../script/UpgradeGovernance.sol";
import {IRegistryErrors} from "../../src/interfaces/IRegistry.sol";
import {SubscriptionRegistryV2} from "../../src/uups/v2/SubscriptionRegistryV2.sol";
import {SubscriptionRegistryV3} from "../../src/uups/v3/SubscriptionRegistryV3.sol";
import {IUUPS, LabBase} from "../utils/LabBase.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice An implementation the owner would like to install without waiting for the timelock.
contract HijackTarget {
    function proxiableUUID() external pure returns (bytes32) {
        return 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    }
}

/// @notice Initializer paths of V2 and V3 (fresh deployments and upgrade paths) and implementation locking.
/// @dev Both paths end at the same `Initializable` version (3 for V2, 4 for V3): a fresh `initialize` records the
///      version the upgrade path's re-initializer would, so no upgrade-path re-initializer is ever left open on a
///      fresh proxy.
contract InitializersTest is LabBase {
    event Initialized(uint64 version);

    AccessManager internal manager;
    MockERC20 internal token;
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        manager = new AccessManager(owner);
        token = new MockERC20("Test USD", "TUSD");
    }

    // ------------------------------------------------------------------ V2

    function test_v2_freshInitialize() public {
        SubscriptionRegistryV2 impl = new SubscriptionRegistryV2();
        SubscriptionRegistryV2 reg = SubscriptionRegistryV2(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(SubscriptionRegistryV2.initialize, (owner, address(manager)))
                )
            )
        );
        assertEq(reg.owner(), owner);
        assertEq(reg.authority(), address(manager));
        assertEq(reg.version(), "2.0.0");
        assertEq(uint64(uint256(vm.load(address(reg), OZ_INITIALIZABLE_SLOT))), 3, "same version as the upgrade path");
        // Fresh deployments never touch the legacy region.
        assertEq(vm.load(address(reg), LEGACY_OWNER_SLOT), bytes32(0));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        reg.initialize(attacker, address(manager));
    }

    function test_v2_freshInitializeValidatesInputs() public {
        SubscriptionRegistryV2 impl = new SubscriptionRegistryV2();
        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.InvalidAuthority.selector, attacker));
        new ERC1967Proxy(address(impl), abi.encodeCall(SubscriptionRegistryV2.initialize, (owner, attacker)));

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(SubscriptionRegistryV2.initialize, (address(0), address(manager)))
        );
    }

    function test_v2_freshInitializeEmitsVersion3() public {
        SubscriptionRegistryV2 impl = new SubscriptionRegistryV2();
        vm.expectEmit();
        emit Initialized(3);
        new ERC1967Proxy(address(impl), abi.encodeCall(SubscriptionRegistryV2.initialize, (owner, address(manager))));
    }

    /// @notice Regression test for the review finding: on a fresh V2 proxy the upgrade-path `initializeV2` stayed
    ///         callable once, so the owner could swap the AccessManager for one it controls and upgrade at once.
    function test_v2_freshProxy_ownerCannotSwapTheAuthorityThroughInitializeV2() public {
        AccessManager timelocked = new AccessManager(governance);
        SubscriptionRegistryV2 impl = new SubscriptionRegistryV2();
        address proxy = address(
            new ERC1967Proxy(
                address(impl), abi.encodeCall(SubscriptionRegistryV2.initialize, (owner, address(timelocked)))
            )
        );
        AccessManager mine = new AccessManager(owner);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(owner);
        SubscriptionRegistryV2(proxy).initializeV2(address(mine));
        assertEq(SubscriptionRegistryV2(proxy).authority(), address(timelocked));

        HijackTarget evil = new HijackTarget();
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(mine)));
        vm.prank(owner);
        mine.execute(proxy, abi.encodeCall(IUUPS.upgradeToAndCall, (address(evil), "")));
        assertEq(_implementation(proxy), address(impl));
    }

    /// @notice A fresh V2 proxy still reaches V3 the normal way: timelocked upgrade, then `initializeV3` once.
    function test_v2_freshProxy_upgradesToV3AndEnablesPayments() public {
        AccessManager m = new AccessManager(governance);
        SubscriptionRegistryV2 impl = new SubscriptionRegistryV2();
        address proxy = address(
            new ERC1967Proxy(address(impl), abi.encodeCall(SubscriptionRegistryV2.initialize, (owner, address(m))))
        );
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IUUPS.upgradeToAndCall.selector;
        vm.startPrank(governance);
        UpgradeGovernance.configure(m, proxy, selectors, upgrader, guardian, governance);
        vm.stopPrank();

        _upgradeToV3(proxy, m, token);
        assertEq(SubscriptionRegistryV3(proxy).paymentToken(), address(token));
        assertEq(uint64(uint256(vm.load(proxy, OZ_INITIALIZABLE_SLOT))), 4);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(owner);
        SubscriptionRegistryV3(proxy).initializeV3(token, owner);
    }

    function test_v2_implementationIsLocked() public {
        SubscriptionRegistryV2 impl = new SubscriptionRegistryV2();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(attacker, address(manager));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initializeV2(address(manager));
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        impl.upgradeToAndCall(address(impl), "");
    }

    // ------------------------------------------------------------------ V3

    function _freshV3() internal returns (SubscriptionRegistryV3) {
        SubscriptionRegistryV3 impl = new SubscriptionRegistryV3();
        return SubscriptionRegistryV3(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(SubscriptionRegistryV3.initialize, (owner, address(manager), token, treasury))
                )
            )
        );
    }

    function test_v3_freshInitialize() public {
        SubscriptionRegistryV3 reg = _freshV3();
        assertEq(reg.owner(), owner);
        assertEq(reg.authority(), address(manager));
        assertEq(reg.paymentToken(), address(token));
        assertEq(reg.treasury(), treasury);
        assertEq(reg.version(), "3.0.0");
        assertEq(uint64(uint256(vm.load(address(reg), OZ_INITIALIZABLE_SLOT))), 4, "same version as the upgrade path");

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        reg.initialize(attacker, address(manager), token, attacker);
    }

    /// @notice Regression test for the review finding: on a fresh V3 proxy `initializeV3` stayed callable once, so
    ///         the owner could replace the payment token after prices were set.
    function test_v3_freshProxy_initializeV3IsClosed() public {
        SubscriptionRegistryV3 reg = _freshV3();
        MockERC20 other = new MockERC20("Other", "OTH");
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(owner);
        reg.initializeV3(other, owner);
        assertEq(reg.paymentToken(), address(token));
        assertEq(reg.treasury(), treasury);
    }

    function test_v3_freshInitializeValidatesInputs() public {
        SubscriptionRegistryV3 impl = new SubscriptionRegistryV3();
        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.InvalidAuthority.selector, attacker));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(SubscriptionRegistryV3.initialize, (owner, attacker, token, treasury))
        );
        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.InvalidPaymentToken.selector, attacker));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(SubscriptionRegistryV3.initialize, (owner, address(manager), IERC20(attacker), treasury))
        );
        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.InvalidTreasury.selector, address(0)));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(SubscriptionRegistryV3.initialize, (owner, address(manager), token, address(0)))
        );
    }

    function test_v3_initializeV3_onlyOwnerOnlyOnce() public {
        address proxy = _deployV1(owner);
        AccessManager m = _deployManager(governance, proxy);
        _migrateToV2(proxy, m);
        SubscriptionRegistryV3 v3 = new SubscriptionRegistryV3();
        bytes memory call = abi.encodeCall(IUUPS.upgradeToAndCall, (address(v3), ""));
        vm.prank(upgrader);
        m.schedule(proxy, call, 0);
        vm.warp(vm.getBlockTimestamp() + UPGRADE_DELAY);
        vm.prank(upgrader);
        m.execute(proxy, call);

        SubscriptionRegistryV3 reg = SubscriptionRegistryV3(proxy);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        reg.initializeV3(token, attacker);

        vm.expectRevert(abi.encodeWithSelector(IRegistryErrors.InvalidPaymentToken.selector, address(0)));
        vm.prank(owner);
        reg.initializeV3(IERC20(address(0)), treasury);

        vm.prank(owner);
        reg.initializeV3(token, treasury);
        assertEq(reg.paymentToken(), address(token));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(owner);
        reg.initializeV3(token, treasury);
    }

    function test_v3_implementationIsLocked() public {
        SubscriptionRegistryV3 impl = new SubscriptionRegistryV3();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(attacker, address(manager), token, attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initializeV3(token, attacker);
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        impl.upgradeToAndCall(address(impl), "");
        assertEq(impl.proxiableUUID(), IMPLEMENTATION_SLOT);
    }
}
