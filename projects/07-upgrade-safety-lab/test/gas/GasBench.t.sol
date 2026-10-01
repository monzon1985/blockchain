// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RegistryDiamond} from "../../src/diamond/RegistryDiamond.sol";
import {ISubscriptionRegistry} from "../../src/interfaces/IRegistry.sol";
import {SubscriptionRegistryBridge} from "../../src/uups/bridge/SubscriptionRegistryBridge.sol";
import {SubscriptionRegistryV1} from "../../src/uups/v1/SubscriptionRegistryV1.sol";
import {SubscriptionRegistryV2} from "../../src/uups/v2/SubscriptionRegistryV2.sol";
import {SubscriptionRegistryV3} from "../../src/uups/v3/SubscriptionRegistryV3.sol";
import {IUUPS, LabBase} from "../utils/LabBase.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/// @notice Per-call gas of the same operations through the UUPS proxy (V3) and through the diamond. Every test
///         performs exactly one measured call after `setUp` (a separate transaction), so storage is cold as it
///         would be for a real user. Results: `.gas-snapshot` (whole test) and `snapshots/GasBench.json`
///         (the measured call only, via `vm.snapshotGasLastFrame`).
abstract contract GasBenchBase is LabBase {
    ISubscriptionRegistry internal reg;
    MockERC20 internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _deploy(MockERC20 paymentToken) internal virtual returns (ISubscriptionRegistry);

    function _name() internal pure virtual returns (string memory);

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        token = _newToken();
        reg = _deploy(token);
        vm.startPrank(owner);
        reg.createPlan(30 days); // plan 1: free
        reg.createPlan(7 days); // plan 2: paid
        reg.setPlanPrice(2, 5e6);
        vm.stopPrank();
        token.mint(bob, 100e6);
        vm.prank(bob);
        token.approve(address(reg), type(uint256).max);
        vm.prank(alice);
        reg.subscribe(1); // alice has a live subscription to renew or cancel
    }

    function _snap(string memory op) internal {
        vm.snapshotGasLastFrame("GasBench", string.concat(op, "_", _name()));
    }
}

/// @notice The operations measured on both architectures.
abstract contract OperationsBench is GasBenchBase {
    function test_gas_createPlan() public {
        vm.prank(owner);
        reg.createPlan(90 days);
        _snap("createPlan");
    }

    function test_gas_subscribeFresh() public {
        vm.prank(bob);
        reg.subscribe(1);
        _snap("subscribeFree");
    }

    function test_gas_subscribeRenewal() public {
        vm.prank(alice);
        reg.subscribe(1);
        _snap("subscribeRenewal");
    }

    function test_gas_subscribePaid() public {
        vm.prank(bob);
        reg.subscribeWithMaxPrice(2, 5e6);
        _snap("subscribePaid");
    }

    function test_gas_cancel() public {
        vm.prank(alice);
        reg.cancel();
        _snap("cancel");
    }

    function test_gas_isActive() public {
        reg.isActive(alice);
        _snap("isActive");
    }

    /// @dev First write: V3's grace period sits alone in a namespace slot that is still zero (zero to non-zero
    ///      SSTORE), while the diamond packs it into the counters slot that `createPlan` already made non-zero.
    function test_gas_setGracePeriodFirstWrite() public {
        vm.prank(owner);
        reg.setGracePeriod(1 days);
        _snap("setGracePeriodFirstWrite");
    }
}

/// @notice The same `setGracePeriod` once a grace period is already set (non-zero to non-zero on both sides).
abstract contract GraceUpdateBench is GasBenchBase {
    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        reg.setGracePeriod(1 days);
    }

    function test_gas_setGracePeriodUpdate() public {
        vm.prank(owner);
        reg.setGracePeriod(2 days);
        _snap("setGracePeriodUpdate");
    }
}

