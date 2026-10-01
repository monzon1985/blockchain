// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RegistryLimits} from "../../interfaces/IRegistry.sol";
import {LibRegistryDiamond} from "../libraries/LibRegistryDiamond.sol";
import {RegistryFacetBase} from "./RegistryFacetBase.sol";

/// @title AdminFacet
/// @notice Grace period, pause switch, treasury and payment views of the registry diamond.
contract AdminFacet is RegistryFacetBase {
    /// @notice Sets the post-expiry grace period.
    /// @param newGracePeriod Grace period in seconds, at most MAX_GRACE_PERIOD.
    function setGracePeriod(uint64 newGracePeriod) external onlyOwner {
        if (newGracePeriod > RegistryLimits.MAX_GRACE_PERIOD) {
            revert InvalidGracePeriod(newGracePeriod, RegistryLimits.MAX_GRACE_PERIOD);
        }
        LibRegistryDiamond.RegistryStorage storage $ = LibRegistryDiamond.registryStorage();
        emit GracePeriodUpdated($.gracePeriod, newGracePeriod);
        $.gracePeriod = newGracePeriod;
    }

    /// @notice Pauses new subscriptions (cancellations stay open).
    function pause() external onlyOwner whenNotPaused {
        LibRegistryDiamond.registryStorage().paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Resumes new subscriptions.
    function unpause() external onlyOwner {
        LibRegistryDiamond.RegistryStorage storage $ = LibRegistryDiamond.registryStorage();
        if (!$.paused) revert ExpectedPause();
        $.paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Changes the treasury that receives payments.
    /// @param newTreasury New treasury, non-zero.
    function setTreasury(address newTreasury) external onlyOwner {
        LibRegistryDiamond.RegistryStorage storage $ = LibRegistryDiamond.registryStorage();
        if (address($.paymentToken) == address(0)) revert PaymentsNotConfigured();
        if (newTreasury == address(0)) revert InvalidTreasury(address(0));
        emit TreasuryUpdated($.treasury, newTreasury);
        $.treasury = newTreasury;
    }

    /// @notice Post-expiry grace period in seconds.
    /// @return The grace period.
    function gracePeriod() external view returns (uint64) {
        return LibRegistryDiamond.registryStorage().gracePeriod;
    }

    /// @notice Whether new subscriptions are paused.
    /// @return True when paused.
    function paused() external view returns (bool) {
        return LibRegistryDiamond.registryStorage().paused;
    }

    /// @notice Token subscribers pay in.
    /// @return The payment token.
    function paymentToken() external view returns (address) {
        return address(LibRegistryDiamond.registryStorage().paymentToken);
    }

    /// @notice Account receiving payments.
    /// @return The treasury.
    function treasury() external view returns (address) {
        return LibRegistryDiamond.registryStorage().treasury;
    }

    /// @notice Sum of every payment collected, in payment-token units.
    /// @return The lifetime revenue.
    function totalRevenue() external view returns (uint256) {
        return LibRegistryDiamond.registryStorage().totalRevenue;
    }

    /// @notice Semantic version of the diamond's application facets.
    /// @return The version string.
    function version() external pure returns (string memory) {
        return "diamond-1.0.0";
    }
}
