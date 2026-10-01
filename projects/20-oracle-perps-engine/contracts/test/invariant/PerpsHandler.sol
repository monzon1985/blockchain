// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";

import {PerpsDeployment} from "../../script/PerpsDeployment.sol";
import {LPVault} from "../../src/LPVault.sol";
import {OrderBook} from "../../src/OrderBook.sol";
import {PerpsMarket} from "../../src/PerpsMarket.sol";
import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {IOrderBook} from "../../src/interfaces/IOrderBook.sol";
import {IPerpsMarket} from "../../src/interfaces/IPerpsMarket.sol";
import {PerpMath} from "../../src/libraries/PerpMath.sol";
import {MockUSD} from "../mocks/MockUSD.sol";

/// @notice Risk parameters of the stateful campaigns (Foundry and Medusa): the defaults with hard open-interest caps
///         of $1.2M per side, so that the hard caps, and not only the reserve cap (80% of the pool), bind once LPs
///         have deposited more than $1.5M.
library InvariantParams {
    uint128 internal constant HARD_CAP = 1_200_000e18;

    function riskParams() internal pure returns (IPerpsMarket.RiskParams memory p) {
        p = PerpsDeployment.defaultRiskParams();
        p.maxLongOpenInterest = HARD_CAP;
        p.maxShortOpenInterest = HARD_CAP;
    }
}

