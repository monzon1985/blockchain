// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManager} from "@openzeppelin-contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {FundRoles} from "../src/access/FundRoles.sol";
import {ComplianceEngine} from "../src/compliance/ComplianceEngine.sol";
import {InvestorCapModule} from "../src/compliance/modules/InvestorCapModule.sol";
import {LockupModule} from "../src/compliance/modules/LockupModule.sol";
import {MaxHoldersPerCountryModule} from "../src/compliance/modules/MaxHoldersPerCountryModule.sol";
import {TransferWindowModule} from "../src/compliance/modules/TransferWindowModule.sol";
import {DividendDistributor} from "../src/dividends/DividendDistributor.sol";
import {DocumentRegistry} from "../src/documents/DocumentRegistry.sol";
import {IdentityRegistry} from "../src/identity/IdentityRegistry.sol";
import {FundShareToken} from "../src/token/FundShareToken.sol";
import {FundVault} from "../src/vault/FundVault.sol";

/// @notice Addresses of a deployed fund.
struct FundContracts {
    AccessManager manager;
    IdentityRegistry registry;
    ComplianceEngine engine;
    DocumentRegistry documents;
    FundShareToken share;
    FundVault vault;
    DividendDistributor distributor;
    MaxHoldersPerCountryModule maxHolders;
    InvestorCapModule investorCap;
    LockupModule lockup;
    TransferWindowModule transferWindow;
}

/// @notice AccessManager delays applied when governance takes over (all in seconds; zero leaves a delay unset).
/// @param governanceExecution Execution delay of the ADMIN role held by governance: every governance action
///        (role grants, selector re-wiring, custodian changes, NAV resets, write-downs, closing a target) must be
///        scheduled and waits this long.
/// @param transferAgentExecution Execution delay of the TRANSFER_AGENT holder: forced transfers and recovery
///        steps must be scheduled and wait this long (on top of the 2-day recovery timelock).
/// @param roleGrant Grant delay of every operational role: a newly granted member can act only after it.
/// @param targetAdmin Admin delay of every fund contract: re-wiring its selectors or closing it waits this long.
struct GovernanceDelays {
    uint32 governanceExecution;
    uint32 transferAgentExecution;
    uint32 roleGrant;
    uint32 targetAdmin;
}

/// @notice Deployment parameters.
struct FundConfig {
    IERC20 asset;
    uint8 decimals;
    string name;
    string symbol;
    uint128 initialNav;
    uint64 lockupPeriod;
    address fundAdmin;
    address transferAgent;
    address navOracle;
    address complianceOfficer;
}

