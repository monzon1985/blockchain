// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockERC20 } from "./helpers/MockERC20.sol";

import { KestrelPool } from "kestrel/KestrelPool.sol";
import { KestrelVault } from "kestrel/KestrelVault.sol";
import { KestrelLending } from "kestrel/KestrelLending.sol";
import { KestrelGovernor } from "kestrel/KestrelGovernor.sol";
import { KestrelRelayer } from "kestrel/KestrelRelayer.sol";
import { KestrelProxy } from "kestrel/KestrelProxy.sol";

import { GovToken } from "shared/GovToken.sol";
import { KestrelConfig } from "shared/KestrelConfig.sol";
import { IKestrelConfig } from "shared/IKestrelConfig.sol";
import { PoolTwapOracle, IObservablePool } from "shared/PoolTwapOracle.sol";

/// @title BaseTest
/// @notice Shared deployment for exploit, regression, unit and gas suites. The `kestrel/`
///         remapping resolves to the vulnerable or fixed tree depending on the Foundry profile,
///         so a single setup exercises both.
contract BaseTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant SWAP_FEE = 0.003e18; // 0.30%
    uint256 internal constant NATIVE_FEE = 0.001 ether;
    uint256 internal constant LTV_BPS = 7500; // 75%
    uint256 internal constant ETH_USD = 2000e18; // debt units per ETH
    uint256 internal constant TWAP_PERIOD = 1800; // 30 minutes
    uint256 internal constant TWAP_MAX_WINDOW = 3600; // 1 hour
    uint256 internal constant TWAP_MAX_AGE = 3600; // 1 hour
    uint256 internal constant VOTING_PERIOD = 10; // blocks
    uint256 internal constant QUORUM_BPS = 4000; // 40%
    uint256 internal constant EMERGENCY_QUORUM_BPS = 6666; // 66.66%
    uint256 internal constant EMERGENCY_LOOKBACK = 50; // blocks
    uint256 internal constant GOV_SUPPLY = 1_000_000e18;

    // Actors
    address internal deployer = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal lender = makeAddr("lender");
    address internal riskOwner = makeAddr("riskOwner");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal attacker;
    uint256 internal attackerPk;
    address internal user;
    uint256 internal userPk;

    // Core protocol
    MockERC20 internal collateral; // pool token0 (18d)
    MockERC20 internal debt; // pool token1 (18d)
    MockERC20 internal reward; // LP reward token (18d)
    KestrelPool internal pool;
    KestrelVault internal vault;
    KestrelLending internal lending;
    PoolTwapOracle internal oracle;
    GovToken internal gov;
    KestrelGovernor internal governor;
    KestrelConfig internal configImpl;
    KestrelProxy internal proxy;
    IKestrelConfig internal config; // the proxy, typed as the config interface
    KestrelRelayer internal relayer;

    function setUp() public virtual {
        (attacker, attackerPk) = makeAddrAndKey("attacker");
        (user, userPk) = makeAddrAndKey("user");

        collateral = new MockERC20("Collateral", "COL", 18);
        debt = new MockERC20("Debt USD", "DUSD", 18);
        reward = new MockERC20("Reward", "RWD", 18);

        // token0 = collateral, token1 = debt, so spotPrice0In1 = debt per collateral.
        pool = new KestrelPool(
            IERC20(address(collateral)),
            IERC20(address(debt)),
            0.5e18,
            IERC20(address(reward)),
            SWAP_FEE,
            NATIVE_FEE
        );

        // Seed a 1:1, 1e24 / 1e24 pool.
        _mintApprove(collateral, deployer, 1_000_000e18, address(pool));
        _mintApprove(debt, deployer, 1_000_000e18, address(pool));
        pool.addLiquidity(1_000_000e18, 1_000_000e18, deployer);

        // TWAP oracle: open a window now, let one period elapse and publish it.
        oracle =
            new PoolTwapOracle(IObservablePool(address(pool)), TWAP_PERIOD, TWAP_MAX_WINDOW, TWAP_MAX_AGE);
        vm.warp(block.timestamp + TWAP_PERIOD);
        oracle.update();

        vault = new KestrelVault();

        // Risk config behind the proxy: `proxyAdmin` administers the proxy, `riskOwner` owns the
        // parameters (a transparent proxy keeps the two roles apart).
        configImpl = new KestrelConfig();
        proxy = new KestrelProxy(
            address(configImpl),
            proxyAdmin,
            abi.encodeCall(KestrelConfig.initialize, (riskOwner, LTV_BPS, ETH_USD))
        );
        config = IKestrelConfig(address(proxy));

        lending = new KestrelLending(IERC20(address(debt)), pool, vault, oracle, config);

        gov = new GovToken(deployer, GOV_SUPPLY);
        governor =
            new KestrelGovernor(gov, VOTING_PERIOD, QUORUM_BPS, EMERGENCY_QUORUM_BPS, EMERGENCY_LOOKBACK);

        relayer = new KestrelRelayer(pool);

        // The genesis holder delegates to itself, then enough blocks pass for the governance
        // checkpoints to be "historical" for both the proposal snapshot and the emergency lookback.
        gov.delegate(deployer);
        vm.roll(block.number + EMERGENCY_LOOKBACK + 1);
    }

    // --- helpers ---

    function _mintApprove(MockERC20 token, address to, uint256 amount, address spender) internal {
        token.mint(to, amount);
        vm.prank(to);
        token.approve(spender, type(uint256).max);
    }

    /// @dev Supply debt-token liquidity from `lender` into the lending market.
    function _seedLending(uint256 amount) internal {
        debt.mint(lender, amount);
        vm.startPrank(lender);
        debt.approve(address(lending), type(uint256).max);
        lending.supply(amount);
        vm.stopPrank();
    }

    /// @dev Deposit `amount` ETH into the vault for `who`, returning the minted shares.
    function _vaultDeposit(address who, uint256 amount) internal returns (uint256 shares) {
        vm.deal(who, who.balance + amount);
        vm.prank(who);
        shares = vault.deposit{ value: amount }(who, 0);
    }

    /// @dev Let `seconds_` pass and publish a fresh TWAP window covering them.
    function _advanceAndPublish(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
        oracle.update();
    }

    /// @dev Read the proxy admin the way the admin itself does (transparent proxy).
    function _proxyAdmin() internal returns (address account) {
        vm.prank(proxyAdmin);
        account = proxy.admin();
    }
}
