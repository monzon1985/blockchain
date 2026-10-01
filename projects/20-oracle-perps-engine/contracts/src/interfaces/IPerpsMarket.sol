// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IOracleVerifier} from "./IOracleVerifier.sol";
import {IOrderBook} from "./IOrderBook.sol";

/// @title IPerpsMarket
/// @notice Types, events and errors of the isolated perpetuals market.
/// @dev Units used throughout: USD amounts and collateral amounts are 18-decimal token units of the stable collateral
///      (1e18 = 1 USD); prices are USD per index token in WAD; index-token amounts are WAD; rates are WAD per second;
///      funding velocity is WAD per second squared.
interface IPerpsMarket {
    // ---------------------------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice An open position. One per (account, side).
    /// @param sizeUsd Notional in USD at entry prices (sum of increases minus proportional decreases).
    /// @param sizeInTokens Index tokens represented by the position; PnL = tokens * price - sizeUsd (longs).
    /// @param collateral Collateral backing the position after all settled fees.
    /// @param lastUpdatedAt Timestamp of the last increase/decrease; liquidation and ADL reports must be newer.
    /// @param borrowIndexEntry Borrow index of the position's side at the last settlement.
    /// @param fundingIndexEntry Funding index at the last settlement.
    struct Position {
        uint128 sizeUsd;
        uint128 sizeInTokens;
        uint128 collateral;
        uint64 lastUpdatedAt;
        uint128 borrowIndexEntry;
        int128 fundingIndexEntry;
    }

    /// @notice Aggregate state of one side of the book.
    /// @param openInterest Sum of `sizeUsd` over open positions of this side.
    /// @param openInterestInTokens Sum of `sizeInTokens` over open positions of this side.
    /// @param borrowIndex Cumulative borrow fee per unit of size (WAD), monotonically non-decreasing.
    /// @param borrowEntrySum Sum of `sizeUsd * borrowIndexEntry` over positions (for aggregate pending fees).
    /// @param fundingEntrySum Sum of `sizeUsd * fundingIndexEntry` over positions (for aggregate pending funding).
    struct SideState {
        uint256 openInterest;
        uint256 openInterestInTokens;
        uint256 borrowIndex;
        uint256 borrowEntrySum;
        int256 fundingEntrySum;
    }

    /// @notice Governance-controlled risk parameters. Changed only through a timelocked AccessManager role.
    /// @param maxLongOpenInterest Hard cap on long open interest (USD).
    /// @param maxShortOpenInterest Hard cap on short open interest (USD).
    /// @param reserveFactor Each side's open interest must stay below `reserveFactor * poolAmount` (WAD).
    /// @param maxPnlFactor Cap on aggregate positive trader PnL as a fraction of `poolAmount` (WAD); profits beyond
    ///        it are paid pro rata and excluded from LP pricing. It also bounds what a single settlement may take
    ///        from the pool (profit plus funding credit), which makes the pool impossible to overdraw.
    /// @param adlThresholdFactor PnL-to-pool factor above which auto-deleveraging is enabled (WAD, e.g. 45%).
    /// @param adlTargetFactor PnL-to-pool factor that auto-deleveraging aims for (WAD, e.g. 40%).
    /// @param positionFeeBps Fee on every size change, basis points of the size delta.
    /// @param initialMarginBps Minimum collateral after an increase or collateral withdrawal (500 = 20x).
    /// @param maintenanceMarginBps Liquidation threshold as a fraction of size (basis points).
    /// @param liquidationFeeBps Keeper reward on liquidation, basis points of size (paid from remaining collateral).
    /// @param orderTimeout Seconds after which an owner may cancel an unexecuted order or LP request.
    /// @param minCollateral Minimum collateral of an open position (USD), keeps liquidations economical.
    /// @param positiveImpactFactor Quadratic factor for skew-reducing trades (WAD per USD); must be <= negative.
    /// @param negativeImpactFactor Quadratic factor for skew-increasing trades (WAD per USD).
    /// @param borrowFactor Borrow rate per second at 100% utilisation of the pool by one side (WAD).
    /// @param maxFundingVelocity Rate of change of the funding rate per second at full proportional skew (WAD).
    /// @param maxFundingRate Absolute cap on the funding rate per second (WAD).
    /// @param skewScale Skew (USD) at which the funding velocity saturates.
    /// @param minExecutionFee Minimum keeper fee per order or LP request (collateral units).
    struct RiskParams {
        uint128 maxLongOpenInterest;
        uint128 maxShortOpenInterest;
        uint64 reserveFactor;
        uint64 maxPnlFactor;
        uint64 adlThresholdFactor;
        uint64 adlTargetFactor;
        uint16 positionFeeBps;
        uint16 initialMarginBps;
        uint16 maintenanceMarginBps;
        uint16 liquidationFeeBps;
        uint32 orderTimeout;
        uint128 minCollateral;
        uint128 positiveImpactFactor;
        uint128 negativeImpactFactor;
        uint64 borrowFactor;
        uint64 maxFundingVelocity;
        uint64 maxFundingRate;
        uint128 skewScale;
        uint128 minExecutionFee;
    }