/// @title FundDeployment
/// @notice Deploys and wires the whole fund. Shared by the deployment script, the tests and the Medusa harness
///         so that every suite exercises the production role wiring.
/// @dev `deployer` must be the account whose calls the library issues: the broadcaster in a script, the test
///      contract or the harness itself otherwise. It becomes the AccessManager admin and, unless it is the
///      configured compliance officer, temporarily takes that role to plug the modules in, then renounces it.
library FundDeployment {
    /// @notice Deploys every contract and wires roles, selectors and modules.
    /// @param cfg Parameters.
    /// @param deployer Account issuing the calls (becomes the AccessManager admin).
    /// @return c Deployed contracts.
    function deploy(FundConfig memory cfg, address deployer) internal returns (FundContracts memory c) {
        c.manager = new AccessManager(deployer);
        address authority = address(c.manager);
        c.registry = new IdentityRegistry(authority, _requiredTopics());
        c.engine = new ComplianceEngine(authority, c.registry);
        c.documents = new DocumentRegistry(authority);
        c.share = new FundShareToken(cfg.name, cfg.symbol, cfg.decimals, authority, c.registry, c.engine, c.documents);
        c.vault = new FundVault(cfg.asset, c.share, authority, cfg.initialNav);
        c.distributor = new DividendDistributor(authority, cfg.asset, c.share);
        c.maxHolders = new MaxHoldersPerCountryModule(authority, address(c.engine));
        c.investorCap = new InvestorCapModule(authority, address(c.engine));
        c.lockup = new LockupModule(authority, address(c.engine), cfg.lockupPeriod);
        c.transferWindow = new TransferWindowModule(authority, address(c.engine));

        wireRoles(c);
        grantOperationalRoles(c, cfg);

        c.engine.bindToken(address(c.share));
        c.share.setVault(address(cfg.asset), address(c.vault));

        bool temporaryOfficer = cfg.complianceOfficer != deployer;
        if (temporaryOfficer) c.manager.grantRole(FundRoles.COMPLIANCE_OFFICER, deployer, 0);
        c.engine.addModule(address(c.maxHolders));
        c.engine.addModule(address(c.investorCap));
        c.engine.addModule(address(c.lockup));
        c.engine.addModule(address(c.transferWindow));
        if (temporaryOfficer) c.manager.renounceRole(FundRoles.COMPLIANCE_OFFICER, deployer);
    }

    /// @notice Hands the AccessManager over to `governance` with the given delays, then makes `deployer` give up
    ///         ADMIN (unless it is `governance`). Call it last: once the delays apply, governance actions must be
    ///         scheduled. Grant and target-admin delays take effect after AccessManager's `minSetback` (5 days).
    /// @param c Deployed contracts.
    /// @param cfg Parameters (the transfer agent whose execution delay is set).
    /// @param governance Account that receives the ADMIN role.
    /// @param deployer Account issuing the calls (current ADMIN).
    /// @param d Delays.
    function handOverGovernance(
        FundContracts memory c,
        FundConfig memory cfg,
        address governance,
        address deployer,
        GovernanceDelays memory d
    ) internal {
        AccessManager m = c.manager;
        if (d.roleGrant != 0) {
            m.setGrantDelay(FundRoles.FUND_ADMIN, d.roleGrant);
            m.setGrantDelay(FundRoles.TRANSFER_AGENT, d.roleGrant);
            m.setGrantDelay(FundRoles.NAV_ORACLE, d.roleGrant);
            m.setGrantDelay(FundRoles.COMPLIANCE_OFFICER, d.roleGrant);
        }
        if (d.transferAgentExecution != 0) {
            // Re-granting an existing member updates its execution delay; an increase applies immediately.
            m.grantRole(FundRoles.TRANSFER_AGENT, cfg.transferAgent, d.transferAgentExecution);
        }
        if (d.targetAdmin != 0) {
            address[10] memory targets = [
                address(c.registry),
                address(c.engine),
                address(c.documents),
                address(c.share),
                address(c.vault),
                address(c.distributor),
                address(c.maxHolders),
                address(c.investorCap),
                address(c.lockup),
                address(c.transferWindow)
            ];
            for (uint256 i; i < targets.length; ++i) {
                m.setTargetAdminDelay(targets[i], d.targetAdmin);
            }
        }
        m.grantRole(FundRoles.ADMIN, governance, d.governanceExecution);
        if (governance != deployer) m.renounceRole(FundRoles.ADMIN, deployer);
    }

    /// @notice Maps every restricted selector to its role. Unmapped selectors default to ADMIN.
    /// @param c Deployed contracts.
    function wireRoles(FundContracts memory c) internal {
        AccessManager m = c.manager;

        // Identity registry: wallet binding and trust configuration belong to the compliance officer, so the
        // transfer agent (which executes recoveries to wallets of the same identity) cannot bind wallets.
        bytes4[] memory registrySelectors = new bytes4[](5);
        registrySelectors[0] = IdentityRegistry.registerWallet.selector;
        registrySelectors[1] = IdentityRegistry.unregisterWallet.selector;
        registrySelectors[2] = IdentityRegistry.setTrustedIssuer.selector;
        registrySelectors[3] = IdentityRegistry.setRequiredTopics.selector;
        registrySelectors[4] = IdentityRegistry.removeClaim.selector;
        m.setTargetFunctionRole(address(c.registry), registrySelectors, FundRoles.COMPLIANCE_OFFICER);

        // Compliance engine and modules (bindToken stays ADMIN).
        m.setTargetFunctionRole(
            address(c.engine),
            _sel2(ComplianceEngine.addModule.selector, ComplianceEngine.removeModule.selector),
            FundRoles.COMPLIANCE_OFFICER
        );
        m.setTargetFunctionRole(
            address(c.maxHolders),
            _sel3(
                MaxHoldersPerCountryModule.setCountryCap.selector,
                MaxHoldersPerCountryModule.clearCountryCap.selector,
                MaxHoldersPerCountryModule.setGlobalCap.selector
            ),
            FundRoles.COMPLIANCE_OFFICER
        );
        m.setTargetFunctionRole(
            address(c.investorCap), _sel1(InvestorCapModule.setMaxPerInvestor.selector), FundRoles.COMPLIANCE_OFFICER
        );
        m.setTargetFunctionRole(
            address(c.lockup), _sel1(LockupModule.setLockupPeriod.selector), FundRoles.COMPLIANCE_OFFICER
        );
        m.setTargetFunctionRole(
            address(c.transferWindow),
            _sel2(TransferWindowModule.setWindow.selector, TransferWindowModule.disableWindow.selector),
            FundRoles.COMPLIANCE_OFFICER
        );

        // Share token (3-arg forcedTransfer and setVault stay ADMIN).
        m.setTargetFunctionRole(
            address(c.share),
            _sel2(FundShareToken.mint.selector, FundShareToken.burnForRedemption.selector),
            FundRoles.VAULT
        );
        m.setTargetFunctionRole(
            address(c.share), _sel1(FundShareToken.setFrozenTokens.selector), FundRoles.COMPLIANCE_OFFICER
        );
        m.setTargetFunctionRole(
            address(c.share),
            _sel2(FundShareToken.issueLawfulOrder.selector, FundShareToken.revokeLawfulOrder.selector),
            FundRoles.FUND_ADMIN
        );
        bytes4[] memory agentSelectors = new bytes4[](4);
        agentSelectors[0] = bytes4(keccak256("forcedTransfer(address,address,uint256,bytes32)"));
        agentSelectors[1] = FundShareToken.initiateRecovery.selector;
        agentSelectors[2] = FundShareToken.cancelRecovery.selector;
        agentSelectors[3] = FundShareToken.executeRecovery.selector;
        m.setTargetFunctionRole(address(c.share), agentSelectors, FundRoles.TRANSFER_AGENT);

        // Vault (setCustodian, writeDownCustody and resetNavReference stay ADMIN).
        bytes4[] memory adminSelectors = new bytes4[](4);
        adminSelectors[0] = FundVault.closeEpoch.selector;
        adminSelectors[1] = FundVault.settleEpoch.selector;
        adminSelectors[2] = FundVault.deployToCustodian.selector;
        adminSelectors[3] = FundVault.recallFromCustodian.selector;
        m.setTargetFunctionRole(address(c.vault), adminSelectors, FundRoles.FUND_ADMIN);
        m.setTargetFunctionRole(address(c.vault), _sel1(FundVault.postNav.selector), FundRoles.NAV_ORACLE);

        // Documents and dividends.
        m.setTargetFunctionRole(
            address(c.documents),
            _sel2(DocumentRegistry.setDocument.selector, DocumentRegistry.removeDocument.selector),
            FundRoles.FUND_ADMIN
        );
        m.setTargetFunctionRole(
            address(c.distributor), _sel1(DividendDistributor.createDistribution.selector), FundRoles.FUND_ADMIN
        );

        m.labelRole(FundRoles.FUND_ADMIN, "FUND_ADMIN");
        m.labelRole(FundRoles.TRANSFER_AGENT, "TRANSFER_AGENT");
        m.labelRole(FundRoles.NAV_ORACLE, "NAV_ORACLE");
        m.labelRole(FundRoles.COMPLIANCE_OFFICER, "COMPLIANCE_OFFICER");
        m.labelRole(FundRoles.VAULT, "VAULT");
    }

    /// @notice Grants the operational roles and the vault role.
    /// @param c Deployed contracts.
    /// @param cfg Parameters (role holders).
    function grantOperationalRoles(FundContracts memory c, FundConfig memory cfg) internal {
        c.manager.grantRole(FundRoles.FUND_ADMIN, cfg.fundAdmin, 0);
        c.manager.grantRole(FundRoles.TRANSFER_AGENT, cfg.transferAgent, 0);
        c.manager.grantRole(FundRoles.NAV_ORACLE, cfg.navOracle, 0);
        c.manager.grantRole(FundRoles.COMPLIANCE_OFFICER, cfg.complianceOfficer, 0);
        c.manager.grantRole(FundRoles.VAULT, address(c.vault), 0);
    }

    function _requiredTopics() private pure returns (uint256) {
        return (1 << 1) | (1 << 2) | (1 << 3);
    }

    function _sel1(bytes4 a) private pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = a;
    }

    function _sel2(bytes4 a, bytes4 b) private pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = a;
        s[1] = b;
    }

    function _sel3(bytes4 a, bytes4 b, bytes4 c) private pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = a;
        s[1] = b;
        s[2] = c;
    }
}
