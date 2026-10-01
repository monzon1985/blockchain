// SPDX-License-Identifier: MIT

#[test_only]
/// Shared fixtures for the Move test suites: coin types, actors and helpers that
/// build pools inside a `test_scenario`.
module flash_kiosk::test_utils;

use flash_kiosk::pool::{Self, Pool, AdminCap, PoolCap, LpCoin};
use sui::coin::{Self, Coin};
use sui::coin_registry::{Self, CoinRegistry};
use sui::test_scenario::{Self as ts, Scenario};

/// Test coin "A".
public struct ALPHA has drop {}
/// Test coin "B".
public struct BETA has drop {}
/// LP marker of the lender pool (its LP coin is `LpCoin<LP_L>`).
public struct LP_L has drop {}
/// LP marker of arbitrage pool X.
public struct LP_X has drop {}
/// LP marker of arbitrage pool Y.
public struct LP_Y has drop {}

public fun admin(): address { @0xAD }

public fun alice(): address { @0xA11CE }

public fun bob(): address { @0xB0B }

public fun carol(): address { @0xCA401 }

/// Starts a scenario with a shared `CoinRegistry` (created by the system
/// address, as on chain) and the pool module initialised by `admin()`, so the
/// `AdminCap` sits in the admin's inventory.
public fun begin(): Scenario {
    let mut scenario = ts::begin(@0x0);
    coin_registry::create_coin_data_registry_for_testing(scenario.ctx()).share_for_testing();
    scenario.next_tx(admin());
    pool::init_for_testing(scenario.ctx());
    scenario.next_tx(admin());
    scenario
}

/// Mints a test coin of type `T` inside the current transaction.
public fun mint<T>(scenario: &mut Scenario, value: u64): Coin<T> {
    coin::mint_for_testing<T>(value, scenario.ctx())
}

/// Calls `pool::create_pool<ALPHA, BETA, LP>` in the current transaction with
/// the shared `CoinRegistry`, and returns the creator's LP coin and `PoolCap`.
public fun new_pool<LP>(
    scenario: &mut Scenario,
    amount_a: u64,
    amount_b: u64,
): (Coin<LpCoin<LP>>, PoolCap) {
    let mut registry = ts::take_shared<CoinRegistry>(scenario);
    let coin_a = mint<ALPHA>(scenario, amount_a);
    let coin_b = mint<BETA>(scenario, amount_b);
    let (lp, cap) = pool::create_pool<ALPHA, BETA, LP>(
        &mut registry,
        coin_a,
        coin_b,
        scenario.ctx(),
    );
    ts::return_shared(registry);
    (lp, cap)
}

/// `alice()` creates `Pool<ALPHA, BETA, LP>` with the given reserves. Her LP coin
/// and `PoolCap` go to her inventory; the pool is shared. Ends in a fresh
/// transaction sent by `alice()`.
public fun create_pool<LP>(scenario: &mut Scenario, amount_a: u64, amount_b: u64) {
    scenario.next_tx(alice());
    let (lp, cap) = new_pool<LP>(scenario, amount_a, amount_b);
    transfer::public_transfer(lp, alice());
    transfer::public_transfer(cap, alice());
    scenario.next_tx(alice());
}

/// Takes the shared pool whose LP type is `LP`.
public fun take_pool<LP>(scenario: &Scenario): Pool<ALPHA, BETA, LP> {
    ts::take_shared<Pool<ALPHA, BETA, LP>>(scenario)
}

/// Returns a pool to the shared inventory.
public fun return_pool<LP>(pool: Pool<ALPHA, BETA, LP>) {
    ts::return_shared(pool)
}

/// Takes the `AdminCap` from `admin()`.
public fun take_admin_cap(scenario: &Scenario): AdminCap {
    ts::take_from_address<AdminCap>(scenario, admin())
}

/// Returns the `AdminCap` to `admin()`.
public fun return_admin_cap(cap: AdminCap) {
    ts::return_to_address(admin(), cap)
}

/// Takes `alice()`'s most recent `PoolCap`.
public fun take_pool_cap(scenario: &Scenario): PoolCap {
    ts::take_from_address<PoolCap>(scenario, alice())
}

/// Returns a `PoolCap` to `alice()`.
public fun return_pool_cap(cap: PoolCap) {
    ts::return_to_address(alice(), cap)
}

/// Burns a test coin and returns its value.
public fun burn<T>(c: Coin<T>): u64 {
    coin::burn_for_testing(c)
}

/// `a * b` widened to `u256`.
public fun k(a: u64, b: u64): u256 {
    (a as u256) * (b as u256)
}

/// xorshift64 PRNG for deterministic, seeded property tests. Shifts and xors
/// only, so it never aborts.
public struct Rng has drop { state: u64 }

/// The low 64 bits of a `u128`.
const U64_MASK: u128 = 0xFFFFFFFFFFFFFFFF;

/// A generator seeded with `seed` (any value). The seed goes through the
/// splitmix64 finaliser, so neighbouring seeds start from unrelated states: a
/// plain `seed ^ constant | 1` would give seeds `2k` and `2k + 1` the same
/// state, and therefore the same campaign. The products are taken in `u128`
/// on operands below 2^64, so they cannot overflow. The state is never zero.
public fun rng(seed: u64): Rng {
    let mut z = ((seed as u128) + 0x9E3779B97F4A7C15) & U64_MASK;
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & U64_MASK;
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & U64_MASK;
    let state = (z ^ (z >> 31)) as u64;
    Rng { state: if (state == 0) 0x9E3779B97F4A7C15 else state }
}

/// Next 64 pseudo-random bits.
public fun next(rng: &mut Rng): u64 {
    let mut x = rng.state;
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    rng.state = x;
    x
}

/// Value in `[1, max]` (`max >= 1`).
public fun between_1_and(rng: &mut Rng, max: u64): u64 {
    rng.next() % max + 1
}
