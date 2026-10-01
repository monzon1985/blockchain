// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IOrderBook
/// @notice Types, events and errors of the two-step order book.
interface IOrderBook {
    /// @notice Order kinds. Increase kinds escrow collateral; decrease kinds only escrow the execution fee.
    /// @dev Trigger semantics (price = oracle median at execution):
    ///      LimitIncrease: long fills when price <= trigger, short when price >= trigger.
    ///      TakeProfit:    long fills when price >= trigger, short when price <= trigger.
    ///      StopLoss:      long fills when price <= trigger, short when price >= trigger.
    enum OrderType {
        MarketIncrease,
        MarketDecrease,
        LimitIncrease,
        TakeProfit,
        StopLoss
    }

    /// @notice A pending two-step order. Deleted on execution or cancellation.
    /// @param account Owner of the order and of the resulting position.
    /// @param orderType Kind of order.
    /// @param isLong Side of the position the order acts on.
    /// @param createdAt Block timestamp at creation; settling reports must be strictly newer.
    /// @param sizeDeltaUsd Notional to add (increase) or remove (decrease), USD.
    /// @param collateralDelta Collateral escrowed (increase) or to withdraw (partial decrease).
    /// @param triggerPrice Trigger for limit / take-profit / stop-loss orders; zero for market orders.
    /// @param acceptablePrice Worst fill price the owner accepts (slippage bound).
    /// @param executionFee Collateral paid to the keeper that settles the order.
    struct Order {
        address account;
        OrderType orderType;
        bool isLong;
        uint64 createdAt;
        uint128 sizeDeltaUsd;
        uint128 collateralDelta;
        uint128 triggerPrice;
        uint128 acceptablePrice;
        uint128 executionFee;
    }

    /// @notice A two-step order was created and its collateral and execution fee escrowed.
    /// @param orderId Identifier of the order.
    /// @param account Owner of the order.
    /// @param orderType Kind of order.
    /// @param isLong Side.
    /// @param sizeDeltaUsd Notional delta.
    /// @param collateralDelta Escrowed collateral (increase) or requested withdrawal (decrease).
    /// @param triggerPrice Trigger price (0 for market orders).
    /// @param acceptablePrice Slippage bound.
    /// @param executionFee Escrowed keeper fee.
    event OrderCreated(
        uint256 indexed orderId,
        address indexed account,
        OrderType orderType,
        bool isLong,
        uint256 sizeDeltaUsd,
        uint256 collateralDelta,
        uint256 triggerPrice,
        uint256 acceptablePrice,
        uint256 executionFee
    );

    /// @notice An order was filled.
    /// @param orderId Identifier of the order.
    /// @param keeper Keeper that executed the order and received the execution fee.
    /// @param price Median oracle price used for the fill.
    /// @param oldestReportTimestamp Oldest report timestamp in the batch (strictly newer than order creation).
    event OrderExecuted(uint256 indexed orderId, address indexed keeper, uint256 price, uint256 oldestReportTimestamp);

    /// @notice An order was cancelled and its escrow released.
    /// @param orderId Identifier of the order.
    /// @param cancelledBy The owner (after the timeout) or the keeper (failed fill).
    /// @param reason ABI-encoded revert data of the failed fill; empty for owner cancellations.
    event OrderCancelled(uint256 indexed orderId, address indexed cancelledBy, bytes reason);

    /// @notice New increase orders are blocked while the market is paused.
    error MarketPaused();
    /// @notice The order does not exist (already executed or cancelled).
    /// @param orderId The identifier looked up.
    error UnknownOrder(uint256 orderId);
    /// @notice The caller does not own the order.
    /// @param caller The caller.
    /// @param owner The owner.
    error NotOrderOwner(address caller, address owner);
    /// @notice The execution fee is below the market minimum.
    /// @param fee Fee supplied.
    /// @param minFee Minimum fee.
    error ExecutionFeeTooLow(uint256 fee, uint256 minFee);
    /// @notice The order has nothing to do (zero size and zero collateral, or a trigger order with zero size).
    error EmptyOrder();
    /// @notice A trigger order was created without a trigger price, or a market order with one.
    /// @param triggerPrice The trigger price supplied.
    error InvalidTriggerPrice(uint256 triggerPrice);
    /// @notice Orders cannot be cancelled by their owner before the timeout (free-option guard).
    /// @param cancellableAt First timestamp at which the owner may cancel.
    error CancelTooEarly(uint256 cancellableAt);
    /// @notice The trigger condition of a limit / take-profit / stop-loss order is not met at `price`.
    /// @param price Median oracle price.
    /// @param triggerPrice Order trigger price.
    error TriggerNotMet(uint256 price, uint256 triggerPrice);
    /// @notice The fill ran out of gas; the keeper transaction reverts instead of cancelling the order.
    error ExecutionOutOfGas();
}
