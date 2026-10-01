// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {
    ERC20BridgeableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-ERC20BridgeableUpgradeable.sol";
import {RateLimiter} from "@openzeppelin/contracts/utils/RateLimiter.sol";

import {ReserveGate} from "./ReserveGate.sol";

/**
 * @title MintController
 * @notice Who may create or destroy supply, and how fast.
 *         - Minters (USDC-style): the master minter sets each minter's remaining allowance and its rolling 24 h
 *           limit; a mint consumes both. The rolling limit is an OpenZeppelin `RateLimiter.SlidingWindow`, so the
 *           amount minted in *any* 24 h interval is capped, not just per calendar day.
 *         - Bridges (ERC-7802): `crosschainMint` / `crosschainBurn` are capped by their own rolling 24 h limits,
 *           independent of minter allowances (bridges have none).
 *         Every supply increase, minter or bridge, is also gated on a fresh reserve attestation: three caps on minter
 *         issuance (allowance, rolling limit, reserves), two on bridge issuance (rolling limit, reserves).
 * @dev The master minter can only move a minter's rolling limit up to {minterLimitCeiling}, which ADMIN sets behind
 *      the 2-day governance delay. Reconfiguring or removing a minter never resets its rolling window (the
 *      checkpoint history is kept), so a remove/re-add cycle cannot be used to launder the daily limit.
 */
