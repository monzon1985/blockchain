// SPDX-License-Identifier: MIT

/// Constant-product AMM with hot-potato flash loans.
///
/// * `Pool<A, B, LP>` is a shared object holding both reserves as `Balance`s and
///   the `TreasuryCap` of its LP coin, `Coin<LpCoin<LP>>`. `LP` is a marker type
///   chosen by the creator; `create_pool` registers `LpCoin<LP>` in Sui's
///   `CoinRegistry` itself, so LP coins carry real currency metadata, and the
///   registry's uniqueness check means a marker backs exactly one pool. Because
///   only this module can register that currency, and it never makes it
///   regulated, no `DenyCapV2` for an LP coin can exist: nobody can deny-list
///   an LP or pause LP transfers to trap liquidity.
/// * Swaps charge `swap_fee_bps` (30 bps by default) on the input; the fee stays
///   in the reserves and accrues to LPs.
/// * `flash_borrow_{a,b}` return the borrowed coin together with a
///   `FlashReceipt`. The receipt has **no abilities**: it cannot be dropped,
///   copied, stored or transferred, so the only way to end the transaction is to
///   hand it back to `flash_repay_{a,b}` with principal + fee on the same pool.
///   An unpaid loan therefore aborts the whole programmable transaction block.
/// * While a loan is outstanding the pool is in `PoolState::FlashLoanOpen`, and
///   every state-changing entry point except the matching `flash_repay_*`
///   aborts with `EFlashLoanOpen` (the Move analogue of Uniswap v2's `lock`), as
///   do the price views (`reserves`, `quote_*`). Plain getters stay readable.
/// * Every entry point checks `version == VERSION`; `migrate` is `AdminCap`-gated.
module flash_kiosk::pool;

use flash_kiosk::math;
use std::type_name::{Self, TypeName};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::coin_registry::{Self, CoinRegistry};
use sui::event;

// === Constants ===

/// Version of the package logic. Bumped on every upgrade that changes the
/// semantics of existing entry points; shared objects are moved forward with `migrate`.
const VERSION: u64 = 1;
/// LP units minted to the pool itself on creation and never redeemable. They
/// keep the LP supply (and both reserves) strictly positive forever.
const MINIMUM_LIQUIDITY: u64 = 1_000;
/// Default swap fee: 30 bps.
const DEFAULT_SWAP_FEE_BPS: u64 = 30;
/// Default flash-loan fee: 30 bps.
const DEFAULT_FLASH_FEE_BPS: u64 = 30;
/// Lowest fee the `AdminCap` may configure (a zero fee would make flash loans free).
const MIN_FEE_BPS: u64 = 1;
/// Highest fee the `AdminCap` may configure: 1 %.
const MAX_FEE_BPS: u64 = 100;
/// Display decimals of every LP coin. LP units are `sqrt(a * b)`-scaled, so 9
/// matches the usual 9-decimal Sui coins; it affects wallets only.
const LP_DECIMALS: u8 = 9;
/// Symbol of every LP coin; the coin type (`LpCoin<LP>`) is what identifies it.
const LP_SYMBOL: vector<u8> = b"FKLP";
/// Name of every LP coin.
const LP_NAME: vector<u8> = b"flash_kiosk LP share";
/// Description of every LP coin.
const LP_DESCRIPTION: vector<u8> =
    b"Share of one flash_kiosk pool, identified by its LP marker type. Redeemable only through that pool.";

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Pool version does not match the package VERSION";
#[error(code = 1)]
const ENotUpgrade: vector<u8> = b"Pool is already at the current package VERSION";
#[error(code = 2)]
const EPoolPaused: vector<u8> = b"Pool is paused";
#[error(code = 3)]
const EFlashLoanOpen: vector<u8> = b"A flash loan is outstanding on this pool";
#[error(code = 4)]
const ENotPaused: vector<u8> = b"Pool is not paused";
#[error(code = 5)]
const EIdenticalTypes: vector<u8> = b"Coin A and coin B must be distinct types";
#[error(code = 6)]
const EInsufficientInitialLiquidity: vector<u8> =
    b"Initial liquidity must exceed MINIMUM_LIQUIDITY";