contract GasBenchUupsTest is OperationsBench {
    function _deploy(MockERC20 paymentToken) internal override returns (ISubscriptionRegistry) {
        (address proxy,) = _deployV3ThroughChain(paymentToken);
        return ISubscriptionRegistry(proxy);
    }

    function _name() internal pure override returns (string memory) {
        return "uups";
    }
}

contract GasBenchDiamondTest is OperationsBench {
    function _deploy(MockERC20 paymentToken) internal override returns (ISubscriptionRegistry) {
        (RegistryDiamond diamond,) = _deployDiamond(owner, paymentToken, treasury);
        return ISubscriptionRegistry(address(diamond));
    }

    function _name() internal pure override returns (string memory) {
        return "diamond";
    }
}

contract GasBenchGraceUpdateUupsTest is GraceUpdateBench {
    function _deploy(MockERC20 paymentToken) internal override returns (ISubscriptionRegistry) {
        (address proxy,) = _deployV3ThroughChain(paymentToken);
        return ISubscriptionRegistry(proxy);
    }

    function _name() internal pure override returns (string memory) {
        return "uups";
    }
}

contract GasBenchGraceUpdateDiamondTest is GraceUpdateBench {
    function _deploy(MockERC20 paymentToken) internal override returns (ISubscriptionRegistry) {
        (RegistryDiamond diamond,) = _deployDiamond(owner, paymentToken, treasury);
        return ISubscriptionRegistry(address(diamond));
    }

    function _name() internal pure override returns (string memory) {
        return "diamond";
    }
}

/// @notice Gas of each migration step (the operator-facing cost of the escape hatch). Each step is measured in its
///         own test, with the previous steps done in `setUp`, so every measured call starts cold.
abstract contract MigrationBenchBase is LabBase {
    address internal proxy;
    AccessManager internal manager;
    SubscriptionRegistryBridge internal bridge;
    SubscriptionRegistryV2 internal v2;
    SubscriptionRegistryV3 internal v3;

    function _deployAll() internal {
        proxy = _deployV1(owner);
        manager = _deployManager(governance, proxy);
        bridge = new SubscriptionRegistryBridge();
        v2 = new SubscriptionRegistryV2();
        v3 = new SubscriptionRegistryV3();
    }

    function _step1() internal {
        vm.prank(owner);
        SubscriptionRegistryV1(proxy)
            .upgradeToAndCall(address(bridge), abi.encodeCall(SubscriptionRegistryBridge.migrateFromV4, ()));
    }

    function _step2() internal {
        vm.prank(owner);
        IUUPS(proxy)
            .upgradeToAndCall(address(v2), abi.encodeCall(SubscriptionRegistryV2.initializeV2, (address(manager))));
    }
}

contract GasBenchMigrationStep1Test is MigrationBenchBase {
    function setUp() public {
        _deployAll();
    }

    function test_gas_step1_v1ToBridgeWithMigration() public {
        _step1();
        vm.snapshotGasLastFrame("GasBench", "migration_step1_v1ToBridge");
    }
}

contract GasBenchMigrationStep2Test is MigrationBenchBase {
    function setUp() public {
        _deployAll();
        _step1();
    }

    function test_gas_step2_bridgeToV2() public {
        _step2();
        vm.snapshotGasLastFrame("GasBench", "migration_step2_bridgeToV2");
    }
}

contract GasBenchMigrationStep3Test is MigrationBenchBase {
    bytes internal upgradeCall;

    function setUp() public {
        _deployAll();
        _step1();
        _step2();
        upgradeCall = abi.encodeCall(IUUPS.upgradeToAndCall, (address(v3), ""));
        vm.prank(upgrader);
        manager.schedule(proxy, upgradeCall, 0);
        vm.warp(vm.getBlockTimestamp() + UPGRADE_DELAY);
    }

    function test_gas_step3_executeTimelockedV2ToV3() public {
        vm.prank(upgrader);
        manager.execute(proxy, upgradeCall);
        vm.snapshotGasLastFrame("GasBench", "migration_step3_executeV2ToV3");
    }
}
