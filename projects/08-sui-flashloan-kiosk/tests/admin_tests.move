// SPDX-License-Identifier: MIT

#[test_only]
/// Capabilities (AdminCap, PoolCap), the pause state machine and the
/// versioned-shared-object upgrade path.
module flash_kiosk::admin_tests;

use flash_kiosk::pool::{Self, Pool, PoolCap, LpCoin};
use flash_kiosk::test_utils::{Self as tu, ALPHA, BETA, LP_X, LP_Y, alice};
use std::unit_test::assert_eq;
use sui::coin::Coin;
use sui::test_scenario::{Self as ts, Scenario};

const RESERVE: u64 = 1_000_000;

fun setup(): (Scenario, Pool<ALPHA, BETA, LP_X>) {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(tu::admin());
    let pool = tu::take_pool<LP_X>(&scenario);
    (scenario, pool)
}

// === pause / unpause ===

#[test]
fun pause_then_unpause_round_trip() {
    let (mut scenario, mut pool) = setup();
    let cap = tu::take_admin_cap(&scenario);
    pool.pause(&cap);
    assert!(pool.is_paused());
    assert!(!pool.is_active());
    pool.unpause(&cap);
    assert!(pool.is_active());
    tu::return_admin_cap(cap);
    tu::return_pool(pool);
    let effects = scenario.next_tx(alice());
    assert_eq!(effects.num_user_events(), 2);
    scenario.end();
}

#[test, expected_failure(abort_code = pool::EPoolPaused)]
fun pausing_twice_aborts() {
    let (scenario, mut pool) = setup();
    let cap = tu::take_admin_cap(&scenario);
    pool.pause(&cap);
    pool.pause(&cap);
    abort
}

#[test, expected_failure(abort_code = pool::ENotPaused)]
fun unpausing_an_active_pool_aborts() {
    let (scenario, mut pool) = setup();
    let cap = tu::take_admin_cap(&scenario);
    pool.unpause(&cap);
    abort
}

#[test, expected_failure(abort_code = pool::EPoolPaused)]
fun swaps_abort_while_paused() {
    let (mut scenario, mut pool) = setup();
    let cap = tu::take_admin_cap(&scenario);
    pool.pause(&cap);
    let a = tu::mint<ALPHA>(&mut scenario, 1_000);
    let _b = pool.swap_a_for_b(a, 0, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EPoolPaused)]
fun reverse_swaps_abort_while_paused() {
    let (mut scenario, mut pool) = setup();
    let cap = tu::take_admin_cap(&scenario);
    pool.pause(&cap);
    let b = tu::mint<BETA>(&mut scenario, 1_000);
    let _a = pool.swap_b_for_a(b, 0, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EPoolPaused)]
fun deposits_abort_while_paused() {
    let (mut scenario, mut pool) = setup();
    let cap = tu::take_admin_cap(&scenario);
    pool.pause(&cap);
    let a = tu::mint<ALPHA>(&mut scenario, 1_000);
    let b = tu::mint<BETA>(&mut scenario, 1_000);
    let (_lp, _ra, _rb) = pool.add_liquidity(a, b, 0, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EPoolPaused)]
fun flash_loans_abort_while_paused() {
    let (mut scenario, mut pool) = setup();
    let cap = tu::take_admin_cap(&scenario);
    pool.pause(&cap);
    let (_loan, _receipt) = pool.flash_borrow_b(1_000, scenario.ctx());
    abort
}

#[test]
fun lps_can_always_exit_a_paused_pool() {
    let (mut scenario, mut pool) = setup();
    let cap = tu::take_admin_cap(&scenario);
    pool.pause(&cap);
    let lp = ts::take_from_address<Coin<LpCoin<LP_X>>>(&scenario, alice());
    let (a, b) = pool.remove_liquidity(lp, 0, 0, scenario.ctx());
    assert_eq!(tu::burn(a), RESERVE - pool::minimum_liquidity());
    assert_eq!(tu::burn(b), RESERVE - pool::minimum_liquidity());
    tu::return_admin_cap(cap);
    tu::return_pool(pool);
    scenario.end();
}

// === fees ===