#[error(code = 7)]
const EZeroAmount: vector<u8> = b"Amount must be greater than zero";
#[error(code = 8)]
const EZeroOutput: vector<u8> = b"Output rounds down to zero";
#[error(code = 9)]
const ESlippage: vector<u8> = b"Output is below the caller's minimum";
#[error(code = 10)]
const EInsufficientLiquidity: vector<u8> = b"Flash loan exceeds the pool reserve";
#[error(code = 11)]
const EWrongPool: vector<u8> = b"Flash receipt belongs to another pool";
#[error(code = 12)]
const EWrongSide: vector<u8> = b"Flash receipt is for the other coin of the pool";
#[error(code = 13)]
const ERepayAmount: vector<u8> = b"Repayment must equal principal plus fee";
#[error(code = 14)]
const EFeeOutOfRange: vector<u8> = b"Fee is outside [MIN_FEE_BPS, MAX_FEE_BPS]";
#[error(code = 15)]
const EWrongPoolCap: vector<u8> = b"PoolCap belongs to another pool";
#[error(code = 16)]
const EFlashLoansDisabled: vector<u8> = b"Flash loans are disabled on this pool";

// === Types ===

/// Protocol capability, minted once in `init`: pause / unpause any pool, set
/// fees within `[MIN_FEE_BPS, MAX_FEE_BPS]`, and `migrate` pools to a new VERSION.
/// It cannot move reserves or mint LP coins.
public struct AdminCap has key, store { id: UID }

/// Per-pool configuration capability, minted by `create_pool` for the pool's
/// creator. It can only toggle flash loans on the pool whose id it carries.
public struct PoolCap has key, store {
    id: UID,
    pool_id: ID,
}

/// Lifecycle of a pool. Between transactions a pool is always `Active` or
/// `Paused`: `FlashLoanOpen` only exists inside a PTB, because the receipt that
/// resets it cannot outlive the transaction.
public enum PoolState has copy, drop, store {
    /// All entry points available.
    Active,
    /// Swaps, deposits and flash loans disabled; withdrawals stay open.
    Paused,
    /// A flash loan is outstanding. The matching repay is the only state-changing
    /// call the pool accepts; every other one, and the price views, abort.
    FlashLoanOpen,
}

/// Type of the LP coin of the pool whose marker type is `LP`: shares are
/// `Coin<LpCoin<LP>>`. It is never instantiated. It has `key` only because
/// `coin_registry::new_currency` requires it, and since it is defined here,
/// only this module can register its currency (in `create_pool`).
public struct LpCoin<phantom LP> has key { id: UID }

/// Which reserve a flash loan was taken from.
public enum Side has copy, drop, store {
    A,
    B,
}

/// Shared constant-product pool. No `store`: it can never be wrapped or
/// transferred, only accessed through this module.
public struct Pool<phantom A, phantom B, phantom LP> has key {
    id: UID,
    /// Package VERSION this object was last migrated to.
    version: u64,
    /// Current lifecycle state (see `PoolState`).
    state: PoolState,
    /// Reserve of coin A.
    reserve_a: Balance<A>,
    /// Reserve of coin B.
    reserve_b: Balance<B>,
    /// Treasury of the pool's LP coin; its total supply is the LP supply.
    lp_treasury: TreasuryCap<LpCoin<LP>>,
    /// `MINIMUM_LIQUIDITY` LP units owned by the pool forever.
    locked_lp: Balance<LpCoin<LP>>,
    /// Swap fee in basis points, charged on the input amount.
    swap_fee_bps: u64,
    /// Flash-loan fee in basis points, charged on the borrowed amount.
    flash_fee_bps: u64,
    /// Whether the pool lends its reserves (toggled by the `PoolCap`).
    flash_loans_enabled: bool,
}

