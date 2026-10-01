// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {ComplianceModuleBase} from "./ComplianceModuleBase.sol";
import {IComplianceModule, TransferContext, TransferKind} from "../../interfaces/ICompliance.sol";

/// @title LockupModule
/// @notice Minimum holding period for newly issued shares: shares minted by a 7540 claim cannot be transferred
///         or redeemed until `lockupPeriod` has elapsed.
/// @dev One lock per wallet. A new mint while a lock is active adds to it and restarts the clock for the whole
///      locked amount (conservative: never unlocks early, at the cost of re-locking earlier lots). Forced
///      transfers bypass the rule and shrink the lock to the remaining balance; recoveries move the lock to the
///      successor wallet.
contract LockupModule is ComplianceModuleBase {
    /// @dev Lock of a wallet; `amount` only counts while `until > block.timestamp`.
    struct Lock {
        uint192 amount;
        uint64 until;
    }

    /// @notice Upper bound for `lockupPeriod`.
    uint64 public constant MAX_LOCKUP = 365 days;

    /// @notice Holding period applied to new mints.
    uint64 public lockupPeriod;

    /// @notice Raw lock per wallet (use `lockedBalanceOf` for the effective amount).
    mapping(address wallet => Lock) public locks;

    /// @notice Emitted when the holding period changes.
    /// @param period New period in seconds.
    event LockupPeriodSet(uint64 period);
    /// @notice Emitted whenever a wallet's lock changes.
    /// @param wallet Wallet.
    /// @param amount Locked amount.
    /// @param until Unlock time.
    event LockUpdated(address indexed wallet, uint256 amount, uint64 until);

    /// @notice Period above `MAX_LOCKUP`.
    error LockupTooLong(uint64 period, uint64 max);

    /// @param initialAuthority AccessManager.
    /// @param engine_ Compliance engine.
    /// @param period Initial holding period.
    constructor(address initialAuthority, address engine_, uint64 period)
        ComplianceModuleBase(initialAuthority, engine_)
    {
        _setLockupPeriod(period);
    }

    /// @notice Sets the holding period for future mints (existing locks keep their unlock time).
    /// @param period Period in seconds.
    function setLockupPeriod(uint64 period) external restricted {
        _setLockupPeriod(period);
    }

    /// @inheritdoc IComplianceModule
    function name() external pure returns (string memory) {
        return "Lockup";
    }

    /// @inheritdoc IComplianceModule
    function isStateful() external pure override returns (bool) {
        return true;
    }

    /// @notice Currently locked amount of `wallet`.
    /// @param wallet Wallet.
    /// @return Locked amount (may exceed the balance only transiently inside a movement).
    function lockedBalanceOf(address wallet) public view returns (uint256) {
        Lock memory lock = locks[wallet];
        return lock.until > block.timestamp ? lock.amount : 0;
    }

    /// @inheritdoc IComplianceModule
    function check(TransferContext calldata ctx) external view returns (bool) {
        if (ctx.kind != TransferKind.Transfer && ctx.kind != TransferKind.Burn) return true;
        uint256 locked = lockedBalanceOf(ctx.from);
        // With nothing locked the rule is silent; an amount above the balance is a plain balance failure,
        // which ERC-7943 `canTransfer` must not report as a permission failure.
        if (locked == 0) return true;
        uint256 unlocked = ctx.fromBalance > locked ? ctx.fromBalance - locked : 0;
        return ctx.amount <= unlocked;
    }

    /// @dev Mint: lock the new shares. Forced: shrink the lock to what is left. Recovery: move the lock.
    function _onTransfer(TransferContext calldata ctx) internal override {
        if (ctx.kind == TransferKind.Mint) {
            _lockMint(ctx.to, ctx.amount);
        } else if (ctx.kind == TransferKind.Forced) {
            uint256 locked = lockedBalanceOf(ctx.from);
            uint256 remaining = ctx.fromBalance - ctx.amount;
            if (locked > remaining) _writeLock(ctx.from, remaining, locks[ctx.from].until);
        } else if (ctx.kind == TransferKind.Recovery) {
            _moveLock(ctx.from, ctx.to);
        }
        // Transfer and Burn: `check` guaranteed amount <= unlocked, so the lock stays covered.
    }

    function _lockMint(address to, uint256 amount) private {
        uint64 period = lockupPeriod;
        if (period == 0 || amount == 0) return;
        uint256 newAmount = lockedBalanceOf(to) + amount;
        _writeLock(to, newAmount, SafeCast.toUint64(block.timestamp) + period);
    }

    function _moveLock(address from, address to) private {
        uint256 moving = lockedBalanceOf(from);
        if (moving == 0) return;
        uint64 fromUntil = locks[from].until;
        uint256 existing = lockedBalanceOf(to);
        uint64 until = existing != 0 && locks[to].until > fromUntil ? locks[to].until : fromUntil;
        _writeLock(from, 0, 0);
        _writeLock(to, existing + moving, until);
    }

    function _writeLock(address wallet, uint256 amount, uint64 until) private {
        // SafeCast reverts instead of truncating for amounts above 2^192 - 1.
        locks[wallet] = Lock({amount: SafeCast.toUint192(amount), until: until});
        emit LockUpdated(wallet, amount, until);
    }

    function _setLockupPeriod(uint64 period) private {
        require(period <= MAX_LOCKUP, LockupTooLong(period, MAX_LOCKUP));
        lockupPeriod = period;
        emit LockupPeriodSet(period);
    }
}
