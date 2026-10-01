// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LPVault} from "../src/LPVault.sol";
import {OracleVerifier} from "../src/OracleVerifier.sol";
import {OrderBook} from "../src/OrderBook.sol";
import {PerpsMarket} from "../src/PerpsMarket.sol";
import {IPerpsMarket} from "../src/interfaces/IPerpsMarket.sol";

/// @title PerpsDeployment
/// @notice Deploys and wires the whole system: AccessManager, OracleVerifier, PerpsMarket (which deploys its
///         OrderBook and LPVault) and the role layout. Shared by the Foundry tests and the deployment script; the Go
///         integration test mirrors it step by step.
/// @dev Role layout (see README "Roles and trust assumptions"):
///      KEEPER        executeOrder, executeRequest, liquidate, autoDeleverage       no delay
///      RISK_ADMIN    setRiskParams                                                  GOVERNANCE_DELAY
///      ORACLE_ADMIN  setSigners, setReportLimits                                    GOVERNANCE_DELAY
///      GUARDIAN      setPaused                                                      no delay
///      ADMIN (0)     AccessManager administration; ends with `governor`              GOVERNANCE_DELAY
///      The admin's execution delay is what makes the role timelocks binding: without it the admin could grant
///      itself ORACLE_ADMIN with no delay and rotate the signers in the next transaction.
library PerpsDeployment {
    /// @notice The governor (final AccessManager admin) must be a real account.
    error InvalidGovernor();

    /// @notice Role allowed to settle orders and LP requests, liquidate and auto-deleverage.
    uint64 internal constant KEEPER_ROLE = 1;
    /// @notice Role allowed to change risk parameters (timelocked).
    uint64 internal constant RISK_ADMIN_ROLE = 2;
    /// @notice Role allowed to rotate oracle signers and change report limits (timelocked).
    uint64 internal constant ORACLE_ADMIN_ROLE = 3;
    /// @notice Role allowed to pause new risk.
    uint64 internal constant GUARDIAN_ROLE = 4;
    /// @notice Execution delay of the governance roles.
    uint32 internal constant GOVERNANCE_DELAY = 1 days;

    /// @notice Deployment inputs.
    /// @param admin Initial AccessManager admin that wires the roles; must be the caller of `deploy`.
    /// @param governor Final AccessManager admin, holding the role with a `GOVERNANCE_DELAY` execution delay (e.g. a
    ///        multisig). When it differs from `admin`, `admin` renounces the role at the end of the deployment.
    /// @param signers Oracle signer set.
    /// @param minSigners Oracle quorum.
    /// @param maxReportAge Oracle report age limit in seconds.
    /// @param maxSpreadBps Oracle dispersion limit in basis points.
    /// @param keepers Accounts granted the keeper role.
    /// @param riskAdmin Account granted the timelocked risk-admin role.
    /// @param oracleAdmin Account granted the timelocked oracle-admin role.
    /// @param guardian Account granted the guardian role.
    /// @param marketId Market identifier signed into reports.
    /// @param params Initial risk parameters.
    struct Config {
        address admin;
        address governor;
        address[] signers;
        uint8 minSigners;
        uint32 maxReportAge;
        uint16 maxSpreadBps;
        address[] keepers;
        address riskAdmin;
        address oracleAdmin;
        address guardian;
        bytes32 marketId;
        IPerpsMarket.RiskParams params;
    }

    /// @notice Addresses of a deployed system.
    struct System {
        AccessManager manager;
        OracleVerifier oracle;
        PerpsMarket market;
        OrderBook orderBook;
        LPVault vault;
    }

    /// @notice Risk parameters used by the tests, the replay and the local demo.
    /// @return p 20x max leverage, 1% maintenance, 5 bps fees, 50% PnL cap with ADL from 45% to 40%.
    function defaultRiskParams() internal pure returns (IPerpsMarket.RiskParams memory p) {
        p.maxLongOpenInterest = 50_000_000e18;
        p.maxShortOpenInterest = 50_000_000e18;
        p.reserveFactor = 0.8e18;
        p.maxPnlFactor = 0.5e18;
        p.adlThresholdFactor = 0.45e18;
        p.adlTargetFactor = 0.4e18;
        p.positionFeeBps = 5;
        p.initialMarginBps = 500;
        p.maintenanceMarginBps = 100;
        p.liquidationFeeBps = 20;
        p.orderTimeout = 120;
        p.minCollateral = 10e18;
        // Impact of a $1M skew: 1e24^2 / 1e18 * 5e8 / 1e18 = $500 (5 bps). Positive side pays half of that.
        p.positiveImpactFactor = 2.5e8;
        p.negativeImpactFactor = 5e8;
        // 50% APR at full utilisation: 0.5 / 31_536_000 per second.
        p.borrowFactor = 15_854_895_991;
        // Funding rate drifts by 3%/day per day at full proportional skew.
        p.maxFundingVelocity = 4_018_775;
        // Funding rate capped at 0.1% per hour.
        p.maxFundingRate = 277_777_777_777;
        p.skewScale = 10_000_000e18;
        p.minExecutionFee = 0.1e18;
    }

    /// @notice Deploys and wires the system. Must be called by `cfg.admin` (or while broadcasting as it).
    /// @param collateral 18-decimal stable collateral.
    /// @param cfg Deployment inputs.
    /// @return s The deployed contracts.
    function deploy(IERC20 collateral, Config memory cfg) internal returns (System memory s) {
        s.manager = new AccessManager(cfg.admin);
        s.oracle =
            new OracleVerifier(address(s.manager), cfg.signers, cfg.minSigners, cfg.maxReportAge, cfg.maxSpreadBps);
        s.market = new PerpsMarket(
            address(s.manager), collateral, s.oracle, cfg.marketId, cfg.params, "Perps LP Share", "PLP"
        );
        s.orderBook = s.market.orderBook();
        s.vault = s.market.vault();
        configureRoles(s, cfg);
        lockAdmin(s.manager, cfg);
    }

    /// @notice Maps every restricted selector to its role and grants the roles.
    /// @param s The deployed contracts.
    /// @param cfg Role holders.
    function configureRoles(System memory s, Config memory cfg) internal {
        AccessManager m = s.manager;

        bytes4[] memory one = new bytes4[](1);
        one[0] = OrderBook.executeOrder.selector;
        m.setTargetFunctionRole(address(s.orderBook), one, KEEPER_ROLE);
        one[0] = LPVault.executeRequest.selector;
        m.setTargetFunctionRole(address(s.vault), one, KEEPER_ROLE);

        bytes4[] memory two = new bytes4[](2);
        two[0] = PerpsMarket.liquidate.selector;
        two[1] = PerpsMarket.autoDeleverage.selector;
        m.setTargetFunctionRole(address(s.market), two, KEEPER_ROLE);

        one[0] = PerpsMarket.setRiskParams.selector;
        m.setTargetFunctionRole(address(s.market), one, RISK_ADMIN_ROLE);
        one[0] = PerpsMarket.setPaused.selector;
        m.setTargetFunctionRole(address(s.market), one, GUARDIAN_ROLE);

        two[0] = OracleVerifier.setSigners.selector;
        two[1] = OracleVerifier.setReportLimits.selector;
        m.setTargetFunctionRole(address(s.oracle), two, ORACLE_ADMIN_ROLE);

        m.labelRole(KEEPER_ROLE, "KEEPER");
        m.labelRole(RISK_ADMIN_ROLE, "RISK_ADMIN");
        m.labelRole(ORACLE_ADMIN_ROLE, "ORACLE_ADMIN");
        m.labelRole(GUARDIAN_ROLE, "GUARDIAN");

        for (uint256 i; i < cfg.keepers.length; ++i) {
            m.grantRole(KEEPER_ROLE, cfg.keepers[i], 0);
        }
        m.grantRole(RISK_ADMIN_ROLE, cfg.riskAdmin, GOVERNANCE_DELAY);
        m.grantRole(ORACLE_ADMIN_ROLE, cfg.oracleAdmin, GOVERNANCE_DELAY);
        m.grantRole(GUARDIAN_ROLE, cfg.guardian, 0);
    }

    /// @notice Last deployment step: gives the AccessManager admin role to `cfg.governor` with a `GOVERNANCE_DELAY`
    ///         execution delay, then makes `cfg.admin` renounce it if it is not the governor. From then on every
    ///         admin operation (granting a role, remapping or closing a target, changing the authority) must be
    ///         scheduled a day in advance, so the admin cannot bypass the risk and oracle timelocks.
    /// @dev Raising an existing member's execution delay takes effect immediately (no setback), as does a new grant
    ///      (the admin role has no grant delay), so the lock is active as soon as the deployment ends.
    /// @param m The AccessManager.
    /// @param cfg Deployment inputs (`admin` must be the caller).
    function lockAdmin(AccessManager m, Config memory cfg) internal {
        require(cfg.governor != address(0), InvalidGovernor());
        uint64 adminRole = m.ADMIN_ROLE();
        m.grantRole(adminRole, cfg.governor, GOVERNANCE_DELAY);
        if (cfg.governor != cfg.admin) m.renounceRole(adminRole, cfg.admin);
    }
}