    /// @notice Cumulative, monotonically increasing flow counters, packed in pairs (8 storage slots). They reconcile
    ///         exactly with `poolAmount` and `impactPoolAmount` (see the fee-conservation invariant) and feed the replay
    ///         reports.
    /// @param positionFees Open/close fees collected into the pool.
    /// @param borrowFees Borrow fees collected into the pool.
    /// @param fundingPaidByTraders Funding collected from payers into the pool.
    /// @param fundingPaidToTraders Funding credited to receivers out of the pool.
    /// @param traderLosses Realised trader losses collected into the pool.
    /// @param traderProfits Realised (capped) trader profits paid out of the pool.
    /// @param badDebt Amounts owed to the pool that collateral could not cover.
    /// @param keeperFees Execution fees and liquidation rewards paid to keepers.
    /// @param impactCollected Negative price impact collected into the impact pool.
    /// @param impactPaid Positive price impact paid out of the impact pool.
    /// @param lpDeposited Assets deposited by LPs into the pool.
    /// @param lpWithdrawn Assets withdrawn by LPs from the pool.
    /// @param liquidations Number of liquidations.
    /// @param autoDeleverages Number of auto-deleverage actions.
    /// @param haircuts Trader gains (profit and funding credit) forfeited by the per-settlement payout backstop.
    /// @param impactDistributed Impact-pool balance handed to the LPs (moved into `poolAmount`) by accrual.
    struct MarketStats {
        uint128 positionFees;
        uint128 borrowFees;
        uint128 fundingPaidByTraders;
        uint128 fundingPaidToTraders;
        uint128 traderLosses;
        uint128 traderProfits;
        uint128 badDebt;
        uint128 keeperFees;
        uint128 impactCollected;
        uint128 impactPaid;
        uint128 lpDeposited;
        uint128 lpWithdrawn;
        uint128 liquidations;
        uint128 autoDeleverages;
        uint128 haircuts;
        uint128 impactDistributed;
    }

    /// @notice Read-only valuation of a position at a given price, including fees accrued up to `block.timestamp`.
    /// @param pnl Unrealised PnL before the pool cap (USD, signed).
    /// @param borrowFee Pending borrow fee (USD).
    /// @param fundingFee Pending funding, positive when owed by the trader (USD, signed).
    /// @param closeFee Position fee a full close would pay (USD).
    /// @param remainingCollateral Collateral + capped PnL - pending fees - close fee (USD, signed).
    /// @param maintenanceMargin Liquidation threshold for the current size (USD).
    /// @param liquidatable True when `remainingCollateral < maintenanceMargin`.
    struct PositionInfo {
        int256 pnl;
        uint256 borrowFee;
        int256 fundingFee;
        uint256 closeFee;
        int256 remainingCollateral;
        uint256 maintenanceMargin;
        bool liquidatable;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice A position was opened or increased.
    /// @param account Owner.
    /// @param isLong Side.
    /// @param sizeDeltaUsd Notional added.
    /// @param collateralDelta Collateral added from escrow.
    /// @param price Fill price.
    /// @param positionFee Open fee charged.
    /// @param priceImpactUsd Price impact credited (+) or charged (-).
    /// @param sizeUsd Resulting size.
    /// @param collateral Resulting collateral.
    event PositionIncreased(
        address indexed account,
        bool indexed isLong,
        uint256 sizeDeltaUsd,
        uint256 collateralDelta,
        uint256 price,
        uint256 positionFee,
        int256 priceImpactUsd,
        uint256 sizeUsd,
        uint256 collateral
    );

    /// @notice A position was reduced or closed by its owner.
    /// @param account Owner.
    /// @param isLong Side.
    /// @param sizeDeltaUsd Notional removed.
    /// @param price Fill price.
    /// @param realizedPnl PnL realised on the removed notional after the pool cap and the payout backstop.
    /// @param positionFee Close fee charged.
    /// @param priceImpactUsd Price impact credited (+) or charged (-).
    /// @param amountOut Collateral transferred to the owner.
    /// @param badDebt Shortfall absorbed by the pool (full closes of underwater positions only).
    event PositionDecreased(
        address indexed account,
        bool indexed isLong,
        uint256 sizeDeltaUsd,
        uint256 price,
        int256 realizedPnl,
        uint256 positionFee,
        int256 priceImpactUsd,
        uint256 amountOut,
        uint256 badDebt
    );

