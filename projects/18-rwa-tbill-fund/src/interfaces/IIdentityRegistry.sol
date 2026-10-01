// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IIdentityRegistry
/// @notice Read surface of the claims-based identity registry consumed by the token and compliance engine.
interface IIdentityRegistry {
    /// @notice Investor identity bound to `wallet`, or zero.
    /// @param wallet Wallet to resolve.
    /// @return identity Identity id.
    function identityOf(address wallet) external view returns (bytes32 identity);

    /// @notice Whether `wallet` is bound to an identity holding a valid claim for every required topic.
    /// @param wallet Wallet to check.
    /// @return verified True if verified.
    function isVerified(address wallet) external view returns (bool verified);

    /// @notice ISO 3166-1 numeric country of `identity` from its valid jurisdiction claim, or 0.
    /// @param identity Identity id.
    /// @return country Country code.
    function investorCountry(bytes32 identity) external view returns (uint16 country);
}
