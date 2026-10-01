// SPDX-License-Identifier: MIT

#[test_only]
/// Stateful invariant campaigns. A seeded PRNG picks the pool's starting
/// reserves (barely above `MINIMUM_LIQUIDITY`, ordinary, or near 2^58) and then
/// drives a random sequence of swaps (up to 4x the input reserve), deposits (up
/// to 3x the reserves), withdrawals, flash loans on both sides, fee changes,
/// pauses, unpauses and flash-loan toggles, one `test_scenario` transaction per
/// operation, across four actors. After every transaction the pool is checked
/// against ghost accounting kept by the test.
///
/// Every swap, deposit and withdrawal passes its exact expected output as the
/// slippage minimum, so quote, result and slippage bound must agree to the
/// unit; the `*_one_unit_above_*` tests show that one unit more aborts.
///
/// Non-vacuity: every campaign, seeded or fuzzed, opens with a prologue that runs
/// each operation kind once on the fresh pool, with random sizes from a range in
/// which it cannot be skipped, and asserts that each one ran. Seeded campaigns
/// also require every kind to run again during the random phase.
///
/// Invariants (numbered as in the README):
///   I1  LP share value `k / S^2` never decreases, for any operation.
///   I2  Conservation: each reserve equals seed + coins in - coins out.
///   I3  LP supply equals seed LP + minted - burned.
///   I4  `MINIMUM_LIQUIDITY` stays locked; supply and both reserves stay positive.
///   I5  Between transactions the pool is never in `FlashLoanOpen`.
///   I6  Every swap and every flash loan strictly increases `k`.
module flash_kiosk::invariant_tests;

use flash_kiosk::pool::{Self, Pool, AdminCap, PoolCap, LpCoin};
use flash_kiosk::test_utils::{Self as tu, ALPHA, BETA, LP_X, Rng, alice, bob, carol};
use std::unit_test::assert_eq;
use sui::coin::{Self, Coin};
use sui::test_scenario::{Self as ts, Scenario};

/// Random operations per seeded campaign (after the prologue).
const OPS_PER_CAMPAIGN: u64 = 200;
/// Random operations per fuzzed campaign (after the prologue).
const OPS_PER_FUZZ_CAMPAIGN: u64 = 60;
/// Number of weighted slots `random_op` draws from.
const OP_SLOTS: u64 = 24;
/// Swaps and deposits never push a reserve or the LP supply above 2^61 ...
const SOFT_CAP: u64 = 1 << 61;
/// ... and flash-loan fees never push a reserve above 2^62, so the I1 check
/// (`k * S^2` with `k < 2^124` and `S^2 < 2^124`) cannot overflow `u256`.
const HARD_CAP: u64 = 1 << 62;

/// How many times each operation kind actually executed (skips not counted).
public struct Counts has copy, drop {
    swaps_a: u64,
    swaps_b: u64,
    deposits: u64,
    withdrawals: u64,
    loans_a: u64,
    loans_b: u64,
    fee_changes: u64,
    pauses: u64,
    unpauses: u64,
    toggles: u64,
}

/// Ghost accounting, updated from coin values the test itself observes.
public struct Ghost has drop {
    in_a: u128,
    out_a: u128,
    in_b: u128,
    out_b: u128,
    lp_minted: u128,
    lp_burned: u128,
    counts: Counts,
}

/// Pool observables captured after each transaction.
public struct Snapshot has copy, drop {
    reserve_a: u64,
    reserve_b: u64,
    supply: u64,
}

/// A running campaign: the scenario, the PRNG, the ghost state and the LP
/// coins held by the two liquidity providers (alice seeded the pool).
public struct Campaign {
    scenario: Scenario,
    rng: Rng,
    ghost: Ghost,
    prev: Snapshot,
    seed_a: u64,
    seed_b: u64,
    seed_lp: u64,
    alice_lp: Coin<LpCoin<LP_X>>,
    carol_lp: Coin<LpCoin<LP_X>>,
}

fun snapshot(pool: &Pool<ALPHA, BETA, LP_X>): Snapshot {
    let (reserve_a, reserve_b) = pool.reserves();
    Snapshot { reserve_a, reserve_b, supply: pool.lp_supply() }
}

fun k_of(s: &Snapshot): u256 {
    (s.reserve_a as u256) * (s.reserve_b as u256)
}

