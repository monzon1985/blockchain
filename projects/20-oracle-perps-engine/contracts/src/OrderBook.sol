// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IOracleVerifier} from "./interfaces/IOracleVerifier.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {IPerpsMarket} from "./interfaces/IPerpsMarket.sol";

/// @title OrderBook
/// @notice Two-step order entry for the perpetuals market. Users escrow collateral and an execution fee; a keeper
///         later settles the order with signed oracle reports that are all strictly newer than the order, which
///         removes the latency-arbitrage option of trading against a price the user has already seen.
/// @dev Deployed by the market's constructor (`market == msg.sender`). The order book holds exactly the escrow of the
///      pending orders (`balanceOf(this) == totalEscrow`, an enforced invariant) and grants the market an allowance to
///      pull the collateral of an increase order inside `fillOrder`, so a failed fill leaves the escrow untouched.
contract OrderBook is IOrderBook, AccessManaged, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice The market that fills orders.
    IPerpsMarket public immutable market;

    /// @notice Collateral token (escrowed collateral and execution fees).
    IERC20 public immutable collateralToken;

    /// @notice Identifier the next order will receive.
    uint256 public nextOrderId = 1;

    /// @notice Collateral and execution fees escrowed by pending orders.
    uint256 public totalEscrow;

    /// @dev Pending orders by identifier.
    mapping(uint256 orderId => Order) private _orders;

    /// @param collateral_ Collateral token of the market.
    /// @param authority_ AccessManager gating `executeOrder` to keepers.
    constructor(IERC20 collateral_, address authority_) AccessManaged(authority_) {
        market = IPerpsMarket(msg.sender);
        collateralToken = collateral_;
        // The market is immutable and only pulls the collateral of the order it is filling (see `fillOrder`).
        collateral_.forceApprove(msg.sender, type(uint256).max);
    }

    /// @notice Creates a two-step order and escrows its collateral (increase orders) and execution fee.
    /// @dev Market orders must have `triggerPrice == 0`; trigger orders need a non-zero trigger and size. Use
    ///      `type(uint128).max` (buys) or 0 (sells) as `acceptablePrice` for "no slippage limit".
    /// @param orderType Kind of order.
    /// @param isLong Side.
    /// @param sizeDeltaUsd Notional to add or remove (USD).
    /// @param collateralDelta Collateral to escrow (increase) or to withdraw on a partial decrease.
    /// @param triggerPrice Trigger price for limit / take-profit / stop-loss orders.
    /// @param acceptablePrice Worst acceptable fill price.
    /// @param executionFee Keeper fee, at least the market's `minExecutionFee`.
    /// @return orderId Identifier of the new order.
    function createOrder(
        OrderType orderType,
        bool isLong,
        uint256 sizeDeltaUsd,
        uint256 collateralDelta,
        uint256 triggerPrice,
        uint256 acceptablePrice,
        uint256 executionFee
    ) external nonReentrant returns (uint256 orderId) {
        // slither-disable-next-line unused-return
        (uint256 minFee,, bool isPaused) = market.requestConfig();
        bool increase = _isIncrease(orderType);
        require(!(increase && isPaused), MarketPaused());
        require(executionFee >= minFee, ExecutionFeeTooLow(executionFee, minFee));
        require(sizeDeltaUsd != 0 || collateralDelta != 0, EmptyOrder());
        if (_isMarketOrder(orderType)) {
            require(triggerPrice == 0, InvalidTriggerPrice(triggerPrice));
        } else {
            require(triggerPrice != 0, InvalidTriggerPrice(triggerPrice));
            require(sizeDeltaUsd != 0, EmptyOrder());
        }

        orderId = nextOrderId++;
        _orders[orderId] = Order({
            account: msg.sender,
            orderType: orderType,
            isLong: isLong,
            createdAt: uint64(block.timestamp),
            sizeDeltaUsd: sizeDeltaUsd.toUint128(),
            collateralDelta: collateralDelta.toUint128(),
            triggerPrice: triggerPrice.toUint128(),
            acceptablePrice: acceptablePrice.toUint128(),
            executionFee: executionFee.toUint128()
        });

        uint256 escrow = (increase ? collateralDelta : 0) + executionFee;
        totalEscrow += escrow;
        emit OrderCreated(
            orderId,
            msg.sender,
            orderType,
            isLong,
            sizeDeltaUsd,
            collateralDelta,
            triggerPrice,
            acceptablePrice,
            executionFee
        );
        collateralToken.safeTransferFrom(msg.sender, address(this), escrow);
    }

    /// @notice Cancels an unexecuted order after the market's `orderTimeout` and refunds its whole escrow, including
    ///         the execution fee.
    /// @dev The timeout applies to every order type: an order its owner could cancel at will before a keeper settles
    ///      it would be a free option on the next oracle update.
    /// @param orderId Identifier of the order.
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order memory order = _orders[orderId];
        require(order.account != address(0), UnknownOrder(orderId));
        require(order.account == msg.sender, NotOrderOwner(msg.sender, order.account));
        // slither-disable-next-line unused-return
        (, uint256 timeout,) = market.requestConfig();
        uint256 cancellableAt = uint256(order.createdAt) + timeout;
        require(block.timestamp >= cancellableAt, CancelTooEarly(cancellableAt));

        delete _orders[orderId];
        uint256 refund = _escrowedCollateral(order) + order.executionFee;
        totalEscrow -= refund;
        emit OrderCancelled(orderId, msg.sender, "");
        collateralToken.safeTransfer(order.account, refund);
    }

    /// @notice Settles an order with signed price reports that are all strictly newer than the order.
    /// @dev Reverts, without cancelling, when a trigger order's condition is not met. Any other failure of the fill
    ///      cancels the order, refunds its collateral and still pays the execution fee to the keeper. A fill that runs
    ///      out of gas returns empty revert data; the whole transaction then reverts, so a keeper cannot force
    ///      cancellations by under-supplying gas.
    /// @param orderId Identifier of the order.
    /// @param reports Signed reports from distinct oracle signers.
    function executeOrder(uint256 orderId, IOracleVerifier.SignedPriceReport[] calldata reports)
        external
        nonReentrant
        restricted
    {
        Order memory order = _orders[orderId];
        require(order.account != address(0), UnknownOrder(orderId));
        (uint256 price, uint256 oldestTs) = market.refreshPrice(reports, order.createdAt);
        if (!_isMarketOrder(order.orderType)) {
            require(_triggerMet(order, price), TriggerNotMet(price, order.triggerPrice));
        }

        delete _orders[orderId];
        uint256 collateral = _escrowedCollateral(order);
        totalEscrow -= collateral + order.executionFee;

        try market.fillOrder(order, price) {
            emit OrderExecuted(orderId, msg.sender, price, oldestTs);
        } catch (bytes memory reason) {
            require(reason.length != 0, ExecutionOutOfGas());
            emit OrderCancelled(orderId, msg.sender, reason);
            if (collateral != 0) collateralToken.safeTransfer(order.account, collateral);
        }
        collateralToken.safeTransfer(msg.sender, order.executionFee);
    }

    /// @notice A pending order (all zero once executed or cancelled).
    /// @param orderId Identifier.
    /// @return The stored order.
    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    /// @notice Whether an order's trigger condition holds at `price` (always true for market orders).
    /// @param orderId Identifier of a pending order.
    /// @param price Candidate median price.
    /// @return True when a keeper may settle the order at `price`.
    function isExecutable(uint256 orderId, uint256 price) external view returns (bool) {
        Order memory order = _orders[orderId];
        if (order.account == address(0)) return false;
        return _isMarketOrder(order.orderType) || _triggerMet(order, price);
    }

    function _triggerMet(Order memory order, uint256 price) private pure returns (bool) {
        uint256 trigger = order.triggerPrice;
        if (order.orderType == OrderType.TakeProfit) {
            return order.isLong ? price >= trigger : price <= trigger;
        }
        // LimitIncrease and StopLoss share the same direction: long at or below the trigger, short at or above.
        return order.isLong ? price <= trigger : price >= trigger;
    }

    function _escrowedCollateral(Order memory order) private pure returns (uint256) {
        return _isIncrease(order.orderType) ? order.collateralDelta : 0;
    }

    function _isIncrease(OrderType t) private pure returns (bool) {
        return t == OrderType.MarketIncrease || t == OrderType.LimitIncrease;
    }

    function _isMarketOrder(OrderType t) private pure returns (bool) {
        return t == OrderType.MarketIncrease || t == OrderType.MarketDecrease;
    }
}
