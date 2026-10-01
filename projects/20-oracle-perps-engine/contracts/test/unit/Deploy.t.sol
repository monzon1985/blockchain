// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {PerpsDeployment} from "../../script/PerpsDeployment.sol";
import {LPVault} from "../../src/LPVault.sol";
import {OracleVerifier} from "../../src/OracleVerifier.sol";
import {OrderBook} from "../../src/OrderBook.sol";
import {PerpsMarket} from "../../src/PerpsMarket.sol";
import {IPerpsMarket} from "../../src/interfaces/IPerpsMarket.sol";
import {PerpsTestBase} from "../utils/PerpsTestBase.sol";

contract DeployScriptTest is Test {
    address internal constant GOVERNOR = address(0xBb);

    function _env() internal {
        vm.setEnv("SIGNERS", "0x0000000000000000000000000000000000000011,0x0000000000000000000000000000000000000012");
        vm.setEnv("KEEPERS", "0x00000000000000000000000000000000000000Aa");
        // Both tests set the same value: the environment is shared by tests running in parallel.
        vm.setEnv("GOVERNOR", "0x00000000000000000000000000000000000000Bb");
    }

    function test_deployScript_wiresRoles() public {
        vm.chainId(31_337);
        _env();
        Deploy script = new Deploy();
        PerpsDeployment.System memory s = script.run();

        assertEq(address(s.market.orderBook()), address(s.orderBook));
        assertEq(address(s.market.vault()), address(s.vault));
        assertEq(s.market.marketId(), keccak256("ETH-USD"));
        assertEq(s.oracle.signers().length, 2);

        address keeper = address(0xAa);
        (bool isKeeper,) = s.manager.hasRole(PerpsDeployment.KEEPER_ROLE, keeper);
        assertTrue(isKeeper);
        (bool immediate,) = s.manager.canCall(keeper, address(s.orderBook), OrderBook.executeOrder.selector);
        assertTrue(immediate);
        (immediate,) = s.manager.canCall(keeper, address(s.vault), LPVault.executeRequest.selector);
        assertTrue(immediate);
        (immediate,) = s.manager.canCall(keeper, address(s.market), PerpsMarket.liquidate.selector);
        assertTrue(immediate);
        // Governance is timelocked for the deployer (the default risk admin): a scheduled call is required.
        (bool riskNow, uint32 delay) =
            s.manager.canCall(tx.origin, address(s.market), PerpsMarket.setRiskParams.selector);
        assertFalse(riskNow);
        assertEq(delay, PerpsDeployment.GOVERNANCE_DELAY);

        // The AccessManager admin role ends with GOVERNOR, behind the same delay; the deployer renounced it.
        (bool deployerIsAdmin,) = s.manager.hasRole(s.manager.ADMIN_ROLE(), tx.origin);
        assertFalse(deployerIsAdmin);
        (bool governorIsAdmin, uint32 adminDelay) = s.manager.hasRole(s.manager.ADMIN_ROLE(), GOVERNOR);
        assertTrue(governorIsAdmin);
        assertEq(adminDelay, PerpsDeployment.GOVERNANCE_DELAY);
    }

    function test_revert_deployScript_needsCollateralOutsideLocalChain() public {
        vm.chainId(1);
        _env();
        Deploy script = new Deploy();
        vm.expectRevert("COLLATERAL is required outside a local chain");
        script.run();
    }
}

