// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title FundRoles
/// @notice AccessManager role ids shared by every fund contract.
/// @dev Role 0 is the AccessManager `ADMIN_ROLE` (fund governance, expected to be a multisig behind a timelock).
library FundRoles {
    /// @notice AccessManager root role: grants roles, wires selectors, governance-only actions.
    uint64 internal constant ADMIN = 0;
    /// @notice Fund administrator: epochs, custody, documents, dividends.
    uint64 internal constant FUND_ADMIN = 1;
    /// @notice Transfer agent: wallet onboarding, referenced forced transfers, lost-wallet recovery.
    uint64 internal constant TRANSFER_AGENT = 2;
    /// @notice NAV oracle: posts net asset value per share.
    uint64 internal constant NAV_ORACLE = 3;
    /// @notice Compliance officer: trusted issuers, required claims, modules and their limits, freezes.
    uint64 internal constant COMPLIANCE_OFFICER = 4;
    /// @notice Issuing vault contract: mints on claims and burns on redemption requests.
    uint64 internal constant VAULT = 5;
}