abstract contract MintController is ReserveGate, ERC20BridgeableUpgradeable {
    using RateLimiter for RateLimiter.SlidingWindow;

    /// @notice Length of every rolling window (minters and bridges).
    uint48 public constant RATE_LIMIT_WINDOW = 24 hours;

    /// @dev Each minter owns a dedicated limiter (per-minter limits), so a single constant key is enough.
    bytes32 private constant MINTER_KEY = bytes32(0);

    /// @custom:storage-location erc7201:tpd.storage.Minting
    struct MintingStorage {
        /// @dev Whether the address is a configured minter (a MINTER role holder also needs this to mint or burn).
        mapping(address minter => bool) isMinter;
        /// @dev Remaining amount each minter may mint; decreases on every mint, never restored by burns.
        mapping(address minter => uint256) allowance;
        /// @dev Per-minter rolling 24 h limiter; its `_limit` is the minter's daily limit.
        mapping(address minter => RateLimiter.SlidingWindow) minterWindow;
        /// @dev Upper bound the master minter may give any single minter as a daily limit.
        uint208 minterLimitCeiling;
        /// @dev Rolling 24 h cap on `crosschainMint`, shared configuration, one entry per bridge address.
        RateLimiter.SlidingWindow bridgeMintWindow;
        /// @dev Rolling 24 h cap on `crosschainBurn`, shared configuration, one entry per bridge address.
        RateLimiter.SlidingWindow bridgeBurnWindow;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("tpd.storage.Minting")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant MINTING_STORAGE_LOCATION =
        0xbec6ac1cfd57e1b4c2f7aa1c4ce67635c7f9f5a5cb5be2dde3f05a5c063ea400;

    // ------------------------------------------------------------------------------------------------------------
    // Master minter
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Configures `minter` with a remaining allowance and a rolling 24 h limit. Restricted to MASTER_MINTER.
    /// @dev The allowance is *set*, not increased (USDC semantics). The minter also needs the MINTER role, which only
    ///      ADMIN can grant (2-day delay), so the master minter cannot create new minting keys on its own.
    /// @param minter The minter to configure; must not be the zero address.
    /// @param allowance Total amount the minter may still mint.
    /// @param dailyLimit Maximum amount the minter may mint in any rolling 24 h window; at most the ceiling.
    function configureMinter(address minter, uint256 allowance, uint208 dailyLimit) external restricted {
        MintingStorage storage $ = _getMintingStorage();
        require(minter != address(0), InvalidAccount(minter));
        uint208 ceiling = $.minterLimitCeiling;
        require(dailyLimit <= ceiling, DailyLimitAboveCeiling(dailyLimit, ceiling));
        $.isMinter[minter] = true;
        $.allowance[minter] = allowance;
        $.minterWindow[minter].updateSettings(RATE_LIMIT_WINDOW, dailyLimit);
        emit MinterConfigured(minter, allowance, dailyLimit);
    }

    /// @notice Removes `minter`: zero allowance, zero rolling limit, no more mints or burns. Restricted to
    ///         MASTER_MINTER. This is the instant kill switch for a compromised minter key.
    /// @param minter A configured minter.
    function removeMinter(address minter) external restricted {
        MintingStorage storage $ = _getMintingStorage();
        require($.isMinter[minter], MinterNotConfigured(minter));
        $.isMinter[minter] = false;
        $.allowance[minter] = 0;
        $.minterWindow[minter].updateSettings(RATE_LIMIT_WINDOW, 0);
        emit MinterRemoved(minter);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Minters
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Mints `amount` to `to`, consuming the caller's allowance and rolling limit. Restricted to MINTER.
    /// @dev Reverts if the caller is not a configured minter or is restricted, if `to` is restricted, while paused,
    ///      or if the mint is not covered by a fresh reserve attestation.
    /// @param to Recipient; must not be the zero address, blocklisted or frozen.
    /// @param amount Amount to mint; non-zero.
    function mint(address to, uint256 amount) external restricted {
        address minter = _msgSender();
        MintingStorage storage $ = _getMintingStorage();
        require($.isMinter[minter], MinterNotConfigured(minter));
        require(amount != 0, ZeroAmount());
        _requireUnrestricted(minter);
        uint256 remaining = $.allowance[minter];
        require(amount <= remaining, MinterAllowanceExceeded(minter, remaining, amount));
        RateLimiter.SlidingWindow storage window = $.minterWindow[minter];
        if (!window.tryConsume(MINTER_KEY, amount)) {
            revert MinterRateLimitExceeded(minter, window.available(MINTER_KEY), amount);
        }
        _requireReserveHeadroom(amount);
        $.allowance[minter] = remaining - amount;
        _mint(to, amount);
        emit Mint(minter, to, amount);
    }

    /// @notice Burns `amount` from the caller's own balance (the redemption leg). Restricted to MINTER.
    /// @dev Burning does not restore the minter's allowance. Reverts while paused or if the caller is restricted.
    /// @param amount Amount to burn; non-zero and at most the caller's balance.
    function burn(uint256 amount) external restricted {
        address minter = _msgSender();
        require(_getMintingStorage().isMinter[minter], MinterNotConfigured(minter));
        require(amount != 0, ZeroAmount());
        _burn(minter, amount);
        emit Burn(minter, amount);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Bridge (ERC-7802)
    // ------------------------------------------------------------------------------------------------------------

    /// @notice ERC-7802 cross-chain mint. Restricted to BRIDGE; capped by the rolling bridge mint limit and gated on
    ///         reserves like any other supply increase.
    /// @dev Replaces the OpenZeppelin implementation instead of extending it so that every check runs before the
    ///      mint. `onlyTokenBridge` resolves to the AccessManager check in {_checkTokenBridge}. A blocklisted or
    ///      frozen bridge is refused, exactly like a restricted minter, so the blocklist and freezes contain a
    ///      compromised or sanctioned bridge contract instantly, without a global pause.
    /// @param to Recipient; must not be the zero address, blocklisted or frozen.
    /// @param value Amount to mint; non-zero.
    function crosschainMint(address to, uint256 value) public override onlyTokenBridge {
        MintingStorage storage $ = _getMintingStorage();
        require(value != 0, ZeroAmount());
        _requireUnrestricted(msg.sender);
        bytes32 key = _bridgeKey(msg.sender);
        if (!$.bridgeMintWindow.tryConsume(key, value)) {
            revert BridgeMintLimitExceeded(msg.sender, $.bridgeMintWindow.available(key), value);
        }
        _requireReserveHeadroom(value);
        _mint(to, value);
        emit CrosschainMint(to, value, msg.sender);
    }

    /// @notice ERC-7802 cross-chain burn. Restricted to BRIDGE; capped by the rolling bridge burn limit.
    /// @dev A bridge can burn from any unrestricted holder without an allowance (ERC-7802 semantics), which is why
    ///      the burn side has its own cap. Burning from a blocklisted or frozen account reverts in `_update`, and a
    ///      blocklisted or frozen bridge is refused (see {crosschainMint}).
    /// @param from Account to burn from; must not be blocklisted or frozen.
    /// @param value Amount to burn; non-zero and at most the balance of `from`.
    function crosschainBurn(address from, uint256 value) public override onlyTokenBridge {
        MintingStorage storage $ = _getMintingStorage();
        require(value != 0, ZeroAmount());
        _requireUnrestricted(msg.sender);
        bytes32 key = _bridgeKey(msg.sender);
        if (!$.bridgeBurnWindow.tryConsume(key, value)) {
            revert BridgeBurnLimitExceeded(msg.sender, $.bridgeBurnWindow.available(key), value);
        }
        _burn(from, value);
        emit CrosschainBurn(from, value, msg.sender);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Governance (ADMIN, 2-day delay)
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Sets the maximum rolling 24 h limit the master minter may give a single minter. Restricted to ADMIN.
    /// @dev Lowering the ceiling does not shrink limits that are already configured; remove or reconfigure those
    ///      minters to apply it.
    /// @param ceiling New ceiling in token units.
    function setMinterLimitCeiling(uint208 ceiling) external restricted {
        _setMinterLimitCeiling(ceiling);
    }

    /// @notice Sets the rolling 24 h limits that apply to each bridge. Restricted to ADMIN.
    /// @param mintLimit Per-bridge `crosschainMint` cap in any rolling 24 h window.
    /// @param burnLimit Per-bridge `crosschainBurn` cap in any rolling 24 h window.
    function setBridgeLimits(uint208 mintLimit, uint208 burnLimit) external restricted {
        _setBridgeLimits(mintLimit, burnLimit);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Whether `minter` is a configured minter.
    /// @param minter The address to query.
    /// @return True if configured.
    function isMinter(address minter) external view returns (bool) {
        return _getMintingStorage().isMinter[minter];
    }

    /// @notice Remaining allowance of `minter`.
    /// @param minter The address to query.
    /// @return Amount the minter may still mint, ignoring the rolling limit and reserves.
    function minterAllowance(address minter) external view returns (uint256) {
        return _getMintingStorage().allowance[minter];
    }

    /// @notice Rolling 24 h limit of `minter`.
    /// @param minter The address to query.
    /// @return The configured daily limit (0 if never configured or removed).
    function minterDailyLimit(address minter) external view returns (uint256) {
        // Reading the limiter's configuration field directly: the library exposes no getter for it, and reading
        // (as opposed to writing) it cannot corrupt the limiter.
        return _getMintingStorage().minterWindow[minter]._limit;
    }

    /// @notice What `minter` may still mint in the current rolling window.
    /// @param minter The address to query.
    /// @return Remaining rolling-window capacity (the allowance and reserves may be lower).
    function minterWindowAvailable(address minter) external view returns (uint256) {
        return _getMintingStorage().minterWindow[minter].available(MINTER_KEY);
    }

    /// @notice The governance ceiling on minter daily limits.
    /// @return The ceiling in token units.
    function minterLimitCeiling() external view returns (uint256) {
        return _getMintingStorage().minterLimitCeiling;
    }

    /// @notice Per-bridge rolling 24 h limits.
    /// @return mintLimit The `crosschainMint` cap.
    /// @return burnLimit The `crosschainBurn` cap.
    function bridgeLimits() external view returns (uint256 mintLimit, uint256 burnLimit) {
        MintingStorage storage $ = _getMintingStorage();
        return ($.bridgeMintWindow._limit, $.bridgeBurnWindow._limit);
    }

    /// @notice What `bridge` may still mint and burn in the current rolling windows.
    /// @param bridge The bridge address.
    /// @return mintAvailable Remaining `crosschainMint` capacity.
    /// @return burnAvailable Remaining `crosschainBurn` capacity.
    function bridgeAvailable(address bridge) external view returns (uint256 mintAvailable, uint256 burnAvailable) {
        MintingStorage storage $ = _getMintingStorage();
        bytes32 key = _bridgeKey(bridge);
        return ($.bridgeMintWindow.available(key), $.bridgeBurnWindow.available(key));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------------------

    /// @dev ERC-7802 bridge check delegated to the AccessManager, exactly like a `restricted` function.
    function _checkTokenBridge(address caller) internal override {
        _checkCanCall(caller, _msgData());
    }

    /// @dev Sets the minter-limit ceiling and emits {MinterLimitCeilingSet}.
    function _setMinterLimitCeiling(uint208 ceiling) internal {
        _getMintingStorage().minterLimitCeiling = ceiling;
        emit MinterLimitCeilingSet(ceiling);
    }

    /// @dev Updates both bridge limiters and emits {BridgeLimitsSet}.
    function _setBridgeLimits(uint208 mintLimit, uint208 burnLimit) internal {
        MintingStorage storage $ = _getMintingStorage();
        $.bridgeMintWindow.updateSettings(RATE_LIMIT_WINDOW, mintLimit);
        $.bridgeBurnWindow.updateSettings(RATE_LIMIT_WINDOW, burnLimit);
        emit BridgeLimitsSet(mintLimit, burnLimit);
    }

    /// @dev Limiter key of a bridge address.
    function _bridgeKey(address bridge) private pure returns (bytes32) {
        return bytes32(uint256(uint160(bridge)));
    }

    /// @dev Returns the ERC-7201 namespaced storage of this module.
    function _getMintingStorage() private pure returns (MintingStorage storage $) {
        // Assigning a constant slot to a storage pointer is the ERC-7201 pattern; nothing is read or written here.
        assembly ("memory-safe") {
            $.slot := MINTING_STORAGE_LOCATION
        }
    }
}
