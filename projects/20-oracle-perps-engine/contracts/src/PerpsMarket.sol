// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";

import {LPVault} from "./LPVault.sol";
import {OrderBook} from "./OrderBook.sol";
import {IOracleVerifier} from "./interfaces/IOracleVerifier.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {IPerpsMarket} from "./interfaces/IPerpsMarket.sol";
import {PerpMath} from "./libraries/PerpMath.sol";

/// @title PerpsMarket
/// @notice Isolated, oracle-priced perpetuals market (one synthetic index asset, one 18-decimal stable collateral).
///         LPs are the counterparty through an ERC-4626 vault. Traders submit two-step orders to the `OrderBook`,
///         which keepers settle with EIP-712 median price reports strictly newer than the order. The market charges
///         skew-based velocity funding, utilisation-based borrow fees and quadratic price impact, liquidates below
///         maintenance margin and auto-deleverages profitable positions when trader PnL exceeds the ADL threshold.
/// @dev Components: this contract owns positions and the pool; the `OrderBook` and the `LPVault` are deployed by the
///      constructor (so their addresses are immutable here and `market` is immutable there) and hold only the escrow
///      of pending requests. Market custody is split into accounting buckets: `poolAmount` (LP-owned),
///      `impactPoolAmount` and `totalCollateral` (open positions); `balanceOf(this) == sum of buckets` is an enforced
///      invariant. The order book and the vault call `refreshPrice` before settling anything, so every fill, deposit
///      and redemption is priced with reports newer than its request.
contract PerpsMarket is IPerpsMarket, AccessManaged, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    int256 private constant IWAD = 1e18;

    /// @notice Every accrual hands `min(dt, period) / period` of the impact pool to the LPs (`poolAmount`), so the
    ///         part of negative impact that positive impact never pays back reaches the LPs instead of being stranded.
    uint256 public constant IMPACT_POOL_DISTRIBUTION_PERIOD = 7 days;

    // Ceilings of `setRiskParams` (bounds 9-12): about 10x the defaults, so a compromised risk admin cannot sweep
    // collateral through fees after the 1-day delay. 500% APR borrow at full utilisation; funding 1%/h, its velocity
    // 30%/day per day; impact $5,000 on a $1M skew; minimum execution fee $10 and minimum collateral $1,000.
    uint256 private constant MAX_BORROW_FACTOR = 158_548_959_918;
    uint256 private constant MAX_FUNDING_RATE = 2_777_777_777_777;
    uint256 private constant MAX_FUNDING_VELOCITY = 40_187_750;
    uint256 private constant MAX_IMPACT_FACTOR = 5e9;
    uint256 private constant MAX_EXECUTION_FEE = 10e18;
    uint256 private constant MAX_MIN_COLLATERAL = 1000e18;

    enum DecreaseKind {
        User,
        Liquidation,
        Adl
    }

    /// @dev Everything a settlement debits from or credits to a position's collateral.
    struct Settlement {
        int256 pnl; // realised PnL after the cap; + credited from the pool, - collected into the pool
        uint256 borrowFee; // collected into the pool
        int256 fundingFee; // + collected into the pool, - credited from the pool
        uint256 positionFee; // collected into the pool
        int256 impact; // + credited from the impact pool, - collected into the impact pool
        uint256 keeperReward; // paid to the keeper after every pool claim
    }

    /// @dev Result of the settlement waterfall.
    struct SettleOutcome {
        uint256 remaining; // collateral left after credits and debits
        uint256 shortfall; // debits that collateral could not cover (pool + impact pool)
        uint256 badDebt; // part of `shortfall` owed to the pool
        uint256 keeperPaid; // keeper reward actually covered
    }

    /// @dev Inputs of a decrease, bundled to keep the stack shallow.
    struct DecreaseCtx {
        address account;
        bool isLong;
        uint256 sizeDelta; // clamped to the position size
        uint256 collateralOut; // requested withdrawal (user partial decreases only)
        uint256 price;
        DecreaseKind kind;
        bool full;
        uint256 tokensDelta; // index tokens removed
    }

    /// @dev Output of a decrease, used for events and transfers.
    struct DecreaseResult {
        uint256 sizeDeltaUsd;
        int256 realizedPnl;
        uint256 positionFee;
        int256 impact;
        uint256 amountOut;
        uint256 badDebt;
        uint256 keeperReward;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Immutable configuration
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Identifier signed into every price report (e.g. keccak256("ETH-USD")).
    bytes32 public immutable marketId;

    /// @notice 18-decimal stable collateral; also the LP vault asset.
    IERC20 public immutable collateralToken;

    /// @notice Signer-set verifier producing the median price.
    IOracleVerifier public immutable oracle;

    /// @notice ERC-4626 share token of the pool (asynchronous entry), deployed by this contract.
    LPVault public immutable vault;

    /// @notice Two-step order entry, deployed by this contract; the only caller of `fillOrder`.
    OrderBook public immutable orderBook;

    // ---------------------------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Current risk parameters (timelocked governance).
    RiskParams private _params;

    /// @notice LP-owned liquidity (realised), in collateral units.
    uint256 public poolAmount;

    /// @notice Negative price impact collected and not yet paid out as positive impact or distributed to the LPs.
    uint256 public impactPoolAmount;

    /// @notice Sum of the collateral of all open positions.
    uint256 public totalCollateral;

    /// @dev Aggregates of the long side.
    SideState private _long;

    /// @dev Aggregates of the short side.
    SideState private _short;

    /// @notice Funding rate per second (WAD); positive means longs pay.
    int256 public fundingRate;

    /// @notice Cumulative funding per unit of size (WAD).
    int256 public fundingIndex;

    /// @notice Timestamp up to which funding and borrow indices are accrued.
    uint64 public lastAccrualAt;

    /// @notice Whether new increase orders and LP deposits are blocked.
    bool public paused;

    /// @notice Median price of the last keeper execution; marks the pool for LP valuation.
    uint256 public lastPrice;

    /// @notice Oldest report timestamp behind `lastPrice`.
    uint256 public lastPriceTimestamp;

    /// @dev Open positions by (account, side).
    mapping(address account => mapping(bool isLong => Position)) private _positions;

    /// @dev Cumulative flow counters.
    MarketStats private _stats;

    /// @param authority_ AccessManager holding the keeper, guardian and (timelocked) risk-admin roles; also the
    ///        authority of the order book and the vault.
    /// @param collateral_ 18-decimal stable collateral token.
    /// @param oracle_ Price-report verifier.
    /// @param marketId_ Market identifier signed into reports.
    /// @param params_ Initial risk parameters.
    /// @param vaultName ERC-20 name of the LP share token.
    /// @param vaultSymbol ERC-20 symbol of the LP share token.
    constructor(
        address authority_,
        IERC20 collateral_,
        IOracleVerifier oracle_,
        bytes32 marketId_,
        RiskParams memory params_,
        string memory vaultName,
        string memory vaultSymbol
    ) AccessManaged(authority_) {
        uint8 decimals = IERC20Metadata(address(collateral_)).decimals();
        require(decimals == 18, UnsupportedCollateralDecimals(decimals));
        collateralToken = collateral_;
        oracle = oracle_;
        marketId = marketId_;
        vault = new LPVault(collateral_, authority_, vaultName, vaultSymbol);
        orderBook = new OrderBook(collateral_, authority_);
        lastAccrualAt = uint64(block.timestamp);
        _setRiskParams(params_);
    }

    // ===============================================================================================================
    // Component entry points (order book and vault)
    // ===============================================================================================================

    /// @inheritdoc IPerpsMarket
    function refreshPrice(IOracleVerifier.SignedPriceReport[] calldata reports, uint256 notBefore)
        external
        nonReentrant
        returns (uint256 price, uint256 oldestTimestamp)
    {
        require(msg.sender == address(orderBook) || msg.sender == address(vault), UnauthorizedCaller(msg.sender));
        return _refreshPrice(reports, notBefore);
    }

    /// @inheritdoc IPerpsMarket
    function fillOrder(IOrderBook.Order calldata order, uint256 price) external nonReentrant {
        require(msg.sender == address(orderBook), UnauthorizedCaller(msg.sender));
        IOrderBook.OrderType t = order.orderType;
        bool increase = t == IOrderBook.OrderType.MarketIncrease || t == IOrderBook.OrderType.LimitIncrease;
        // Opening a long or closing a short buys the index: the price must not exceed the bound; otherwise it sells.
        bool buys = order.isLong == increase;
        require(
            buys ? price <= order.acceptablePrice : price >= order.acceptablePrice,
            AcceptablePriceExceeded(price, order.acceptablePrice)
        );
        if (increase) {
            if (order.collateralDelta != 0) {
                collateralToken.safeTransferFrom(msg.sender, address(this), order.collateralDelta);
            }
            _increase(order.account, order.isLong, order.sizeDeltaUsd, order.collateralDelta, price);
        } else {
            DecreaseResult memory r = _decrease(
                order.account, order.isLong, order.sizeDeltaUsd, order.collateralDelta, price, DecreaseKind.User
            );
            if (r.amountOut != 0) collateralToken.safeTransfer(order.account, r.amountOut);
        }
    }

    /// @inheritdoc IPerpsMarket
    function addLiquidity(uint256 assets) external nonReentrant {
        require(msg.sender == address(vault), UnauthorizedCaller(msg.sender));
        poolAmount += assets;
        _stats.lpDeposited += assets.toUint128();
        emit LiquidityAdded(assets, poolAmount);
        collateralToken.safeTransferFrom(msg.sender, address(this), assets);
    }

    /// @inheritdoc IPerpsMarket
    function removeLiquidity(uint256 assets, address receiver) external nonReentrant {
        require(msg.sender == address(vault), UnauthorizedCaller(msg.sender));
        _checkFreeLiquidity(assets);
        poolAmount -= assets;
        _stats.lpWithdrawn += assets.toUint128();
        emit LiquidityRemoved(assets, receiver, poolAmount);
        collateralToken.safeTransfer(receiver, assets);
    }

    // ===============================================================================================================
    // Keeper entry points
    // ===============================================================================================================

    /// @notice Liquidates a position whose collateral net of PnL and fees is below maintenance margin.
    /// @dev Reports must be newer than the position's last update, so a trader's fresh collateral is never judged
    ///      with a stale price. Waterfall: losses and fees to the pool first, then the keeper reward, then the
    ///      remainder back to the trader; any uncovered pool claim is recorded as bad debt.
    /// @param account Owner of the position.
    /// @param isLong Side.
    /// @param reports Signed reports from distinct oracle signers.
    function liquidate(address account, bool isLong, IOracleVerifier.SignedPriceReport[] calldata reports)
        external
        nonReentrant
        restricted
    {
        Position memory pos = _positions[account][isLong];
        require(pos.sizeUsd != 0, NoPosition(account, isLong));
        (uint256 price,) = _refreshPrice(reports, pos.lastUpdatedAt);

        PositionInfo memory info = _positionInfo(pos, isLong, price, _side(isLong).borrowIndex, fundingIndex);
        require(info.liquidatable, NotLiquidatable(info.remainingCollateral, info.maintenanceMargin));

        DecreaseResult memory r = _decrease(account, isLong, pos.sizeUsd, 0, price, DecreaseKind.Liquidation);
        ++_stats.liquidations;
        emit PositionLiquidated(
            account,
            isLong,
            msg.sender,
            price,
            pos.sizeUsd,
            info.remainingCollateral,
            r.keeperReward,
            r.amountOut,
            r.badDebt
        );
        _payKeeper(r.keeperReward);
        if (r.amountOut != 0) collateralToken.safeTransfer(account, r.amountOut);
    }

    /// @notice Auto-deleverages a profitable position while the PnL-to-pool factor exceeds the ADL threshold.
    /// @dev The market computes how much of the position to close so that the factor falls to `adlTargetFactor`
    ///      (capped at the full position). Keepers choose which position to deleverage, ranking by PnL per unit of
    ///      size within sides whose netted PnL is positive; the contract enforces that the threshold is exceeded, the
    ///      position is in profit and the factor strictly decreases. The last check rejects a winner on a side whose
    ///      netted PnL is negative: paying it shrinks the pool without lowering aggregate positive PnL. No position
    ///      fee or price impact is charged: ADL is involuntary.
    /// @param account Owner of the position.
    /// @param isLong Side.
    /// @param reports Signed reports from distinct oracle signers.
    function autoDeleverage(address account, bool isLong, IOracleVerifier.SignedPriceReport[] calldata reports)
        external
        nonReentrant
        restricted
    {
        Position memory pos = _positions[account][isLong];
        require(pos.sizeUsd != 0, NoPosition(account, isLong));
        (uint256 price,) = _refreshPrice(reports, pos.lastUpdatedAt);

        (uint256 factorBefore, uint256 positivePnl) = _pnlFactor(price);
        uint256 threshold = _params.adlThresholdFactor;
        require(factorBefore > threshold, AdlNotRequired(factorBefore, threshold));
        int256 positionPnl = PerpMath.pnl(isLong, pos.sizeUsd, pos.sizeInTokens, price);
        require(positionPnl > 0, AdlPositionNotProfitable(positionPnl));

        uint256 sizeDelta = _adlSizeDelta(pos.sizeUsd, uint256(positionPnl), positivePnl);
        DecreaseResult memory r = _decrease(account, isLong, sizeDelta, 0, price, DecreaseKind.Adl);
        (uint256 factorAfter,) = _pnlFactor(price);
        require(factorAfter < factorBefore, AdlDoesNotReduceFactor(factorBefore, factorAfter));
        ++_stats.autoDeleverages;
        emit PositionAutoDeleveraged(
            account, isLong, r.sizeDeltaUsd, price, r.realizedPnl, r.amountOut, factorBefore, factorAfter
        );
        if (r.amountOut != 0) collateralToken.safeTransfer(account, r.amountOut);
    }

    // ===============================================================================================================
    // Governance
    // ===============================================================================================================

    /// @notice Replaces the risk parameters. Accrues indices first so past intervals use the old rates.
    /// @param newParams The new parameters (validated against safety bounds).
    function setRiskParams(RiskParams calldata newParams) external restricted {
        _accrue();
        _setRiskParams(newParams);
    }

    /// @notice Pauses or unpauses new risk: new increase orders and new LP deposit requests. Decreases,
    ///         cancellations, liquidations, redemptions and already-created requests keep working while paused.
    /// @param paused_ New state.
    function setPaused(bool paused_) external restricted {
        paused = paused_;
        emit PausedSet(paused_);
    }

    // ===============================================================================================================
    // Views
    // ===============================================================================================================

    /// @inheritdoc IPerpsMarket
    function poolValue() external view returns (uint256) {
        return _poolValue(lastPrice);
    }

    /// @notice Pool value at an arbitrary `price`, with fees accrued to `block.timestamp`.
    /// @param price Mark price (WAD).
    /// @return Pool value in collateral units (floored at zero).
    function poolValueAt(uint256 price) external view returns (uint256) {
        return _poolValue(price);
    }

    /// @notice Aggregate positive trader PnL as a fraction of `poolAmount` at `price` (the ADL trigger metric).
    /// @param price Mark price (WAD).
    /// @return factor PnL-to-pool factor (WAD).
    /// @return positivePnl Sum of the positive side PnLs (USD).
    function pnlToPoolFactor(uint256 price) external view returns (uint256 factor, uint256 positivePnl) {
        return _pnlFactor(price);
    }

    /// @notice Valuation of a position at `price` with fees accrued to `block.timestamp`.
    /// @param account Owner.
    /// @param isLong Side.
    /// @param price Mark price (WAD).
    /// @return info PnL, pending fees, remaining collateral and liquidation status.
    function positionInfo(address account, bool isLong, uint256 price)
        external
        view
        returns (PositionInfo memory info)
    {
        Position memory pos = _positions[account][isLong];
        if (pos.sizeUsd == 0) return info;
        (, int256 fIndex, uint256 bLong, uint256 bShort) = _projectIndices(block.timestamp - lastAccrualAt);
        return _positionInfo(pos, isLong, price, isLong ? bLong : bShort, fIndex);
    }

    /// @notice The position of `account` on side `isLong` (all zero if none).
    /// @param account Owner.
    /// @param isLong Side.
    /// @return The stored position.
    function getPosition(address account, bool isLong) external view returns (Position memory) {
        return _positions[account][isLong];
    }

    /// @notice Stored aggregates of one side (indices as of `lastAccrualAt`).
    /// @param isLong Side.
    /// @return The side state.
    function getSide(bool isLong) external view returns (SideState memory) {
        return _side(isLong);
    }

    /// @inheritdoc IPerpsMarket
    function requestConfig() external view returns (uint256 minExecutionFee, uint256 orderTimeout, bool isPaused) {
        return (_params.minExecutionFee, _params.orderTimeout, paused);
    }

    /// @notice Current risk parameters.
    /// @return The parameters.
    function getRiskParams() external view returns (RiskParams memory) {
        return _params;
    }

    /// @notice Cumulative flow counters.
    /// @return The counters.
    function getStats() external view returns (MarketStats memory) {
        return _stats;
    }

    // ===============================================================================================================
    // Internal: position lifecycle
    // ===============================================================================================================

    function _increase(address account, bool isLong, uint256 sizeDelta, uint256 collateralIn, uint256 price) private {
        RiskParams memory p = _params;
        SideState storage side = _side(isLong);
        Position memory pos = _positions[account][isLong];
        require(pos.sizeUsd != 0 || sizeDelta != 0, NoPosition(account, isLong));

        // Memory structs are zero-initialised; the fields that apply to an increase are set below.
        // slither-disable-next-line uninitialized-local
        Settlement memory s;
        (s.borrowFee, s.fundingFee) = _pendingFees(pos, isLong, side.borrowIndex, fundingIndex);
        s.positionFee = PerpMath.bpsUp(sizeDelta, p.positionFeeBps);
        s.impact = _cappedImpact(isLong, true, sizeDelta, p);

        SettleOutcome memory o = _settle(uint256(pos.collateral) + collateralIn, s);
        require(o.shortfall == 0, InsufficientCollateral(uint256(pos.collateral) + collateralIn, o.shortfall));
        if (s.borrowFee != 0 || s.fundingFee != 0) emit FeesSettled(account, isLong, s.borrowFee, s.fundingFee);

        _removeAggregates(side, pos);
        totalCollateral = totalCollateral - pos.collateral + o.remaining;
        pos.sizeUsd += sizeDelta.toUint128();
        pos.sizeInTokens += PerpMath.tokensForSize(sizeDelta, price, isLong).toUint128();
        pos.collateral = o.remaining.toUint128();
        pos.lastUpdatedAt = uint64(block.timestamp);
        _stampEntries(pos, side);
        _addAggregates(side, pos);
        _positions[account][isLong] = pos;

        uint256 oiCap = FPM.min(
            isLong ? p.maxLongOpenInterest : p.maxShortOpenInterest, FPM.fullMulDiv(poolAmount, p.reserveFactor, WAD)
        );
        require(side.openInterest <= oiCap, OpenInterestCapExceeded(side.openInterest, oiCap));
        require(pos.collateral >= p.minCollateral, CollateralBelowMinimum(pos.collateral, p.minCollateral));
        _validateMargin(pos, isLong, price, p.initialMarginBps, p.positionFeeBps);

        emit PositionIncreased(
            account, isLong, sizeDelta, collateralIn, price, s.positionFee, s.impact, pos.sizeUsd, pos.collateral
        );
    }

    function _decrease(
        address account,
        bool isLong,
        uint256 sizeDelta,
        uint256 collateralOut,
        uint256 price,
        DecreaseKind kind
    ) private returns (DecreaseResult memory r) {
        Position memory pos = _positions[account][isLong];
        require(pos.sizeUsd != 0, NoPosition(account, isLong));
        DecreaseCtx memory c = DecreaseCtx({
            account: account,
            isLong: isLong,
            sizeDelta: FPM.min(sizeDelta, pos.sizeUsd),
            collateralOut: collateralOut,
            price: price,
            kind: kind,
            full: false,
            tokensDelta: 0
        });
        c.full = c.sizeDelta == pos.sizeUsd;

        Settlement memory s = _decreaseSettlement(c, pos);
        SettleOutcome memory o = _settle(pos.collateral, s);
        if (!c.full) require(o.shortfall == 0, InsufficientCollateral(pos.collateral, o.shortfall));
        if (s.borrowFee != 0 || s.fundingFee != 0) emit FeesSettled(account, isLong, s.borrowFee, s.fundingFee);

        r.sizeDeltaUsd = c.sizeDelta;
        r.realizedPnl = s.pnl;
        r.positionFee = s.positionFee;
        r.impact = s.impact;
        r.badDebt = o.badDebt;
        r.keeperReward = o.keeperPaid;
        r.amountOut = _applyDecrease(c, pos, o.remaining);

        if (kind == DecreaseKind.User) {
            emit PositionDecreased(
                account, isLong, c.sizeDelta, price, s.pnl, s.positionFee, s.impact, r.amountOut, o.badDebt
            );
        }
    }

    /// @dev Computes the settlement of a decrease: realised (capped) PnL, pending fees, fee/impact/keeper reward by
    ///      kind, and the index tokens removed.
    function _decreaseSettlement(DecreaseCtx memory c, Position memory pos) private view returns (Settlement memory s) {
        RiskParams memory p = _params;
        (s.borrowFee, s.fundingFee) = _pendingFees(pos, c.isLong, _side(c.isLong).borrowIndex, fundingIndex);
        int256 totalPnl = PerpMath.pnl(c.isLong, pos.sizeUsd, pos.sizeInTokens, c.price);
        if (c.full) {
            s.pnl = totalPnl;
            c.tokensDelta = pos.sizeInTokens;
        } else {
            s.pnl = PerpMath.mulDivFloor(totalPnl, c.sizeDelta, pos.sizeUsd);
            // Longs remove rounded-up tokens and shorts rounded-down tokens, so the remaining slice never carries
            // more PnL than it should (see docs/DESIGN.md, "Rounding").
            c.tokensDelta = c.isLong
                ? FPM.fullMulDivUp(pos.sizeInTokens, c.sizeDelta, pos.sizeUsd)
                : FPM.fullMulDiv(pos.sizeInTokens, c.sizeDelta, pos.sizeUsd);
        }
        if (s.pnl > 0) s.pnl = _capProfit(uint256(s.pnl), c.price).toInt256();
        if (c.kind == DecreaseKind.User) {
            s.positionFee = PerpMath.bpsUp(c.sizeDelta, p.positionFeeBps);
            s.impact = _cappedImpact(c.isLong, false, c.sizeDelta, p);
        } else if (c.kind == DecreaseKind.Liquidation) {
            s.positionFee = PerpMath.bpsUp(c.sizeDelta, p.positionFeeBps);
            s.keeperReward = FPM.fullMulDiv(c.sizeDelta, p.liquidationFeeBps, BPS);
        }
    }

    /// @dev Writes the post-decrease position (or deletes it) and returns the collateral to transfer to the owner.
    function _applyDecrease(DecreaseCtx memory c, Position memory pos, uint256 remaining)
        private
        returns (uint256 amountOut)
    {
        SideState storage side = _side(c.isLong);
        _removeAggregates(side, pos);
        if (c.full) {
            totalCollateral -= pos.collateral;
            delete _positions[c.account][c.isLong];
            return remaining;
        }
        if (c.kind == DecreaseKind.User) {
            // `if` rather than `require`: the error argument subtracts, so it must only be built on failure.
            if (c.collateralOut > remaining) revert InsufficientCollateral(remaining, c.collateralOut - remaining);
            amountOut = c.collateralOut;
            remaining -= amountOut;
        }
        totalCollateral = totalCollateral - pos.collateral + remaining;
        pos.sizeUsd -= c.sizeDelta.toUint128();
        pos.sizeInTokens -= c.tokensDelta.toUint128();
        pos.collateral = remaining.toUint128();
        pos.lastUpdatedAt = uint64(block.timestamp);
        _stampEntries(pos, side);
        _addAggregates(side, pos);
        _positions[c.account][c.isLong] = pos;
        if (c.kind == DecreaseKind.User) {
            RiskParams memory p = _params;
            require(pos.collateral >= p.minCollateral, CollateralBelowMinimum(pos.collateral, p.minCollateral));
            uint256 marginBps = amountOut != 0 ? p.initialMarginBps : p.maintenanceMarginBps;
            _validateMargin(pos, c.isLong, c.price, marginBps, p.positionFeeBps);
        }
    }

    /// @dev Settlement waterfall. Credits (capped profit, funding received, positive impact) are added first; then
    ///      pool claims (loss, funding owed, borrow fee, position fee), the impact-pool claim and finally the keeper
    ///      reward are taken while collateral lasts. Every movement is mirrored in `_stats`.
    ///      Payout backstop: one settlement may take at most `maxPnlFactor * poolAmount` of profit and funding credit
    ///      from the pool; any entitlement beyond is forfeited and recorded in `haircuts`. The pro-rata profit cap and
    ///      ADL keep settlements far from this bound in normal operation; the backstop covers the cases they cannot:
    ///      a winner whose PnL exceeds its side's netted PnL, and funding credits fronted for payers that defaulted
    ///      while keepers were down. With it, `poolAmount` can never be overdrawn.
    function _settle(uint256 collateral, Settlement memory s) private returns (SettleOutcome memory o) {
        MarketStats storage st = _stats;
        uint256 pool = poolAmount;
        uint256 avail = collateral;
        uint256 poolIn = 0;

        uint256 profit = s.pnl > 0 ? uint256(s.pnl) : 0;
        uint256 fundingCredit = s.fundingFee < 0 ? uint256(-s.fundingFee) : 0;
        uint256 maxPayout = FPM.fullMulDiv(pool, _params.maxPnlFactor, WAD);
        if (profit + fundingCredit > maxPayout) {
            st.haircuts += (profit + fundingCredit - maxPayout).toUint128();
            // Only gains are cut back: a loss (pnl < 0) and funding the trader owes (fundingFee > 0) are still
            // collected below.
            if (profit > maxPayout) {
                profit = maxPayout;
                s.pnl = profit.toInt256();
            }
            if (fundingCredit != 0) {
                fundingCredit = maxPayout - profit;
                s.fundingFee = -fundingCredit.toInt256();
            }
        }
        uint256 poolOut = profit + fundingCredit;
        avail += poolOut;
        if (profit != 0) st.traderProfits += profit.toUint128();
        if (fundingCredit != 0) st.fundingPaidToTraders += fundingCredit.toUint128();
        if (s.impact > 0) {
            uint256 x = uint256(s.impact);
            avail += x;
            impactPoolAmount -= x;
            st.impactPaid += x.toUint128();
        }

        uint256 taken;
        if (s.pnl < 0) {
            (taken, avail) = _take(avail, uint256(-s.pnl), o);
            poolIn += taken;
            st.traderLosses += taken.toUint128();
        }
        if (s.fundingFee > 0) {
            (taken, avail) = _take(avail, uint256(s.fundingFee), o);
            poolIn += taken;
            st.fundingPaidByTraders += taken.toUint128();
        }
        if (s.borrowFee != 0) {
            (taken, avail) = _take(avail, s.borrowFee, o);
            poolIn += taken;
            st.borrowFees += taken.toUint128();
        }
        if (s.positionFee != 0) {
            (taken, avail) = _take(avail, s.positionFee, o);
            poolIn += taken;
            st.positionFees += taken.toUint128();
        }
        o.badDebt = o.shortfall;
        if (s.impact < 0) {
            (taken, avail) = _take(avail, uint256(-s.impact), o);
            impactPoolAmount += taken;
            st.impactCollected += taken.toUint128();
        }
        if (s.keeperReward != 0) {
            o.keeperPaid = FPM.min(avail, s.keeperReward);
            avail -= o.keeperPaid;
        }
        if (o.badDebt != 0) st.badDebt += o.badDebt.toUint128();

        // poolOut <= maxPayout <= pool, so this cannot underflow.
        poolAmount = pool + poolIn - poolOut;
        o.remaining = avail;
    }

    /// @dev Takes up to `amount` from `avail`; the uncovered part is added to `o.shortfall`.
    function _take(uint256 avail, uint256 amount, SettleOutcome memory o)
        private
        pure
        returns (uint256 taken, uint256 left)
    {
        taken = FPM.min(avail, amount);
        o.shortfall += amount - taken;
        left = avail - taken;
    }

    // ===============================================================================================================
    // Internal: pricing, fees, validation
    // ===============================================================================================================

    /// @dev Verifies `reports` (all newer than `notBefore`), accrues indices and records the mark price.
    function _refreshPrice(IOracleVerifier.SignedPriceReport[] calldata reports, uint256 notBefore)
        private
        returns (uint256 price, uint256 oldestTs)
    {
        (price, oldestTs) = oracle.verifyReports(marketId, reports, notBefore);
        _accrue();
        lastPrice = price;
        lastPriceTimestamp = oldestTs;
        emit PriceUpdated(price, oldestTs);
    }

    /// @dev Accrues funding and borrow indices over the elapsed interval (at the pool size of that interval), then
    ///      hands the elapsed share of the impact pool to the LPs.
    function _accrue() private {
        uint256 dt = block.timestamp - lastAccrualAt;
        if (dt == 0) return;
        (int256 rate, int256 index, uint256 bLong, uint256 bShort) = _projectIndices(dt);
        fundingRate = rate;
        fundingIndex = index;
        _long.borrowIndex = bLong;
        _short.borrowIndex = bShort;
        lastAccrualAt = uint64(block.timestamp);
        emit IndicesAccrued(rate, index, bLong, bShort);

        uint256 distributed = _impactDistribution(dt);
        if (distributed != 0) {
            impactPoolAmount -= distributed;
            poolAmount += distributed;
            _stats.impactDistributed += distributed.toUint128();
            emit ImpactPoolDistributed(distributed, poolAmount);
        }
    }

    /// @dev Part of the impact pool owed to the LPs after `dt` seconds without accrual. Negative impact that positive
    ///      impact has not paid back decays into `poolAmount` over `IMPACT_POOL_DISTRIBUTION_PERIOD`; positive impact
    ///      stays capped by what is left, so the no-free-round-trip argument is unaffected (the cap only shrinks).
    function _impactDistribution(uint256 dt) private view returns (uint256) {
        uint256 impactPool = impactPoolAmount;
        if (dt >= IMPACT_POOL_DISTRIBUTION_PERIOD) return impactPool;
        return impactPool * dt / IMPACT_POOL_DISTRIBUTION_PERIOD;
    }

    /// @dev Funding and borrow indices `dt` seconds after `lastAccrualAt`, using the current open interest and pool.
    function _projectIndices(uint256 dt)
        private
        view
        returns (int256 rate, int256 index, uint256 bLong, uint256 bShort)
    {
        uint256 longOi = _long.openInterest;
        uint256 shortOi = _short.openInterest;
        bLong = _long.borrowIndex;
        bShort = _short.borrowIndex;
        if (dt == 0) return (fundingRate, fundingIndex, bLong, bShort);

        RiskParams memory p = _params;
        int256 velocity = PerpMath.fundingVelocity(longOi, shortOi, p.skewScale, p.maxFundingVelocity);
        int256 integral;
        (integral, rate) = PerpMath.fundingIntegral(fundingRate, velocity, dt, p.maxFundingRate);
        index = fundingIndex + integral;

        uint256 pool = poolAmount;
        bLong += PerpMath.borrowRate(longOi, pool, p.borrowFactor) * dt;
        bShort += PerpMath.borrowRate(shortOi, pool, p.borrowFactor) * dt;
    }

    /// @dev Borrow fee (rounded up) and funding (positive = owed by the trader, rounded against the trader).
    function _pendingFees(Position memory pos, bool isLong, uint256 borrowIdx, int256 fundingIdx)
        private
        pure
        returns (uint256 borrowFee, int256 fundingFee)
    {
        if (pos.sizeUsd == 0) return (0, 0);
        borrowFee = FPM.fullMulDivUp(borrowIdx - pos.borrowIndexEntry, pos.sizeUsd, WAD);
        int256 delta = fundingIdx - pos.fundingIndexEntry;
        fundingFee = PerpMath.mulWadOwed(isLong ? delta : -delta, pos.sizeUsd);
    }

    /// @dev Price impact of a trade with the positive part capped by the impact pool balance.
    function _cappedImpact(bool isLong, bool increase, uint256 sizeDelta, RiskParams memory p)
        private
        view
        returns (int256 impact)
    {
        if (sizeDelta == 0) return 0;
        impact = PerpMath.priceImpactUsd(
            _long.openInterest,
            _short.openInterest,
            isLong,
            increase,
            sizeDelta,
            p.positiveImpactFactor,
            p.negativeImpactFactor
        );
        if (impact > 0) {
            uint256 pool = impactPoolAmount;
            if (uint256(impact) > pool) impact = pool.toInt256();
        }
    }

    /// @dev Scales a positive realised PnL down pro rata when aggregate positive trader PnL exceeds
    ///      `maxPnlFactor * poolAmount`. Each payout is then at most the current cap, so the pool never goes negative.
    function _capProfit(uint256 profit, uint256 price) private view returns (uint256) {
        (, uint256 positivePnl) = _pnlFactor(price);
        uint256 cap = FPM.fullMulDiv(poolAmount, _params.maxPnlFactor, WAD);
        if (positivePnl <= cap) return profit;
        return FPM.fullMulDiv(profit, cap, positivePnl);
    }

    /// @dev Sum of positive side PnLs and its ratio to `poolAmount`.
    function _pnlFactor(uint256 price) private view returns (uint256 factor, uint256 positivePnl) {
        (int256 longPnl, int256 shortPnl) = _sidePnls(price);
        positivePnl = (longPnl > 0 ? uint256(longPnl) : 0) + (shortPnl > 0 ? uint256(shortPnl) : 0);
        if (positivePnl == 0) return (0, 0);
        uint256 pool = poolAmount;
        factor = pool == 0 ? type(uint256).max : FPM.fullMulDiv(positivePnl, WAD, pool);
    }

    function _sidePnls(uint256 price) private view returns (int256 longPnl, int256 shortPnl) {
        if (price == 0) return (0, 0);
        longPnl = PerpMath.pnl(true, _long.openInterest, _long.openInterestInTokens, price);
        shortPnl = PerpMath.pnl(false, _short.openInterest, _short.openInterestInTokens, price);
    }

    /// @dev poolAmount + pending impact-pool distribution + pending borrow + net pending funding - (capped positive PnL
    ///      + negative PnL), floored at 0.
    function _poolValue(uint256 price) private view returns (uint256) {
        uint256 dt = block.timestamp - lastAccrualAt;
        (, int256 fIndex, uint256 bLong, uint256 bShort) = _projectIndices(dt);
        SideState memory l = _long;
        SideState memory sh = _short;
        uint256 pool = poolAmount + _impactDistribution(dt);

        int256 value = pool.toInt256();
        value += ((l.openInterest * bLong - l.borrowEntrySum) / WAD).toInt256();
        value += ((sh.openInterest * bShort - sh.borrowEntrySum) / WAD).toInt256();
        // Funding owed to the pool: longs owe (index - entry) * size, shorts owe the opposite. Floor division.
        int256 fundingNumerator = (l.openInterest.toInt256() * fIndex - l.fundingEntrySum)
            - (sh.openInterest.toInt256() * fIndex - sh.fundingEntrySum);
        value += _floorDivWad(fundingNumerator);

        (int256 longPnl, int256 shortPnl) = _sidePnls(price);
        uint256 positivePnl = (longPnl > 0 ? uint256(longPnl) : 0) + (shortPnl > 0 ? uint256(shortPnl) : 0);
        int256 negativePnl = (longPnl < 0 ? longPnl : int256(0)) + (shortPnl < 0 ? shortPnl : int256(0));
        uint256 cap = FPM.fullMulDiv(pool, _params.maxPnlFactor, WAD);
        value -= FPM.min(positivePnl, cap).toInt256();
        value -= negativePnl;
        return value > 0 ? uint256(value) : 0;
    }

    function _positionInfo(Position memory pos, bool isLong, uint256 price, uint256 borrowIdx, int256 fundingIdx)
        private
        view
        returns (PositionInfo memory info)
    {
        RiskParams memory p = _params;
        info.pnl = PerpMath.pnl(isLong, pos.sizeUsd, pos.sizeInTokens, price);
        (info.borrowFee, info.fundingFee) = _pendingFees(pos, isLong, borrowIdx, fundingIdx);
        info.closeFee = PerpMath.bpsUp(pos.sizeUsd, p.positionFeeBps);
        int256 cappedPnl = info.pnl > 0 ? _capProfit(uint256(info.pnl), price).toInt256() : info.pnl;
        info.remainingCollateral = uint256(pos.collateral).toInt256() + cappedPnl - info.borrowFee.toInt256()
            - info.fundingFee - info.closeFee.toInt256();
        info.maintenanceMargin = PerpMath.bpsUp(pos.sizeUsd, p.maintenanceMarginBps);
        info.liquidatable = info.remainingCollateral < info.maintenanceMargin.toInt256();
    }

    /// @dev collateral + min(pnl, 0) - closeFee must cover `marginBps` of size. Positive PnL is ignored here.
    function _validateMargin(Position memory pos, bool isLong, uint256 price, uint256 marginBps, uint256 feeBps)
        private
        pure
    {
        int256 pnl = PerpMath.pnl(isLong, pos.sizeUsd, pos.sizeInTokens, price);
        int256 effective = uint256(pos.collateral).toInt256() + (pnl < 0 ? pnl : int256(0))
            - PerpMath.bpsUp(pos.sizeUsd, feeBps).toInt256();
        uint256 required = PerpMath.bpsUp(pos.sizeUsd, marginBps);
        require(effective >= required.toInt256(), MarginTooLow(effective, required));
    }

    /// @dev Share of the position to close so that the PnL-to-pool factor falls to `adlTargetFactor`.
    ///      Removing y of PnL (paid at scale s <= 1) moves the factor to (P - y) / (A - s*y); solving for the target
    ///      t gives y = (P - t*A) / (1 - t*s).
    function _adlSizeDelta(uint256 size, uint256 positionPnl, uint256 positivePnl) private view returns (uint256) {
        uint256 pool = poolAmount;
        uint256 target = _params.adlTargetFactor;
        uint256 targetPnl = FPM.fullMulDiv(pool, target, WAD);
        if (positivePnl <= targetPnl) return 0;
        uint256 cap = FPM.fullMulDiv(pool, _params.maxPnlFactor, WAD);
        uint256 scale = positivePnl > cap ? FPM.fullMulDiv(cap, WAD, positivePnl) : WAD;
        uint256 denominator = WAD - FPM.fullMulDiv(target, scale, WAD);
        uint256 pnlToRemove = FPM.fullMulDivUp(positivePnl - targetPnl, WAD, denominator);
        if (pnlToRemove >= positionPnl) return size;
        return FPM.min(FPM.fullMulDivUp(size, pnlToRemove, positionPnl), size);
    }

    /// @dev After a withdrawal of `assets`, each side's open interest must fit the reserve cap and the PnL factor
    ///      must stay at or below the ADL threshold, so LPs cannot exit into a pool that is already stressed.
    function _checkFreeLiquidity(uint256 assets) private view {
        uint256 pool = poolAmount;
        require(assets <= pool, WithdrawalExceedsFreeLiquidity(assets, pool));
        uint256 nextPool = pool - assets;
        RiskParams memory p = _params;
        uint256 reserveCap = FPM.fullMulDiv(nextPool, p.reserveFactor, WAD);
        require(
            _long.openInterest <= reserveCap && _short.openInterest <= reserveCap,
            WithdrawalExceedsFreeLiquidity(assets, pool)
        );
        (, uint256 positivePnl) = _pnlFactor(lastPrice);
        require(
            positivePnl <= FPM.fullMulDiv(nextPool, p.adlThresholdFactor, WAD),
            WithdrawalExceedsFreeLiquidity(assets, pool)
        );
    }

    // ===============================================================================================================
    // Internal: bookkeeping helpers
    // ===============================================================================================================

    function _side(bool isLong) private view returns (SideState storage) {
        return isLong ? _long : _short;
    }

    function _stampEntries(Position memory pos, SideState storage side) private view {
        pos.borrowIndexEntry = side.borrowIndex.toUint128();
        pos.fundingIndexEntry = fundingIndex.toInt128();
    }

    function _addAggregates(SideState storage side, Position memory pos) private {
        side.openInterest += pos.sizeUsd;
        side.openInterestInTokens += pos.sizeInTokens;
        side.borrowEntrySum += uint256(pos.sizeUsd) * pos.borrowIndexEntry;
        side.fundingEntrySum += int256(uint256(pos.sizeUsd)) * pos.fundingIndexEntry;
    }

    function _removeAggregates(SideState storage side, Position memory pos) private {
        if (pos.sizeUsd == 0) return;
        side.openInterest -= pos.sizeUsd;
        side.openInterestInTokens -= pos.sizeInTokens;
        side.borrowEntrySum -= uint256(pos.sizeUsd) * pos.borrowIndexEntry;
        side.fundingEntrySum -= int256(uint256(pos.sizeUsd)) * pos.fundingIndexEntry;
    }

    function _payKeeper(uint256 amount) private {
        if (amount == 0) return;
        _stats.keeperFees += amount.toUint128();
        collateralToken.safeTransfer(msg.sender, amount);
    }

    /// @dev Bound identifiers reported by `InvalidRiskParams`: 1 reserve factor in (0, 1]; 2 pnl factors ordered
    ///      0 < adlTarget < adlThreshold < maxPnl < 1; 3 position fee <= 1%; 4 0 < maintenance < initial <= 100%;
    ///      5 liquidation fee < maintenance; 6 positive impact <= negative impact (no free round trips);
    ///      7 skew scale > 0; 8 order timeout in [10 s, 1 day]; 9 borrow factor <= 500% APR; 10 funding rate <= 1%/h
    ///      and velocity <= 30%/day per day; 11 negative impact factor <= 5e9; 12 min execution fee <= $10 and
    ///      min collateral <= $1,000.
    function _setRiskParams(RiskParams memory p) private {
        require(p.reserveFactor != 0 && p.reserveFactor <= WAD, InvalidRiskParams(1));
        require(
            p.adlTargetFactor != 0 && p.adlTargetFactor < p.adlThresholdFactor && p.adlThresholdFactor < p.maxPnlFactor
                && p.maxPnlFactor < WAD,
            InvalidRiskParams(2)
        );
        require(p.positionFeeBps <= 100, InvalidRiskParams(3));
        require(
            p.maintenanceMarginBps != 0 && p.maintenanceMarginBps < p.initialMarginBps && p.initialMarginBps <= BPS,
            InvalidRiskParams(4)
        );
        require(p.liquidationFeeBps < p.maintenanceMarginBps, InvalidRiskParams(5));
        require(p.positiveImpactFactor <= p.negativeImpactFactor, InvalidRiskParams(6));
        require(p.skewScale != 0, InvalidRiskParams(7));
        require(p.orderTimeout >= 10 && p.orderTimeout <= 1 days, InvalidRiskParams(8));
        require(p.borrowFactor <= MAX_BORROW_FACTOR, InvalidRiskParams(9));
        require(
            p.maxFundingRate <= MAX_FUNDING_RATE && p.maxFundingVelocity <= MAX_FUNDING_VELOCITY, InvalidRiskParams(10)
        );
        require(p.negativeImpactFactor <= MAX_IMPACT_FACTOR, InvalidRiskParams(11));
        require(p.minExecutionFee <= MAX_EXECUTION_FEE && p.minCollateral <= MAX_MIN_COLLATERAL, InvalidRiskParams(12));
        _params = p;
        int256 cap = uint256(p.maxFundingRate).toInt256();
        fundingRate = FPM.clamp(fundingRate, -cap, cap);
        emit RiskParamsUpdated(p);
    }

    function _floorDivWad(int256 x) private pure returns (int256) {
        if (x >= 0) return x / IWAD;
        return -((-x + IWAD - 1) / IWAD);
    }
}
