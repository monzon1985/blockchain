// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OracleRouterGovernance} from "../../script/OracleRouterGovernance.sol";
import {OracleRouter} from "../../src/OracleRouter.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {RouterTestBase} from "../utils/RouterTestBase.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

/// @notice The production permission layout (script/OracleRouterGovernance.sol) and the router's own delay floor.
contract GovernanceTest is RouterTestBase {
    uint64 internal constant CONFIG_ROLE = OracleRouterGovernance.CONFIG_ROLE;
    uint64 internal constant GUARDIAN_ROLE = OracleRouterGovernance.GUARDIAN_ROLE;
    uint32 internal constant DELAY = 2 days;

    address internal guardian = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");
    OracleRouter internal router;
    bytes internal loosenCall;

    function setUp() public override {
        super.setUp();
        router = softRouter;
        OracleRouterGovernance.wire(manager, router, governance, guardian, address(this));
        loosenCall = abi.encodeCall(IOracleRouter.setAssetConfig, (ASSET, _params(IOracleRouter.Mode.Soft)));
    }

    function test_Wiring_HandsAdminToGovernanceWithDelay() public view {
        (bool deployerIsAdmin,) = manager.hasRole(manager.ADMIN_ROLE(), address(this));
        assertFalse(deployerIsAdmin, "deployer renounced");
        (bool isAdmin, uint32 adminDelay) = manager.hasRole(manager.ADMIN_ROLE(), governance);
        assertTrue(isAdmin);
        assertEq(adminDelay, DELAY);
        (bool isConfig, uint32 configDelay) = manager.hasRole(CONFIG_ROLE, governance);
        assertTrue(isConfig);
        assertEq(configDelay, DELAY);
        (bool isGuardian, uint32 guardianDelay) = manager.hasRole(GUARDIAN_ROLE, guardian);
        assertTrue(isGuardian);
        assertEq(guardianDelay, 0);
        assertEq(manager.getRoleGuardian(CONFIG_ROLE), GUARDIAN_ROLE);
        assertEq(manager.getTargetFunctionRole(address(router), IOracleRouter.setAssetConfig.selector), CONFIG_ROLE);
        assertEq(manager.getTargetFunctionRole(address(router), IOracleRouter.setSequencerConfig.selector), CONFIG_ROLE);
        assertEq(manager.getTargetFunctionRole(address(router), IOracleRouter.forceStrict.selector), GUARDIAN_ROLE);
    }

    function test_Config_WithoutScheduleReverts() public {
        bytes32 id = manager.hashOperation(governance, address(router), loosenCall);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id));
        _call(loosenCall);
    }

    function test_Config_BeforeDelayReverts() public {
        vm.prank(governance);
        (bytes32 id,) = manager.schedule(address(router), loosenCall, 0);
        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, id));
        _call(loosenCall);
    }

    function test_Config_AfterDelaySucceeds() public {
        vm.prank(governance);
        manager.schedule(address(router), loosenCall, 0);
        vm.warp(block.timestamp + DELAY);
        vm.prank(governance);
        _call(loosenCall);
        assertEq(uint256(router.getAssetConfig(ASSET).mode), uint256(IOracleRouter.Mode.Soft));
    }

    /// @notice A relay through `AccessManager.execute` hides the caller's delay from the router, so it is refused.
    function test_Config_RelayedThroughExecuteIsRefused() public {
        vm.prank(governance);
        manager.schedule(address(router), loosenCall, 0);
        vm.warp(block.timestamp + DELAY);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.ConfigDelayTooShort.selector, address(manager), 0, DELAY));
        manager.execute(address(router), loosenCall);
    }

    /// @notice Even a misconfigured AccessManager (a config role granted with a 1-day or zero delay) cannot shorten
    ///         the router's 2-day floor.
    function test_Config_ShortDelayRoleIsRefusedByRouter() public {
        address hasty = makeAddr("hasty");
        address instant = makeAddr("instant");
        // Governance must itself schedule these admin actions and wait 2 days.
        bytes memory grantHasty = abi.encodeCall(IAccessManager.grantRole, (CONFIG_ROLE, hasty, 1 days));
        bytes memory grantInstant = abi.encodeCall(IAccessManager.grantRole, (CONFIG_ROLE, instant, 0));
        vm.startPrank(governance);
        manager.schedule(address(manager), grantHasty, 0);
        manager.schedule(address(manager), grantInstant, 0);
        vm.warp(block.timestamp + DELAY);
        manager.execute(address(manager), grantHasty);
        manager.execute(address(manager), grantInstant);
        vm.stopPrank();
        vm.warp(block.timestamp + DELAY); // CONFIG_ROLE grant delay

        vm.prank(hasty);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.ConfigDelayTooShort.selector, hasty, 1 days, DELAY));
        _call(loosenCall);

        vm.prank(instant);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.ConfigDelayTooShort.selector, instant, 0, DELAY));
        _call(loosenCall);
    }

    function test_Config_StrangerIsUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        _call(loosenCall);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian));
        _call(loosenCall);
    }

    function test_Guardian_ForcesStrictImmediately() public {
        secondary.pushAnswer(1800e18); // 10 % below the primary
        _assertQuote(router, COLLATERAL, 1800e18, IPriceOracle.Status.DEVIATION);

        vm.expectEmit(address(router));
        emit IOracleRouter.ModeForcedStrict(ASSET, guardian);
        vm.prank(guardian);
        router.forceStrict(ASSET);

        assertEq(uint256(router.getAssetConfig(ASSET).mode), uint256(IOracleRouter.Mode.Strict));
        _assertQuote(router, COLLATERAL, 0, IPriceOracle.Status.DEVIATION);
    }

    function test_ForceStrict_OnlyGuardian() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, governance));
        router.forceStrict(ASSET);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        router.forceStrict(ASSET);
    }

    /// @notice A malicious or mistaken configuration is public for 2 days, and the guardian can veto it.
    function test_Guardian_CancelsScheduledConfig() public {
        vm.prank(governance);
        (bytes32 id,) = manager.schedule(address(router), loosenCall, 0);
        vm.prank(guardian);
        manager.cancel(governance, address(router), loosenCall);
        vm.warp(block.timestamp + DELAY);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id));
        _call(loosenCall);
    }

    function test_AdminActions_AreDelayedToo() public {
        bytes memory grant = abi.encodeCall(IAccessManager.grantRole, (GUARDIAN_ROLE, stranger, 0));
        bytes32 id = manager.hashOperation(governance, address(manager), grant);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id));
        manager.grantRole(GUARDIAN_ROLE, stranger, 0);
    }

    function _call(bytes memory data) internal {
        (bool ok, bytes memory returnData) = address(router).call(data);
        if (!ok) {
            // Safety: re-throws the router's revert data unchanged so `vm.expectRevert` can match it.
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}
