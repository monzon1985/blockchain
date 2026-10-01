// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";

import {IPaymentStablecoinEvents} from "../interfaces/IPaymentStablecoinEvents.sol";

/**
 * @title ComplianceControls
 * @notice Issuer controls a regulated payment stablecoin has to be able to exercise: a global pause, a sanctions
 *         blocklist, per-account freezes, and seizure or destruction of frozen funds under a recorded lawful order.
 * @dev Enforcement lives in the token's single `_update` choke point (see `TestPaymentDollarV1._update`): any
 *      movement that debits or credits a blocklisted or frozen account reverts, and every movement reverts while
 *      paused. The only two paths that can debit a restricted account are {seize} and {burnFrozen}; both require the
 *      account to be frozen, a non-zero order reference, and an unpaused token, and neither can credit a restricted
 *      account. They reach the ERC-20 base `_update` directly, which is why the choke point cannot be bypassed from
 *      anywhere else: no other function in the codebase calls `ERC20Upgradeable._update`.
 *
 *      The blocklist (sanctions screening, BLOCKLISTER role) and freezes (lawful orders, COMPLIANCE_OFFICER role)
 *      are kept separate on purpose: the two lists are maintained by different teams under different legal bases,
 *      and only a lawful order may lead to funds being taken.
 */