/// Hot potato returned by `flash_borrow_{a,b}`. It has no abilities, so the
/// Move type system guarantees it is consumed by `flash_repay_{a,b}` before the
/// transaction ends.
public struct FlashReceipt {
    /// Pool the loan was taken from.
    pool_id: ID,
    /// Reserve the loan was taken from.
    side: Side,
    /// Borrowed principal.
    amount: u64,
    /// Fee owed on top of the principal (fixed at borrow time).
    fee: u64,
}

// === Events ===

/// Emitted once per pool by `create_pool`.
public struct PoolCreated has copy, drop {
    pool_id: ID,
    pool_cap_id: ID,
    coin_a: TypeName,
    coin_b: TypeName,
    lp_coin: TypeName,
    amount_a: u64,
    amount_b: u64,
    lp_minted: u64,
    creator: address,
}

/// Emitted on every swap. Reserves are post-trade.
public struct Swapped has copy, drop {
    pool_id: ID,
    sender: address,
    a_to_b: bool,
    amount_in: u64,
    amount_out: u64,
    fee: u64,
    reserve_a: u64,
    reserve_b: u64,
}

/// Emitted by `add_liquidity`.
public struct LiquidityAdded has copy, drop {
    pool_id: ID,
    sender: address,
    amount_a: u64,
    amount_b: u64,
    lp_minted: u64,
}

/// Emitted by `remove_liquidity`.
public struct LiquidityRemoved has copy, drop {
    pool_id: ID,
    sender: address,
    amount_a: u64,
    amount_b: u64,
    lp_burned: u64,
}

/// Emitted by `flash_borrow_{a,b}`.
public struct FlashLoanTaken has copy, drop {
    pool_id: ID,
    side: Side,
    amount: u64,
    fee: u64,
}

/// Emitted by `flash_repay_{a,b}`.
public struct FlashLoanRepaid has copy, drop {
    pool_id: ID,
    side: Side,
    amount: u64,
    fee: u64,
}

/// Emitted by `pause` and `unpause`.
public struct StateChanged has copy, drop {
    pool_id: ID,
    state: PoolState,
}

/// Emitted by `set_fees`.
public struct FeesUpdated has copy, drop {
    pool_id: ID,
    swap_fee_bps: u64,
    flash_fee_bps: u64,
}

/// Emitted by `set_flash_loans_enabled`.
public struct FlashLoansToggled has copy, drop {
    pool_id: ID,
    enabled: bool,
}

/// Emitted by `migrate`.
public struct PoolMigrated has copy, drop {
    pool_id: ID,
    from_version: u64,
    to_version: u64,
}

// === Init ===

/// Mints the single `AdminCap` to the publisher.
fun init(ctx: &mut TxContext) {
    transfer::transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
}

// === Pool creation ===

