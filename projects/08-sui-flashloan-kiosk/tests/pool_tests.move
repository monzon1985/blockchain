// SPDX-License-Identifier: MIT

#[test_only]
/// Pool creation, swaps and liquidity: happy paths, exact rounding and every
/// abort path of those entry points.
module flash_kiosk::pool_tests;

use flash_kiosk::pool::{Self, Pool, AdminCap, PoolCap, LpCoin};
use flash_kiosk::test_utils::{Self as tu, ALPHA, BETA, LP_X, LP_Y, alice, bob};
use std::unit_test::{assert_eq, destroy};
use sui::coin::{Self, Coin};
use sui::coin_registry::{Self, CoinRegistry, Currency};
use sui::test_scenario as ts;

const RESERVE: u64 = 1_000_000;

// === init & creation ===

#[test]
fun init_mints_a_single_admin_cap_to_the_publisher() {
    let mut scenario = tu::begin();
    assert_eq!(ts::ids_for_address<AdminCap>(tu::admin()).length(), 1);
    scenario.next_tx(alice());
    assert!(!ts::has_most_recent_for_address<AdminCap>(alice()));
    scenario.end();
}

#[test]
fun create_pool_mints_sqrt_k_and_locks_minimum_liquidity() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, 2_000_000, 500_000);

    let pool = tu::take_pool<LP_X>(&scenario);
    // sqrt(2_000_000 * 500_000) = 1_000_000
    assert_eq!(pool.lp_supply(), 1_000_000);
    assert_eq!(pool.locked_liquidity(), pool::minimum_liquidity());
    let (ra, rb) = pool.reserves();
    assert_eq!(ra, 2_000_000);
    assert_eq!(rb, 500_000);
    assert_eq!(pool.swap_fee_bps(), 30);
    assert_eq!(pool.flash_fee_bps(), 30);
    assert_eq!(pool.version(), pool::package_version());
    assert!(pool.is_active());
    assert!(!pool.is_paused());
    assert!(!pool.is_flash_loan_open());
    assert!(pool.flash_loans_enabled());

    let lp = ts::take_from_address<Coin<LpCoin<LP_X>>>(&scenario, alice());
    assert_eq!(lp.value(), 1_000_000 - pool::minimum_liquidity());
    let cap = tu::take_pool_cap(&scenario);
    assert_eq!(cap.pool_cap_pool_id(), object::id(&pool));

    ts::return_to_address(alice(), lp);
    tu::return_pool_cap(cap);
    tu::return_pool(pool);
    scenario.end();
}

#[test]
fun create_pool_emits_one_event_and_shares_the_pool_and_its_lp_currency() {
    let mut scenario = tu::begin();
    let (lp, cap) = tu::new_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    destroy(lp);
    destroy(cap);
    let effects = scenario.next_tx(alice());
    assert_eq!(effects.num_user_events(), 1);
    // Both the pool and `Currency<LpCoin<LP_X>>` were shared by this transaction.
    let shared = effects.shared();
    let pool_id = ts::most_recent_id_shared<Pool<ALPHA, BETA, LP_X>>().destroy_some();
    let currency_id = ts::most_recent_id_shared<Currency<LpCoin<LP_X>>>().destroy_some();
    assert!(shared.contains(&pool_id));
    assert!(shared.contains(&currency_id));
    scenario.end();
}

/// The LP coin is registered by the pool itself: unregulated (so no deny list
/// can ever freeze an LP's shares), with its metadata frozen (the
/// `MetadataCap` was deleted) and its only `TreasuryCap` inside the pool.
#[test]
fun create_pool_registers_an_unregulated_lp_currency_with_frozen_metadata() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    let currency = ts::take_shared<Currency<LpCoin<LP_X>>>(&scenario);
    assert!(!currency.is_regulated());
    assert!(currency.deny_cap_id().is_none());
    assert!(currency.is_metadata_cap_deleted());
    assert!(currency.treasury_cap_id().is_some());
    assert_eq!(currency.decimals(), 9);
    assert_eq!(currency.symbol(), b"FKLP".to_string());
    // Supply is pool-controlled (minted and burned through its TreasuryCap).
    assert!(currency.total_supply().is_none());
    ts::return_shared(currency);
    scenario.end();
}

/// One-time witness of this module, for the legacy currency below.
public struct POOL_TESTS has drop {}

