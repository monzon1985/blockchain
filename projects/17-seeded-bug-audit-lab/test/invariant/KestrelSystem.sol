// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { CommonBase } from "forge-std/Base.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockERC20 } from "../helpers/MockERC20.sol";
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

/// @title KestrelSystem
/// @notice Deploys and seeds the whole protocol for the stateful campaigns, so the Foundry
///         invariant suite and the Medusa harness exercise the identical system. It is the
///         deployer, so it owns the pools, holds the genesis governance supply and keeps a
///         small lending position used as the valuation probe.
/// @dev    Uses only cheatcodes both engines implement (`deal`, `warp`, `roll`).
contract KestrelSystem is CommonBase {
    /// @notice Proxy administrator (never one of the fuzzed actors).
    address public constant PROXY_ADMIN = address(0xAD00);
    /// @notice Owner of the risk parameters.
    address public constant RISK_OWNER = address(0xB0B0);
    /// @notice Initial governor treasury (governance tokens).
    uint256 public constant TREASURY = 100_000e18;

    MockERC20 public immutable collateral;
    MockERC20 public immutable debt;
    MockERC20 public immutable reward;
    MockERC20 public immutable stable;
    MockERC20 public immutable usdc;
    KestrelPool public immutable pool;
    KestrelPool public immutable pool6;
    PoolTwapOracle public immutable oracle;
    KestrelVault public immutable vault;
    KestrelProxy public immutable proxy;
    KestrelLending public immutable lending;
    GovToken public immutable gov;
    KestrelGovernor public immutable governor;
    KestrelRelayer public immutable relayer;

    constructor() {
        vm.deal(address(this), 1000 ether);
        collateral = new MockERC20("Collateral", "COL", 18);
        debt = new MockERC20("Debt USD", "DUSD", 18);
        reward = new MockERC20("Reward", "RWD", 18);
        stable = new MockERC20("Stable", "STB", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Main pool: 18/18 decimals, 0.30% fee. Second pool: 18/6 decimals, fee-free.
        pool = new KestrelPool(
            IERC20(address(collateral)),
            IERC20(address(debt)),
            0.5e18,
            IERC20(address(reward)),
            0.003e18,
            0.001 ether
        );
        pool6 = new KestrelPool(
            IERC20(address(stable)), IERC20(address(usdc)), 0.5e18, IERC20(address(reward)), 0, 0.001 ether
        );
        _seed(collateral, debt, pool, 1_000_000e18, 1_000_000e18);
        _seed(stable, usdc, pool6, 1_000_000e18, 1_000_000e6);

        oracle = new PoolTwapOracle(IObservablePool(address(pool)), 1800, 3600, 3600);
        vm.warp(block.timestamp + 1800);
        oracle.update();

        vault = new KestrelVault();
        vault.deposit{ value: 10 ether }(address(this), 0);

        KestrelConfig impl = new KestrelConfig();
        proxy = new KestrelProxy(
            address(impl), PROXY_ADMIN, abi.encodeCall(KestrelConfig.initialize, (RISK_OWNER, 7500, 2000e18))
        );
        lending =
            new KestrelLending(IERC20(address(debt)), pool, vault, oracle, IKestrelConfig(address(proxy)));
        debt.mint(address(this), 1_000_000e18);
        debt.approve(address(lending), type(uint256).max);
        lending.supply(1_000_000e18);
        // The valuation probe: a collateral position whose value the campaign watches.
        collateral.mint(address(this), 1000e18);
        collateral.approve(address(lending), type(uint256).max);
        lending.depositCollateral(1000e18);

        gov = new GovToken(address(this), 1_000_000e18);
        gov.delegate(address(this));
        governor = new KestrelGovernor(gov, 10, 4000, 6666, 50);
        gov.transfer(address(governor), TREASURY);

        relayer = new KestrelRelayer(pool);
        vm.roll(block.number + 51);
    }

    /// @notice Accept ETH (native fee withdrawals, vault redemptions).
    receive() external payable { }

    function _seed(MockERC20 a, MockERC20 b, KestrelPool p, uint256 amountA, uint256 amountB) private {
        a.mint(address(this), amountA);
        b.mint(address(this), amountB);
        a.approve(address(p), type(uint256).max);
        b.approve(address(p), type(uint256).max);
        p.addLiquidity(amountA, amountB, address(this));
    }
}
