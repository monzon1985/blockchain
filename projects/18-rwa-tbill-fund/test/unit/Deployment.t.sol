// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManager} from "@openzeppelin-contracts/access/manager/IAccessManager.sol";
import {FundRoles} from "../../src/access/FundRoles.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {FundDeployment, FundContracts, FundConfig, GovernanceDelays} from "../../script/FundDeployment.sol";
import {FundFixture} from "../utils/FundFixture.sol";

/// @notice The production hand-over: governance behind an execution delay, delayed role grants and target
///         re-wiring, an optional execution delay on the transfer agent, and the deployment script end to end.
contract DeploymentTest is FundFixture {
    address internal multisig = makeAddr("multisig");

    function _delays() internal pure returns (GovernanceDelays memory) {
        return GovernanceDelays({
            governanceExecution: 2 days, transferAgentExecution: 1 days, roleGrant: 3 days, targetAdmin: 4 days
        });
    }

    function _cfg() internal view returns (FundConfig memory cfg) {
        cfg.transferAgent = transferAgent;
    }

    function test_handOverGovernance_appliesEveryDelay() public {
        FundDeployment.handOverGovernance(f, _cfg(), multisig, address(this), _delays());

        (bool isMember, uint32 delay) = manager.hasRole(FundRoles.ADMIN, multisig);
        assertTrue(isMember);
        assertEq(delay, 2 days);
        (isMember,) = manager.hasRole(FundRoles.ADMIN, address(this));
        assertFalse(isMember, "the deployer gave ADMIN up");
        (isMember, delay) = manager.hasRole(FundRoles.TRANSFER_AGENT, transferAgent);
        assertTrue(isMember);
        assertEq(delay, 1 days);

        // Grant and target-admin delays apply after AccessManager's minimum setback (5 days).
        vm.warp(block.timestamp + manager.minSetback());
        assertEq(manager.getRoleGrantDelay(FundRoles.FUND_ADMIN), 3 days);
        assertEq(manager.getRoleGrantDelay(FundRoles.TRANSFER_AGENT), 3 days);
        assertEq(manager.getRoleGrantDelay(FundRoles.NAV_ORACLE), 3 days);
        assertEq(manager.getRoleGrantDelay(FundRoles.COMPLIANCE_OFFICER), 3 days);
        assertEq(manager.getTargetAdminDelay(address(vault)), 4 days);
        assertEq(manager.getTargetAdminDelay(address(share)), 4 days);
        assertEq(manager.getTargetAdminDelay(address(registry)), 4 days);
    }

    function test_handOverGovernance_governanceActionsMustBeScheduled() public {
        FundDeployment.handOverGovernance(f, _cfg(), multisig, address(this), _delays());
        address newCustodian = makeAddr("newCustodian");
        bytes memory data = abi.encodeCall(vault.setCustodian, (newCustodian));
        bytes32 operationId = manager.hashOperation(multisig, address(vault), data);

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, operationId));
        vault.setCustodian(newCustodian);

        vm.prank(multisig);
        manager.schedule(address(vault), data, 0);
        vm.warp(block.timestamp + 2 days - 1);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, operationId));
        manager.execute(address(vault), data);
        vm.warp(block.timestamp + 1);
        vm.prank(multisig);
        manager.execute(address(vault), data);
        assertEq(vault.custodian(), newCustodian);
    }

    function test_handOverGovernance_transferAgentActionsWaitForItsDelay() public {
        _seed(alice, 10 * USDC);
        _issueOrder("order", alice, bob, 1 * USDC);
        FundDeployment.handOverGovernance(f, _cfg(), multisig, address(this), _delays());
        bytes memory data = abi.encodeWithSignature(
            "forcedTransfer(address,address,uint256,bytes32)", alice, bob, 1 * USDC, bytes32("order")
        );

        vm.prank(transferAgent);
        (bool ok,) = address(share).call(data);
        assertFalse(ok, "not scheduled");
        vm.prank(transferAgent);
        (bytes32 operationId,) = manager.schedule(address(share), data, 0);
        assertEq(manager.getSchedule(operationId), block.timestamp + 1 days);
        vm.warp(block.timestamp + 1 days);
        vm.prank(transferAgent);
        manager.execute(address(share), data);
        assertEq(share.balanceOf(bob), 1 * USDC);
    }

    function test_handOverGovernance_toTheDeployerItselfKeepsItAdminBehindTheDelay() public {
        GovernanceDelays memory d;
        d.governanceExecution = 1 days;
        FundDeployment.handOverGovernance(f, _cfg(), address(this), address(this), d);
        (bool isMember, uint32 delay) = manager.hasRole(FundRoles.ADMIN, address(this));
        assertTrue(isMember);
        assertEq(delay, 1 days);
        assertEq(manager.getRoleGrantDelay(FundRoles.FUND_ADMIN), 0, "zero leaves a delay unset");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerNotScheduled.selector,
                manager.hashOperation(address(this), address(vault), abi.encodeCall(vault.setCustodian, (stranger)))
            )
        );
        vault.setCustodian(stranger);
    }

    function test_deployScript_readsDecimalsFromTheAssetAndHandsOver() public {
        vm.setEnv("FUND_ASSET", vm.toString(address(usdc)));
        vm.setEnv("FUND_ADMIN", vm.toString(fundAdmin));
        vm.setEnv("TRANSFER_AGENT", vm.toString(transferAgent));
        vm.setEnv("NAV_ORACLE", vm.toString(navOracle));
        vm.setEnv("COMPLIANCE_OFFICER", vm.toString(complianceOfficer));
        vm.setEnv("FUND_CUSTODIAN", vm.toString(custodian));
        vm.setEnv("FUND_GOVERNANCE", vm.toString(multisig));

        FundContracts memory c = new Deploy().run();

        assertEq(c.share.decimals(), usdc.decimals());
        assertEq(c.vault.custodian(), custodian);
        (bool isMember, uint32 delay) = c.manager.hasRole(FundRoles.ADMIN, multisig);
        assertTrue(isMember);
        assertEq(delay, 2 days, "default governance execution delay");
        (, delay) = c.manager.hasRole(FundRoles.TRANSFER_AGENT, transferAgent);
        assertEq(delay, 0, "default transfer-agent execution delay");
        vm.warp(block.timestamp + c.manager.minSetback());
        assertEq(c.manager.getRoleGrantDelay(FundRoles.COMPLIANCE_OFFICER), 2 days);
        assertEq(c.manager.getTargetAdminDelay(address(c.vault)), 2 days);
    }
}