/// Starting reserves, from one of three magnitudes: just enough for an LP
/// supply above `MINIMUM_LIQUIDITY`, an ordinary pool, or a pool near 2^58.
fun seed_reserves(rng: &mut Rng): (u64, u64) {
    let (lo, hi) = seed_range(rng.next() % 3);
    (lo + rng.next() % (hi - lo + 1), lo + rng.next() % (hi - lo + 1))
}

/// `[lo, hi]` of each seed-reserve class.
fun seed_range(class: u64): (u64, u64) {
    if (class == 0) return (1_001, 20_000);
    if (class == 1) return (1_000_000, 1_000_000_000_000);
    (1 << 50, 1 << 58)
}

/// `alice` creates the pool from seed reserves picked by the PRNG.
fun new_campaign(seed: u64): Campaign {
    let mut rng = tu::rng(seed);
    let (seed_a, seed_b) = seed_reserves(&mut rng);
    let mut scenario = tu::begin();
    scenario.next_tx(alice());
    let (alice_lp, cap) = tu::new_pool<LP_X>(&mut scenario, seed_a, seed_b);
    transfer::public_transfer(cap, alice());
    scenario.next_tx(alice());
    let pool = tu::take_pool<LP_X>(&scenario);
    let seed_lp = pool.lp_supply();
    let prev = snapshot(&pool);
    tu::return_pool(pool);
    let carol_lp = coin::zero<LpCoin<LP_X>>(scenario.ctx());
    Campaign {
        scenario,
        rng,
        ghost: Ghost {
            in_a: 0,
            out_a: 0,
            in_b: 0,
            out_b: 0,
            lp_minted: 0,
            lp_burned: 0,
            counts: Counts {
                swaps_a: 0,
                swaps_b: 0,
                deposits: 0,
                withdrawals: 0,
                loans_a: 0,
                loans_b: 0,
                fee_changes: 0,
                pauses: 0,
                unpauses: 0,
                toggles: 0,
            },
        },
        prev,
        seed_a,
        seed_b,
        seed_lp,
        alice_lp,
        carol_lp,
    }
}

fun finish(c: Campaign) {
    let Campaign { scenario, alice_lp, carol_lp, .. } = c;
    tu::burn(alice_lp);
    tu::burn(carol_lp);
    scenario.end();
}

/// Ends the current transaction and asserts I1-I5 against the previous snapshot.
fun check_invariants(c: &mut Campaign) {
    c.scenario.next_tx(alice());
    let pool = tu::take_pool<LP_X>(&c.scenario);
    // I5: a flash loan can never survive its transaction.
    assert!(!pool.is_flash_loan_open());
    assert!(pool.is_active() || pool.is_paused());
    let now = snapshot(&pool);

    // I1: k / S^2 is non-decreasing  <=>  k' * S^2 >= k * S'^2 (all in u256).
    let s_prev = (c.prev.supply as u256);
    let s_now = (now.supply as u256);
    assert!(k_of(&now) * s_prev * s_prev >= k_of(&c.prev) * s_now * s_now);

    // I2: conservation of both coins.
    assert_eq!((now.reserve_a as u128), (c.seed_a as u128) + c.ghost.in_a - c.ghost.out_a);
    assert_eq!((now.reserve_b as u128), (c.seed_b as u128) + c.ghost.in_b - c.ghost.out_b);

    // I3: LP supply accounting.
    assert_eq!((now.supply as u128), (c.seed_lp as u128) + c.ghost.lp_minted - c.ghost.lp_burned);

    // I4: the locked minimum never moves.
    assert_eq!(pool.locked_liquidity(), pool::minimum_liquidity());
    assert!(now.supply >= pool::minimum_liquidity());
    assert!(now.reserve_a > 0 && now.reserve_b > 0);

    tu::return_pool(pool);
    c.prev = now;
}

/// Room left under `SOFT_CAP` for a reserve or the supply.
fun headroom(value: u64): u64 {
    if (value >= SOFT_CAP) 0 else SOFT_CAP - value
}

