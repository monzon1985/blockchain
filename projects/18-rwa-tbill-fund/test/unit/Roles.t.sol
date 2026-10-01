// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import {FundRoles} from "../../src/access/FundRoles.sol";
import {ComplianceEngine} from "../../src/compliance/ComplianceEngine.sol";
import {InvestorCapModule} from "../../src/compliance/modules/InvestorCapModule.sol";
import {LockupModule} from "../../src/compliance/modules/LockupModule.sol";
import {MaxHoldersPerCountryModule} from "../../src/compliance/modules/MaxHoldersPerCountryModule.sol";
import {TransferWindowModule} from "../../src/compliance/modules/TransferWindowModule.sol";
import {DividendDistributor} from "../../src/dividends/DividendDistributor.sol";
import {DocumentRegistry} from "../../src/documents/DocumentRegistry.sol";
import {IdentityRegistry} from "../../src/identity/IdentityRegistry.sol";
import {FundShareToken} from "../../src/token/FundShareToken.sol";
import {FundVault} from "../../src/vault/FundVault.sol";
import {FundFixture} from "../utils/FundFixture.sol";

/// @notice The production role wiring, selector by selector. This is the table the README documents.
contract RolesTest is FundFixture {
    function _expectRole(address target, bytes4 selector, uint64 role) internal view {
        assertEq(manager.getTargetFunctionRole(target, selector), role);
    }

    function test_roleHolders() public view {
        (bool isMember,) = manager.hasRole(FundRoles.ADMIN, governance);
        assertTrue(isMember);
        (isMember,) = manager.hasRole(FundRoles.FUND_ADMIN, fundAdmin);
        assertTrue(isMember);
        (isMember,) = manager.hasRole(FundRoles.TRANSFER_AGENT, transferAgent);
        assertTrue(isMember);
        (isMember,) = manager.hasRole(FundRoles.NAV_ORACLE, navOracle);
        assertTrue(isMember);
        (isMember,) = manager.hasRole(FundRoles.COMPLIANCE_OFFICER, complianceOfficer);
        assertTrue(isMember);
        (isMember,) = manager.hasRole(FundRoles.VAULT, address(vault));
        assertTrue(isMember);
        (isMember,) = manager.hasRole(FundRoles.COMPLIANCE_OFFICER, governance);
        assertFalse(isMember, "deployer renounced the temporary compliance role");
    }

    function test_selectorWiring() public view {
        // Identity registry
        _expectRole(address(registry), IdentityRegistry.registerWallet.selector, FundRoles.COMPLIANCE_OFFICER);
        _expectRole(address(registry), IdentityRegistry.unregisterWallet.selector, FundRoles.COMPLIANCE_OFFICER);
        _expectRole(address(registry), IdentityRegistry.setTrustedIssuer.selector, FundRoles.COMPLIANCE_OFFICER);
        _expectRole(address(registry), IdentityRegistry.setRequiredTopics.selector, FundRoles.COMPLIANCE_OFFICER);
        _expectRole(address(registry), IdentityRegistry.removeClaim.selector, FundRoles.COMPLIANCE_OFFICER);
        // Compliance
        _expectRole(address(engine), ComplianceEngine.bindToken.selector, FundRoles.ADMIN);
        _expectRole(address(engine), ComplianceEngine.addModule.selector, FundRoles.COMPLIANCE_OFFICER);
        _expectRole(address(engine), ComplianceEngine.removeModule.selector, FundRoles.COMPLIANCE_OFFICER);
        _expectRole(
            address(maxHolders), MaxHoldersPerCountryModule.setCountryCap.selector, FundRoles.COMPLIANCE_OFFICER
        );
        _expectRole(
            address(maxHolders), MaxHoldersPerCountryModule.clearCountryCap.selector, FundRoles.COMPLIANCE_OFFICER
        );
        _expectRole(address(maxHolders), MaxHoldersPerCountryModule.setGlobalCap.selector, FundRoles.COMPLIANCE_OFFICER);
        _expectRole(address(investorCap), InvestorCapModule.setMaxPerInvestor.selector, FundRoles.COMPLIANCE_OFFICER);
        _expectRole(address(lockup), LockupModule.setLockupPeriod.selector, FundRoles.COMPLIANCE_OFFICER);
        _expectRole(address(transferWindow), TransferWindowModule.setWindow.selector, FundRoles.COMPLIANCE_OFFICER);
        _expectRole(address(transferWindow), TransferWindowModule.disableWindow.selector, FundRoles.COMPLIANCE_OFFICER);
        // Share token
        _expectRole(address(share), FundShareToken.mint.selector, FundRoles.VAULT);
        _expectRole(address(share), FundShareToken.burnForRedemption.selector, FundRoles.VAULT);
        _expectRole(address(share), FundShareToken.setFrozenTokens.selector, FundRoles.COMPLIANCE_OFFICER);
        _expectRole(
            address(share),
            bytes4(keccak256("forcedTransfer(address,address,uint256,bytes32)")),
            FundRoles.TRANSFER_AGENT
        );
        _expectRole(address(share), bytes4(keccak256("forcedTransfer(address,address,uint256)")), FundRoles.ADMIN);
        _expectRole(address(share), FundShareToken.initiateRecovery.selector, FundRoles.TRANSFER_AGENT);
        _expectRole(address(share), FundShareToken.cancelRecovery.selector, FundRoles.TRANSFER_AGENT);
        _expectRole(address(share), FundShareToken.executeRecovery.selector, FundRoles.TRANSFER_AGENT);
        _expectRole(address(share), FundShareToken.setVault.selector, FundRoles.ADMIN);
        _expectRole(address(share), FundShareToken.issueLawfulOrder.selector, FundRoles.FUND_ADMIN);
        _expectRole(address(share), FundShareToken.revokeLawfulOrder.selector, FundRoles.FUND_ADMIN);
        // Vault
        _expectRole(address(vault), FundVault.closeEpoch.selector, FundRoles.FUND_ADMIN);
        _expectRole(address(vault), FundVault.settleEpoch.selector, FundRoles.FUND_ADMIN);
        _expectRole(address(vault), FundVault.deployToCustodian.selector, FundRoles.FUND_ADMIN);
        _expectRole(address(vault), FundVault.recallFromCustodian.selector, FundRoles.FUND_ADMIN);
        _expectRole(address(vault), FundVault.postNav.selector, FundRoles.NAV_ORACLE);
        _expectRole(address(vault), FundVault.setCustodian.selector, FundRoles.ADMIN);
        _expectRole(address(vault), FundVault.resetNavReference.selector, FundRoles.ADMIN);
        _expectRole(address(vault), FundVault.writeDownCustody.selector, FundRoles.ADMIN);
        // Documents and dividends
        _expectRole(address(documents), DocumentRegistry.setDocument.selector, FundRoles.FUND_ADMIN);
        _expectRole(address(documents), DocumentRegistry.removeDocument.selector, FundRoles.FUND_ADMIN);
        _expectRole(address(distributor), DividendDistributor.createDistribution.selector, FundRoles.FUND_ADMIN);
    }

    function test_separationOfDuties_transferAgentCannotAnchorOrders() public {
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, transferAgent));
        documents.setDocument("order", "x", keccak256("x"));
    }

    function test_separationOfDuties_transferAgentCannotIssueOrdersOrBindWallets() public {
        vm.startPrank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, transferAgent));
        share.issueLawfulOrder("order", alice, bob, 1, uint64(block.timestamp + 1 days), "doc");
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, transferAgent));
        registry.registerWallet(stranger, ID_ALICE);
        vm.stopPrank();
    }

    function test_separationOfDuties_complianceOfficerCannotMoveShares() public {
        _seed(alice, 10 * USDC);
        _issueOrder("order", alice, bob, 1);
        vm.startPrank(complianceOfficer);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, complianceOfficer));
        share.forcedTransfer(alice, bob, 1, "order");
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, complianceOfficer));
        share.initiateRecovery(alice, bob, "case");
        vm.stopPrank();
    }

    function test_separationOfDuties_oracleCannotSettle() public {
        vm.prank(navOracle);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, navOracle));
        vault.closeEpoch();
    }

    function test_separationOfDuties_fundAdminCannotFreezeOrOnboard() public {
        vm.startPrank(fundAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, fundAdmin));
        share.setFrozenTokens(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, fundAdmin));
        registry.registerWallet(stranger, keccak256("x"));
        vm.stopPrank();
    }

    function test_governanceCanCloseTargetsInEmergency() public {
        manager.setTargetClosed(address(vault), true);
        vm.prank(fundAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, fundAdmin));
        vault.closeEpoch();
    }
}