/// @title PerpsHandler
/// @notice Stateful fuzzing handler shared by the Foundry invariant suite and the Medusa harness. It drives the
///         system along a fuzzed price path (discretised GBM with occasional jumps) through the real entry points:
///         two-step orders settled by the keeper with signed reports, trigger orders, liquidations, ADL and LP
///         requests. Every token that crosses the system boundary is recorded in ghost variables so that the
///         invariants can reconcile external flows with internal accounting.
/// @dev Actions never revert on legitimate protocol outcomes (a cancelled order is a valid outcome); any revert is a
///      finding under `fail_on_revert = true`.
contract PerpsHandler is CommonBase, StdUtils {
    /// @dev Annualised volatility 80%: 0.8 / sqrt(365 days) per sqrt(second), in WAD.
    uint256 internal constant SIGMA_PER_SQRT_SECOND = 142_457_955_512_535;
    uint256 internal constant MIN_PRICE = 10e18;
    uint256 internal constant MAX_PRICE = 1_000_000e18;
    uint256 internal constant MAX_PENDING_TRIGGERS = 16;

    error CloseAllSucceeded(uint256 lpAssets, uint256 poolAfter);
    error CloseAllFailed(address account, bool isLong, bytes reason);
    /// @dev A close paid something other than the independent model's capped PnL net of fees and impact, or the
    ///      payout backstop forfeited a different amount than the model predicts.
    error PayoutMismatch(
        address account, bool isLong, uint256 expectedOut, uint256 paidOut, uint256 expectedHaircut, uint256 haircut
    );

    PerpsMarket public market;
    OrderBook public orderBook;
    LPVault public vault;
    MockUSD public usd;
    address public keeper;
    bytes32 internal marketId;
    uint256[3] internal signerPks;

    address[] internal traders;
    address[] internal lps;
    address[] internal accounts; // every address that may hold a position
    address internal roundTripper;
    uint256[] internal pendingTriggers;

    /// @notice Current oracle price of the path.
    uint256 public price;

    // Ghost flows (tokens crossing the system boundary).
    uint256 public ghostTraderIn;
    uint256 public ghostTraderOut;
    uint256 public ghostLpIn;
    uint256 public ghostLpOut;
    uint256 public ghostKeeperTrading;
    uint256 public ghostKeeperLp;

    // Ghost property counters.
    uint256 public ghostRoundTrips;
    uint256 public ghostFreeRoundTrips;
    uint256 public ghostStaleAttempts;
    uint256 public ghostStaleFills;
    uint256 public ghostLiquidations;
    uint256 public ghostAdls;
    uint256 public ghostPriceSteps;
    uint256 public ghostShocks;
    uint256 public ghostMaxLongBorrowIndex;
    uint256 public ghostMaxShortBorrowIndex;
    bool public ghostBorrowIndexDecreased;
    /// @dev An auto-deleverage that succeeded without lowering the PnL-to-pool factor (must never happen).
    bool public ghostAdlRaisedFactor;
    /// @dev ADL attempts the market refused with `AdlDoesNotReduceFactor` (the keeper moves to its next candidate).
    uint256 public ghostAdlRefusals;
    /// @dev Opens for which the hard open-interest cap, not the reserve cap, was the binding limit.
    uint256 public ghostHardCapBinding;

    /// @dev Records the borrow indices after every action so that a decrease is caught between any two calls.
    modifier trackIndices() {
        _;
        _trackBorrowIndices();
    }

    function _initHandler(
        PerpsMarket market_,
        MockUSD usd_,
        address keeper_,
        uint256[3] memory signerPks_,
        bytes32 marketId_,
        uint256 initialPrice
    ) internal {
        market = market_;
        orderBook = market_.orderBook();
        vault = market_.vault();
        usd = usd_;
        keeper = keeper_;
        signerPks = signerPks_;
        marketId = marketId_;
        price = initialPrice;

        for (uint256 i; i < 4; ++i) {
            address t = address(uint160(uint256(keccak256(abi.encode("trader", i)))));
            traders.push(t);
            accounts.push(t);
            _approveAll(t);
        }
        for (uint256 i; i < 2; ++i) {
            address l = address(uint160(uint256(keccak256(abi.encode("lp", i)))));
            lps.push(l);
            _approveAll(l);
        }
        roundTripper = address(uint160(uint256(keccak256("roundTripper"))));
        accounts.push(roundTripper);
        _approveAll(roundTripper);

        // Seed liquidity so trading is possible from the first call. The pool is kept small relative to the
        // maximum open interest so that price shocks can push trader PnL past the ADL threshold.
        _lpDeposit(lps[0], 1_000_000e18);
    }

    // ===============================================================================================================
    // Actions
    // ===============================================================================================================

    /// @notice One step of the price path: GBM with 80% volatility over 1..1800 s, plus a +-20% jump with
    ///         probability 1/64 (Merton-style), clamped to [10, 1,000,000].
    function movePrice(int256 zSeed, uint256 dtSeed, uint256 jumpSeed) external trackIndices {
        uint256 dt = bound(dtSeed, 1, 1800);
        int256 z = bound(zSeed, -4e18, 4e18);
        uint256 volDt = FPM.fullMulDiv(SIGMA_PER_SQRT_SECOND, FPM.sqrt(dt * 1e36), 1e18);
        int256 logReturn = (int256(volDt) * z) / 1e18 - int256(FPM.fullMulDiv(volDt, volDt, 2e18));
        if (jumpSeed % 64 == 0) logReturn += int256(bound(jumpSeed >> 8, 0, 0.4e18)) - 0.2e18;
        uint256 next = FPM.fullMulDiv(price, uint256(FPM.expWad(logReturn)), 1e18);
        price = FPM.clamp(next, MIN_PRICE, MAX_PRICE);
        vm.warp(block.timestamp + dt);
        ++ghostPriceSteps;
    }

    /// @notice Adversarial gap: an instantaneous move of 5-60% in either direction (tests liquidations with bad debt,
    ///         the profit cap and auto-deleveraging).
    function priceShock(bool up, uint256 magnitudeSeed) external trackIndices {
        uint256 bps = bound(magnitudeSeed, 500, 6000);
        uint256 next = up ? price * (10_000 + bps) / 10_000 : price * (10_000 - bps) / 10_000;
        price = FPM.clamp(next, MIN_PRICE, MAX_PRICE);
        vm.warp(block.timestamp + 1);
        ++ghostShocks;
    }

    /// @notice Lets time pass at a constant price so that funding and borrow fees accrue.
    function passTime(uint256 dtSeed) external trackIndices {
        vm.warp(block.timestamp + bound(dtSeed, 1, 3 days));
    }

    function openPosition(uint256 actorSeed, bool isLong, uint256 sizeSeed, uint256 leverageSeed)
        external
        trackIndices
    {
        address a = traders[actorSeed % traders.length];
        uint256 size = bound(sizeSeed, 1000e18, 400_000e18);
        uint256 collateral = size / bound(leverageSeed, 1, 18) + 20e18;
        _trackHardCap(isLong, size);
        uint256 id = _createOrder(a, IOrderBook.OrderType.MarketIncrease, isLong, size, collateral, 0);
        _executeOrder(id, a);
    }

    /// @dev Counts opens that the hard cap refuses while the reserve cap would have allowed them.
    function _trackHardCap(bool isLong, uint256 size) internal {
        IPerpsMarket.RiskParams memory p = market.getRiskParams();
        uint256 next = market.getSide(isLong).openInterest + size;
        uint256 hardCap = isLong ? p.maxLongOpenInterest : p.maxShortOpenInterest;
        uint256 reserveCap = FPM.fullMulDiv(market.poolAmount(), p.reserveFactor, 1e18);
        if (next > hardCap && next <= reserveCap) ++ghostHardCapBinding;
    }

    function closePosition(uint256 actorSeed, bool isLong, uint256 quarterSeed) external trackIndices {
        address a = traders[actorSeed % traders.length];
        uint256 size = market.getPosition(a, isLong).sizeUsd;
        if (size == 0) return;
        uint256 quarters = bound(quarterSeed, 1, 4);
        uint256 delta = quarters == 4 ? type(uint128).max : size * quarters / 4;
        uint256 id = _createOrder(a, IOrderBook.OrderType.MarketDecrease, isLong, delta, 0, 0);
        _executeOrder(id, a);
    }

    function withdrawCollateral(uint256 actorSeed, bool isLong, uint256 amountSeed) external trackIndices {
        address a = traders[actorSeed % traders.length];
        uint256 collateral = market.getPosition(a, isLong).collateral;
        if (collateral < 2) return;
        uint256 amount = bound(amountSeed, 1, collateral / 2);
        uint256 id = _createOrder(a, IOrderBook.OrderType.MarketDecrease, isLong, 0, amount, 0);
        _executeOrder(id, a);
    }

    function placeTriggerOrder(uint256 actorSeed, bool isLong, uint256 kindSeed, uint256 offsetSeed, uint256 sizeSeed)
        external
        trackIndices
    {
        if (pendingTriggers.length >= MAX_PENDING_TRIGGERS) return;
        address a = traders[actorSeed % traders.length];
        uint256 kind = kindSeed % 3;
        uint256 trigger = _triggerPrice(kind, isLong, bound(offsetSeed, 1, 1000));
        uint256 id;
        if (kind == 0) {
            uint256 size = bound(sizeSeed, 1000e18, 100_000e18);
            id = _createOrder(a, IOrderBook.OrderType.LimitIncrease, isLong, size, size / 5 + 20e18, trigger);
        } else {
            IOrderBook.OrderType t = kind == 1 ? IOrderBook.OrderType.TakeProfit : IOrderBook.OrderType.StopLoss;
            id = _createOrder(a, t, isLong, type(uint128).max, 0, trigger);
        }
        pendingTriggers.push(id);
    }

    /// @dev Limit buys and stop-losses of longs sit below the price; take-profits of longs above (mirrored for
    ///      shorts).
    function _triggerPrice(uint256 kind, bool isLong, uint256 offsetBps) internal view returns (uint256) {
        bool below = kind == 1 ? !isLong : isLong;
        return below ? price * (10_000 - offsetBps) / 10_000 : price * (10_000 + offsetBps) / 10_000;
    }

    function executeTriggeredOrders() external trackIndices {
        vm.warp(block.timestamp + 1);
        uint256 i;
        while (i < pendingTriggers.length) {
            uint256 id = pendingTriggers[i];
            address owner = orderBook.getOrder(id).account;
            if (owner == address(0)) {
                _removeTrigger(i);
            } else if (orderBook.isExecutable(id, price)) {
                _executeOrderNow(id, owner);
                _removeTrigger(i);
            } else {
                ++i;
            }
        }
    }

    function cancelExpiredOrders() external trackIndices {
        (, uint256 timeout,) = market.requestConfig();
        vm.warp(block.timestamp + timeout);
        while (pendingTriggers.length != 0) {
            uint256 id = pendingTriggers[pendingTriggers.length - 1];
            pendingTriggers.pop();
            address owner = orderBook.getOrder(id).account;
            if (owner == address(0)) continue;
            uint256 before = usd.balanceOf(owner);
            vm.prank(owner);
            orderBook.cancelOrder(id);
            ghostTraderOut += usd.balanceOf(owner) - before;
        }
    }

    function liquidateUnhealthy() external trackIndices {
        vm.warp(block.timestamp + 1);
        for (uint256 i; i < accounts.length; ++i) {
            for (uint256 s; s < 2; ++s) {
                bool isLong = s == 0;
                address a = accounts[i];
                if (market.getPosition(a, isLong).sizeUsd == 0) continue;
                if (!market.positionInfo(a, isLong, price).liquidatable) continue;
                IOracleVerifier.SignedPriceReport[] memory r = _reports(price, uint64(block.timestamp));
                (uint256 k0, uint256 a0) = (usd.balanceOf(keeper), usd.balanceOf(a));
                vm.prank(keeper);
                market.liquidate(a, isLong, r);
                ghostKeeperTrading += usd.balanceOf(keeper) - k0;
                ghostTraderOut += usd.balanceOf(a) - a0;
                ++ghostLiquidations;
            }
        }
    }

    /// @notice Keeper-side ADL, ranked like the Go keeper: among positions on sides whose netted PnL is positive,
    ///         the highest PnL per unit of size. The only refusal accepted from the market is
    ///         `AdlDoesNotReduceFactor` (e.g. a position whose pool-fronted funding credit outweighs its PnL); any
    ///         other revert fails the campaign, and a successful ADL must lower the PnL-to-pool factor.
    function autoDeleverage() external trackIndices {
        vm.warp(block.timestamp + 1);
        (uint256 factor,) = market.pnlToPoolFactor(price);
        if (factor <= market.getRiskParams().adlThresholdFactor) return;
        (address best, bool bestLong) = _adlCandidate();
        if (best == address(0)) return;
        IOracleVerifier.SignedPriceReport[] memory r = _reports(price, uint64(block.timestamp));
        uint256 a0 = usd.balanceOf(best);
        vm.prank(keeper);
        try market.autoDeleverage(best, bestLong, r) {
            ghostTraderOut += usd.balanceOf(best) - a0;
            ++ghostAdls;
            (uint256 afterFactor,) = market.pnlToPoolFactor(price);
            if (afterFactor >= factor) ghostAdlRaisedFactor = true;
        } catch (bytes memory reason) {
            if (bytes4(reason) != IPerpsMarket.AdlDoesNotReduceFactor.selector) _bubble(reason);
            ++ghostAdlRefusals;
        }
    }

    function _adlCandidate() internal view returns (address best, bool bestLong) {
        uint256 bestScore;
        for (uint256 s; s < 2; ++s) {
            bool isLong = s == 0;
            if (_sidePnl(isLong) <= 0) continue;
            for (uint256 i; i < accounts.length; ++i) {
                IPerpsMarket.Position memory p = market.getPosition(accounts[i], isLong);
                if (p.sizeUsd == 0) continue;
                int256 pnl = PerpMath.pnl(isLong, p.sizeUsd, p.sizeInTokens, price);
                if (pnl <= 0) continue;
                uint256 score = FPM.fullMulDiv(uint256(pnl), 1e18, p.sizeUsd);
                if (score > bestScore) (best, bestLong, bestScore) = (accounts[i], isLong, score);
            }
        }
    }

    /// @dev Netted PnL of one side at the handler price.
    function _sidePnl(bool isLong) internal view returns (int256) {
        IPerpsMarket.SideState memory side = market.getSide(isLong);
        return PerpMath.pnl(isLong, side.openInterest, side.openInterestInTokens, price);
    }

    function _bubble(bytes memory reason) internal pure {
        assembly ("memory-safe") {
            revert(add(reason, 32), mload(reason))
        }
    }

    function lpDeposit(uint256 lpSeed, uint256 amountSeed) external trackIndices {
        _lpDeposit(lps[lpSeed % lps.length], bound(amountSeed, 1000e18, 500_000e18));
    }

    function lpRedeem(uint256 lpSeed, uint256 percentSeed) external trackIndices {
        address l = lps[lpSeed % lps.length];
        uint256 shares = vault.balanceOf(l);
        if (shares == 0) return;
        uint256 amount = shares * bound(percentSeed, 1, 100) / 100;
        if (amount == 0) return;
        uint256 fee = _fee();
        usd.mint(l, fee);
        uint256 before = usd.balanceOf(l);
        vm.prank(l);
        uint256 id = vault.requestRedeem(amount, 0, fee);
        ghostLpIn += before - usd.balanceOf(l);
        _executeLpRequest(id, l);
    }

    /// @dev State of one round trip (kept in memory so the non-optimised coverage build fits the stack).
    struct RoundTripState {
        bool isLong;
        uint256 fee;
        uint256 start;
        uint256 mid;
        uint256 openId;
        uint256 closeId;
    }

    /// @notice Opens and closes a position in the same block at the same price; records it if it paid off.
    function roundTrip(bool isLong, uint256 sizeSeed, uint256 leverageSeed) external trackIndices {
        RoundTripState memory rt;
        rt.isLong = isLong;
        rt.fee = _fee();
        uint256 size = bound(sizeSeed, 1000e18, 400_000e18);
        uint256 collateral = size / bound(leverageSeed, 1, 18) + 20e18;
        usd.mint(roundTripper, collateral + 2 * rt.fee);
        rt.start = usd.balanceOf(roundTripper);
        (rt.openId, rt.closeId) = _roundTripOrders(isLong, size, collateral, rt.fee);
        rt.mid = usd.balanceOf(roundTripper);
        ghostTraderIn += rt.start - rt.mid;
        _settleRoundTrip(rt);
    }

    function _settleRoundTrip(RoundTripState memory rt) internal {
        vm.warp(block.timestamp + 1);
        IOracleVerifier.SignedPriceReport[] memory r = _reports(price, uint64(block.timestamp));
        uint256 k0 = usd.balanceOf(keeper);
        vm.prank(keeper);
        orderBook.executeOrder(rt.openId, r);
        bool opened = market.getPosition(roundTripper, rt.isLong).sizeUsd != 0;
        vm.prank(keeper);
        orderBook.executeOrder(rt.closeId, r);
        ghostKeeperTrading += usd.balanceOf(keeper) - k0;
        uint256 end = usd.balanceOf(roundTripper);
        ghostTraderOut += end - rt.mid;
        if (opened) {
            ++ghostRoundTrips;
            if (end + 2 * rt.fee >= rt.start) ++ghostFreeRoundTrips;
        }
    }

    function _roundTripOrders(bool isLong, uint256 size, uint256 collateral, uint256 fee)
        internal
        returns (uint256 openId, uint256 closeId)
    {
        uint256 buyBound = type(uint128).max;
        vm.startPrank(roundTripper);
        openId = orderBook.createOrder(
            IOrderBook.OrderType.MarketIncrease, isLong, size, collateral, 0, isLong ? buyBound : 0, fee
        );
        closeId = orderBook.createOrder(
            IOrderBook.OrderType.MarketDecrease, isLong, type(uint128).max, 0, 0, isLong ? 0 : buyBound, fee
        );
        vm.stopPrank();
    }

    /// @notice Tries to settle a fresh order with reports the user could have seen before creating it.
    function attemptStaleExecution(uint256 actorSeed, bool isLong, uint256 ageSeed) external trackIndices {
        address a = traders[actorSeed % traders.length];
        uint256 id = _createOrder(a, IOrderBook.OrderType.MarketIncrease, isLong, 1000e18, 200e18, 0);
        uint64 staleTs = uint64(block.timestamp - bound(ageSeed, 0, 30));
        IOracleVerifier.SignedPriceReport[] memory stale = _reports(price, staleTs);
        ++ghostStaleAttempts;
        vm.prank(keeper);
        try orderBook.executeOrder(id, stale) {
            ++ghostStaleFills;
        } catch {}
        if (orderBook.getOrder(id).account != address(0)) _executeOrder(id, a);
    }

    // ===============================================================================================================
    // Property helpers
    // ===============================================================================================================

    /// @notice Sums over every account that can hold a position.
    function sumPositions(bool isLong)
        public
        view
        returns (uint256 size, uint256 tokens, uint256 collateral, uint256 borrowEntrySum, int256 fundingEntrySum)
    {
        for (uint256 i; i < accounts.length; ++i) {
            IPerpsMarket.Position memory p = market.getPosition(accounts[i], isLong);
            size += p.sizeUsd;
            tokens += p.sizeInTokens;
            collateral += p.collateral;
            borrowEntrySum += uint256(p.sizeUsd) * p.borrowIndexEntry;
            fundingEntrySum += int256(uint256(p.sizeUsd)) * p.fundingIndexEntry;
        }
    }

    /// @notice Tokens held by each custody contract equal the sum of its accounting buckets.
    function checkTokenConservation() public view returns (bool) {
        return usd.balanceOf(address(market))
                == market.poolAmount() + market.impactPoolAmount() + market.totalCollateral()
            && usd.balanceOf(address(orderBook)) == orderBook.totalEscrow()
            && usd.balanceOf(address(vault)) == vault.escrowedAssets()
            && vault.balanceOf(address(vault)) == vault.escrowedShares();
    }

    /// @notice Open interest, index-token totals, collateral and entry sums equal the sums over positions.
    function checkOpenInterest() public view returns (bool) {
        bool ok = true;
        uint256 totalCollateral;
        for (uint256 s; s < 2; ++s) {
            bool isLong = s == 0;
            IPerpsMarket.SideState memory side = market.getSide(isLong);
            (uint256 size, uint256 tokens, uint256 collateral, uint256 bSum, int256 fSum) = sumPositions(isLong);
            ok = ok && side.openInterest == size && side.openInterestInTokens == tokens && side.borrowEntrySum == bSum
                && side.fundingEntrySum == fSum;
            totalCollateral += collateral;
        }
        return ok && market.totalCollateral() == totalCollateral;
    }

    /// @notice Pool and impact-pool balances reconcile exactly with the cumulative flow counters.
    function checkCounterConservation() public view returns (bool) {
        IPerpsMarket.MarketStats memory st = market.getStats();
        uint256 inflow = uint256(st.lpDeposited) + st.positionFees + st.borrowFees + st.fundingPaidByTraders
            + st.traderLosses + st.impactDistributed;
        uint256 outflow = uint256(st.lpWithdrawn) + st.fundingPaidToTraders + st.traderProfits;
        return market.poolAmount() + outflow == inflow
            && market.impactPoolAmount() + st.impactPaid + st.impactDistributed == st.impactCollected;
    }

    /// @notice External flows reconcile with internal buckets: what traders put in net of what they took out is
    ///         exactly their open collateral and escrow plus what the pool, the impact pool and keepers earned from
    ///         trading; what LPs put in net is their escrow plus their net pool deposits plus LP keeper fees.
    function checkFlowConservation() public view returns (bool) {
        IPerpsMarket.MarketStats memory st = market.getStats();
        // Written without subtractions: LPs may withdraw more than they deposited (their share of trader losses).
        bool traders_ = ghostTraderIn + st.lpDeposited
            == ghostTraderOut + st.lpWithdrawn + market.totalCollateral() + orderBook.totalEscrow()
                + market.poolAmount() + market.impactPoolAmount() + ghostKeeperTrading;
        bool lps_ = ghostLpIn + st.lpWithdrawn == ghostLpOut + vault.escrowedAssets() + st.lpDeposited + ghostKeeperLp;
        return traders_ && lps_;
    }

    /// @notice Borrow indices never decreased between any two handler calls.
    function checkBorrowIndicesMonotonic() public view returns (bool) {
        return !ghostBorrowIndexDecreased;
    }

    function _trackBorrowIndices() internal {
        uint256 l = market.getSide(true).borrowIndex;
        uint256 s = market.getSide(false).borrowIndex;
        if (l < ghostMaxLongBorrowIndex || s < ghostMaxShortBorrowIndex) ghostBorrowIndexDecreased = true;
        ghostMaxLongBorrowIndex = l;
        ghostMaxShortBorrowIndex = s;
    }

    /// @notice Solvency: every open position can be closed at the current price, each close pays exactly the
    ///         trader's capped PnL net of fees and impact (an independent model, below), and the LPs can then redeem
    ///         the whole pool. Runs the closes for real and reverts with the outcome, so no state is kept.
    function checkSolvency() public returns (bool ok, bytes memory detail) {
        try this.simulateCloseAll() {
            return (false, "simulation did not revert");
        } catch (bytes memory ret) {
            return (bytes4(ret) == CloseAllSucceeded.selector, ret);
        }
    }

    /// @dev Only callable by `checkSolvency`; always reverts. Funding, borrow fees and the impact-pool distribution
    ///      are accrued to now first (with fresh reports, exactly as a keeper's close would), so up to a week of
    ///      keeper inactivity is priced in.
    function simulateCloseAll() external {
        require(msg.sender == address(this), "only self");
        IOracleVerifier.SignedPriceReport[] memory fresh = _reports(price, uint64(block.timestamp));
        vm.prank(address(orderBook));
        market.refreshPrice(fresh, 0);
        for (uint256 i; i < accounts.length; ++i) {
            for (uint256 s; s < 2; ++s) {
                bool isLong = s == 0;
                address a = accounts[i];
                if (market.getPosition(a, isLong).sizeUsd == 0) continue;
                (uint256 expectedOut, uint256 expectedHaircut) = _expectedClose(a, isLong);
                uint256 balanceBefore = usd.balanceOf(a);
                uint256 haircutsBefore = market.getStats().haircuts;
                IOrderBook.Order memory o = IOrderBook.Order({
                    account: a,
                    orderType: IOrderBook.OrderType.MarketDecrease,
                    isLong: isLong,
                    createdAt: uint64(block.timestamp),
                    sizeDeltaUsd: type(uint128).max,
                    collateralDelta: 0,
                    triggerPrice: 0,
                    acceptablePrice: uint128(_acceptable(isLong, false)),
                    executionFee: 0
                });
                vm.prank(address(orderBook));
                try market.fillOrder(o, price) {}
                catch (bytes memory reason) {
                    revert CloseAllFailed(a, isLong, reason);
                }
                uint256 paid = usd.balanceOf(a) - balanceBefore;
                uint256 haircut = market.getStats().haircuts - haircutsBefore;
                if (paid != expectedOut || haircut != expectedHaircut) {
                    revert PayoutMismatch(a, isLong, expectedOut, paid, expectedHaircut, haircut);
                }
            }
        }
        // Nothing is left but the pool and the impact pool.
        require(market.totalCollateral() == 0, "collateral left");
        require(usd.balanceOf(address(market)) == market.poolAmount() + market.impactPoolAmount(), "market balance");
        uint256 assets = vault.previewRedeem(vault.totalSupply());
        uint256 pool = market.poolAmount();
        require(assets <= pool, "LP claims exceed pool");
        vm.prank(address(vault));
        try market.removeLiquidity(assets, address(0xdead)) {}
        catch (bytes memory reason) {
            revert CloseAllFailed(address(vault), false, reason);
        }
        revert CloseAllSucceeded(assets, market.poolAmount());
    }

    /// @dev Inputs and running totals of the payout model (memory keeps the unoptimised coverage build within the
    ///      stack limit).
    struct CloseModel {
        uint256 pool;
        uint256 profit;
        uint256 credit;
        uint256 gains;
        uint256 debits;
        int256 pnl;
        int256 impact;
    }

    /// @notice What a full user close of (`a`, `isLong`) at `price` must pay, written independently of
    ///         `PerpsMarket._settle` from the documented rules: PnL capped pro rata when aggregate positive side PnL
    ///         exceeds `maxPnlFactor * poolAmount`; borrow fee `ceil(size * (index - entry))`; funding owed by longs
    ///         when the index rose (and by shorts when it fell), rounded against the trader; close fee; impact capped
    ///         by the impact pool; the payout backstop; and a waterfall floored at zero.
    /// @return expectedOut Collateral the close transfers to the trader.
    /// @return haircut Profit plus funding credit the payout backstop forfeits.
    function _expectedClose(address a, bool isLong) internal view returns (uint256 expectedOut, uint256 haircut) {
        IPerpsMarket.Position memory pos = market.getPosition(a, isLong);
        IPerpsMarket.RiskParams memory p = market.getRiskParams();
        CloseModel memory m;
        m.pool = market.poolAmount();
        m.pnl = PerpMath.pnl(isLong, pos.sizeUsd, pos.sizeInTokens, price);

        // Pro-rata profit cap over the positive side PnLs.
        if (m.pnl > 0) {
            int256 longPnl = _sidePnl(true);
            int256 shortPnl = _sidePnl(false);
            uint256 positive = (longPnl > 0 ? uint256(longPnl) : 0) + (shortPnl > 0 ? uint256(shortPnl) : 0);
            uint256 cap = FPM.fullMulDiv(m.pool, p.maxPnlFactor, 1e18);
            m.profit = positive > cap ? FPM.fullMulDiv(uint256(m.pnl), cap, positive) : uint256(m.pnl);
        }

        // Funding: longs owe the index increase, shorts the decrease; owed rounds up, credit towards zero.
        int256 indexDelta = market.fundingIndex() - pos.fundingIndexEntry;
        int256 funding = PerpMath.mulWadOwed(isLong ? indexDelta : -indexDelta, pos.sizeUsd);
        if (funding < 0) m.credit = uint256(-funding);

        m.impact = PerpMath.priceImpactUsd(
            market.getSide(true).openInterest,
            market.getSide(false).openInterest,
            isLong,
            false,
            pos.sizeUsd,
            p.positiveImpactFactor,
            p.negativeImpactFactor
        );
        if (m.impact > 0 && uint256(m.impact) > market.impactPoolAmount()) {
            m.impact = int256(market.impactPoolAmount());
        }

        // Payout backstop: one settlement takes at most maxPnlFactor of the pool as profit plus funding credit.
        uint256 maxPayout = FPM.fullMulDiv(m.pool, p.maxPnlFactor, 1e18);
        if (m.profit + m.credit > maxPayout) {
            haircut = m.profit + m.credit - maxPayout;
            if (m.profit > maxPayout) m.profit = maxPayout;
            m.credit = maxPayout - m.profit;
        }

        m.gains = uint256(pos.collateral) + m.profit + m.credit + (m.impact > 0 ? uint256(m.impact) : 0);
        m.debits = (m.pnl < 0 ? uint256(-m.pnl) : 0) + (funding > 0 ? uint256(funding) : 0)
            + FPM.fullMulDivUp(market.getSide(isLong).borrowIndex - pos.borrowIndexEntry, pos.sizeUsd, 1e18)
            + PerpMath.bpsUp(pos.sizeUsd, p.positionFeeBps) + (m.impact < 0 ? uint256(-m.impact) : 0);
        expectedOut = m.gains > m.debits ? m.gains - m.debits : 0;
    }

    /// @notice Number of pending trigger orders tracked by the handler.
    function pendingTriggerCount() external view returns (uint256) {
        return pendingTriggers.length;
    }

    // ===============================================================================================================
    // Internals
    // ===============================================================================================================

    function _approveAll(address who) internal {
        vm.startPrank(who);
        usd.approve(address(orderBook), type(uint256).max);
        usd.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _fee() internal view returns (uint256 fee) {
        (fee,,) = market.requestConfig();
    }

    function _acceptable(bool isLong, bool increase) internal pure returns (uint256) {
        return isLong == increase ? type(uint128).max : 0;
    }

    function _createOrder(
        address who,
        IOrderBook.OrderType t,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 trigger
    ) internal returns (uint256 id) {
        bool increase =
            t == IOrderBook.OrderType.MarketIncrease || t == IOrderBook.OrderType.LimitIncrease;
        uint256 fee = _fee();
        usd.mint(who, (increase ? collateral : 0) + fee);
        uint256 before = usd.balanceOf(who);
        vm.prank(who);
        id = orderBook.createOrder(t, isLong, size, collateral, trigger, _acceptable(isLong, increase), fee);
        ghostTraderIn += before - usd.balanceOf(who);
    }

    function _executeOrder(uint256 id, address owner) internal {
        vm.warp(block.timestamp + 1);
        _executeOrderNow(id, owner);
    }

    function _executeOrderNow(uint256 id, address owner) internal {
        IOracleVerifier.SignedPriceReport[] memory r = _reports(price, uint64(block.timestamp));
        (uint256 k0, uint256 a0) = (usd.balanceOf(keeper), usd.balanceOf(owner));
        vm.prank(keeper);
        orderBook.executeOrder(id, r);
        ghostKeeperTrading += usd.balanceOf(keeper) - k0;
        ghostTraderOut += usd.balanceOf(owner) - a0;
    }

    function _lpDeposit(address l, uint256 amount) internal {
        uint256 fee = _fee();
        usd.mint(l, amount + fee);
        uint256 before = usd.balanceOf(l);
        vm.prank(l);
        uint256 id = vault.requestDeposit(amount, 0, fee);
        ghostLpIn += before - usd.balanceOf(l);
        _executeLpRequest(id, l);
    }

    function _executeLpRequest(uint256 id, address l) internal {
        vm.warp(block.timestamp + 1);
        IOracleVerifier.SignedPriceReport[] memory r = _reports(price, uint64(block.timestamp));
        (uint256 k0, uint256 l0) = (usd.balanceOf(keeper), usd.balanceOf(l));
        vm.prank(keeper);
        vault.executeRequest(id, r);
        ghostKeeperLp += usd.balanceOf(keeper) - k0;
        ghostLpOut += usd.balanceOf(l) - l0;
    }

    function _removeTrigger(uint256 i) internal {
        pendingTriggers[i] = pendingTriggers[pendingTriggers.length - 1];
        pendingTriggers.pop();
    }

    /// @dev Three signed reports; signers quote the path price with a small deterministic dispersion (<= 10 bps).
    function _reports(uint256 p, uint64 ts) internal view returns (IOracleVerifier.SignedPriceReport[] memory r) {
        r = new IOracleVerifier.SignedPriceReport[](3);
        address verifier = address(market.oracle());
        int256[3] memory skewBps = [int256(-5), int256(0), int256(5)];
        for (uint256 i; i < 3; ++i) {
            uint256 quote = uint256(int256(p) + (int256(p) * skewBps[i]) / 10_000);
            (uint8 v, bytes32 rr, bytes32 s) = vm.sign(signerPks[i], _digest(verifier, quote, ts));
            r[i] = IOracleVerifier.SignedPriceReport({
                signer: vm.addr(signerPks[i]), price: quote, timestamp: ts, signature: abi.encodePacked(rr, s, v)
            });
        }
    }

    function _digest(address verifier, uint256 p, uint64 ts) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PerpsOracle"),
                keccak256("1"),
                block.chainid,
                verifier
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(keccak256("PriceReport(bytes32 marketId,uint256 price,uint64 timestamp)"), marketId, p, ts)
        );
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }
}

/// @notice Foundry handler: wraps an already-deployed system.
contract ForgePerpsHandler is PerpsHandler {
    constructor(
        PerpsMarket market_,
        MockUSD usd_,
        address keeper_,
        uint256[3] memory signerPks_,
        bytes32 marketId_,
        uint256 initialPrice
    ) {
        _initHandler(market_, usd_, keeper_, signerPks_, marketId_, initialPrice);
    }
}
