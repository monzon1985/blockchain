// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RateLimiter} from "@openzeppelin/contracts/utils/RateLimiter.sol";

import {TestPaymentDollarV1} from "./TestPaymentDollarV1.sol";

/**
 * @title Test Payment Dollar (tPD), version 2
 * @notice Adds a rolling 24 h outflow cap for accounts the compliance officer flags (for example accounts under
 *         enhanced due diligence), on top of everything version 1 does. TEST TOKEN: technical demonstration only.
 * @dev Upgrade-safe by construction: v2 inherits v1 unchanged and keeps its new state in a fresh ERC-7201 namespace
 *      (`tpd.storage.TransferCaps`), so no v1 slot moves. `scripts/check-storage-layout.mjs` verifies that against
 *      the committed v1 baseline, and `test/unit/Upgrade.t.sol` checks sentinels across a real upgrade.
 *
 *      The cap applies to every outflow of a flagged account that goes through `_update` (transfer, transferFrom,
 *      both ERC-3009 flavours, minter burn, crosschainBurn). The lawful-order paths (seize, burnFrozen) are exempt
 *      because they bypass `_update` by design.
 */
contract TestPaymentDollarV2 is TestPaymentDollarV1 {
    using RateLimiter for RateLimiter.SlidingWindow;

    /// @notice Cap installed by {initializeV2}; governance can change it afterwards with {setFlaggedDailyCap}.
    uint208 public constant DEFAULT_FLAGGED_DAILY_CAP = 10_000e6;

    /// @custom:storage-location erc7201:tpd.storage.TransferCaps
    struct TransferCapStorage {
        /// @dev Accounts subject to the rolling outflow cap.
        mapping(address account => bool) flagged;
        /// @dev Shared-configuration limiter, one entry per flagged account (key = account address).
        RateLimiter.SlidingWindow outflow;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("tpd.storage.TransferCaps")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant TRANSFER_CAPS_STORAGE_LOCATION =
        0x2e7d943a214ca2a23416e28b2c8389a4957cad20d6314e40976c8877fa554900;

    /// @notice `account` was flagged or unflagged for the rolling outflow cap.
    /// @param account The account.
    /// @param flagged The new status.
    event TransferCapFlagSet(address indexed account, bool flagged);

    /// @notice The rolling 24 h outflow cap for flagged accounts changed.
    /// @param cap The new cap in token units.
    event FlaggedDailyCapSet(uint256 cap);

    /// @notice The outflow exceeds what the flagged `account` may still send in the current rolling 24 h window.
    /// @param account The flagged account.
    /// @param available What it may still send.
    /// @param amount The attempted outflow.
    error FlaggedTransferCapExceeded(address account, uint256 available, uint256 amount);

    /// @notice A flag update would not change anything.
    /// @param account The account.
    /// @param flagged The status it already has.
    error TransferCapFlagUnchanged(address account, bool flagged);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Version-2 initializer, run atomically through `upgradeToAndCall`. Installs the default cap.
    /// @dev Takes no argument on purpose: if an upgrade were ever executed without it, a front-runner calling it
    ///      could only install the documented default, never a value of their choosing.
    function initializeV2() external reinitializer(2) {
        _setFlaggedDailyCap(DEFAULT_FLAGGED_DAILY_CAP);
    }

    /// @notice Flags or unflags `account` for the rolling outflow cap. Restricted to COMPLIANCE_OFFICER.
    /// @param account The account; must not be the zero address.
    /// @param flagged The new status; must differ from the current one.
    function setTransferCapFlag(address account, bool flagged) external restricted {
        require(account != address(0), InvalidAccount(account));
        TransferCapStorage storage $ = _getTransferCapStorage();
        require($.flagged[account] != flagged, TransferCapFlagUnchanged(account, flagged));
        $.flagged[account] = flagged;
        emit TransferCapFlagSet(account, flagged);
    }

    /// @notice Sets the rolling 24 h outflow cap of flagged accounts. Restricted to ADMIN (2-day delay).
    /// @param cap New cap in token units.
    function setFlaggedDailyCap(uint208 cap) external restricted {
        _setFlaggedDailyCap(cap);
    }

    /// @notice Whether `account` is flagged for the outflow cap.
    /// @param account The address to query.
    /// @return True if flagged.
    function isTransferCapFlagged(address account) external view returns (bool) {
        return _getTransferCapStorage().flagged[account];
    }

    /// @notice The rolling 24 h outflow cap of flagged accounts.
    /// @return The cap in token units.
    function flaggedDailyCap() external view returns (uint256) {
        return _getTransferCapStorage().outflow._limit;
    }

    /// @notice What `account` may still send in the current rolling window if it is flagged.
    /// @param account The address to query.
    /// @return Remaining capacity (meaningful only while the account is flagged).
    function flaggedOutflowAvailable(address account) external view returns (uint256) {
        return _getTransferCapStorage().outflow.available(_accountKey(account));
    }

    /// @inheritdoc TestPaymentDollarV1
    function implementationVersion() external pure override returns (string memory) {
        return "2";
    }

    /// @dev Consumes the rolling cap for outflows of flagged accounts, then runs the v1 choke point.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) {
            TransferCapStorage storage $ = _getTransferCapStorage();
            if ($.flagged[from]) {
                bytes32 key = _accountKey(from);
                if (!$.outflow.tryConsume(key, value)) {
                    revert FlaggedTransferCapExceeded(from, $.outflow.available(key), value);
                }
            }
        }
        super._update(from, to, value);
    }

    /// @dev Updates the cap and emits {FlaggedDailyCapSet}.
    function _setFlaggedDailyCap(uint208 cap) private {
        _getTransferCapStorage().outflow.updateSettings(RATE_LIMIT_WINDOW, cap);
        emit FlaggedDailyCapSet(cap);
    }

    /// @dev Limiter key of an account.
    function _accountKey(address account) private pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    /// @dev Returns the ERC-7201 namespaced storage added in version 2.
    function _getTransferCapStorage() private pure returns (TransferCapStorage storage $) {
        // Assigning a constant slot to a storage pointer is the ERC-7201 pattern; nothing is read or written here.
        assembly ("memory-safe") {
            $.slot := TRANSFER_CAPS_STORAGE_LOCATION
        }
    }
}