abstract contract ComplianceControls is
    ERC20Upgradeable,
    PausableUpgradeable,
    AccessManagedUpgradeable,
    IPaymentStablecoinEvents
{
    /// @custom:storage-location erc7201:tpd.storage.Compliance
    struct ComplianceStorage {
        /// @dev Sanctions blocklist: a listed account can neither send, receive, approve nor spend.
        mapping(address account => bool) blocklisted;
        /// @dev Lawful-order freezes: same transfer restrictions, and the balance becomes seizable / burnable.
        mapping(address account => bool) frozen;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("tpd.storage.Compliance")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant COMPLIANCE_STORAGE_LOCATION =
        0xc3e971441d2608db304310d47b5ed908589a5be55299dc519509c51da3c55600;

    // ------------------------------------------------------------------------------------------------------------
    // Emergency brake
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Stops every value movement (transfers, gasless payments, mints, burns, bridge operations, seizures)
    ///         and every new approval. Restricted to PAUSER.
    function pause() external restricted {
        _pause();
    }

    /// @notice Resumes value movements. Restricted to PAUSER.
    function unpause() external restricted {
        _unpause();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Sanctions blocklist
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Adds `account` to the sanctions blocklist. Restricted to BLOCKLISTER.
    /// @param account The address to block; must not be the zero address or already blocklisted.
    function blocklist(address account) external restricted {
        ComplianceStorage storage $ = _getComplianceStorage();
        require(account != address(0), InvalidAccount(account));
        require(!$.blocklisted[account], BlocklistStatusUnchanged(account, true));
        $.blocklisted[account] = true;
        emit Blocklisted(account);
    }

    /// @notice Removes `account` from the sanctions blocklist. Restricted to BLOCKLISTER.
    /// @param account A currently blocklisted address.
    function unBlocklist(address account) external restricted {
        ComplianceStorage storage $ = _getComplianceStorage();
        require($.blocklisted[account], BlocklistStatusUnchanged(account, false));
        $.blocklisted[account] = false;
        emit UnBlocklisted(account);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Lawful orders: freeze, seize, burn
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Freezes `account` under the lawful order `orderRef`. Restricted to COMPLIANCE_OFFICER.
    /// @param account The address to freeze; must not be the zero address or already frozen.
    /// @param orderRef Hash identifying the lawful order (for example keccak256 of the signed order document).
    function freeze(address account, bytes32 orderRef) external restricted {
        ComplianceStorage storage $ = _getComplianceStorage();
        require(orderRef != bytes32(0), MissingOrderReference());
        require(account != address(0), InvalidAccount(account));
        require(!$.frozen[account], FreezeStatusUnchanged(account, true));
        $.frozen[account] = true;
        emit Frozen(account, orderRef);
    }

    /// @notice Lifts the freeze on `account` under the lawful order `orderRef`. Restricted to COMPLIANCE_OFFICER.
    /// @param account A currently frozen address.
    /// @param orderRef Hash identifying the order that lifts the freeze.
    function unfreeze(address account, bytes32 orderRef) external restricted {
        ComplianceStorage storage $ = _getComplianceStorage();
        require(orderRef != bytes32(0), MissingOrderReference());
        require($.frozen[account], FreezeStatusUnchanged(account, false));
        $.frozen[account] = false;
        emit Unfrozen(account, orderRef);
    }

    /// @notice Moves `amount` out of the frozen account `from` into the unrestricted account `to` under the lawful
    ///         order `orderRef`. Restricted to COMPLIANCE_OFFICER. Reverts while paused.
    /// @dev Emits the ERC-20 `Transfer(from, to, amount)` and {Seized}. `to` is checked against the blocklist and
    ///      freezes, so seized funds can never land in a restricted account.
    /// @param from A frozen account.
    /// @param to The recipient (for example a court-controlled custody wallet); must be unrestricted and non-zero.
    /// @param amount The amount to seize; non-zero and at most the balance of `from`.
    /// @param orderRef Hash identifying the lawful order.
    function seize(address from, address to, uint256 amount, bytes32 orderRef) external restricted {
        _requireNotPaused();
        require(orderRef != bytes32(0), MissingOrderReference());
        require(amount != 0, ZeroAmount());
        require(_getComplianceStorage().frozen[from], AccountNotFrozen(from));
        require(to != address(0), InvalidAccount(to));
        _requireUnrestricted(to);
        // Lawful-order path: the ERC-20 base `_update` is reached directly so the debit of the frozen `from` is not
        // rejected by the restriction checks in the token's `_update` override. `to` was checked just above.
        ERC20Upgradeable._update(from, to, amount);
        emit Seized(from, to, amount, orderRef);
    }

    /// @notice Destroys the entire balance of the frozen account `account` under the lawful order `orderRef`.
    ///         Restricted to COMPLIANCE_OFFICER. Reverts while paused.
    /// @dev Emits the ERC-20 `Transfer(account, address(0), amount)` and {FrozenFundsBurned}. Reduces total supply,
    ///      so it can never break the supply <= attested reserves property.
    /// @param account A frozen account with a non-zero balance.
    /// @param orderRef Hash identifying the lawful order.
    function burnFrozen(address account, bytes32 orderRef) external restricted {
        _requireNotPaused();
        require(orderRef != bytes32(0), MissingOrderReference());
        require(_getComplianceStorage().frozen[account], AccountNotFrozen(account));
        uint256 amount = balanceOf(account);
        require(amount != 0, ZeroAmount());
        // Lawful-order path, see {seize}.
        ERC20Upgradeable._update(account, address(0), amount);
        emit FrozenFundsBurned(account, amount, orderRef);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Whether `account` is on the sanctions blocklist.
    /// @param account The address to query.
    /// @return True if blocklisted.
    function isBlocklisted(address account) external view returns (bool) {
        return _getComplianceStorage().blocklisted[account];
    }

    /// @notice Whether `account` is frozen under a lawful order.
    /// @param account The address to query.
    /// @return True if frozen.
    function isFrozen(address account) external view returns (bool) {
        return _getComplianceStorage().frozen[account];
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Reverts with {AccountBlocklisted} or {AccountFrozen} when `account` is restricted.
    function _requireUnrestricted(address account) internal view {
        ComplianceStorage storage $ = _getComplianceStorage();
        require(!$.blocklisted[account], AccountBlocklisted(account));
        require(!$.frozen[account], AccountFrozen(account));
    }

    /// @dev Returns the ERC-7201 namespaced storage of this module.
    function _getComplianceStorage() private pure returns (ComplianceStorage storage $) {
        // Assigning a constant slot to a storage pointer is the ERC-7201 pattern; nothing is read or written here.
        assembly ("memory-safe") {
            $.slot := COMPLIANCE_STORAGE_LOCATION
        }
    }
}