/// @notice The AccessManager admin cannot bypass the governance timelocks.
contract GovernanceTest is PerpsTestBase {
    address internal attacker = makeAddr("attacker");

    function test_admin_holdsRoleBehindGovernanceDelay() public view {
        (bool isAdmin, uint32 delay) = sys.manager.hasRole(sys.manager.ADMIN_ROLE(), address(this));
        assertTrue(isAdmin);
        assertEq(delay, PerpsDeployment.GOVERNANCE_DELAY);
    }

    /// @dev Regression for a review finding: the admin used to hold its role with no execution delay, so it could
    ///      grant itself (or an accomplice) ORACLE_ADMIN with no delay and rotate the signers in the next
    ///      transaction. Every path now needs an operation scheduled (publicly) a day in advance.
    function test_admin_cannotRotateSignersInLessThanADay() public {
        address[] memory evil = new address[](2);
        evil[0] = attacker;
        evil[1] = makeAddr("accomplice");

        // The admin does not hold ORACLE_ADMIN.
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        oracle.setSigners(evil, 2);

        // Granting the role needs a scheduled operation.
        bytes memory grant = abi.encodeCall(IAccessManager.grantRole, (PerpsDeployment.ORACLE_ADMIN_ROLE, attacker, 0));
        bytes32 grantId = sys.manager.hashOperation(address(this), address(sys.manager), grant);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, grantId));
        sys.manager.grantRole(PerpsDeployment.ORACLE_ADMIN_ROLE, attacker, 0);

        // So does remapping setSigners to a role the admin holds.
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = OracleVerifier.setSigners.selector;
        uint64 adminRole = sys.manager.ADMIN_ROLE();
        bytes memory remap = abi.encodeCall(IAccessManager.setTargetFunctionRole, (address(oracle), sel, adminRole));
        bytes32 remapId = sys.manager.hashOperation(address(this), address(sys.manager), remap);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, remapId));
        sys.manager.setTargetFunctionRole(address(oracle), sel, adminRole);

        // Scheduled (and visible through OperationScheduled), the grant is executable only a day later.
        vm.expectEmit(true, false, false, false, address(sys.manager));
        emit IAccessManager.OperationScheduled(grantId, 1, 0, address(this), address(sys.manager), grant);
        sys.manager.schedule(address(sys.manager), grant, 0);
        skip(1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, grantId));
        sys.manager.execute(address(sys.manager), grant);
        skip(1);
        sys.manager.execute(address(sys.manager), grant);
        vm.prank(attacker);
        oracle.setSigners(evil, 2);
        assertEq(oracle.signers()[0], attacker);
    }

    function test_deploy_handsAdminToSeparateGovernor() public {
        PerpsDeployment.Config memory cfg = _config(_riskParams());
        address multisig = makeAddr("multisig");
        cfg.governor = multisig;
        PerpsDeployment.System memory s = PerpsDeployment.deploy(IERC20(address(usd)), cfg);
        (bool deployerIsAdmin,) = s.manager.hasRole(s.manager.ADMIN_ROLE(), address(this));
        assertFalse(deployerIsAdmin);
        (bool governorIsAdmin, uint32 delay) = s.manager.hasRole(s.manager.ADMIN_ROLE(), multisig);
        assertTrue(governorIsAdmin);
        assertEq(delay, PerpsDeployment.GOVERNANCE_DELAY);
    }

    function test_revert_deploy_zeroGovernor() public {
        PerpsDeployment.Config memory cfg = _config(_riskParams());
        cfg.governor = address(0);
        vm.expectRevert(PerpsDeployment.InvalidGovernor.selector);
        this.deployExternal(cfg);
    }

    /// @dev External entry so `vm.expectRevert` can observe a revert inside the internal deployment library.
    function deployExternal(PerpsDeployment.Config memory cfg) external {
        PerpsDeployment.deploy(IERC20(address(usd)), cfg);
    }
}

