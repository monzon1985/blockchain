// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {ILPVault} from "../../src/interfaces/ILPVault.sol";
import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {IOrderBook} from "../../src/interfaces/IOrderBook.sol";
import {IPerpsMarket} from "../../src/interfaces/IPerpsMarket.sol";
import {PerpsTestBase} from "../utils/PerpsTestBase.sol";

contract LPVaultTest is PerpsTestBase {
    uint256 internal constant POOL = 1_000_000e18;

    function _riskParams() internal pure override returns (IPerpsMarket.RiskParams memory) {
        return _staticRiskParams();
    }

    function _requestRedeem(address who, uint256 shares, uint256 minAssets) internal returns (uint256 id) {
        uint256 fee = _minFee();
        _fund(who, fee);
        vm.prank(who);
        id = vault.requestRedeem(shares, minAssets, fee);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Deposits
    // ---------------------------------------------------------------------------------------------------------------

    function test_deposit_requestAndExecute() public {
        uint256 fee = _minFee();
        _fund(lp, POOL + fee);
        vm.expectEmit(address(vault));
        emit ILPVault.LpRequestCreated(1, lp, true, POOL, POOL, fee);
        vm.prank(lp);
        uint256 id = vault.requestDeposit(POOL, POOL, fee);
        assertEq(vault.escrowedAssets(), POOL + fee);
        assertEq(usd.balanceOf(address(vault)), POOL + fee);
        ILPVault.LpRequest memory req = vault.getRequest(id);
        assertEq(req.account, lp);
        assertTrue(req.isDeposit);

        skip(1);
        vm.expectEmit(address(market));
        emit IPerpsMarket.LiquidityAdded(POOL, POOL);
        vm.expectEmit(address(vault));
        emit ILPVault.LpRequestExecuted(id, keeper, POOL, POOL, PRICE0);
        vm.prank(keeper);
        vault.executeRequest(id, _reports(PRICE0));

        assertEq(vault.balanceOf(lp), POOL);
        assertEq(vault.totalSupply(), POOL);
        assertEq(vault.totalAssets(), POOL);
        assertEq(market.poolAmount(), POOL);
        assertEq(usd.balanceOf(keeper), fee);
        assertEq(vault.escrowedAssets(), 0);
        assertEq(market.getStats().lpDeposited, POOL);
        _assertConservation();
    }

    function test_deposit_slippageCancelsAndRefunds() public {
        _deposit(lp, POOL, PRICE0);
        uint256 fee = _minFee();
        _fund(alice, 1000e18 + fee);
        vm.prank(alice);
        uint256 id = vault.requestDeposit(1000e18, 1001e18, fee);
        skip(1);
        vm.expectEmit(address(vault));
        emit ILPVault.LpRequestCancelled(
            id, keeper, abi.encodeWithSelector(ILPVault.SlippageExceeded.selector, 1000e18, 1001e18)
        );
        vm.prank(keeper);
        vault.executeRequest(id, _reports(PRICE0));
        assertEq(usd.balanceOf(alice), 1000e18);
        assertEq(vault.balanceOf(alice), 0);
        _assertConservation();
    }

    function test_revert_requestDeposit_validation() public {
        uint256 fee = _minFee();
        _fund(alice, 10e18);
        vm.startPrank(alice);
        vm.expectRevert(ILPVault.EmptyRequest.selector);
        vault.requestDeposit(0, 0, fee);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.ExecutionFeeTooLow.selector, 0, fee));
        vault.requestDeposit(1e18, 0, 0);
        vm.stopPrank();
        vm.prank(guardian);
        market.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(ILPVault.MarketPaused.selector);
        vault.requestDeposit(1e18, 0, fee);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Redemptions
    // ---------------------------------------------------------------------------------------------------------------

    function test_redeem_requestAndExecute() public {
        uint256 shares = _deposit(lp, POOL, PRICE0);
        uint256 id = _requestRedeem(lp, shares / 2, 0);
        assertEq(vault.balanceOf(address(vault)), shares / 2);
        assertEq(vault.escrowedShares(), shares / 2);
        skip(1);
        vm.prank(keeper);
        vault.executeRequest(id, _reports(PRICE0));
        assertEq(usd.balanceOf(lp), POOL / 2);
        assertEq(vault.totalSupply(), shares / 2);
        assertEq(market.poolAmount(), POOL / 2);
        assertEq(market.getStats().lpWithdrawn, POOL / 2);
        _assertConservation();
    }

    function test_redeem_blockedByReserveCancelsAndReturnsShares() public {
        uint256 shares = _deposit(lp, POOL, PRICE0);
        _open(alice, true, 700_000e18, 70_000e18, PRICE0);
        // Redeeming half would leave 700k OI against a 500k pool (80% reserve cap = 400k).
        uint256 id = _requestRedeem(lp, shares / 2, 0);
        skip(1);
        vm.recordLogs();
        vm.prank(keeper);
        vault.executeRequest(id, _reports(PRICE0));
        assertEq(_cancelReasonSelector(), IPerpsMarket.WithdrawalExceedsFreeLiquidity.selector);
        assertEq(vault.balanceOf(lp), shares, "shares returned");
        _assertConservation();
    }

    /// @dev Mirrors the order book's guard: a keeper that under-supplies gas cannot turn a redemption into a
    ///      cancellation. Swept from 100k to 450k gas in 1k steps, every outcome is "redeemed" or "still pending".
    function test_executeRequest_underSuppliedGasNeverCancelsRedeem() public {
        uint256 shares = _deposit(lp, POOL, PRICE0);
        _open(alice, true, 100_000e18, 10_000e18, PRICE0); // the free-liquidity check then reads a live book
        uint256 id = _requestRedeem(lp, shares / 10, 0);
        skip(1);
        bytes memory call = abi.encodeCall(vault.executeRequest, (id, _reports(PRICE0)));
        bool sawOutOfGasGuard;
        bool sawSuccess;
        for (uint256 g = 100_000; g <= 450_000; g += 1000) {
            uint256 snap = vm.snapshotState();
            vm.prank(keeper);
            (bool ok, bytes memory ret) = address(vault).call{gas: g}(call);
            if (ok) {
                sawSuccess = true;
                assertEq(vault.totalSupply(), shares - shares / 10, "success must mean redeemed");
                assertGt(usd.balanceOf(lp), 0, "assets paid");
            } else {
                assertEq(vault.getRequest(id).account, lp, "failure must leave the request pending");
                if (ret.length == 4 && bytes4(ret) == ILPVault.ExecutionOutOfGas.selector) sawOutOfGasGuard = true;
            }
            vm.revertToState(snap);
        }
        assertTrue(sawOutOfGasGuard, "guard exercised");
        assertTrue(sawSuccess, "enough gas redeems");
    }

    function test_redeem_slippageCancels() public {
        uint256 shares = _deposit(lp, POOL, PRICE0);
        uint256 id = _requestRedeem(lp, shares, POOL + 1);
        skip(1);
        vm.expectEmit(address(vault));
        emit ILPVault.LpRequestCancelled(
            id, keeper, abi.encodeWithSelector(ILPVault.SlippageExceeded.selector, POOL, POOL + 1)
        );
        vm.prank(keeper);
        vault.executeRequest(id, _reports(PRICE0));
        assertEq(vault.balanceOf(lp), shares);
    }

    function test_revert_requestRedeem_validation() public {
        uint256 shares = _deposit(lp, POOL, PRICE0);
        uint256 fee = _minFee();
        _fund(lp, fee);
        vm.startPrank(lp);
        vm.expectRevert(ILPVault.EmptyRequest.selector);
        vault.requestRedeem(0, 0, fee);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.ExecutionFeeTooLow.selector, 1, fee));
        vault.requestRedeem(1, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, lp, shares, shares + 1));
        vault.requestRedeem(shares + 1, 0, fee);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Cancellation and access control
    // ---------------------------------------------------------------------------------------------------------------

    function test_cancelRequest_afterTimeout() public {
        uint256 fee = _minFee();
        _fund(alice, 1000e18 + fee);
        vm.prank(alice);
        uint256 id = vault.requestDeposit(1000e18, 0, fee);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.CancelTooEarly.selector, block.timestamp + 120));
        vault.cancelRequest(id);
        skip(120);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.NotRequestOwner.selector, bob, alice));
        vault.cancelRequest(id);
        vm.expectEmit(address(vault));
        emit ILPVault.LpRequestCancelled(id, alice, "");
        vm.prank(alice);
        vault.cancelRequest(id);
        assertEq(usd.balanceOf(alice), 1000e18 + fee);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.UnknownRequest.selector, id));
        vault.cancelRequest(id);
    }

    function test_cancelRequest_redeemReturnsShares() public {
        uint256 shares = _deposit(lp, POOL, PRICE0);
        uint256 id = _requestRedeem(lp, shares, 0);
        skip(120);
        vm.prank(lp);
        vault.cancelRequest(id);
        assertEq(vault.balanceOf(lp), shares);
        assertEq(vault.escrowedShares(), 0);
        _assertConservation();
    }

    function test_revert_executeRequest_unauthorizedUnknownOrStale() public {
        uint256 fee = _minFee();
        _fund(alice, 1000e18 + fee);
        IOracleVerifier.SignedPriceReport[] memory seen = _reports(PRICE0);
        vm.prank(alice);
        uint256 id = vault.requestDeposit(1000e18, 0, fee);
        skip(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        vault.executeRequest(id, _reports(PRICE0));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.UnknownRequest.selector, 5));
        vault.executeRequest(5, _reports(PRICE0));
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOracleVerifier.ReportPredatesRequest.selector, signer1, block.timestamp - 1, block.timestamp - 1
            )
        );
        vault.executeRequest(id, seen);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // ERC-4626 surface and pricing
    // ---------------------------------------------------------------------------------------------------------------

    function test_synchronousEntryDisabled() public {
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
        vm.expectRevert(ILPVault.SynchronousEntryDisabled.selector);
        vault.deposit(1, alice);
        vm.expectRevert(ILPVault.SynchronousEntryDisabled.selector);
        vault.mint(1, alice);
        vm.expectRevert(ILPVault.SynchronousEntryDisabled.selector);
        vault.withdraw(1, alice, alice);
        vm.expectRevert(ILPVault.SynchronousEntryDisabled.selector);
        vault.redeem(1, alice, alice);
    }

    function test_previewsMatchConversions() public {
        _deposit(lp, POOL, PRICE0);
        _open(alice, true, 100_000e18, 10_000e18, PRICE0); // fees raise the share price
        assertEq(vault.previewDeposit(1e18), vault.convertToShares(1e18));
        assertEq(vault.previewRedeem(1e18), vault.convertToAssets(1e18));
        assertGe(vault.previewMint(1e18), vault.convertToAssets(1e18));
        assertGe(vault.previewWithdraw(1e18), vault.convertToShares(1e18));
        assertGt(vault.convertToAssets(1e18), 1e18);
        assertEq(vault.decimals(), 18);
    }

    function test_sharePriceTracksTraderPnl() public {
        _deposit(lp, POOL, PRICE0);
        _open(alice, true, 100_000e18, 10_000e18, PRICE0);
        uint256 atEntry = vault.convertToAssets(1e18);
        // A later depositor is priced at the report newer than their request: trader profit lowers the share price.
        uint256 fee = _minFee();
        _fund(bob, 10_000e18 + fee);
        vm.prank(bob);
        uint256 id = vault.requestDeposit(10_000e18, 0, fee);
        skip(1);
        vm.prank(keeper);
        vault.executeRequest(id, _reports(3300e18));
        assertLt(vault.convertToAssets(1e18), atEntry);
        assertGt(vault.balanceOf(bob), 10_000e18);
        _assertConservation();
    }

    /// @dev Classic ERC-4626 inflation attempt: a 1-wei first deposit followed by value pushed into the pool.
    ///      Donations do not move `totalAssets` (internal accounting), and fee income needs open interest, which the
    ///      reserve cap ties to pool size, so the share price cannot be pumped; `minShares` is the last line.
    function test_inflationAttempt_hasNoLever() public {
        _deposit(alice, 1, PRICE0);
        uint256 priceBefore = vault.convertToAssets(1e18);

        // Donations to the market or the vault are ignored by the pool accounting.
        usd.mint(address(market), 1_000_000e18);
        usd.mint(address(vault), 1_000_000e18);
        assertEq(vault.totalAssets(), 1);

        // Trading against a 1-wei pool is impossible: the reserve cap cancels the order.
        uint256 id = _createOrder(bob, IOrderBook.OrderType.MarketIncrease, true, 400_000e18, 40_000e18, 0);
        skip(1);
        vm.recordLogs();
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(PRICE0));
        assertEq(_cancelReasonSelector(), IPerpsMarket.OpenInterestCapExceeded.selector);
        assertEq(vault.convertToAssets(1e18), priceBefore);

        // A victim depositing with a tight minShares bound is filled 1:1.
        uint256 fee = _minFee();
        _fund(carol, 1000e18 + fee);
        vm.prank(carol);
        id = vault.requestDeposit(1000e18, 1000e18, fee);
        skip(1);
        vm.prank(keeper);
        vault.executeRequest(id, _reports(PRICE0));
        assertEq(vault.balanceOf(carol), 1000e18);
    }
}
