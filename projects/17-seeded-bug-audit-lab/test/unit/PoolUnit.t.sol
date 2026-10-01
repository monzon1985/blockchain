// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MockERC20 } from "../helpers/MockERC20.sol";
import { KestrelPool } from "kestrel/KestrelPool.sol";
import { RefundStrander } from "../attacks/RefundStrander.sol";

/// @notice Unit tests for {KestrelPool}: happy paths and every revert path.
contract PoolUnit is BaseTest {
    // --- constructor ---

    function test_constructor_rejectsBadParameters() public {
        IERC20 c = IERC20(address(collateral));
        IERC20 d = IERC20(address(debt));
        IERC20 r = IERC20(address(reward));
        vm.expectRevert(abi.encodeWithSelector(KestrelPool.UnknownToken.selector, address(0)));
        new KestrelPool(IERC20(address(0)), d, 0.5e18, r, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(KestrelPool.UnknownToken.selector, address(c)));
        new KestrelPool(c, c, 0.5e18, r, 0, 0);
        vm.expectRevert(KestrelPool.ZeroAmount.selector);
        new KestrelPool(c, d, 0, r, 0, 0);
        vm.expectRevert(KestrelPool.ZeroAmount.selector);
        new KestrelPool(c, d, 1e18, r, 0, 0);
        vm.expectRevert(KestrelPool.ZeroAmount.selector);
        new KestrelPool(c, d, 0.5e18, r, 0.1e18, 0);
    }

    function test_constructor_setsScales() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        KestrelPool p = new KestrelPool(
            IERC20(address(collateral)), IERC20(address(usdc)), 0.8e18, IERC20(address(reward)), 0, 0
        );
        assertEq(p.scale0(), 1);
        assertEq(p.scale1(), 1e12);
        assertEq(p.weight1(), 0.2e18);
    }

    // --- liquidity ---

    function test_addLiquidity_roundTrip() public {
        _mintApprove(collateral, alice, 10_000e18, address(pool));
        _mintApprove(debt, alice, 10_000e18, address(pool));
        vm.prank(alice);
        uint256 shares = pool.addLiquidity(10_000e18, 10_000e18, alice);
        assertEq(shares, 10_000e18, "1:1 pool, shares == amount");

        vm.prank(alice);
        (uint256 a0, uint256 a1) = pool.removeLiquidity(shares, alice);
        assertEq(a0, 10_000e18);
        assertEq(a1, 10_000e18);
        assertEq(collateral.balanceOf(alice), 10_000e18);
    }

    function test_addLiquidity_reverts() public {
        vm.expectRevert(KestrelPool.ZeroAmount.selector);
        pool.addLiquidity(0, 1, alice);
        _mintApprove(collateral, alice, 10e18, address(pool));
        _mintApprove(debt, alice, 10e18, address(pool));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KestrelPool.UnbalancedJoin.selector, 1e18, 2e18));
        pool.addLiquidity(1e18, 2e18, alice);
    }

    function test_addLiquidity_firstJoinMustExceedMinimumLiquidity() public {
        KestrelPool p = _freshPool();
        vm.expectRevert(KestrelPool.ZeroAmount.selector);
        p.addLiquidity(1000, 1000, deployer); // sqrt == MINIMUM_LIQUIDITY
        p.addLiquidity(1e18, 1e18, deployer);
        assertEq(p.sharesOf(address(0xdead)), 1000, "minimum liquidity locked");
    }

    function test_addLiquidity_rejectsZeroShares() public {
        KestrelPool p = _freshPool();
        p.addLiquidity(1e18, 1e18, deployer);
        uint256 s = p.totalShares();
        // Fee-paying round trips grow both reserves above the share supply (token1 more).
        uint256 out = p.swap(address(collateral), 0.1e18, 0, deployer);
        p.swap(address(debt), out, 0, deployer);
        out = p.swap(address(debt), 0.5e18, 0, deployer);
        p.swap(address(collateral), out, 0, deployer);
        assertGt(p.reserve0(), s, "reserve0 above supply");
        assertGe(p.reserve1(), p.reserve0(), "reserve1 at least reserve0");
        // 1 wei of token0 is balanced by 1 wei of token1 but is worth less than one share.
        vm.expectRevert(KestrelPool.ZeroAmount.selector);
        p.addLiquidity(1, 1, deployer);
    }

    function test_addLiquidityExactShares_paysProRataRoundedUp() public {
        _mintApprove(collateral, alice, 1000e18, address(pool));
        _mintApprove(debt, alice, 1000e18, address(pool));
        uint256 total = pool.totalShares();
        uint256 r0 = pool.reserve0();
        vm.prank(alice);
        (uint256 a0, uint256 a1) = pool.addLiquidityExactShares(100e18, 1000e18, 1000e18, alice);
        assertGe(a0 * total, 100e18 * r0, "paid at least pro-rata");
        assertLe(a0, 100e18 + 1, "rounded up by at most a wei");
        assertEq(a0, a1, "symmetric pool");
        assertEq(pool.sharesOf(alice), 100e18);
    }

    function test_addLiquidityExactShares_reverts() public {
        vm.expectRevert(KestrelPool.ZeroAmount.selector);
        pool.addLiquidityExactShares(0, 1, 1, alice);

        KestrelPool empty = _freshPool();
        vm.expectRevert(KestrelPool.EmptyPool.selector);
        empty.addLiquidityExactShares(1, 1, 1, alice);

        vm.expectPartialRevert(KestrelPool.SlippageExceeded.selector);
        pool.addLiquidityExactShares(100e18, 1e18, 1e18, alice);
    }

    function test_removeLiquidity_reverts() public {
        vm.expectRevert(KestrelPool.ZeroAmount.selector);
        pool.removeLiquidity(0, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KestrelPool.InsufficientShares.selector, 1, 0));
        pool.removeLiquidity(1, alice);

        // A 6-decimal side: one share is worth less than one unit of it.
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        KestrelPool p = new KestrelPool(
            IERC20(address(collateral)), IERC20(address(usdc)), 0.5e18, IERC20(address(reward)), 0, 0
        );
        _mintApprove(collateral, deployer, 1e24, address(p));
        usdc.mint(deployer, 1e12);
        usdc.approve(address(p), type(uint256).max);
        p.addLiquidity(1e24, 1e12, deployer);
        vm.expectRevert(KestrelPool.ZeroAmount.selector);
        p.removeLiquidity(1, deployer);
    }

    // --- swaps ---

    function test_swap_matchesQuoteAndPreservesSolvency() public {
        _mintApprove(collateral, alice, 10_000e18, address(pool));
        uint256 quote = pool.getAmountOut(address(collateral), 10_000e18);
        vm.prank(alice);
        uint256 out = pool.swap(address(collateral), 10_000e18, quote, alice);
        assertEq(out, quote, "swap == quote");
        assertEq(debt.balanceOf(alice), out);
        assertEq(pool.reserve0(), collateral.balanceOf(address(pool)));
        assertEq(pool.reserve1(), debt.balanceOf(address(pool)));
    }

    function test_swap_reverts() public {
        vm.expectRevert(KestrelPool.ZeroAmount.selector);
        pool.swap(address(collateral), 0, 0, alice);
        vm.expectRevert(abi.encodeWithSelector(KestrelPool.UnknownToken.selector, address(0xBEEF)));
        pool.swap(address(0xBEEF), 1e18, 0, alice);
        _mintApprove(collateral, alice, 1e18, address(pool));
        uint256 quote = pool.getAmountOut(address(collateral), 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KestrelPool.InsufficientOutput.selector, quote, quote + 1));
        pool.swap(address(collateral), 1e18, quote + 1, alice);
    }

    function test_swapWithNativeSponsor_refundsOverpayment() public {
        _mintApprove(debt, alice, 1e18, address(pool));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        pool.swapWithNativeSponsor{ value: 1 ether }(address(debt), 1e18, 0, alice);
        assertEq(alice.balance, 1 ether - NATIVE_FEE, "refunded all but the fee");
        assertEq(pool.nativeFeesCollected(), NATIVE_FEE);
        assertEq(address(pool).balance, NATIVE_FEE);
    }

    function test_swapWithNativeSponsor_reverts() public {
        vm.expectRevert(KestrelPool.ZeroAmount.selector);
        pool.swapWithNativeSponsor{ value: NATIVE_FEE }(address(debt), 0, 0, alice);
        vm.expectRevert(abi.encodeWithSelector(KestrelPool.InsufficientNativeFee.selector, 1, NATIVE_FEE));
        pool.swapWithNativeSponsor{ value: 1 }(address(debt), 1e18, 0, alice);
        _mintApprove(debt, alice, 1e18, address(pool));
        vm.deal(alice, NATIVE_FEE);
        uint256 quote = pool.getAmountOut(address(debt), 1e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(KestrelPool.InsufficientOutput.selector, quote, type(uint256).max)
        );
        pool.swapWithNativeSponsor{ value: NATIVE_FEE }(address(debt), 1e18, type(uint256).max, alice);
    }

    function test_batchSwap_multiStepRoundTrip() public {
        _mintApprove(collateral, alice, 1000e18, address(pool));
        _mintApprove(debt, alice, 1000e18, address(pool));
        address[] memory assets = _pair();
        KestrelPool.BatchStep[] memory steps = new KestrelPool.BatchStep[](2);
        steps[0] = KestrelPool.BatchStep({ assetInIndex: 0, assetOutIndex: 1, amountIn: 100e18 });
        steps[1] = KestrelPool.BatchStep({ assetInIndex: 1, assetOutIndex: 0, amountIn: 50e18 });
        vm.prank(alice);
        int256[] memory deltas = pool.batchSwap(assets, steps, alice);
        assertGt(deltas[0], 0, "net token0 paid");
        assertLt(deltas[1], 0, "net token1 received");
        assertEq(pool.reserve0(), collateral.balanceOf(address(pool)));
        assertEq(pool.reserve1(), debt.balanceOf(address(pool)));
    }

    function test_batchSwap_netZeroDeltaMovesNothing() public {
        address[] memory assets = _pair();
        KestrelPool.BatchStep[] memory steps = new KestrelPool.BatchStep[](0);
        int256[] memory deltas = pool.batchSwap(assets, steps, alice);
        assertEq(deltas[0], 0);
        assertEq(deltas[1], 0);
    }

    function test_batchSwap_reverts() public {
        address[] memory one = new address[](1);
        one[0] = address(collateral);
        KestrelPool.BatchStep[] memory steps = new KestrelPool.BatchStep[](1);
        vm.expectRevert(KestrelPool.BadAssetIndex.selector);
        pool.batchSwap(one, steps, alice);

        address[] memory assets = _pair();
        steps[0] = KestrelPool.BatchStep({ assetInIndex: 0, assetOutIndex: 2, amountIn: 1e18 });
        vm.expectRevert(KestrelPool.BadAssetIndex.selector);
        pool.batchSwap(assets, steps, alice);

        steps[0] = KestrelPool.BatchStep({ assetInIndex: 1, assetOutIndex: 1, amountIn: 1e18 });
        vm.expectRevert(KestrelPool.BadAssetIndex.selector);
        pool.batchSwap(assets, steps, alice);

        steps[0] = KestrelPool.BatchStep({ assetInIndex: 0, assetOutIndex: 1, amountIn: 0 });
        vm.expectRevert(KestrelPool.ZeroAmount.selector);
        pool.batchSwap(assets, steps, alice);

        assets[1] = address(0xBEEF);
        steps[0] = KestrelPool.BatchStep({ assetInIndex: 0, assetOutIndex: 1, amountIn: 1e18 });
        vm.expectRevert(abi.encodeWithSelector(KestrelPool.UnknownToken.selector, address(0xBEEF)));
        pool.batchSwap(assets, steps, alice);
    }

    function test_getAmountOut_unknownToken() public {
        vm.expectRevert(abi.encodeWithSelector(KestrelPool.UnknownToken.selector, address(0xBEEF)));
        pool.getAmountOut(address(0xBEEF), 1e18);
    }

    // --- rewards ---

    function test_rewards_accrueClaimAndCapAtReserve() public {
        reward.mint(deployer, 100e18);
        reward.approve(address(pool), type(uint256).max);
        pool.fundRewards(100e18);
        pool.setRewardRate(1e18);

        _mintApprove(collateral, alice, 1_000_000e18, address(pool));
        _mintApprove(debt, alice, 1_000_000e18, address(pool));
        vm.prank(alice);
        pool.addLiquidity(1_000_000e18, 1_000_000e18, alice);

        vm.warp(block.timestamp + 10);
        uint256 previewed = pool.earned(alice);
        assertApproxEqAbs(previewed, 5e18, 1e6, "half of 10 s of emissions");
        vm.prank(alice);
        uint256 got = pool.claimReward();
        assertEq(got, previewed);

        // A long accrual is capped by the remaining reserve.
        vm.warp(block.timestamp + 1000);
        vm.prank(alice);
        got = pool.claimReward();
        assertEq(got, 100e18 - previewed, "capped at the reserve");
        assertEq(pool.rewardReserve(), 0);
        assertGt(pool.rewardsOwed(alice), 0, "the shortfall stays owed");
    }

    function test_rewards_claimWithNothingOwed() public {
        vm.prank(alice);
        assertEq(pool.claimReward(), 0);
    }

    function test_rewards_earnedWithoutShares() public {
        KestrelPool p = _freshPool();
        assertEq(p.earned(alice), 0);
    }

    function test_rewards_reverts() public {
        vm.expectRevert(KestrelPool.ZeroAmount.selector);
        pool.fundRewards(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.setRewardRate(1);
    }

    // --- native fees ---

    function test_withdrawNativeFees_ownerSweepsCollectedFees() public {
        _sponsoredSwap();
        uint256 before = bob.balance;
        pool.withdrawNativeFees(payable(bob), NATIVE_FEE);
        assertEq(bob.balance - before, NATIVE_FEE);
        assertEq(pool.nativeFeesCollected(), 0);
        assertEq(address(pool).balance, 0);
    }

    function test_withdrawNativeFees_reverts() public {
        _sponsoredSwap();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.withdrawNativeFees(payable(alice), 1);
        vm.expectRevert(KestrelPool.InvalidRecipient.selector);
        pool.withdrawNativeFees(payable(address(0)), 1);
        vm.expectRevert(
            abi.encodeWithSelector(KestrelPool.ExceedsNativeFees.selector, NATIVE_FEE + 1, NATIVE_FEE)
        );
        pool.withdrawNativeFees(payable(bob), NATIVE_FEE + 1);
        RefundStrander noReceive = new RefundStrander(pool);
        vm.expectRevert(KestrelPool.NativeTransferFailed.selector);
        pool.withdrawNativeFees(payable(address(noReceive)), NATIVE_FEE);
    }

    // --- views ---

    function test_views() public view {
        (uint256 r0, uint256 r1) = pool.getReserves();
        assertEq(r0, 1_000_000e18);
        assertEq(r1, 1_000_000e18);
        assertEq(pool.spotPrice0In1(), 1e18);
        (uint256 c, uint256 t) = pool.observe();
        assertEq(t, block.timestamp);
        assertGt(c, 0);
    }

    function test_observe_sameBlockAddsNothing() public {
        _mintApprove(collateral, alice, 1e18, address(pool));
        vm.prank(alice);
        pool.swap(address(collateral), 1e18, 0, alice); // syncs the accumulator now
        (uint256 c,) = pool.observe();
        assertEq(c, pool.priceCumulativeLast(), "no elapsed time, no accrual");
    }

    // --- helpers ---

    function _freshPool() internal returns (KestrelPool p) {
        p = new KestrelPool(
            IERC20(address(collateral)),
            IERC20(address(debt)),
            0.5e18,
            IERC20(address(reward)),
            SWAP_FEE,
            NATIVE_FEE
        );
        collateral.mint(deployer, 10e18);
        debt.mint(deployer, 10e18);
        collateral.approve(address(p), type(uint256).max);
        debt.approve(address(p), type(uint256).max);
    }

    function _pair() internal view returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = address(collateral);
        assets[1] = address(debt);
    }

    function _sponsoredSwap() internal {
        _mintApprove(debt, alice, 1e18, address(pool));
        vm.deal(alice, NATIVE_FEE);
        vm.prank(alice);
        pool.swapWithNativeSponsor{ value: NATIVE_FEE }(address(debt), 1e18, 0, alice);
    }
}