/// @notice `PerpsDeployment` matches `test/fixtures/deployment.json`, the file the Go deployment mirror
///         (`keeper/internal/deploy`) is checked against too, so the keeper is tested against the shipped config.
contract DeploymentParityTest is PerpsTestBase {
    /// @dev Field order is alphabetical: `vm.parseJson` decodes JSON objects with sorted keys.
    struct FunctionRole {
        uint256 role;
        string signature;
        string target;
    }

    struct Role {
        uint256 executionDelay;
        uint256 id;
        string name;
    }

    string internal json;

    function setUp() public override {
        super.setUp();
        json = vm.readFile("test/fixtures/deployment.json");
    }

    function test_parity_governanceDelayAndRoles() public view {
        assertEq(vm.parseJsonUint(json, ".governanceDelay"), PerpsDeployment.GOVERNANCE_DELAY);
        Role[] memory roles = abi.decode(vm.parseJson(json, ".roles"), (Role[]));
        assertEq(roles.length, 5);
        assertEq(roles[0].id, sys.manager.ADMIN_ROLE());
        assertEq(roles[1].id, PerpsDeployment.KEEPER_ROLE);
        assertEq(roles[2].id, PerpsDeployment.RISK_ADMIN_ROLE);
        assertEq(roles[3].id, PerpsDeployment.ORACLE_ADMIN_ROLE);
        assertEq(roles[4].id, PerpsDeployment.GUARDIAN_ROLE);
        address[5] memory holders = [address(this), keeper, riskAdmin, oracleAdmin, guardian];
        for (uint256 i; i < roles.length; ++i) {
            (bool member, uint32 delay) = sys.manager.hasRole(uint64(roles[i].id), holders[i]);
            assertTrue(member, roles[i].name);
            assertEq(delay, roles[i].executionDelay, roles[i].name);
        }
    }

    function test_parity_functionRoles() public view {
        FunctionRole[] memory entries = abi.decode(vm.parseJson(json, ".functionRoles"), (FunctionRole[]));
        assertEq(entries.length, 8);
        for (uint256 i; i < entries.length; ++i) {
            bytes4 selector = bytes4(keccak256(bytes(entries[i].signature)));
            assertEq(sys.manager.getTargetFunctionRole(_target(entries[i].target), selector), entries[i].role);
        }
        // The fixture's signatures are the real selectors (a typo would read back as the admin role above).
        assertEq(bytes4(keccak256(bytes(entries[4].signature))), PerpsMarket.setRiskParams.selector);
        assertEq(bytes4(keccak256(bytes(entries[0].signature))), OrderBook.executeOrder.selector);
    }

    function test_parity_defaultRiskParams() public view {
        IPerpsMarket.RiskParams memory p = PerpsDeployment.defaultRiskParams();
        assertEq(_param("maxLongOpenInterest"), p.maxLongOpenInterest);
        assertEq(_param("maxShortOpenInterest"), p.maxShortOpenInterest);
        assertEq(_param("reserveFactor"), p.reserveFactor);
        assertEq(_param("maxPnlFactor"), p.maxPnlFactor);
        assertEq(_param("adlThresholdFactor"), p.adlThresholdFactor);
        assertEq(_param("adlTargetFactor"), p.adlTargetFactor);
        assertEq(_param("positionFeeBps"), p.positionFeeBps);
        assertEq(_param("initialMarginBps"), p.initialMarginBps);
        assertEq(_param("maintenanceMarginBps"), p.maintenanceMarginBps);
        assertEq(_param("liquidationFeeBps"), p.liquidationFeeBps);
        assertEq(_param("orderTimeout"), p.orderTimeout);
        assertEq(_param("minCollateral"), p.minCollateral);
        assertEq(_param("positiveImpactFactor"), p.positiveImpactFactor);
        assertEq(_param("negativeImpactFactor"), p.negativeImpactFactor);
        assertEq(_param("borrowFactor"), p.borrowFactor);
        assertEq(_param("maxFundingVelocity"), p.maxFundingVelocity);
        assertEq(_param("maxFundingRate"), p.maxFundingRate);
        assertEq(_param("skewScale"), p.skewScale);
        assertEq(_param("minExecutionFee"), p.minExecutionFee);
        assertEq(vm.parseJsonKeys(json, ".riskParams").length, 19, "one entry per RiskParams field");
    }

    function _param(string memory key) internal view returns (uint256) {
        return vm.parseJsonUint(json, string.concat(".riskParams.", key));
    }

    function _target(string memory name) internal view returns (address) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("PerpsMarket")) return address(market);
        if (h == keccak256("OrderBook")) return address(orderBook);
        if (h == keccak256("LPVault")) return address(vault);
        if (h == keccak256("OracleVerifier")) return address(oracle);
        revert(string.concat("unknown target ", name));
    }
}
