// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Balance movement categories. Every share balance change is exactly one of these.
/// @dev `Transfer`: peer-to-peer `transfer`/`transferFrom`. `Mint`: issuance through a 7540 claim.
///      `Burn`: redemption request. `Forced`: ERC-7943 enforcement. `Recovery`: lost-wallet recovery.
enum TransferKind {
    Transfer,
    Mint,
    Burn,
    Forced,
    Recovery
}

/// @notice Everything a compliance module needs to judge or record a balance movement.
/// @dev Built once per movement by the engine so that modules do not re-query the registry.
struct TransferContext {
    TransferKind kind;
    address from;
    address to;
    uint256 amount;
    bytes32 fromId;
    bytes32 toId;
    uint16 fromCountry;
    uint16 toCountry;
    uint256 fromBalance;
    uint256 toInvestorBalance;
    bool toBecomesHolder;
    bool fromLeavesHolders;
}

/// @title IComplianceModule
/// @notice A pluggable transfer rule bound to one compliance engine.
interface IComplianceModule {
    /// @notice Engine this module is bound to.
    /// @return engineAddress Engine address.
    function engine() external view returns (address engineAddress);

    /// @notice Human-readable rule name.
    /// @return moduleName Name.
    function name() external view returns (string memory moduleName);

    /// @notice Whether the engine must call `onTransfer` after each movement.
    /// @return stateful True if the module keeps per-movement state.
    function isStateful() external view returns (bool stateful);

    /// @notice Whether the movement described by `ctx` satisfies this rule. Must not revert.
    /// @param ctx Movement context.
    /// @return allowed True if allowed.
    function check(TransferContext calldata ctx) external view returns (bool allowed);

    /// @notice Records an executed movement. Only callable by the engine, only for stateful modules.
    /// @param ctx Movement context.
    function onTransfer(TransferContext calldata ctx) external;
}

/// @title IComplianceEngine
/// @notice Single choke point that every share balance movement goes through.
interface IComplianceEngine {
    /// @notice Validates and records a movement; reverts if any module rejects it. Only the bound token.
    /// @param kind Movement category.
    /// @param from Sender (zero for mints).
    /// @param to Recipient (zero for burns).
    /// @param amount Amount.
    function transferred(TransferKind kind, address from, address to, uint256 amount) external;

    /// @notice Whether a movement would pass every module, without recording it.
    /// @param kind Movement category.
    /// @param from Sender.
    /// @param to Recipient.
    /// @param amount Amount.
    /// @return allowed True if every module accepts.
    /// @return rejectedBy First rejecting module, or zero.
    function checkTransfer(TransferKind kind, address from, address to, uint256 amount)
        external
        view
        returns (bool allowed, address rejectedBy);

    /// @notice Identity attributed to `wallet`: the snapshot taken when it became a holder, else the registry's.
    /// @param wallet Wallet.
    /// @return identity Identity id.
    function resolveIdentity(address wallet) external view returns (bytes32 identity);

    /// @notice Aggregate share balance of `identity` across all its wallets.
    /// @param identity Identity id.
    /// @return balance Aggregate balance.
    function investorBalance(bytes32 identity) external view returns (uint256 balance);

    /// @notice Number of investors (identities) with a positive balance attributed to `country`.
    /// @param country ISO 3166-1 numeric code.
    /// @return count Holder count.
    function holderCount(uint16 country) external view returns (uint256 count);

    /// @notice Number of investors with a positive balance, all countries.
    /// @return count Holder count.
    function totalHolders() external view returns (uint256 count);
}