#[test]
fun admin_can_set_fees_within_bounds() {
    let (scenario, mut pool) = setup();
    let cap = tu::take_admin_cap(&scenario);
    pool.set_fees(&cap, 1, 100);
    assert_eq!(pool.swap_fee_bps(), 1);
    assert_eq!(pool.flash_fee_bps(), 100);
    // 1 bp on 10_000 in: fee 1, out = floor(9_999 * 1e6 / 1_009_999) = 9_900
    assert_eq!(pool.quote_a_for_b(10_000), 9_900);
    assert_eq!(pool.flash_fee(10_000), 100);
    tu::return_admin_cap(cap);
    tu::return_pool(pool);
    scenario.end();
}

#[test, expected_failure(abort_code = pool::EFeeOutOfRange)]
fun zero_swap_fee_is_rejected() {
    let (scenario, mut pool) = setup();
    let cap = tu::take_admin_cap(&scenario);
    pool.set_fees(&cap, 0, 30);
    abort
}

#[test, expected_failure(abort_code = pool::EFeeOutOfRange)]
fun swap_fee_above_one_percent_is_rejected() {
    let (scenario, mut pool) = setup();
    let cap = tu::take_admin_cap(&scenario);
    pool.set_fees(&cap, 101, 30);
    abort
}

#[test, expected_failure(abort_code = pool::EFeeOutOfRange)]
fun zero_flash_fee_is_rejected() {
    let (scenario, mut pool) = setup();
    let cap = tu::take_admin_cap(&scenario);
    pool.set_fees(&cap, 30, 0);
    abort
}

#[test, expected_failure(abort_code = pool::EFeeOutOfRange)]
fun flash_fee_above_one_percent_is_rejected() {
    let (scenario, mut pool) = setup();
    let cap = tu::take_admin_cap(&scenario);
    pool.set_fees(&cap, 30, 101);
    abort
}

// === PoolCap ===

#[test]
fun pool_cap_toggles_flash_loans_on_its_own_pool() {
    let (mut scenario, mut pool) = setup();
    scenario.next_tx(alice());
    let cap = tu::take_pool_cap(&scenario);
    pool.set_flash_loans_enabled(&cap, false);
    assert!(!pool.flash_loans_enabled());
    pool.set_flash_loans_enabled(&cap, true);
    assert!(pool.flash_loans_enabled());
    tu::return_pool_cap(cap);
    tu::return_pool(pool);
    scenario.end();
}

#[test, expected_failure(abort_code = pool::EWrongPoolCap)]
fun a_pool_cap_cannot_configure_another_pool() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    let cap_x_id = ts::most_recent_id_for_address<PoolCap>(alice()).destroy_some();
    tu::create_pool<LP_Y>(&mut scenario, RESERVE, RESERVE);
    let cap_x = ts::take_from_address_by_id<PoolCap>(&scenario, alice(), cap_x_id);
    let mut pool_y = tu::take_pool<LP_Y>(&scenario);
    pool_y.set_flash_loans_enabled(&cap_x, false);
    abort
}

// === versioned shared objects ===

/// Simulates the state after a package upgrade: the pool still carries the old
/// version, so every entry point of the new package refuses it until `migrate`.
fun setup_stale(): (Scenario, Pool<ALPHA, BETA, LP_X>) {
    let (scenario, mut pool) = setup();
    pool.set_version_for_testing(0);
    (scenario, pool)
}

#[test]
fun migrate_moves_a_stale_pool_to_the_current_version() {
    let (mut scenario, mut pool) = setup_stale();
    let cap = tu::take_admin_cap(&scenario);
    assert_eq!(pool.version(), 0);
    pool.migrate(&cap);
    assert_eq!(pool.version(), pool::package_version());
    // Entry points work again.
    let a = tu::mint<ALPHA>(&mut scenario, 10_000);
    tu::burn(pool.swap_a_for_b(a, 0, scenario.ctx()));
    tu::return_admin_cap(cap);
    tu::return_pool(pool);
    scenario.end();
}

#[test, expected_failure(abort_code = pool::ENotUpgrade)]
fun migrating_a_current_pool_aborts() {
    let (scenario, mut pool) = setup();
    let cap = tu::take_admin_cap(&scenario);
    pool.migrate(&cap);
    abort
}

