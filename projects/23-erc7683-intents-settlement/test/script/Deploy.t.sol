// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin-contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin-contracts/access/manager/IAccessManager.sol";

import {ConfigureDestination, DeployDestination, DeployOrigin, Governance, Roles} from "../../script/Deploy.s.sol";
import {OnchainCrossChainOrder} from "../../src/erc7683/IERC7683.sol";
import {OrderStatus} from "../../src/interfaces/IEscrowSettler.sol";
import {Intent, IntentLib, IntentOrderData} from "../../src/libraries/IntentLib.sol";
import {MockMailbox} from "../../src/settlement/mailbox/MockMailbox.sol";
import {MockERC20} from "../utils/TestTokens.sol";

/// @notice The three deployment scripts produce a wired system that settles an order end to end, and leave both
/// AccessManagers with a slow admin (timelock-style execution delay) and relayer roles with a grant delay.
contract DeployScriptTest is Test {
    uint256 internal constant ORIGIN = 1001;
    uint256 internal constant DEST = 1002;
    uint32 internal constant ADMIN_DELAY = 3 days;
    uint32 internal constant GRANT_DELAY = 2 days;

    address internal deployer = makeAddr("deployer");
    address internal relayer = makeAddr("relayer");
    address internal timelock = makeAddr("timelock");
    DeployDestination.Deployed internal d;
    DeployOrigin.Deployed internal o;

    function _governance() internal view returns (Governance memory) {
        return Governance({admin: timelock, adminExecutionDelay: ADMIN_DELAY, relayerGrantDelay: GRANT_DELAY});
    }

    function _deployAll() internal {
        vm.chainId(DEST);
        DeployDestination destScript = new DeployDestination();
        d = destScript.deploy(deployer, relayer);

        vm.chainId(ORIGIN);
        MockERC20 bond = new MockERC20("Bond", "BOND");
        DeployOrigin originScript = new DeployOrigin();
        DeployOrigin.Config memory c = DeployOrigin.Config({
            permit2: address(0),
            refundGrace: 1 hours,
            bondToken: address(bond),
            bond: 1e18,
            challengeWindow: 30 minutes,
            destChainId: DEST,
            destSettler: address(d.settler),
            destReporter: address(d.reporter),
            headerRelayer: relayer,
            mailboxRelayer: relayer,
            governance: _governance()
        });
        o = originScript.deploy(deployer, c);

        vm.chainId(DEST);
        ConfigureDestination configScript = new ConfigureDestination();
        configScript.configure(deployer, d.reporter, ORIGIN, address(o.mailboxModule), _governance());
    }

    function test_scriptsWireTheSystem() public {
        _deployAll();
        assertTrue(o.origin.isSettlementModule(address(o.mailboxModule)));
        assertTrue(o.origin.isSettlementModule(address(o.optimistic)));
        assertTrue(o.origin.isSettlementModule(address(o.proofModule)));
        assertEq(o.mailboxModule.destinationSettler(DEST), address(d.settler));
        assertEq(o.optimistic.destinationSettler(DEST), address(d.settler));
        assertEq(o.proofModule.destinationSettler(DEST), address(d.settler));
        assertEq(d.reporter.originModule(ORIGIN), address(o.mailboxModule));
        assertTrue(address(o.origin.PERMIT2()).code.length > 0, "Permit2 deployed from its artifact");
        assertEq(address(o.adapter.ORIGIN_SETTLER()), address(o.origin));
    }

    function test_scriptsDeployAWorkingSystem() public {
        _deployAll();
        (bytes32 orderId, MockERC20 input) = _openAndFill();
        bytes memory message = _report(orderId);
        vm.chainId(ORIGIN);
        vm.prank(relayer);
        o.mailbox.process(message);
        assertEq(uint8(o.origin.escrowOf(orderId).status), uint8(OrderStatus.Repaid));
        assertEq(input.balanceOf(makeAddr("solver")), 100e18);
    }

    /// @dev The admin handover on both chains: the deployer keeps nothing, the final admin has an execution delay,
    ///      and the relayer roles get their grant delay once AccessManager's minimum setback has passed.
    function test_scriptsHandAdminToASlowAdminAndDelayRelayerGrants() public {
        _deployAll();
        AccessManager[2] memory managers = [o.manager, d.manager];
        for (uint256 i = 0; i < 2; ++i) {
            AccessManager manager = managers[i];
            (bool deployerIsAdmin,) = manager.hasRole(manager.ADMIN_ROLE(), deployer);
            assertFalse(deployerIsAdmin, "deployer renounced ADMIN_ROLE");
            (bool isAdmin, uint32 executionDelay) = manager.hasRole(manager.ADMIN_ROLE(), timelock);
            assertTrue(isAdmin);
            assertEq(executionDelay, ADMIN_DELAY, "admin execution delay");
            assertEq(manager.getRoleGrantDelay(Roles.MAILBOX_RELAYER), 0, "grant delay pending the setback");
        }
        assertEq(o.manager.getRoleGrantDelay(Roles.HEADER_RELAYER), 0);

        vm.warp(block.timestamp + o.manager.minSetback());
        assertEq(o.manager.getRoleGrantDelay(Roles.HEADER_RELAYER), GRANT_DELAY);
        assertEq(o.manager.getRoleGrantDelay(Roles.MAILBOX_RELAYER), GRANT_DELAY);
        assertEq(d.manager.getRoleGrantDelay(Roles.MAILBOX_RELAYER), GRANT_DELAY);
        // Relayers granted during deployment are effective at once.
        (bool isRelayer, uint32 relayerDelay) = o.manager.hasRole(Roles.HEADER_RELAYER, relayer);
        assertTrue(isRelayer);
        assertEq(relayerDelay, 0);
    }

    /// @dev What a compromised admin key can do, and how slowly: it cannot grant itself the header relayer role at
    ///      once; the grant must be scheduled publicly, waits the execution delay, and then the role only becomes
    ///      effective after the grant delay. Until then a forged header is rejected.
    function test_compromisedAdminNeedsExecutionPlusGrantDelayToForgeHeaders() public {
        _deployAll();
        vm.chainId(ORIGIN);
        vm.warp(block.timestamp + o.manager.minSetback());
        address thief = makeAddr("thief");
        bytes memory grant = abi.encodeCall(AccessManager.grantRole, (Roles.HEADER_RELAYER, thief, 0));
        bytes32 operationId = o.manager.hashOperation(timelock, address(o.manager), grant);

        vm.startPrank(timelock);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, operationId));
        o.manager.grantRole(Roles.HEADER_RELAYER, thief, 0);

        vm.recordLogs();
        o.manager.schedule(address(o.manager), grant, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[0], IAccessManager.OperationScheduled.selector, "the attack is public");

        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, operationId));
        o.manager.execute(address(o.manager), grant);
        vm.warp(block.timestamp + ADMIN_DELAY);
        o.manager.execute(address(o.manager), grant);
        vm.stopPrank();

        (bool isRelayer,) = o.manager.hasRole(Roles.HEADER_RELAYER, thief);
        assertFalse(isRelayer, "not a relayer before the grant delay");
        vm.prank(thief);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, thief));
        o.headers.submitHeader(DEST, hex"c0");

        vm.warp(block.timestamp + GRANT_DELAY);
        (isRelayer,) = o.manager.hasRole(Roles.HEADER_RELAYER, thief);
        assertTrue(isRelayer, "effective after execution delay + grant delay");
    }

    function _openAndFill() internal returns (bytes32 orderId, MockERC20 input) {
        vm.chainId(ORIGIN);
        input = new MockERC20("In", "IN");
        vm.chainId(DEST);
        MockERC20 output = new MockERC20("Out", "OUT");
        address user = makeAddr("user");
        IntentOrderData memory data = IntentOrderData({
            inputToken: address(input),
            inputAmount: 100e18,
            outputToken: address(output),
            outputStartAmount: 99e18,
            outputEndAmount: 98e18,
            recipient: user,
            destinationChainId: DEST,
            destinationSettler: address(d.settler),
            exclusiveFiller: address(0),
            exclusivityDeadline: uint32(block.timestamp),
            settlementModule: address(o.mailboxModule)
        });
        uint32 fillDeadline = uint32(block.timestamp + 600);
        vm.chainId(ORIGIN);
        input.mint(user, 100e18);
        vm.startPrank(user);
        input.approve(address(o.origin), 100e18);
        o.origin.open(OnchainCrossChainOrder(fillDeadline, IntentLib.INTENT_ORDER_DATA_TYPEHASH, abi.encode(data)));
        vm.stopPrank();
        bytes memory originData =
            abi.encode(Intent(address(o.origin), user, 0, ORIGIN, type(uint32).max, fillDeadline, data));
        orderId = IntentLib.orderId(ORIGIN, address(o.origin), keccak256(originData));

        vm.chainId(DEST);
        address solver = makeAddr("solver");
        output.mint(solver, 99e18);
        vm.startPrank(solver);
        output.approve(address(d.settler), 99e18);
        d.settler.fill(orderId, originData, "");
        vm.stopPrank();
    }

    function _report(bytes32 orderId) internal returns (bytes memory message) {
        vm.recordLogs();
        d.reporter.report(orderId, ORIGIN);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == MockMailbox.Dispatch.selector) message = abi.decode(logs[i].data, (bytes));
        }
    }
}