/// Why the pool registers its LP coin itself instead of vetting one the creator
/// brings: a *legacy* regulated coin migrated into the registry reports
/// `is_regulated() == false` (its state is `Unknown`), although its issuer holds
/// a working `DenyCapV2`. A check on a creator-supplied currency could not tell.
#[test]
#[allow(deprecated_usage)]
fun is_regulated_cannot_vouch_for_a_creator_supplied_currency() {
    let mut scenario = tu::begin();
    let otw = sui::test_utils::create_one_time_witness<POOL_TESTS>();
    let (treasury, deny_cap, metadata) = coin::create_regulated_currency_v2(
        otw,
        9,
        b"RLP",
        b"Regulated LP",
        b"",
        option::none(),
        true,
        scenario.ctx(),
    );
    let mut registry = ts::take_shared<CoinRegistry>(&scenario);
    let currency = coin_registry::migrate_legacy_metadata_for_testing(
        &mut registry,
        &metadata,
        scenario.ctx(),
    );
    assert!(!currency.is_regulated());
    assert!(currency.deny_cap_id().is_none());
    destroy(currency);
    destroy(deny_cap);
    destroy(metadata);
    destroy(treasury);
    ts::return_shared(registry);
    scenario.end();
}

/// The registry refuses a second `Currency<LpCoin<LP_X>>`, so one marker type
/// can never back two pools (their LP coins would be interchangeable).
#[test, expected_failure(abort_code = sui::coin_registry::ECurrencyAlreadyExists)]
fun a_marker_type_backs_exactly_one_pool() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    abort
}

#[test, expected_failure(abort_code = pool::EIdenticalTypes)]
fun create_pool_rejects_identical_coin_types() {
    let mut scenario = tu::begin();
    let mut registry = ts::take_shared<CoinRegistry>(&scenario);
    let a1 = tu::mint<ALPHA>(&mut scenario, RESERVE);
    let a2 = tu::mint<ALPHA>(&mut scenario, RESERVE);
    let (_lp, _cap) = pool::create_pool<ALPHA, ALPHA, LP_X>(&mut registry, a1, a2, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EZeroAmount)]
fun create_pool_rejects_empty_side() {
    let mut scenario = tu::begin();
    let mut registry = ts::take_shared<CoinRegistry>(&scenario);
    let a = tu::mint<ALPHA>(&mut scenario, RESERVE);
    let b = coin::zero<BETA>(scenario.ctx());
    let (_lp, _cap) = pool::create_pool<ALPHA, BETA, LP_X>(&mut registry, a, b, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EZeroAmount)]
fun create_pool_rejects_empty_a_side() {
    let mut scenario = tu::begin();
    let mut registry = ts::take_shared<CoinRegistry>(&scenario);
    let a = coin::zero<ALPHA>(scenario.ctx());
    let b = tu::mint<BETA>(&mut scenario, RESERVE);
    let (_lp, _cap) = pool::create_pool<ALPHA, BETA, LP_X>(&mut registry, a, b, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EInsufficientInitialLiquidity)]
fun create_pool_rejects_dust_liquidity() {
    let mut scenario = tu::begin();
    // sqrt(1_000 * 1_000) = 1_000 == MINIMUM_LIQUIDITY, not strictly above it.
    let (_lp, _cap) = tu::new_pool<LP_X>(&mut scenario, 1_000, 1_000);
    abort
}

// === swaps ===

#[test]
fun swap_a_for_b_matches_the_constant_product_formula() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_X>(&scenario);

    let quote = pool.quote_a_for_b(10_000);
    let coin_in = tu::mint<ALPHA>(&mut scenario, 10_000);
    let out = pool.swap_a_for_b(coin_in, 0, scenario.ctx());
    // fee = ceil(10_000 * 30 / 10_000) = 30; out = floor(9_970 * 1e6 / 1_009_970) = 9_871
    assert_eq!(out.value(), 9_871);
    assert_eq!(quote, 9_871);
    let (ra, rb) = pool.reserves();
    assert_eq!(ra, RESERVE + 10_000);
    assert_eq!(rb, RESERVE - 9_871);
    assert!(tu::k(ra, rb) > tu::k(RESERVE, RESERVE));

    tu::burn(out);
    tu::return_pool(pool);
    scenario.end();
}

#[test]
fun swap_b_for_a_matches_the_constant_product_formula() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_X>(&scenario);

    assert_eq!(pool.quote_b_for_a(50_000), 47_482);
    let coin_in = tu::mint<BETA>(&mut scenario, 50_000);
    let out = pool.swap_b_for_a(coin_in, 47_482, scenario.ctx());
    // fee = 150; out = floor(49_850 * 1e6 / 1_049_850) = 47_482
    assert_eq!(out.value(), 47_482);
    let (ra, rb) = pool.reserves();
    assert_eq!(ra, RESERVE - 47_482);
    assert_eq!(rb, RESERVE + 50_000);

    tu::burn(out);
    tu::return_pool(pool);
    scenario.end();
}

