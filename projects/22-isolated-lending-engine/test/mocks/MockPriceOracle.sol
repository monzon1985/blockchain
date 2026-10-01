// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @notice Scriptable `IPriceOracle` that returns a configured (price, status) per asset, mimicking the resilient
///         oracle router's non-reverting API. Intent-based rounding is modelled by an optional one-wei spread.
contract MockPriceOracle is IPriceOracle {
    struct Quote {
        uint256 price;
        Status status;
    }

    mapping(address asset => Quote) public quotes;

    /// @notice When true, `Debt` quotes are one wei above `Collateral` quotes (the router's rounding asymmetry).
    bool public roundingSpread;

    function setQuote(address asset, uint256 price, Status status) external {
        quotes[asset] = Quote(price, status);
    }

    function setRoundingSpread(bool enabled) external {
        roundingSpread = enabled;
    }

    function tryGetPrice(address asset, Intent intent) external view returns (uint256 price, Status status) {
        Quote memory q = quotes[asset];
        price = q.price;
        if (roundingSpread && intent == Intent.Debt && price != 0) price += 1;
        status = q.status;
    }
}
