// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { KestrelProxy } from "kestrel/KestrelProxy.sol";
import { KestrelConfig } from "shared/KestrelConfig.sol";

/// @notice Implementation whose initializer reverts without data, then with a reason.
contract BadInit {
    function silent() external pure {
        revert();
    }

    function loud() external pure {
        revert("nope");
    }
}

/// @notice Unit tests for {KestrelProxy} (transparent routing) and {KestrelConfig}.
contract ProxyConfigUnit is BaseTest {
    KestrelConfig internal cfg; // the proxy, typed as the full config

    function setUp() public override {
        super.setUp();
        cfg = KestrelConfig(address(proxy));
    }

    // --- proxy ---

    function test_proxy_adminSeesAdminFunctions() public {
        assertEq(_proxyAdmin(), proxyAdmin);
        vm.prank(proxyAdmin);
        assertEq(proxy.implementation(), address(configImpl));
    }

    function test_proxy_nonAdminIsDelegated() public {
        // `admin()` is not a config function, so the delegated call reverts.
        vm.prank(alice);
        vm.expectRevert(bytes(""));
        proxy.admin();
        vm.prank(alice);
        assertEq(cfg.version(), "KestrelConfig-1", "non-admin reaches the implementation");
    }

    function test_proxy_adminCannotFallback() public {
        vm.prank(proxyAdmin);
        vm.expectRevert(KestrelProxy.AdminCannotFallback.selector);
        cfg.version();
    }

    function test_proxy_upgradeAndChangeAdmin() public {
        KestrelConfig impl2 = new KestrelConfig();
        vm.startPrank(proxyAdmin);
        proxy.upgradeTo(address(impl2));
        assertEq(proxy.implementation(), address(impl2));
        proxy.changeAdmin(bob);
        vm.stopPrank();
        assertEq(config.ltvBps(), LTV_BPS, "storage survives the upgrade");
        vm.prank(bob);
        assertEq(proxy.admin(), bob);
    }

    function test_proxy_reverts() public {
        vm.startPrank(proxyAdmin);
        vm.expectRevert(abi.encodeWithSelector(KestrelProxy.InvalidAddress.selector, alice));
        proxy.upgradeTo(alice); // not a contract
        vm.expectRevert(abi.encodeWithSelector(KestrelProxy.InvalidAddress.selector, address(0)));
        proxy.changeAdmin(address(0));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(KestrelProxy.InvalidAddress.selector, alice));
        new KestrelProxy(alice, deployer, "");
        vm.expectRevert(abi.encodeWithSelector(KestrelProxy.InvalidAddress.selector, address(0)));
        new KestrelProxy(address(configImpl), address(0), "");

        BadInit bad = new BadInit();
        vm.expectRevert(KestrelProxy.InitializationFailed.selector);
        new KestrelProxy(address(bad), deployer, abi.encodeCall(BadInit.silent, ()));
        vm.expectRevert(bytes("nope"));
        new KestrelProxy(address(bad), deployer, abi.encodeCall(BadInit.loud, ()));
    }

    function test_proxy_withoutInitData() public {
        KestrelProxy p = new KestrelProxy(address(configImpl), deployer, "");
        vm.prank(alice);
        assertEq(KestrelConfig(address(p)).owner(), address(0), "uninitialized storage");
    }

    // --- config ---

    function test_config_ownerManagesParameters() public {
        vm.startPrank(riskOwner);
        cfg.setLtvBps(8000);
        cfg.setEthPrice(2500e18);
        vm.stopPrank();
        assertEq(config.ltvBps(), 8000);
        assertEq(config.ethPrice(), 2500e18);
    }

    function test_config_twoStepOwnership() public {
        vm.prank(riskOwner);
        cfg.transferOwnership(bob);
        assertEq(cfg.pendingOwner(), bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KestrelConfig.Unauthorized.selector, alice));
        cfg.acceptOwnership();
        vm.prank(bob);
        cfg.acceptOwnership();
        assertEq(cfg.owner(), bob);
        assertEq(cfg.pendingOwner(), address(0));
    }

    function test_config_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(KestrelConfig.Unauthorized.selector, alice));
        cfg.setLtvBps(1);
        vm.expectRevert(abi.encodeWithSelector(KestrelConfig.Unauthorized.selector, alice));
        cfg.setEthPrice(1);
        vm.expectRevert(abi.encodeWithSelector(KestrelConfig.Unauthorized.selector, alice));
        cfg.transferOwnership(alice);
        vm.stopPrank();

        vm.startPrank(riskOwner);
        vm.expectRevert(abi.encodeWithSelector(KestrelConfig.InvalidLtv.selector, 0));
        cfg.setLtvBps(0);
        vm.expectRevert(abi.encodeWithSelector(KestrelConfig.InvalidLtv.selector, 9001));
        cfg.setLtvBps(9001);
        vm.expectRevert(KestrelConfig.InvalidPrice.selector);
        cfg.setEthPrice(0);
        vm.expectRevert(KestrelConfig.ZeroAddress.selector);
        cfg.transferOwnership(address(0));
        vm.stopPrank();
    }

    function test_config_initializeValidates() public {
        KestrelProxy p = new KestrelProxy(address(configImpl), deployer, "");
        KestrelConfig c = KestrelConfig(address(p));
        vm.startPrank(alice);
        vm.expectRevert(KestrelConfig.ZeroAddress.selector);
        c.initialize(address(0), 7500, 1);
        c.initialize(alice, 7500, 1);
        vm.expectRevert(KestrelConfig.AlreadyInitialized.selector);
        c.initialize(alice, 7500, 1);
        vm.stopPrank();
    }

    function test_config_implementationIsLocked() public {
        vm.expectRevert(KestrelConfig.AlreadyInitialized.selector);
        configImpl.initialize(alice, 7500, 1);
    }
}