#[test]
fun fees_accrue_to_lps_on_a_round_trip() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_X>(&scenario);
    let k_before = tu::k(RESERVE, RESERVE);

    let a_in = tu::mint<ALPHA>(&mut scenario, 100_000);
    let b_out = pool.swap_a_for_b(a_in, 0, scenario.ctx());
    let a_back = pool.swap_b_for_a(b_out, 0, scenario.ctx());
    // The trader loses to fees and rounding; the LPs' k strictly grows.
    assert!(a_back.value() < 100_000);
    let (ra, rb) = pool.reserves();
    assert!(tu::k(ra, rb) > k_before);
    assert!(rb >= RESERVE);

    tu::burn(a_back);
    tu::return_pool(pool);
    scenario.end();
}

#[test, expected_failure(abort_code = pool::ESlippage)]
fun swap_rejects_output_below_min_out() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_X>(&scenario);
    let coin_in = tu::mint<ALPHA>(&mut scenario, 10_000);
    let _out = pool.swap_a_for_b(coin_in, 9_872, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EZeroAmount)]
fun swap_rejects_zero_input() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_X>(&scenario);
    let coin_in = coin::zero<BETA>(scenario.ctx());
    let _out = pool.swap_b_for_a(coin_in, 0, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EZeroOutput)]
fun swap_rejects_input_that_is_all_fee() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_X>(&scenario);
    // 1 unit in: fee rounds up to 1, nothing is left to trade.
    let coin_in = tu::mint<ALPHA>(&mut scenario, 1);
    let _out = pool.swap_a_for_b(coin_in, 0, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EZeroOutput)]
fun swap_rejects_output_that_rounds_to_zero() {
    let mut scenario = tu::begin();
    // Deep A side, shallow B side: 2 units of A are worth less than 1 unit of B.
    tu::create_pool<LP_X>(&mut scenario, 1_000_000_000, 2_000);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_X>(&scenario);
    let coin_in = tu::mint<ALPHA>(&mut scenario, 2);
    let _out = pool.swap_a_for_b(coin_in, 0, scenario.ctx());
    abort
}

// === liquidity ===

#[test]
fun add_liquidity_mints_pro_rata_and_refunds_the_excess() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_X>(&scenario);
    // Move the price first so the pool is no longer 1:1.
    let a_in = tu::mint<ALPHA>(&mut scenario, 10_000);
    tu::burn(pool.swap_a_for_b(a_in, 0, scenario.ctx()));
    // reserves: (1_010_000, 990_129), supply 1_000_000

    let a = tu::mint<ALPHA>(&mut scenario, 101_000);
    let b = tu::mint<BETA>(&mut scenario, 200_000);
    let (lp, refund_a, refund_b) = pool.add_liquidity(a, b, 100_000, scenario.ctx());
    // lp = min(101_000 * 1e6 / 1_010_000, 200_000 * 1e6 / 990_129) = min(100_000, 201_993)
    assert_eq!(lp.value(), 100_000);
    // used = ceil(100_000 * R / 1e6) = (101_000, 99_013)
    assert_eq!(refund_a.value(), 0);
    assert_eq!(refund_b.value(), 200_000 - 99_013);
    let (ra, rb) = pool.reserves();
    assert_eq!(ra, 1_010_000 + 101_000);
    assert_eq!(rb, 990_129 + 99_013);
    assert_eq!(pool.lp_supply(), 1_100_000);

    tu::burn(lp);
    tu::burn(refund_a);
    tu::burn(refund_b);
    tu::return_pool(pool);
    scenario.end();
}

#[test, expected_failure(abort_code = pool::EZeroOutput)]
fun add_liquidity_rejects_dust() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, 1_000_000_000, 1_000_000_000);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_X>(&scenario);
    // 1 * 1e9 / 1e9 = 1 LP from A, but 0 from B.
    let a = tu::mint<ALPHA>(&mut scenario, 1);
    let b = coin::zero<BETA>(scenario.ctx());
    let (_lp, _ra, _rb) = pool.add_liquidity(a, b, 0, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::ESlippage)]
fun add_liquidity_rejects_mint_below_min_lp_out() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_X>(&scenario);
    let a = tu::mint<ALPHA>(&mut scenario, 10_000);
    let b = tu::mint<BETA>(&mut scenario, 10_000);
    let (_lp, _ra, _rb) = pool.add_liquidity(a, b, 10_001, scenario.ctx());
    abort
}

