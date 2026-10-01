// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/**
 * @title Roles
 * @notice AccessManager role identifiers and governance delays used by the Test Payment Dollar deployment.
 * @dev Role ids are `uint64` values inside an OpenZeppelin `AccessManager`. `ADMIN` is the manager's built-in
 *      `ADMIN_ROLE` (id 0), which also administers every other role. Who may call which selector is wired by
 *      `script/StablecoinDeployment.sol` and re-checked after deployment by `script/VerifyRoles.s.sol`.
 */
library Roles {
    /// @notice AccessManager's built-in `ADMIN_ROLE`: grants/revokes roles, rewires selectors, sets the reserve
    ///         attestor and the governance ceilings. Granted with a {GOVERNANCE_DELAY} execution delay.
    uint64 internal constant ADMIN = 0;

    /// @notice Configures and removes minters (allowance + rolling 24 h limit) with no delay.
    uint64 internal constant MASTER_MINTER = 1;

    /// @notice Mints against its own allowance and burns its own balance.
    uint64 internal constant MINTER = 2;

    /// @notice Emergency brake: pauses and unpauses every value movement; guardian of {UPGRADER}, so it can cancel
    ///         a scheduled upgrade during the delay window.
    uint64 internal constant PAUSER = 3;

    /// @notice Maintains the sanctions blocklist.
    uint64 internal constant BLOCKLISTER = 4;

    /// @notice Freezes and unfreezes accounts, seizes and burns frozen funds under a lawful-order reference and, from
    ///         v2 on, flags accounts for the daily transfer cap.
    uint64 internal constant COMPLIANCE_OFFICER = 5;

    /// @notice ERC-7802 cross-chain mint and burn within its own rolling limits.
    uint64 internal constant BRIDGE = 6;

    /// @notice Upgrades the UUPS proxy. Granted with a {GOVERNANCE_DELAY} execution delay.
    uint64 internal constant UPGRADER = 7;

    /// @notice Execution delay applied to {ADMIN} and {UPGRADER}: upgrades and every role-admin selector of the
    ///         AccessManager must be scheduled at least this long before they can execute.
    uint32 internal constant GOVERNANCE_DELAY = 2 days;
}