/// Creates and shares a pool seeded with `coin_a` and `coin_b`, and registers
/// its LP coin `LpCoin<LP>` in the `CoinRegistry` (`0xc`).
///
/// `LP` is any marker type the creator picks. The registry refuses a second
/// currency for the same type, so a marker that already backs a pool aborts
/// with `coin_registry::ECurrencyAlreadyExists`. The LP currency is never made
/// regulated and its `MetadataCap` is deleted, so its metadata is fixed and no
/// deny list can ever apply to it. The first depositor receives
/// `sqrt(a * b) - MINIMUM_LIQUIDITY` LP; `MINIMUM_LIQUIDITY` stays locked in the
/// pool. Returns the LP coin and the pool's `PoolCap`.
public fun create_pool<A, B, LP>(
    registry: &mut CoinRegistry,
    coin_a: Coin<A>,
    coin_b: Coin<B>,
    ctx: &mut TxContext,
): (Coin<LpCoin<LP>>, PoolCap) {
    let coin_a_type = type_name::with_defining_ids<A>();
    let coin_b_type = type_name::with_defining_ids<B>();
    assert!(coin_a_type != coin_b_type, EIdenticalTypes);

    let amount_a = coin_a.value();
    let amount_b = coin_b.value();
    assert!(amount_a > 0 && amount_b > 0, EZeroAmount);
    let initial_lp = math::sqrt_down(amount_a, amount_b);
    assert!(initial_lp > MINIMUM_LIQUIDITY, EInsufficientInitialLiquidity);

    // Registering the currency here is what makes the LP coin unregulatable:
    // `make_regulated` only exists on the initializer, which never leaves this call.
    let (lp_currency, lp_treasury) = coin_registry::new_currency<LpCoin<LP>>(
        registry,
        LP_DECIMALS,
        LP_SYMBOL.to_string(),
        LP_NAME.to_string(),
        LP_DESCRIPTION.to_string(),
        b"".to_string(),
        ctx,
    );
    lp_currency.finalize_and_delete_metadata_cap(ctx);

    let mut pool = Pool<A, B, LP> {
        id: object::new(ctx),
        version: VERSION,
        state: PoolState::Active,
        reserve_a: coin_a.into_balance(),
        reserve_b: coin_b.into_balance(),
        lp_treasury,
        locked_lp: balance::zero(),
        swap_fee_bps: DEFAULT_SWAP_FEE_BPS,
        flash_fee_bps: DEFAULT_FLASH_FEE_BPS,
        flash_loans_enabled: true,
    };
    let locked = pool.lp_treasury.mint_balance(MINIMUM_LIQUIDITY);
    pool.locked_lp.join(locked);
    let lp_minted = initial_lp - MINIMUM_LIQUIDITY;
    let lp = pool.lp_treasury.mint(lp_minted, ctx);

    let pool_id = object::id(&pool);
    let cap = PoolCap { id: object::new(ctx), pool_id };
    event::emit(PoolCreated {
        pool_id,
        pool_cap_id: object::id(&cap),
        coin_a: coin_a_type,
        coin_b: coin_b_type,
        lp_coin: type_name::with_defining_ids<LpCoin<LP>>(),
        amount_a,
        amount_b,
        lp_minted,
        creator: ctx.sender(),
    });
    transfer::share_object(pool);
    (lp, cap)
}

// === Swaps ===

/// Sells `coin_in` for coin B. Aborts unless the output is at least `min_out`.
public fun swap_a_for_b<A, B, LP>(
    pool: &mut Pool<A, B, LP>,
    coin_in: Coin<A>,
    min_out: u64,
    ctx: &mut TxContext,
): Coin<B> {
    pool.assert_active();
    let amount_in = coin_in.value();
    let (amount_out, fee) = math::amount_out(
        amount_in,
        pool.reserve_a.value(),
        pool.reserve_b.value(),
        pool.swap_fee_bps,
    );
    check_swap(amount_in, amount_out, min_out);

    pool.reserve_a.join(coin_in.into_balance());
    let coin_out = coin::take(&mut pool.reserve_b, amount_out, ctx);
    pool.emit_swap(ctx.sender(), true, amount_in, amount_out, fee);
    coin_out
}

/// Sells `coin_in` for coin A. Aborts unless the output is at least `min_out`.
public fun swap_b_for_a<A, B, LP>(
    pool: &mut Pool<A, B, LP>,
    coin_in: Coin<B>,
    min_out: u64,
    ctx: &mut TxContext,
): Coin<A> {
    pool.assert_active();
    let amount_in = coin_in.value();
    let (amount_out, fee) = math::amount_out(
        amount_in,
        pool.reserve_b.value(),
        pool.reserve_a.value(),
        pool.swap_fee_bps,
    );
    check_swap(amount_in, amount_out, min_out);

    pool.reserve_b.join(coin_in.into_balance());
    let coin_out = coin::take(&mut pool.reserve_a, amount_out, ctx);
    pool.emit_swap(ctx.sender(), false, amount_in, amount_out, fee);
    coin_out
}

// === Liquidity ===

