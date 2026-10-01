// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IOracle} from "../../src/interfaces/IOracle.sol";

/// @notice Settable `IOracle` (1e36 scale). Can be switched to revert to simulate an unavailable price.
contract MockOracle is IOracle {
    error OracleDown();

    uint256 public currentPrice;
    bool public down;

    constructor(uint256 initialPrice) {
        currentPrice = initialPrice;
    }

    function setPrice(uint256 newPrice) external {
        currentPrice = newPrice;
    }

    function setDown(bool isDown) external {
        down = isDown;
    }

    function price() external view returns (uint256) {
        require(!down, OracleDown());
        return currentPrice;
    }
}