#[test, expected_failure(abort_code = pool::EWrongVersion)]
fun stale_pool_rejects_swap_a_for_b() {
    let (mut scenario, mut pool) = setup_stale();
    let a = tu::mint<ALPHA>(&mut scenario, 1_000);
    let _b = pool.swap_a_for_b(a, 0, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EWrongVersion)]
fun stale_pool_rejects_swap_b_for_a() {
    let (mut scenario, mut pool) = setup_stale();
    let b = tu::mint<BETA>(&mut scenario, 1_000);
    let _a = pool.swap_b_for_a(b, 0, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EWrongVersion)]
fun stale_pool_rejects_add_liquidity() {
    let (mut scenario, mut pool) = setup_stale();
    let a = tu::mint<ALPHA>(&mut scenario, 1_000);
    let b = tu::mint<BETA>(&mut scenario, 1_000);
    let (_lp, _ra, _rb) = pool.add_liquidity(a, b, 0, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EWrongVersion)]
fun stale_pool_rejects_remove_liquidity() {
    let (mut scenario, mut pool) = setup_stale();
    let lp = ts::take_from_address<Coin<LpCoin<LP_X>>>(&scenario, alice());
    let (_a, _b) = pool.remove_liquidity(lp, 0, 0, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EWrongVersion)]
fun stale_pool_rejects_flash_borrow_a() {
    let (mut scenario, mut pool) = setup_stale();
    let (_loan, _receipt) = pool.flash_borrow_a(1_000, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EWrongVersion)]
fun stale_pool_rejects_flash_borrow_b() {
    let (mut scenario, mut pool) = setup_stale();
    let (_loan, _receipt) = pool.flash_borrow_b(1_000, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EWrongVersion)]
fun stale_pool_rejects_flash_repay_a() {
    let (mut scenario, mut pool) = setup();
    let (mut loan, receipt) = pool.flash_borrow_a(1_000, scenario.ctx());
    loan.join(tu::mint<ALPHA>(&mut scenario, 3));
    // An upgrade cannot land mid-PTB; this only exercises the repay-side check.
    pool.set_version_for_testing(0);
    pool.flash_repay_a(receipt, loan);
    abort
}

#[test, expected_failure(abort_code = pool::EWrongVersion)]
fun stale_pool_rejects_flash_repay_b() {
    let (mut scenario, mut pool) = setup();
    let (mut loan, receipt) = pool.flash_borrow_b(1_000, scenario.ctx());
    loan.join(tu::mint<BETA>(&mut scenario, 3));
    pool.set_version_for_testing(0);
    pool.flash_repay_b(receipt, loan);
    abort
}

#[test, expected_failure(abort_code = pool::EWrongVersion)]
fun stale_pool_rejects_pause() {
    let (scenario, mut pool) = setup_stale();
    let cap = tu::take_admin_cap(&scenario);
    pool.pause(&cap);
    abort
}

#[test, expected_failure(abort_code = pool::EWrongVersion)]
fun stale_pool_rejects_unpause() {
    let (scenario, mut pool) = setup();
    let cap = tu::take_admin_cap(&scenario);
    pool.pause(&cap);
    pool.set_version_for_testing(0);
    pool.unpause(&cap);
    abort
}

#[test, expected_failure(abort_code = pool::EWrongVersion)]
fun stale_pool_rejects_set_fees() {
    let (scenario, mut pool) = setup_stale();
    let cap = tu::take_admin_cap(&scenario);
    pool.set_fees(&cap, 30, 30);
    abort
}

#[test, expected_failure(abort_code = pool::EWrongVersion)]
fun stale_pool_rejects_set_flash_loans_enabled() {
    let (scenario, mut pool) = setup_stale();
    let cap = ts::take_from_address<PoolCap>(&scenario, alice());
    pool.set_flash_loans_enabled(&cap, false);
    abort
}

#[test]
fun views_stay_readable_on_a_stale_pool() {
    // Reads never mutate, so they are not version-gated: indexers and the
    // migration tooling can inspect a stale pool before migrating it.
    let (scenario, pool) = setup_stale();
    let (ra, rb) = pool.reserves();
    assert_eq!(ra, RESERVE);
    assert_eq!(rb, RESERVE);
    assert!(pool.quote_b_for_a(1_000) > 0);
    tu::return_pool(pool);
    scenario.end();
}