/// `bob` sells coin A (`a_to_b`) or coin B with `min_out` = the exact quote.
/// Random size: up to 4x the input reserve. Forced size (prologue): between
/// half and all of the input reserve, which always quotes a non-zero output.
/// Skipped while paused, without headroom, or when the output rounds to zero.
fun swap(c: &mut Campaign, a_to_b: bool, forced: bool) {
    c.scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_X>(&c.scenario);
    if (pool.is_active()) {
        let (ra, rb) = pool.reserves();
        let reserve_in = if (a_to_b) ra else rb;
        let room = headroom(reserve_in);
        let amount = if (forced) {
            (reserve_in / 2 + c.rng.between_1_and(reserve_in - reserve_in / 2)).min(room)
        } else {
            let max = room.min(reserve_in.min(SOFT_CAP) * 4);
            if (max == 0) 0 else c.rng.between_1_and(max)
        };
        let quote = if (amount == 0) 0
        else if (a_to_b) pool.quote_a_for_b(amount)
        else pool.quote_b_for_a(amount);
        if (quote > 0) {
            let k_before = tu::k(ra, rb);
            if (a_to_b) {
                let coin_in = tu::mint<ALPHA>(&mut c.scenario, amount);
                let out = pool.swap_a_for_b(coin_in, quote, c.scenario.ctx());
                assert_eq!(out.value(), quote);
                c.ghost.in_a = c.ghost.in_a + (amount as u128);
                c.ghost.out_b = c.ghost.out_b + (tu::burn(out) as u128);
                c.ghost.counts.swaps_a = c.ghost.counts.swaps_a + 1;
            } else {
                let coin_in = tu::mint<BETA>(&mut c.scenario, amount);
                let out = pool.swap_b_for_a(coin_in, quote, c.scenario.ctx());
                assert_eq!(out.value(), quote);
                c.ghost.in_b = c.ghost.in_b + (amount as u128);
                c.ghost.out_a = c.ghost.out_a + (tu::burn(out) as u128);
                c.ghost.counts.swaps_b = c.ghost.counts.swaps_b + 1;
            };
            let (ra2, rb2) = pool.reserves();
            // I6 for swaps.
            assert!(tu::k(ra2, rb2) > k_before);
        };
    };
    tu::return_pool(pool);
}

/// Largest deposit of a coin with reserve `reserve` that is at most 3x the
/// reserve and keeps both that reserve and the LP supply under `SOFT_CAP`.
fun deposit_bound(reserve: u64, supply: u64): u64 {
    let by_supply = ((headroom(supply) as u128) * (reserve as u128) / (supply as u128)).min(
        (reserve.min(SOFT_CAP) as u128) * 3,
    );
    headroom(reserve).min(by_supply as u64)
}

/// `carol` deposits with `min_lp_out` = the exact expected mint. Random size:
/// up to 3x each reserve (the excess side is refunded). Forced size: exactly
/// the reserves, which mints exactly the current supply.
fun deposit(c: &mut Campaign, forced: bool) {
    c.scenario.next_tx(carol());
    let mut pool = tu::take_pool<LP_X>(&c.scenario);
    if (pool.is_active()) {
        let (ra, rb) = pool.reserves();
        let supply = pool.lp_supply();
        let max_a = deposit_bound(ra, supply);
        let max_b = deposit_bound(rb, supply);
        let (a, b) = if (forced) {
            (ra.min(max_a), rb.min(max_b))
        } else if (max_a == 0 || max_b == 0) {
            (0, 0)
        } else {
            (c.rng.between_1_and(max_a), c.rng.between_1_and(max_b))
        };
        let expected = if (a == 0 || b == 0) 0
        else {
            let from_a = (a as u128) * (supply as u128) / (ra as u128);
            let from_b = (b as u128) * (supply as u128) / (rb as u128);
            (from_a.min(from_b) as u64)
        };
        if (expected > 0) {
            let ca = tu::mint<ALPHA>(&mut c.scenario, a);
            let cb = tu::mint<BETA>(&mut c.scenario, b);
            let (lp, refund_a, refund_b) = pool.add_liquidity(ca, cb, expected, c.scenario.ctx());
            assert_eq!(lp.value(), expected);
            c.ghost.in_a = c.ghost.in_a + ((a - refund_a.value()) as u128);
            c.ghost.in_b = c.ghost.in_b + ((b - refund_b.value()) as u128);
            c.ghost.lp_minted = c.ghost.lp_minted + (expected as u128);
            c.carol_lp.join(lp);
            tu::burn(refund_a);
            tu::burn(refund_b);
            c.ghost.counts.deposits = c.ghost.counts.deposits + 1;
        };
    };
    tu::return_pool(pool);
}