/// Deposits at the current ratio. Mints `min(a * S / Ra, b * S / Rb)` LP (rounded
/// down), pulls `ceil(lp * R / S)` of each coin (rounded up, so the depositor
/// pays the rounding) and refunds whatever is left of `coin_a` and `coin_b`.
/// Returns `(lp, refund_a, refund_b)`.
public fun add_liquidity<A, B, LP>(
    pool: &mut Pool<A, B, LP>,
    mut coin_a: Coin<A>,
    mut coin_b: Coin<B>,
    min_lp_out: u64,
    ctx: &mut TxContext,
): (Coin<LpCoin<LP>>, Coin<A>, Coin<B>) {
    pool.assert_active();
    let (reserve_a, reserve_b) = pool.reserves();
    let supply = pool.lp_supply();
    let lp_from_a = math::mul_div_down!(coin_a.value(), supply, reserve_a);
    let lp_from_b = math::mul_div_down!(coin_b.value(), supply, reserve_b);
    let lp_minted = lp_from_a.min(lp_from_b);
    assert!(lp_minted > 0, EZeroOutput);
    assert!(lp_minted >= min_lp_out, ESlippage);

    // `lp_minted <= value * S / R` implies `ceil(lp_minted * R / S) <= value`,
    // so neither split can exceed the coin it is taken from.
    let used_a = math::mul_div_up!(lp_minted, reserve_a, supply);
    let used_b = math::mul_div_up!(lp_minted, reserve_b, supply);
    pool.reserve_a.join(coin_a.split(used_a, ctx).into_balance());
    pool.reserve_b.join(coin_b.split(used_b, ctx).into_balance());
    let lp = pool.lp_treasury.mint(lp_minted, ctx);

    event::emit(LiquidityAdded {
        pool_id: object::id(pool),
        sender: ctx.sender(),
        amount_a: used_a,
        amount_b: used_b,
        lp_minted,
    });
    (lp, coin_a, coin_b)
}

/// Burns `lp` for a pro-rata share of both reserves (rounded down). Allowed
/// while the pool is paused, so no capability can lock LPs in.
public fun remove_liquidity<A, B, LP>(
    pool: &mut Pool<A, B, LP>,
    lp: Coin<LpCoin<LP>>,
    min_a: u64,
    min_b: u64,
    ctx: &mut TxContext,
): (Coin<A>, Coin<B>) {
    pool.assert_version();
    pool.assert_no_open_loan();
    let lp_burned = lp.value();
    assert!(lp_burned > 0, EZeroAmount);

    let (reserve_a, reserve_b) = pool.reserves();
    let supply = pool.lp_supply();
    // `lp_burned < supply` because `MINIMUM_LIQUIDITY` is never in circulation,
    // so both outputs are strictly below the reserves they come from.
    let amount_a = math::mul_div_down!(lp_burned, reserve_a, supply);
    let amount_b = math::mul_div_down!(lp_burned, reserve_b, supply);
    assert!(amount_a > 0 && amount_b > 0, EZeroOutput);
    assert!(amount_a >= min_a && amount_b >= min_b, ESlippage);

    pool.lp_treasury.burn(lp);
    event::emit(LiquidityRemoved {
        pool_id: object::id(pool),
        sender: ctx.sender(),
        amount_a,
        amount_b,
        lp_burned,
    });
    (coin::take(&mut pool.reserve_a, amount_a, ctx), coin::take(&mut pool.reserve_b, amount_b, ctx))
}

// === Flash loans ===

/// Borrows `amount` of coin A. The returned `FlashReceipt` must be handed to
/// `flash_repay_a` on this pool, with `amount + fee`, before the PTB ends.
public fun flash_borrow_a<A, B, LP>(
    pool: &mut Pool<A, B, LP>,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<A>, FlashReceipt) {
    let reserve = pool.reserve_a.value();
    let receipt = pool.open_loan(Side::A, amount, reserve);
    (coin::take(&mut pool.reserve_a, amount, ctx), receipt)
}

