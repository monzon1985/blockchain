// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {MockGasHeavyStrategy, MockPausableStrategy} from "../mocks/MockStrategies.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

/// @notice A strategy whose views revert (paused, or broken) must not freeze the vault. The position is counted at 0,
///         profit and loss are not booked, withdrawals keep working at the conservative price, deposits pause, and the
///         strategy can be force-removed. Regression tests for the review finding "one reverting strategy freezes the
///         whole vault and cannot be removed".
contract ImpairmentTest is VaultFixture {
    MockPausableStrategy internal pausable;

    function setUp() public override {
        super.setUp();
        pausable = new MockPausableStrategy(IERC20(address(asset)));
        vm.label(address(pausable), "pausable");
        _listStrategy(pausable, _cap());
        _deposit(alice, 1000 * unit);
        _allocate(pausable, 100 * unit); // 900 stay idle
    }

    function test_pausedStrategy_vaultKeepsWorkingAtTheConservativePrice() public {
        pausable.setPaused(true);

        // Every ERC-4626 "MUST NOT revert" view answers, pricing the paused position at 0.
        assertEq(vault.totalAssets(), 900 * unit);
        assertEq(vault.maxWithdraw(alice), 900 * unit);
        assertEq(vault.maxRedeem(alice), vault.balanceOf(alice));
        assertEq(vault.availableLiquidity(), 900 * unit);
        assertEq(vault.strategyAssets(pausable), 0);
        assertEq(vault.maxDeposit(bob), 0, "deposits are paused");
        assertEq(vault.maxMint(bob), 0);
        assertEq(address(vault.previewAccrual().impairedStrategy), address(pausable));

        // The keeper accrual works and books nothing.
        vm.expectEmit(address(vault));
        emit IAllocatorVault.PnLDeferred(pausable, 900 * unit, 1000 * unit);
        vault.accrue();
        assertEq(vault.lastTotalAssets(), 1000 * unit, "the markdown is not booked as a loss");

        // Withdrawals from idle keep working.
        vm.prank(alice);
        vault.withdraw(10 * unit, alice, alice);
        assertEq(asset.balanceOf(alice), 10 * unit);
        vm.prank(alice);
        vault.redeem(1, alice, alice);
    }

    function test_pausedStrategy_depositsAndMintsArePaused() public {
        pausable.setPaused(true);
        asset.mint(bob, 100 * unit);
        vm.startPrank(bob);
        asset.approve(address(vault), 100 * unit);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.DepositsPausedWhileImpaired.selector, pausable));
        vault.deposit(100 * unit, bob);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.DepositsPausedWhileImpaired.selector, pausable));
        vault.mint(1e6, bob);
        vm.stopPrank();

        pausable.setPaused(false);
        assertEq(vault.maxDeposit(bob), type(uint256).max, "deposits resume with the strategy");
        _deposit(bob, 100 * unit);
    }

    /// @dev Pause arbitrage, both ways: nobody can buy the markdown cheaply, and whoever exits during the pause gets no
    ///      more than those who stay. When the strategy resumes, its value is back in the price at once (it was never
    ///      booked as a loss, so it is not re-locked as profit).
    function test_pausedStrategy_noFirstMoverGainAndValueReturnsAtOnce() public {
        _deposit(bob, 1000 * unit);
        _allocate(pausable, 200 * unit); // 1800 idle + 200 in the strategy
        pausable.setPaused(true);

        uint256 aliceOut = _redeemAll(alice); // exits during the pause
        assertEq(aliceOut, 900 * unit, "the exit is priced with the paused position at 0");

        pausable.setPaused(false);
        uint256 bobValue = vault.convertToAssets(vault.balanceOf(bob));
        assertApproxEqAbs(bobValue, 1100 * unit, 1, "the stayer keeps the haircut, immediately");
        vault.accrue();
        assertEq(vault.previewAccrual().lockedProfit, 0, "no profit: the value was never written off");
        assertGe(_redeemAll(bob), aliceOut, "whoever stays gets at least as much as whoever ran");
    }

    function test_pausedStrategy_canBeForceRemovedAndItsValueWrittenOff() public {
        pausable.setPaused(true);
        vm.prank(guardian);
        vault.zeroCap(pausable);

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.StrategyHasAssets.selector, pausable, 0));
        vault.removeStrategy(pausable);

        vm.prank(curator);
        vault.submitStrategyRemoval(pausable);
        vm.warp(block.timestamp + 3 days);

        vm.expectEmit(address(vault));
        emit IAllocatorVault.StrategyRemoved(curator, pausable, 0, 0);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.LossRealized(100 * unit, 0);
        vm.prank(curator);
        vault.removeStrategy(pausable);

        assertEq(vault.withdrawQueueLength(), 3);
        assertEq(vault.totalAssets(), 900 * unit);
        assertEq(address(vault.previewAccrual().impairedStrategy), address(0));
        _deposit(bob, 90 * unit); // deposits resume once the impaired strategy is gone
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(bob)), 90 * unit, 1);
    }

    function test_brokenStrategy_everyViewRevertsButTheVaultKeepsWorking() public {
        pausable.setBroken(true); // balanceOf, previewRedeem, maxWithdraw and maxRedeem all revert

        assertEq(vault.totalAssets(), 900 * unit);
        assertEq(vault.maxWithdraw(alice), 900 * unit);
        assertEq(vault.availableLiquidity(), 900 * unit);
        vm.prank(alice);
        vault.withdraw(450 * unit, alice, alice);

        vm.prank(guardian);
        vault.zeroCap(pausable);
        vm.prank(curator);
        vault.submitStrategyRemoval(pausable);
        vm.warp(block.timestamp + 3 days);
        vm.prank(curator);
        vault.removeStrategy(pausable);
        assertEq(vault.withdrawQueueLength(), 3);
        assertEq(vault.totalAssets(), 450 * unit);
    }

    /// @dev Not EIP-4626 compliant: `maxRedeem` says the position can be redeemed, `redeem` refuses. The removal still
    ///      goes through after the forced-removal timelock and writes the whole position off.
    function test_strategyThatRefusesRedemptionsCanStillBeForceRemoved() public {
        pausable.setWithdrawalsBlocked(true);
        vm.prank(guardian);
        vault.zeroCap(pausable);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAllocatorVault.StrategyHasAssets.selector, pausable, 100 * unit));
        vault.removeStrategy(pausable);

        vm.prank(curator);
        vault.submitStrategyRemoval(pausable);
        vm.warp(block.timestamp + 3 days);
        vm.expectEmit(address(vault));
        emit IAllocatorVault.StrategyRemoved(curator, pausable, 0, 100 * unit);
        vm.prank(curator);
        vault.removeStrategy(pausable);
        assertEq(vault.totalAssets(), 900 * unit);
    }

    /// @dev The one strategy failure that is not contained automatically: a non-compliant strategy that reports
    ///      `maxWithdraw` liquidity but reverts `withdraw` blocks the withdrawals that reach it in the withdraw queue.
    ///      The allocator can move it to the end of the queue at once (no timelock), which restores them.
    function test_strategyThatRefusesWithdrawalsOnlyBlocksWithdrawalsThatReachIt() public {
        _allocate(liquid, 400 * unit); // idle 500, liquid 400, pausable 100
        IERC4626[] memory q = new IERC4626[](4);
        (q[0], q[1], q[2], q[3]) = (pausable, liquid, lossy, illiquid);
        vm.prank(allocator);
        vault.setWithdrawQueue(q);
        pausable.setWithdrawalsBlocked(true);

        vm.prank(alice);
        vault.withdraw(500 * unit, alice, alice); // idle alone covers it
        vm.prank(alice);
        vm.expectRevert(MockPausableStrategy.StrategyPaused.selector);
        vault.withdraw(50 * unit, alice, alice); // reaches the refusing strategy first

        (q[0], q[3]) = (illiquid, pausable);
        vm.prank(allocator);
        vault.setWithdrawQueue(q);
        vm.prank(alice);
        vault.withdraw(50 * unit, alice, alice);
        assertEq(asset.balanceOf(alice), 550 * unit);
    }

    /// @dev While a position is impaired the safe-price limiter's clock stops: a 30-day impairment followed by recovery
    ///      leaves the collateral price exactly where it was (no headroom banked behind the conservative price), while
    ///      30 unimpaired days let it grow.
    function test_rateLimiterClockStopsWhileImpaired() public {
        asset.mint(address(vault), 10_000 * unit); // the price will run far above the limiter's ceiling
        vault.accrue();
        vm.warp(block.timestamp + 7 days);
        vault.accrue();
        uint256 safeBefore = vault.safeSharePrice();
        assertLt(safeBefore, vault.sharePrice(), "the limiter binds");

        uint256 snapshot = vm.snapshotState();
        vm.warp(block.timestamp + 30 days);
        vault.accrue();
        uint256 safeUnimpaired = vault.safeSharePrice();
        vm.revertToState(snapshot);

        pausable.setPaused(true);
        for (uint256 i; i < 30; ++i) {
            vm.warp(block.timestamp + 1 days);
            vault.accrue();
            assertEq(vault.safeSharePrice(), safeBefore, "no growth while impaired");
        }
        pausable.setPaused(false);
        assertEq(vault.safeSharePrice(), safeBefore, "and none banked for afterwards");
        assertGt(safeUnimpaired, safeBefore, "30 unimpaired days do let it grow");
        vm.warp(block.timestamp + 30 days);
        assertEq(vault.safeSharePrice(), safeUnimpaired, "growth resumes from where it stopped");
    }

    function test_pausedStrategy_cannotBeAllocatedTo() public {
        pausable.setPaused(true);
        IAllocatorVault.Allocation[] memory allocations = new IAllocatorVault.Allocation[](1);
        allocations[0] = IAllocatorVault.Allocation({strategy: pausable, assets: 500 * unit});
        vm.prank(allocator);
        vm.expectRevert(MockPausableStrategy.StrategyPaused.selector);
        vault.reallocate(allocations);
    }

    function test_relistingAWrittenOffStrategyReturnsItsValueAsLockedProfit() public {
        pausable.setPaused(true);
        vm.prank(guardian);
        vault.zeroCap(pausable);
        vm.prank(curator);
        vault.submitStrategyRemoval(pausable);
        vm.warp(block.timestamp + 3 days);
        vm.prank(curator);
        vault.removeStrategy(pausable);
        assertEq(vault.totalAssets(), 900 * unit);

        pausable.setPaused(false);
        _listStrategy(pausable, _cap());
        vault.accrue();
        assertEq(vault.totalAssets(), 900 * unit, "written-off value comes back as locked profit");
        vm.warp(block.timestamp + 7 days);
        assertEq(vault.totalAssets(), 1000 * unit);
    }
}