/// `alice` or `carol` burns LP with `min_a` / `min_b` = the exact expected
/// outputs (allowed while paused). Random size: up to everything held. Forced
/// size: half of what is held. Skipped when an output rounds to zero.
fun withdraw(c: &mut Campaign, from_alice: bool, forced: bool) {
    let held = if (from_alice) c.alice_lp.value() else c.carol_lp.value();
    if (held == 0) return;
    c.scenario.next_tx(if (from_alice) alice() else carol());
    let mut pool = tu::take_pool<LP_X>(&c.scenario);
    let (ra, rb) = pool.reserves();
    let supply = pool.lp_supply();
    let burn = if (forced) (held / 2).max(1) else c.rng.between_1_and(held);
    let out_a = (((burn as u128) * (ra as u128) / (supply as u128)) as u64);
    let out_b = (((burn as u128) * (rb as u128) / (supply as u128)) as u64);
    if (out_a > 0 && out_b > 0) {
        let lp = if (from_alice) c.alice_lp.split(burn, c.scenario.ctx())
        else c.carol_lp.split(burn, c.scenario.ctx());
        let (ca, cb) = pool.remove_liquidity(lp, out_a, out_b, c.scenario.ctx());
        assert_eq!(ca.value(), out_a);
        assert_eq!(cb.value(), out_b);
        c.ghost.out_a = c.ghost.out_a + (tu::burn(ca) as u128);
        c.ghost.out_b = c.ghost.out_b + (tu::burn(cb) as u128);
        c.ghost.lp_burned = c.ghost.lp_burned + (burn as u128);
        c.ghost.counts.withdrawals = c.ghost.counts.withdrawals + 1;
    };
    tu::return_pool(pool);
}

/// `bob` borrows a random amount of coin A (`side_a`) or B, up to the whole
/// reserve, and repays principal + fee in the same transaction. Skipped while
/// paused, while flash loans are disabled, or without fee headroom.
fun flash_loan(c: &mut Campaign, side_a: bool) {
    c.scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_X>(&c.scenario);
    if (pool.is_active() && pool.flash_loans_enabled()) {
        let (ra, rb) = pool.reserves();
        let reserve = if (side_a) ra else rb;
        let amount = c.rng.between_1_and(reserve);
        let fee = pool.flash_fee(amount);
        if (reserve <= HARD_CAP - fee) {
            let k_before = tu::k(ra, rb);
            if (side_a) {
                let (mut loan, receipt) = pool.flash_borrow_a(amount, c.scenario.ctx());
                assert_eq!(receipt.receipt_fee(), fee);
                loan.join(tu::mint<ALPHA>(&mut c.scenario, fee));
                pool.flash_repay_a(receipt, loan);
                c.ghost.in_a = c.ghost.in_a + (fee as u128);
                c.ghost.counts.loans_a = c.ghost.counts.loans_a + 1;
            } else {
                let (mut loan, receipt) = pool.flash_borrow_b(amount, c.scenario.ctx());
                assert_eq!(receipt.receipt_fee(), fee);
                loan.join(tu::mint<BETA>(&mut c.scenario, fee));
                pool.flash_repay_b(receipt, loan);
                c.ghost.in_b = c.ghost.in_b + (fee as u128);
                c.ghost.counts.loans_b = c.ghost.counts.loans_b + 1;
            };
            let (ra2, rb2) = pool.reserves();
            // I6 for flash loans: the fee (>= 1 unit, rounded up) strictly grows k.
            assert!(tu::k(ra2, rb2) > k_before);
        };
    };
    tu::return_pool(pool);
}

/// The `AdminCap` sets both fees to random values in `[1, 100]` bps.
fun set_fees(c: &mut Campaign) {
    c.scenario.next_tx(tu::admin());
    let mut pool = tu::take_pool<LP_X>(&c.scenario);
    let cap = ts::take_from_address<AdminCap>(&c.scenario, tu::admin());
    let swap_fee = c.rng.between_1_and(100);
    let flash_fee = c.rng.between_1_and(100);
    pool.set_fees(&cap, swap_fee, flash_fee);
    assert_eq!(pool.swap_fee_bps(), swap_fee);
    assert_eq!(pool.flash_fee_bps(), flash_fee);
    c.ghost.counts.fee_changes = c.ghost.counts.fee_changes + 1;
    tu::return_admin_cap(cap);
    tu::return_pool(pool);
}