/// Borrows `amount` of coin B. See `flash_borrow_a`.
public fun flash_borrow_b<A, B, LP>(
    pool: &mut Pool<A, B, LP>,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<B>, FlashReceipt) {
    let reserve = pool.reserve_b.value();
    let receipt = pool.open_loan(Side::B, amount, reserve);
    (coin::take(&mut pool.reserve_b, amount, ctx), receipt)
}

/// Repays a coin-A loan. `payment` must be exactly `amount_due(&receipt)`.
public fun flash_repay_a<A, B, LP>(
    pool: &mut Pool<A, B, LP>,
    receipt: FlashReceipt,
    payment: Coin<A>,
) {
    pool.close_loan(receipt, Side::A, payment.value());
    pool.reserve_a.join(payment.into_balance());
}

/// Repays a coin-B loan. `payment` must be exactly `amount_due(&receipt)`.
public fun flash_repay_b<A, B, LP>(
    pool: &mut Pool<A, B, LP>,
    receipt: FlashReceipt,
    payment: Coin<B>,
) {
    pool.close_loan(receipt, Side::B, payment.value());
    pool.reserve_b.join(payment.into_balance());
}

// === Capability-gated configuration ===

/// Emergency stop: `Active -> Paused`. Withdrawals remain available.
public fun pause<A, B, LP>(pool: &mut Pool<A, B, LP>, _: &AdminCap) {
    pool.assert_active();
    pool.state = PoolState::Paused;
    event::emit(StateChanged { pool_id: object::id(pool), state: PoolState::Paused });
}

/// `Paused -> Active`.
public fun unpause<A, B, LP>(pool: &mut Pool<A, B, LP>, _: &AdminCap) {
    pool.assert_version();
    pool.assert_no_open_loan();
    assert!(pool.state == PoolState::Paused, ENotPaused);
    pool.state = PoolState::Active;
    event::emit(StateChanged { pool_id: object::id(pool), state: PoolState::Active });
}

/// Sets both fees. Each must lie in `[MIN_FEE_BPS, MAX_FEE_BPS]`. Aborts while
/// a loan is open, so a loan always owes the fee quoted when it was taken (the
/// receipt records that fee as well).
public fun set_fees<A, B, LP>(
    pool: &mut Pool<A, B, LP>,
    _: &AdminCap,
    swap_fee_bps: u64,
    flash_fee_bps: u64,
) {
    pool.assert_version();
    pool.assert_no_open_loan();
    assert!(swap_fee_bps >= MIN_FEE_BPS && swap_fee_bps <= MAX_FEE_BPS, EFeeOutOfRange);
    assert!(flash_fee_bps >= MIN_FEE_BPS && flash_fee_bps <= MAX_FEE_BPS, EFeeOutOfRange);
    pool.swap_fee_bps = swap_fee_bps;
    pool.flash_fee_bps = flash_fee_bps;
    event::emit(FeesUpdated { pool_id: object::id(pool), swap_fee_bps, flash_fee_bps });
}

/// Lets the pool's creator decide whether its reserves can be flash-borrowed.
public fun set_flash_loans_enabled<A, B, LP>(
    pool: &mut Pool<A, B, LP>,
    cap: &PoolCap,
    enabled: bool,
) {
    pool.assert_version();
    pool.assert_no_open_loan();
    assert!(cap.pool_id == object::id(pool), EWrongPoolCap);
    pool.flash_loans_enabled = enabled;
    event::emit(FlashLoansToggled { pool_id: object::id(pool), enabled });
}

/// Moves a pool created by an older package version to `VERSION`. After this,
/// the previous package's entry points (which still exist on chain and still
/// compare against their own, older `VERSION`) abort on this pool. Aborts while
/// a loan is open, so a loan is always repaid through the version it came from.
public fun migrate<A, B, LP>(pool: &mut Pool<A, B, LP>, _: &AdminCap) {
    pool.assert_no_open_loan();
    assert!(pool.version < VERSION, ENotUpgrade);
    let from_version = pool.version;
    pool.version = VERSION;
    event::emit(PoolMigrated { pool_id: object::id(pool), from_version, to_version: VERSION });
}