    /// @notice Pending borrow and funding fees of a position were settled against its collateral.
    /// @param account Owner.
    /// @param isLong Side.
    /// @param borrowFee Borrow fee settled.
    /// @param fundingFee Funding settled (+ paid by the trader, - received).
    event FeesSettled(address indexed account, bool indexed isLong, uint256 borrowFee, int256 fundingFee);

    /// @notice A position was liquidated.
    /// @param account Owner.
    /// @param isLong Side.
    /// @param keeper Liquidating keeper.
    /// @param price Oracle price used.
    /// @param sizeUsd Size closed.
    /// @param remainingCollateral Collateral + PnL - fees before the keeper reward (signed).
    /// @param keeperReward Reward paid to the keeper.
    /// @param amountOut Collateral returned to the owner.
    /// @param badDebt Shortfall absorbed by the pool.
    event PositionLiquidated(
        address indexed account,
        bool indexed isLong,
        address indexed keeper,
        uint256 price,
        uint256 sizeUsd,
        int256 remainingCollateral,
        uint256 keeperReward,
        uint256 amountOut,
        uint256 badDebt
    );

    /// @notice A profitable position was auto-deleveraged.
    /// @param account Owner.
    /// @param isLong Side.
    /// @param sizeDeltaUsd Notional removed.
    /// @param price Oracle price used.
    /// @param realizedPnl PnL realised (after the pool cap).
    /// @param amountOut Collateral transferred to the owner.
    /// @param pnlFactorBefore PnL-to-pool factor before the action (WAD).
    /// @param pnlFactorAfter PnL-to-pool factor after the action (WAD).
    event PositionAutoDeleveraged(
        address indexed account,
        bool indexed isLong,
        uint256 sizeDeltaUsd,
        uint256 price,
        int256 realizedPnl,
        uint256 amountOut,
        uint256 pnlFactorBefore,
        uint256 pnlFactorAfter
    );

    /// @notice Funding and borrow indices were accrued to the current block.
    /// @param fundingRate New funding rate per second (WAD, + means longs pay).
    /// @param fundingIndex New cumulative funding per unit of size (WAD).
    /// @param borrowIndexLong New long borrow index (WAD).
    /// @param borrowIndexShort New short borrow index (WAD).
    event IndicesAccrued(int256 fundingRate, int256 fundingIndex, uint256 borrowIndexLong, uint256 borrowIndexShort);

    /// @notice Part of the impact pool was handed to the LPs during accrual.
    /// @param amount Collateral moved from `impactPoolAmount` to `poolAmount`.
    /// @param poolAmount Pool liquidity after the distribution.
    event ImpactPoolDistributed(uint256 amount, uint256 poolAmount);

    /// @notice The mark price used for LP valuation was refreshed by a keeper execution.
    /// @param price New median price.
    /// @param timestamp Oldest report timestamp of the batch.
    event PriceUpdated(uint256 price, uint256 timestamp);

    /// @notice LP assets joined the pool (a settled vault deposit).
    /// @param assets Assets added.
    /// @param poolAmount Pool liquidity after the deposit.
    event LiquidityAdded(uint256 assets, uint256 poolAmount);

    /// @notice LP assets left the pool (a settled vault redemption).
    /// @param assets Assets paid out.
    /// @param receiver LP receiving the assets.
    /// @param poolAmount Pool liquidity after the redemption.
    event LiquidityRemoved(uint256 assets, address indexed receiver, uint256 poolAmount);

    /// @notice Risk parameters were replaced.
    /// @param params The new parameters.
    event RiskParamsUpdated(RiskParams params);

    /// @notice The market was paused or unpaused (paused blocks new increase orders and LP deposits).
    /// @param paused New state.
    event PausedSet(bool paused);