/// The `AdminCap` pauses an active pool (skipped when already paused).
fun pause(c: &mut Campaign) {
    c.scenario.next_tx(tu::admin());
    let mut pool = tu::take_pool<LP_X>(&c.scenario);
    let cap = ts::take_from_address<AdminCap>(&c.scenario, tu::admin());
    if (pool.is_active()) {
        pool.pause(&cap);
        c.ghost.counts.pauses = c.ghost.counts.pauses + 1;
    };
    tu::return_admin_cap(cap);
    tu::return_pool(pool);
}

/// The `AdminCap` unpauses a paused pool (skipped when active).
fun unpause(c: &mut Campaign) {
    c.scenario.next_tx(tu::admin());
    let mut pool = tu::take_pool<LP_X>(&c.scenario);
    let cap = ts::take_from_address<AdminCap>(&c.scenario, tu::admin());
    if (pool.is_paused()) {
        pool.unpause(&cap);
        c.ghost.counts.unpauses = c.ghost.counts.unpauses + 1;
    };
    tu::return_admin_cap(cap);
    tu::return_pool(pool);
}

/// `alice`'s `PoolCap` flips whether the pool lends.
fun toggle_flash_loans(c: &mut Campaign) {
    c.scenario.next_tx(alice());
    let mut pool = tu::take_pool<LP_X>(&c.scenario);
    let cap = ts::take_from_address<PoolCap>(&c.scenario, alice());
    let enabled = pool.flash_loans_enabled();
    pool.set_flash_loans_enabled(&cap, !enabled);
    assert!(pool.flash_loans_enabled() != enabled);
    c.ghost.counts.toggles = c.ghost.counts.toggles + 1;
    ts::return_to_address(alice(), cap);
    tu::return_pool(pool);
}

/// Runs every operation kind once on the fresh pool (active, lending) and
/// asserts that none of them was skipped.
fun prologue(c: &mut Campaign) {
    swap(c, true, true);
    check_invariants(c);
    swap(c, false, true);
    check_invariants(c);
    deposit(c, true);
    check_invariants(c);
    withdraw(c, false, true);
    check_invariants(c);
    flash_loan(c, true);
    check_invariants(c);
    flash_loan(c, false);
    check_invariants(c);
    set_fees(c);
    check_invariants(c);
    toggle_flash_loans(c);
    check_invariants(c);
    toggle_flash_loans(c);
    check_invariants(c);
    pause(c);
    check_invariants(c);
    unpause(c);
    check_invariants(c);
    assert_eq!(
        c.ghost.counts,
        Counts {
            swaps_a: 1,
            swaps_b: 1,
            deposits: 1,
            withdrawals: 1,
            loans_a: 1,
            loans_b: 1,
            fee_changes: 1,
            pauses: 1,
            unpauses: 1,
            toggles: 2,
        },
    );
}

/// Draws one weighted operation, runs it and checks the invariants.
fun random_op(c: &mut Campaign) {
    let slot = c.rng.next() % OP_SLOTS;
    if (slot < 4) swap(c, true, false)
    else if (slot < 8) swap(c, false, false)
    else if (slot < 11) deposit(c, false)
    else if (slot < 13) withdraw(c, true, false)
    else if (slot < 15) withdraw(c, false, false)
    else if (slot < 17) flash_loan(c, true)
    else if (slot < 19) flash_loan(c, false)
    else if (slot < 20) set_fees(c)
    else if (slot < 21) pause(c)
    else if (slot < 23) unpause(c)
    else toggle_flash_loans(c);
    check_invariants(c);
}

/// Every operation kind executed at least once after `before`.
fun assert_every_kind_ran_since(now: &Counts, before: &Counts) {
    assert!(now.swaps_a > before.swaps_a);
    assert!(now.swaps_b > before.swaps_b);
    assert!(now.deposits > before.deposits);
    assert!(now.withdrawals > before.withdrawals);
    assert!(now.loans_a > before.loans_a);
    assert!(now.loans_b > before.loans_b);
    assert!(now.fee_changes > before.fee_changes);
    assert!(now.pauses > before.pauses);
    assert!(now.unpauses > before.unpauses);
    assert!(now.toggles > before.toggles);
}

