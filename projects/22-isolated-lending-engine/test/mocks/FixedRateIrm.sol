// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IIrm} from "../../src/interfaces/IIrm.sol";
import {Market, MarketParams} from "../../src/interfaces/ILendingEngine.sol";

/// @notice IRM returning a settable constant per-second rate.
contract FixedRateIrm is IIrm {
    uint256 public ratePerSecond;

    constructor(uint256 initialRatePerSecond) {
        ratePerSecond = initialRatePerSecond;
    }

    function setRate(uint256 newRatePerSecond) external {
        ratePerSecond = newRatePerSecond;
    }

    function borrowRate(MarketParams calldata, Market calldata) external view returns (uint256) {
        return ratePerSecond;
    }

    function borrowRateView(MarketParams calldata, Market calldata) external view returns (uint256) {
        return ratePerSecond;
    }
}
