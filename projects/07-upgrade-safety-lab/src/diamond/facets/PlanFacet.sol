// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RegistryLimits} from "../../interfaces/IRegistry.sol";
import {LibRegistryDiamond} from "../libraries/LibRegistryDiamond.sol";
import {RegistryFacetBase} from "./RegistryFacetBase.sol";

/// @title PlanFacet
/// @notice Plan administration and plan views of the registry diamond.
contract PlanFacet is RegistryFacetBase {
    /// @notice Creates a plan (free until priced).
    /// @param duration Seconds of access per subscription, 1..MAX_DURATION.
    /// @return planId Identifier of the new plan.
    function createPlan(uint64 duration) external onlyOwner returns (uint256 planId) {
        if (duration == 0 || duration > RegistryLimits.MAX_DURATION) {
            revert InvalidDuration(duration, RegistryLimits.MAX_DURATION);
        }
        LibRegistryDiamond.RegistryStorage storage $ = LibRegistryDiamond.registryStorage();
        uint64 id = $.planCount + 1;
        $.planCount = id;
        $.plans[id] = LibRegistryDiamond.Plan({duration: duration, active: true, price: 0});
        emit PlanCreated(id, duration);
        return id;
    }

    /// @notice Opens or closes a plan for new subscriptions.
    /// @param planId The plan to update.
    /// @param active True to accept new subscriptions.
    function setPlanActive(uint256 planId, bool active) external onlyOwner {
        LibRegistryDiamond.RegistryStorage storage $ = LibRegistryDiamond.registryStorage();
        _requirePlan($, planId);
        $.plans[planId].active = active;
        emit PlanStatusChanged(planId, active);
    }

    /// @notice Sets the price of a plan.
    /// @param planId The plan to reprice.
    /// @param price Payment-token units per period; zero makes the plan free.
    function setPlanPrice(uint256 planId, uint128 price) external onlyOwner {
        LibRegistryDiamond.RegistryStorage storage $ = LibRegistryDiamond.registryStorage();
        if (address($.paymentToken) == address(0)) revert PaymentsNotConfigured();
        _requirePlan($, planId);
        $.plans[planId].price = price;
        emit PlanPriceUpdated(planId, price);
    }

    /// @notice Number of plans created; valid ids are 1..planCount.
    /// @return The plan count.
    function planCount() external view returns (uint256) {
        return LibRegistryDiamond.registryStorage().planCount;
    }

    /// @notice Plan parameters.
    /// @param planId The plan to read.
    /// @return duration Seconds of access per subscription.
    /// @return active Whether new subscriptions are accepted.
    function plan(uint256 planId) external view returns (uint64 duration, bool active) {
        LibRegistryDiamond.Plan memory p = LibRegistryDiamond.registryStorage().plans[planId];
        return (p.duration, p.active);
    }

    /// @notice Price of a plan in payment-token units.
    /// @param planId The plan to read.
    /// @return The price (zero for free plans).
    function planPrice(uint256 planId) external view returns (uint128) {
        return LibRegistryDiamond.registryStorage().plans[planId].price;
    }
}
