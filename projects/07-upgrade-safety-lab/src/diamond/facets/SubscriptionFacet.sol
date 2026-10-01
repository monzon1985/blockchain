// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LibRegistryDiamond} from "../libraries/LibRegistryDiamond.sol";
import {RegistryFacetBase} from "./RegistryFacetBase.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title SubscriptionFacet
/// @notice Subscribing, cancelling and subscription views of the registry diamond.
/// @dev The reentrancy guard lives in transient storage of the diamond (facets run via delegatecall), so it
///      protects every facet at once and adds no persistent state.
contract SubscriptionFacet is RegistryFacetBase, ReentrancyGuardTransient {
    /// @notice Subscribes the caller to a free plan; never moves tokens (a priced plan reverts with
    ///         `PriceAboveMax(planId, price, 0)`).
    /// @param planId The plan to subscribe to.
    /// @return expiresAt Timestamp at which the caller's access ends.
    function subscribe(uint256 planId) external nonReentrant whenNotPaused returns (uint64 expiresAt) {
        return _subscribe(planId, 0);
    }

    /// @notice Subscribes the caller and pulls the plan price, which must not exceed `maxPrice`, into the treasury.
    /// @param planId The plan to subscribe to.
    /// @param maxPrice Highest price the caller accepts, in payment-token units.
    /// @return expiresAt Timestamp at which the caller's access ends.
    function subscribeWithMaxPrice(uint256 planId, uint128 maxPrice)
        external
        nonReentrant
        whenNotPaused
        returns (uint64 expiresAt)
    {
        return _subscribe(planId, maxPrice);
    }

    /// @notice Cancels the caller's subscription; the remaining time is forfeited (no refund).
    function cancel() external {
        LibRegistryDiamond.RegistryStorage storage $ = LibRegistryDiamond.registryStorage();
        uint64 planId = $.subscriptions[msg.sender].planId;
        if (planId == 0) revert NoSubscription(msg.sender);
        delete $.subscriptions[msg.sender];
        emit SubscriptionCancelled(msg.sender, planId);
    }

    /// @notice The subscription of an account.
    /// @param subscriber The account to read.
    /// @return planId Plan subscribed to (0 when none).
    /// @return expiresAt Expiry timestamp (0 when none).
    function subscriptionOf(address subscriber) external view returns (uint256 planId, uint64 expiresAt) {
        LibRegistryDiamond.Subscription memory s = LibRegistryDiamond.registryStorage().subscriptions[subscriber];
        return (s.planId, s.expiresAt);
    }

    /// @notice Whether the account currently has access.
    /// @param subscriber The account to check.
    /// @return True while `block.timestamp < expiresAt + gracePeriod`.
    function isActive(address subscriber) external view returns (bool) {
        LibRegistryDiamond.RegistryStorage storage $ = LibRegistryDiamond.registryStorage();
        uint64 expiresAt = $.subscriptions[subscriber].expiresAt;
        return expiresAt != 0 && block.timestamp < uint256(expiresAt) + $.gracePeriod;
    }

    /// @notice Number of renewals by an account.
    /// @param subscriber The account to read.
    /// @return The renewal count.
    function renewalsOf(address subscriber) external view returns (uint32) {
        return LibRegistryDiamond.registryStorage().renewals[subscriber];
    }

    /// @notice Lifetime number of successful `subscribe` calls.
    /// @return The counter.
    function totalSubscriptions() external view returns (uint64) {
        return LibRegistryDiamond.registryStorage().totalSubscriptions;
    }

    /// @dev Shared body of both entry points. Checks-effects-interactions: all writes and events precede the single
    ///      token transfer. Checks run in the same order as in UUPS V3, so both revert with identical data.
    function _subscribe(uint256 planId, uint128 maxPrice) private returns (uint64 expiresAt) {
        LibRegistryDiamond.RegistryStorage storage $ = LibRegistryDiamond.registryStorage();
        _requirePlan($, planId);
        LibRegistryDiamond.Plan memory p = $.plans[planId];
        if (!p.active) revert PlanInactive(planId);
        if (p.price > maxPrice) revert PriceAboveMax(planId, p.price, maxPrice);

        LibRegistryDiamond.Subscription storage s = $.subscriptions[msg.sender];
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 nowTs = uint64(block.timestamp); // lossless until the year 2^64 s (about 5.8e11 years)
        bool renewal = s.planId == planId && s.expiresAt > nowTs;
        expiresAt = (renewal ? s.expiresAt : nowTs) + p.duration;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.planId = uint64(planId); // lossless: planId <= planCount, which is a uint64
        s.expiresAt = expiresAt;
        $.totalSubscriptions += 1;
        if (renewal) $.renewals[msg.sender] += 1;
        emit Subscribed(msg.sender, planId, expiresAt, renewal);

        if (p.price != 0) {
            address treasury_ = $.treasury;
            $.totalRevenue += p.price;
            emit PaymentCollected(msg.sender, planId, treasury_, p.price);
            SafeERC20.safeTransferFrom($.paymentToken, msg.sender, treasury_, p.price);
        }
    }
}