// === Views ===

/// `(reserve_a, reserve_b)`.
///
/// Aborts while a flash loan is open: mid-loan reserves are temporarily depleted,
/// and a protocol that priced collateral off them inside the same PTB would be
/// exposed to the Sui equivalent of read-only reentrancy.
public fun reserves<A, B, LP>(pool: &Pool<A, B, LP>): (u64, u64) {
    pool.assert_no_open_loan();
    (pool.reserve_a.value(), pool.reserve_b.value())
}

/// Total LP supply, including the locked `MINIMUM_LIQUIDITY`.
public fun lp_supply<A, B, LP>(pool: &Pool<A, B, LP>): u64 {
    pool.lp_treasury.total_supply()
}

/// LP units owned by the pool itself (always `MINIMUM_LIQUIDITY`).
public fun locked_liquidity<A, B, LP>(pool: &Pool<A, B, LP>): u64 {
    pool.locked_lp.value()
}

/// Current swap fee in basis points.
public fun swap_fee_bps<A, B, LP>(pool: &Pool<A, B, LP>): u64 { pool.swap_fee_bps }

/// Current flash-loan fee in basis points.
public fun flash_fee_bps<A, B, LP>(pool: &Pool<A, B, LP>): u64 { pool.flash_fee_bps }

/// Whether flash loans are enabled on this pool.
public fun flash_loans_enabled<A, B, LP>(pool: &Pool<A, B, LP>): bool {
    pool.flash_loans_enabled
}

/// Package VERSION this pool was last migrated to.
public fun version<A, B, LP>(pool: &Pool<A, B, LP>): u64 { pool.version }

/// `true` when every entry point is available.
public fun is_active<A, B, LP>(pool: &Pool<A, B, LP>): bool { pool.state == PoolState::Active }

/// `true` while an `AdminCap` holder has paused the pool.
public fun is_paused<A, B, LP>(pool: &Pool<A, B, LP>): bool { pool.state == PoolState::Paused }

/// `true` while a flash loan is outstanding (only observable inside a PTB).
public fun is_flash_loan_open<A, B, LP>(pool: &Pool<A, B, LP>): bool {
    pool.state == PoolState::FlashLoanOpen
}

/// Coin B received for selling `amount_in` of coin A at the current state.
/// Aborts while a flash loan is open (see `reserves`).
public fun quote_a_for_b<A, B, LP>(pool: &Pool<A, B, LP>, amount_in: u64): u64 {
    pool.assert_no_open_loan();
    let (out, _) = math::amount_out(
        amount_in,
        pool.reserve_a.value(),
        pool.reserve_b.value(),
        pool.swap_fee_bps,
    );
    out
}

/// Coin A received for selling `amount_in` of coin B at the current state.
/// Aborts while a flash loan is open (see `reserves`).
public fun quote_b_for_a<A, B, LP>(pool: &Pool<A, B, LP>, amount_in: u64): u64 {
    pool.assert_no_open_loan();
    let (out, _) = math::amount_out(
        amount_in,
        pool.reserve_b.value(),
        pool.reserve_a.value(),
        pool.swap_fee_bps,
    );
    out
}

/// Fee a flash loan of `amount` would owe right now (rounded up).
public fun flash_fee<A, B, LP>(pool: &Pool<A, B, LP>, amount: u64): u64 {
    math::fee_up!(amount, pool.flash_fee_bps)
}

/// Pool a receipt must be repaid to.
public fun receipt_pool_id(receipt: &FlashReceipt): ID { receipt.pool_id }

/// Borrowed principal.
public fun receipt_amount(receipt: &FlashReceipt): u64 { receipt.amount }

/// Fee frozen at borrow time.
public fun receipt_fee(receipt: &FlashReceipt): u64 { receipt.fee }