/// Prologue, then `OPS_PER_CAMPAIGN` random operations, each of which must
/// have occurred during the random phase too.
fun seeded_campaign(seed: u64) {
    let mut c = new_campaign(seed);
    c.prologue();
    let after_prologue = c.ghost.counts;
    OPS_PER_CAMPAIGN.do!(|_| c.random_op());
    assert_every_kind_ran_since(&c.ghost.counts, &after_prologue);
    c.finish();
}

#[test]
fun campaign_seed_1() { seeded_campaign(1) }

#[test]
fun campaign_seed_2() { seeded_campaign(2) }

#[test]
fun campaign_seed_3() { seeded_campaign(3) }

#[test]
fun campaign_seed_4() { seeded_campaign(4) }

#[test]
fun campaign_seed_5() { seeded_campaign(5) }

#[test]
fun campaign_seed_6() { seeded_campaign(6) }

#[test]
fun campaign_seed_7() { seeded_campaign(7) }

#[test]
fun campaign_seed_8() { seeded_campaign(8) }

/// Fresh inputs on every `sui move test` run without `--seed`. The push / PR gate
/// pins the seed; the scheduled CI job runs 1,000 fresh campaigns with
/// `--rand-num-iters`. The prologue makes the campaign non-vacuous whatever the seed.
#[random_test]
fun fuzz_campaign(seed: u64) {
    let mut c = new_campaign(seed);
    c.prologue();
    OPS_PER_FUZZ_CAMPAIGN.do!(|_| c.random_op());
    c.finish();
}

// === the slippage bounds are tight, at any state a campaign reaches ===

/// A campaign of `ops` random operations from `seed`, left active.
fun campaign_left_active(seed: u64, ops: u64): Campaign {
    let mut c = new_campaign(seed);
    c.prologue();
    ops.do!(|_| c.random_op());
    unpause(&mut c);
    c.scenario.next_tx(bob());
    c
}

#[test, expected_failure(abort_code = pool::ESlippage)]
fun a_swap_asking_one_unit_above_its_quote_aborts() {
    let mut c = campaign_left_active(9, 80);
    let mut pool = tu::take_pool<LP_X>(&c.scenario);
    let (ra, _) = pool.reserves();
    let quote = pool.quote_a_for_b(ra);
    assert!(quote > 0);
    let coin_in = tu::mint<ALPHA>(&mut c.scenario, ra);
    let _out = pool.swap_a_for_b(coin_in, quote + 1, c.scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::ESlippage)]
fun a_deposit_asking_one_lp_unit_above_its_mint_aborts() {
    let mut c = campaign_left_active(10, 80);
    let mut pool = tu::take_pool<LP_X>(&c.scenario);
    let (ra, rb) = pool.reserves();
    // Depositing exactly the reserves mints exactly the current supply.
    let supply = pool.lp_supply();
    let ca = tu::mint<ALPHA>(&mut c.scenario, ra);
    let cb = tu::mint<BETA>(&mut c.scenario, rb);
    let (_lp, _ra, _rb) = pool.add_liquidity(ca, cb, supply + 1, c.scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::ESlippage)]
fun a_withdrawal_asking_one_unit_above_its_share_aborts() {
    let mut c = campaign_left_active(11, 80);
    let mut pool = tu::take_pool<LP_X>(&c.scenario);
    let (ra, rb) = pool.reserves();
    let supply = pool.lp_supply();
    let (alice_held, carol_held) = (c.alice_lp.value(), c.carol_lp.value());
    let held = alice_held + carol_held;
    let mut lp = c.alice_lp.split(alice_held, c.scenario.ctx());
    lp.join(c.carol_lp.split(carol_held, c.scenario.ctx()));
    let out_a = (((held as u128) * (ra as u128) / (supply as u128)) as u64);
    let out_b = (((held as u128) * (rb as u128) / (supply as u128)) as u64);
    assert!(out_a > 0 && out_b > 0);
    let (_a, _b) = pool.remove_liquidity(lp, out_a, out_b + 1, c.scenario.ctx());
    abort
}