/// @notice Under-funding a transaction must not let anyone make the vault count a strategy as failing (which would
///         price it at 0 for that call). Regression test for the out-of-gas guard that comes with the try/catch
///         valuation.
contract ImpairmentGasGuardTest is VaultFixture {
    MockGasHeavyStrategy internal heavy;
    uint256 internal constant BURN = 8_000_000;

    function setUp() public override {
        super.setUp();
        heavy = new MockGasHeavyStrategy(IERC20(address(asset)));
        _listStrategy(heavy, _cap());
        _deposit(alice, 1000 * unit);
        _allocate(heavy, 500 * unit);
        heavy.setGasToBurn(BURN);
    }

    /// @dev For every gas limit, `accrue` either reverts or values the heavy strategy in full: it never books it as
    ///      impaired. Between ~4M and ~8.1M gas the strategy's `previewRedeem` runs out of gas while the vault would
    ///      still have enough left to finish, which is exactly the case the guard turns into a revert.
    function test_outOfGasInAStrategyIsNeverTreatedAsAFailingStrategy() public {
        bytes memory oog = abi.encodeWithSelector(IAllocatorVault.StrategyCallOutOfGas.selector, heavy);
        uint256 guarded;
        for (uint256 gasLimit = 1_000_000; gasLimit <= 10_000_000; gasLimit += 250_000) {
            vm.recordLogs();
            (bool ok, bytes memory ret) = address(vault).call{gas: gasLimit}(abi.encodeCall(vault.accrue, ()));
            if (ok) {
                Vm.Log[] memory logs = vm.getRecordedLogs();
                for (uint256 i; i < logs.length; ++i) {
                    assertTrue(logs[i].topics[0] != IAllocatorVault.PnLDeferred.selector, "faked impairment");
                }
                assertEq(vault.lastTotalAssets(), 1000 * unit);
            } else if (keccak256(ret) == keccak256(oog)) {
                ++guarded;
            }
        }
        assertGt(guarded, 0, "the guard fired inside the window");
        vault.accrue{gas: 20_000_000}(); // with enough gas the strategy is valued normally
        assertEq(vault.totalAssets(), 1000 * unit);
    }

    function test_genuineFailureWithPlentyOfGasStillCountsAsImpaired() public {
        heavy.setGasToBurn(0);
        assertEq(vault.totalAssets(), 1000 * unit);
        // A cheap strategy that reverts leaves almost all the gas: that is a genuine failure, priced at 0.
        MockPausableStrategy pausable = new MockPausableStrategy(IERC20(address(asset)));
        _listStrategy(IERC4626(address(pausable)), _cap());
        _allocate(pausable, 100 * unit);
        pausable.setPaused(true);
        assertEq(vault.totalAssets(), 900 * unit);
    }
}