/// `true` if the loan was taken from reserve A.
public fun receipt_is_a(receipt: &FlashReceipt): bool { receipt.side == Side::A }

/// Exact repayment the receipt demands: principal + fee. Usable as a PTB
/// `SplitCoins` amount.
public fun amount_due(receipt: &FlashReceipt): u64 { receipt.amount + receipt.fee }

/// Pool a `PoolCap` configures.
public fun pool_cap_pool_id(cap: &PoolCap): ID { cap.pool_id }

/// Package logic version.
public fun package_version(): u64 { VERSION }

/// LP units locked forever in every pool.
public fun minimum_liquidity(): u64 { MINIMUM_LIQUIDITY }

// === Internal ===

fun assert_version<A, B, LP>(pool: &Pool<A, B, LP>) {
    assert!(pool.version == VERSION, EWrongVersion);
}

/// Version check plus `state == Active`, with a distinct abort per state.
fun assert_active<A, B, LP>(pool: &Pool<A, B, LP>) {
    pool.assert_version();
    match (pool.state) {
        PoolState::Active => (),
        PoolState::Paused => abort EPoolPaused,
        PoolState::FlashLoanOpen => abort EFlashLoanOpen,
    }
}

fun assert_no_open_loan<A, B, LP>(pool: &Pool<A, B, LP>) {
    assert!(pool.state != PoolState::FlashLoanOpen, EFlashLoanOpen);
}

fun check_swap(amount_in: u64, amount_out: u64, min_out: u64) {
    assert!(amount_in > 0, EZeroAmount);
    assert!(amount_out > 0, EZeroOutput);
    assert!(amount_out >= min_out, ESlippage);
}

fun emit_swap<A, B, LP>(
    pool: &Pool<A, B, LP>,
    sender: address,
    a_to_b: bool,
    amount_in: u64,
    amount_out: u64,
    fee: u64,
) {
    let (reserve_a, reserve_b) = pool.reserves();
    event::emit(Swapped {
        pool_id: object::id(pool),
        sender,
        a_to_b,
        amount_in,
        amount_out,
        fee,
        reserve_a,
        reserve_b,
    });
}

/// Validates a borrow, locks the pool and mints the receipt.
fun open_loan<A, B, LP>(
    pool: &mut Pool<A, B, LP>,
    side: Side,
    amount: u64,
    reserve: u64,
): FlashReceipt {
    pool.assert_active();
    assert!(pool.flash_loans_enabled, EFlashLoansDisabled);
    assert!(amount > 0, EZeroAmount);
    assert!(amount <= reserve, EInsufficientLiquidity);
    let fee = math::fee_up!(amount, pool.flash_fee_bps);
    let pool_id = object::id(pool);
    pool.state = PoolState::FlashLoanOpen;
    event::emit(FlashLoanTaken { pool_id, side, amount, fee });
    FlashReceipt { pool_id, side, amount, fee }
}

/// Consumes the receipt after checking pool, side and amount; unlocks the pool.
/// The state is necessarily `FlashLoanOpen` here: a receipt for this pool can
/// only exist if `open_loan` ran in this transaction, and every other
/// state-changing entry point (including `pause`) aborts in that state.
fun close_loan<A, B, LP>(
    pool: &mut Pool<A, B, LP>,
    receipt: FlashReceipt,
    expected_side: Side,
    paid: u64,
) {
    pool.assert_version();
    let FlashReceipt { pool_id, side, amount, fee } = receipt;
    assert!(pool_id == object::id(pool), EWrongPool);
    assert!(side == expected_side, EWrongSide);
    assert!(paid == amount + fee, ERepayAmount);
    pool.state = PoolState::Active;
    event::emit(FlashLoanRepaid { pool_id, side, amount, fee });
}

// === Test-only ===

#[test_only]
/// Runs `init` in a test scenario.
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

#[test_only]
/// Simulates a pool created by an older package version.
public fun set_version_for_testing<A, B, LP>(pool: &mut Pool<A, B, LP>, version: u64) {
    pool.version = version;
}