    // ---------------------------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The caller is not the component allowed to call this entry point.
    /// @param caller The unauthorised caller.
    error UnauthorizedCaller(address caller);
    /// @notice The fill price is worse than the order's acceptable price.
    /// @param price Fill price.
    /// @param acceptablePrice Order bound.
    error AcceptablePriceExceeded(uint256 price, uint256 acceptablePrice);
    /// @notice Collateral cannot cover the fees and losses of the action, or the collateral withdrawal requested.
    /// @param available Collateral available (after credits and debits for a withdrawal).
    /// @param shortfall Amount that could not be covered.
    error InsufficientCollateral(uint256 available, uint256 shortfall);
    /// @notice The resulting position would be over-leveraged.
    /// @param effectiveCollateral Collateral net of losses and close fee.
    /// @param requiredMargin Required margin.
    error MarginTooLow(int256 effectiveCollateral, uint256 requiredMargin);
    /// @notice The resulting position would hold less than `minCollateral`.
    /// @param collateral Resulting collateral.
    /// @param minCollateral Minimum.
    error CollateralBelowMinimum(uint256 collateral, uint256 minCollateral);
    /// @notice Open interest would exceed the side's cap.
    /// @param openInterest Resulting open interest.
    /// @param cap Applicable cap (hard cap or reserve-factor cap, whichever is lower).
    error OpenInterestCapExceeded(uint256 openInterest, uint256 cap);
    /// @notice There is no open position for (account, side).
    /// @param account Owner.
    /// @param isLong Side.
    error NoPosition(address account, bool isLong);
    /// @notice The position is not liquidatable at the supplied price.
    /// @param remainingCollateral Collateral net of PnL and fees.
    /// @param maintenanceMargin Liquidation threshold.
    error NotLiquidatable(int256 remainingCollateral, uint256 maintenanceMargin);
    /// @notice Auto-deleveraging is not enabled at the current PnL-to-pool factor.
    /// @param pnlFactor Current factor (WAD).
    /// @param threshold Threshold (WAD).
    error AdlNotRequired(uint256 pnlFactor, uint256 threshold);
    /// @notice Auto-deleveraging this position would not lower the PnL-to-pool factor (its side's netted PnL is not
    ///         positive enough to offset the payout).
    /// @param factorBefore Factor before the action (WAD).
    /// @param factorAfter Factor the action would leave (WAD).
    error AdlDoesNotReduceFactor(uint256 factorBefore, uint256 factorAfter);
    /// @notice Only profitable positions can be auto-deleveraged.
    /// @param pnl The position's PnL.
    error AdlPositionNotProfitable(int256 pnl);
    /// @notice A withdrawal would leave open interest above the reserve cap or PnL above the ADL threshold.
    /// @param assets Assets requested.
    /// @param poolAmount Pool liquidity before the withdrawal.
    error WithdrawalExceedsFreeLiquidity(uint256 assets, uint256 poolAmount);
    /// @notice Proposed risk parameters violate a safety bound.
    /// @param bound Identifier of the violated bound (see `PerpsMarket._setRiskParams`).
    error InvalidRiskParams(uint256 bound);
    /// @notice The collateral token does not have 18 decimals.
    /// @param decimals Reported decimals.
    error UnsupportedCollateralDecimals(uint8 decimals);

    // ---------------------------------------------------------------------------------------------------------------
    // Component entry points (order book and vault only)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Verifies reports strictly newer than `notBefore`, accrues fees and records the mark price.
    /// @dev Callable only by the order book and the vault, which settle user requests against it.
    /// @param reports Signed reports from distinct oracle signers.
    /// @param notBefore Creation time of the order or request being settled.
    /// @return price Median price.
    /// @return oldestTimestamp Oldest report timestamp in the batch.
    function refreshPrice(IOracleVerifier.SignedPriceReport[] calldata reports, uint256 notBefore)
        external
        returns (uint256 price, uint256 oldestTimestamp);

    /// @notice Fills an order at `price` (already verified through `refreshPrice` in the same transaction).
    /// @dev Callable only by the order book. Reverts on any validation failure; the order book then cancels.
    /// @param order The order being filled.
    /// @param price Median oracle price.
    function fillOrder(IOrderBook.Order calldata order, uint256 price) external;

    /// @notice Moves `assets` from the vault into the pool (a settled LP deposit).
    /// @param assets Assets added to `poolAmount`.
    function addLiquidity(uint256 assets) external;

    /// @notice Pays `assets` out of the pool to `receiver` (a settled LP redemption), subject to free liquidity.
    /// @param assets Assets removed from `poolAmount`.
    /// @param receiver LP receiving the assets.
    function removeLiquidity(uint256 assets, address receiver) external;

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Value of the LP pool at the last oracle price with fees accrued to `block.timestamp`.
    /// @return Pool value in collateral units (floored at zero).
    function poolValue() external view returns (uint256);

    /// @notice Parameters the order book and the vault need on every request.
    /// @return minExecutionFee Minimum keeper fee.
    /// @return orderTimeout Seconds before an owner may cancel.
    /// @return isPaused Whether new increase orders and deposits are blocked.
    function requestConfig() external view returns (uint256 minExecutionFee, uint256 orderTimeout, bool isPaused);

    /// @notice The oracle verifier used by this market.
    /// @return The verifier contract.
    function oracle() external view returns (IOracleVerifier);
}
