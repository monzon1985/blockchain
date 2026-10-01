// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IKestrelConfig
/// @notice Risk parameters the lending market reads on every health check. Served by
///         {KestrelConfig} behind {KestrelProxy}.
interface IKestrelConfig {
    /// @notice Loan-to-value ratio, in basis points (e.g. 7500 = 75%).
    /// @return bps Current loan-to-value.
    function ltvBps() external view returns (uint256 bps);

    /// @notice Debt-token value of 1 ETH (1e18 wei), WAD. Prices vault-share collateral.
    /// @return price Current reference ETH price.
    function ethPrice() external view returns (uint256 price);
}