#[test]
fun remove_liquidity_returns_pro_rata_rounded_down() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, 3_000_000, 1_200_000);
    let mut pool = tu::take_pool<LP_X>(&scenario);
    let supply = pool.lp_supply();
    let mut lp = ts::take_from_address<Coin<LpCoin<LP_X>>>(&scenario, alice());
    let burn = lp.split(333_333, scenario.ctx());

    let (a, b) = pool.remove_liquidity(burn, 0, 0, scenario.ctx());
    assert_eq!(a.value(), ((333_333u128 * 3_000_000 / (supply as u128)) as u64));
    assert_eq!(b.value(), ((333_333u128 * 1_200_000 / (supply as u128)) as u64));
    assert_eq!(pool.lp_supply(), supply - 333_333);

    tu::burn(a);
    tu::burn(b);
    ts::return_to_address(alice(), lp);
    tu::return_pool(pool);
    scenario.end();
}

#[test]
fun full_withdrawal_leaves_the_locked_minimum_behind() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    let mut pool = tu::take_pool<LP_X>(&scenario);
    let lp = ts::take_from_address<Coin<LpCoin<LP_X>>>(&scenario, alice());
    let (a, b) = pool.remove_liquidity(lp, 0, 0, scenario.ctx());
    assert_eq!(a.value(), RESERVE - 1_000);
    assert_eq!(b.value(), RESERVE - 1_000);
    let (ra, rb) = pool.reserves();
    assert_eq!(ra, 1_000);
    assert_eq!(rb, 1_000);
    assert_eq!(pool.lp_supply(), pool::minimum_liquidity());

    tu::burn(a);
    tu::burn(b);
    tu::return_pool(pool);
    scenario.end();
}

#[test, expected_failure(abort_code = pool::EZeroAmount)]
fun remove_liquidity_rejects_zero_lp() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    let mut pool = tu::take_pool<LP_X>(&scenario);
    let lp = coin::zero<LpCoin<LP_X>>(scenario.ctx());
    let (_a, _b) = pool.remove_liquidity(lp, 0, 0, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EZeroOutput)]
fun remove_liquidity_rejects_dust() {
    let mut scenario = tu::begin();
    // 1 LP out of 1e6 against a 1e5-unit reserve rounds down to 0.
    tu::create_pool<LP_X>(&mut scenario, 10_000_000, 100_000);
    let mut pool = tu::take_pool<LP_X>(&scenario);
    let mut lp = ts::take_from_address<Coin<LpCoin<LP_X>>>(&scenario, alice());
    let dust = lp.split(1, scenario.ctx());
    let (_a, _b) = pool.remove_liquidity(dust, 0, 0, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EZeroOutput)]
fun remove_liquidity_rejects_dust_on_the_a_side() {
    let mut scenario = tu::begin();
    // Mirror image of the previous test: the A reserve is the shallow one.
    tu::create_pool<LP_X>(&mut scenario, 100_000, 10_000_000);
    let mut pool = tu::take_pool<LP_X>(&scenario);
    let mut lp = ts::take_from_address<Coin<LpCoin<LP_X>>>(&scenario, alice());
    let dust = lp.split(1, scenario.ctx());
    let (_a, _b) = pool.remove_liquidity(dust, 0, 0, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::ESlippage)]
fun remove_liquidity_rejects_a_below_minimum() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    let mut pool = tu::take_pool<LP_X>(&scenario);
    let mut lp = ts::take_from_address<Coin<LpCoin<LP_X>>>(&scenario, alice());
    let part = lp.split(1_000, scenario.ctx());
    let (_a, _b) = pool.remove_liquidity(part, 1_001, 0, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::ESlippage)]
fun remove_liquidity_rejects_b_below_minimum() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    let mut pool = tu::take_pool<LP_X>(&scenario);
    let mut lp = ts::take_from_address<Coin<LpCoin<LP_X>>>(&scenario, alice());
    let part = lp.split(1_000, scenario.ctx());
    let (_a, _b) = pool.remove_liquidity(part, 1_000, 1_001, scenario.ctx());
    abort
}

// === capabilities in the inventory ===

#[test]
fun each_pool_gets_its_own_pool_cap() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    tu::create_pool<LP_Y>(&mut scenario, RESERVE, RESERVE);
    assert_eq!(ts::ids_for_address<PoolCap>(alice()).length(), 2);
    let px = tu::take_pool<LP_X>(&scenario);
    let py = tu::take_pool<LP_Y>(&scenario);
    assert!(object::id(&px) != object::id(&py));
    tu::return_pool(px);
    tu::return_pool(py);
    scenario.end();
}
