// SPDX-License-Identifier: MIT

#[test_only]
/// Fixed-point helpers: exact values at the edges of the `u64` domain, the
/// rounding direction of every macro, and randomized properties.
module flash_kiosk::math_tests;

use flash_kiosk::math;
use flash_kiosk::test_utils as tu;
use std::unit_test::assert_eq;

const MAX: u64 = 18_446_744_073_709_551_615;

#[test]
fun mul_div_down_floors_and_up_ceils() {
    assert_eq!(math::mul_div_down!(7, 3, 2), 10); // 10.5 -> 10
    assert_eq!(math::mul_div_up!(7, 3, 2), 11); // 10.5 -> 11
    assert_eq!(math::mul_div_down!(1, 1, 2), 0);
    assert_eq!(math::mul_div_up!(1, 1, 2), 1);
    // Exact quotients do not round.
    assert_eq!(math::mul_div_down!(6, 4, 3), 8);
    assert_eq!(math::mul_div_up!(6, 4, 3), 8);
    assert_eq!(math::mul_div_up!(0, 5, 3), 0);
}

#[test]
fun the_u128_product_of_two_max_u64_does_not_overflow() {
    // (2^64 - 1)^2 < 2^128: the widest possible product still fits.
    assert_eq!(math::mul_div_down!(MAX, MAX, MAX), MAX);
    assert_eq!(math::mul_div_up!(MAX, MAX, MAX), MAX);
    assert_eq!(math::mul_div_down!(MAX, MAX - 1, MAX), MAX - 1);
    assert_eq!(math::mul_div_up!(MAX, 1, 2), MAX / 2 + 1);
}

#[test, expected_failure(arithmetic_error, location = Self)]
fun mul_div_down_by_zero_aborts() {
    math::mul_div_down!(1, 1, 0);
}

#[test, expected_failure(arithmetic_error, location = Self)]
fun mul_div_up_by_zero_aborts() {
    math::mul_div_up!(1, 1, 0);
}

#[test, expected_failure(arithmetic_error, location = Self)]
fun a_quotient_above_u64_max_aborts_instead_of_truncating() {
    math::mul_div_down!(MAX, 2, 1);
}

#[test]
fun fee_up_rounds_in_favour_of_the_recipient() {
    assert_eq!(math::fee_up!(0, 30), 0);
    assert_eq!(math::fee_up!(1, 1), 1);
    assert_eq!(math::fee_up!(10_000, 30), 30);
    assert_eq!(math::fee_up!(10_001, 30), 31);
    assert_eq!(math::fee_up!(MAX, 10_000), MAX);
    assert_eq!(math::fee_up!(123, 0), 0);
    assert_eq!(math::bps(), 10_000);
}

#[test]
fun sqrt_down_is_the_integer_square_root() {
    assert_eq!(math::sqrt_down(0, 5), 0);
    assert_eq!(math::sqrt_down(2, 2), 2);
    assert_eq!(math::sqrt_down(2, 3), 2); // sqrt(6) = 2.449
    assert_eq!(math::sqrt_down(3, 3), 3);
    assert_eq!(math::sqrt_down(MAX, MAX), MAX);
    assert_eq!(math::sqrt_down(1_000_000, 1_000_000), 1_000_000);
}

#[test]
fun amount_out_handles_the_extremes_without_overflow() {
    let (out, fee) = math::amount_out(MAX, MAX, MAX, 30);
    assert!(out < MAX);
    assert_eq!(fee, math::fee_up!(MAX, 30));
    // Selling nothing yields nothing.
    let (out, fee) = math::amount_out(0, 1_000, 1_000, 30);
    assert_eq!(out, 0);
    assert_eq!(fee, 0);
}

// === properties ===
//
// Each property is a plain function checked two ways: 1_000 deterministic,
// seeded cases (`#[test]`, identical on every run and in CI) and inputs drawn
// by `sui move test` (`#[random_test]`: fresh on every run, pinned by `--seed`
// in the CI gate; the scheduled CI job runs 10_000 fresh inputs per property,
// and a failure prints the seed that replays it).

const CASES: u64 = 1_000;

fun check_mul_div_up_is_floor_or_floor_plus_one(a: u64, b: u64, d: u64) {
    let d = d % MAX + 1; // [1, MAX]
    let b = b % d; // b < d keeps the quotient below a, so it fits in u64
    let down = math::mul_div_down!(a, b, d);
    let up = math::mul_div_up!(a, b, d);
    let exact = (a as u128) * (b as u128) % (d as u128) == 0;
    if (exact) assert_eq!(up, down) else assert_eq!(up, down + 1);
    assert!((down as u128) * (d as u128) <= (a as u128) * (b as u128));
}

fun check_fee_up_is_the_smallest_sufficient_fee(amount: u64, bps: u64) {
    let bps = bps % 10_001;
    let fee = math::fee_up!(amount, bps);
    let owed = (amount as u128) * (bps as u128);
    assert!(fee <= amount);
    assert!((fee as u128) * 10_000 >= owed);
    if (fee > 0) assert!(((fee - 1) as u128) * 10_000 < owed);
}

fun check_swap_output_is_bounded_and_k_never_decreases(
    amount_in: u64,
    reserve_in: u64,
    reserve_out: u64,
    fee_bps: u64,
) {
    let reserve_in = reserve_in % (MAX / 2) + 1;
    let reserve_out = reserve_out % MAX + 1;
    let amount_in = amount_in % (MAX - reserve_in) + 1; // reserve_in + amount_in <= MAX
    let fee_bps = fee_bps % 100 + 1;
    let (out, fee) = math::amount_out(amount_in, reserve_in, reserve_out, fee_bps);
    assert!(out < reserve_out);
    assert_eq!(fee, math::fee_up!(amount_in, fee_bps));
    let k_before = (reserve_in as u256) * (reserve_out as u256);
    let k_after = ((reserve_in + amount_in) as u256) * ((reserve_out - out) as u256);
    assert!(k_after >= k_before);
}

#[test]
fun prop_mul_div_up_is_floor_or_floor_plus_one() {
    let mut rng = tu::rng(1);
    CASES.do!(|_| check_mul_div_up_is_floor_or_floor_plus_one(rng.next(), rng.next(), rng.next()));
}

#[test]
fun prop_fee_up_is_the_smallest_sufficient_fee() {
    let mut rng = tu::rng(2);
    CASES.do!(|_| check_fee_up_is_the_smallest_sufficient_fee(rng.next(), rng.next()));
}

#[test]
fun prop_swap_output_is_bounded_and_k_never_decreases() {
    let mut rng = tu::rng(3);
    CASES.do!(|_| {
        check_swap_output_is_bounded_and_k_never_decreases(
            rng.next(),
            rng.next(),
            rng.next(),
            rng.next(),
        )
    });
}

#[random_test]
fun fuzz_mul_div_up_is_floor_or_floor_plus_one(a: u64, b: u64, d: u64) {
    check_mul_div_up_is_floor_or_floor_plus_one(a, b, d)
}

#[random_test]
fun fuzz_fee_up_is_the_smallest_sufficient_fee(amount: u64, bps: u64) {
    check_fee_up_is_the_smallest_sufficient_fee(amount, bps)
}

#[random_test]
fun fuzz_swap_output_is_bounded_and_k_never_decreases(
    amount_in: u64,
    reserve_in: u64,
    reserve_out: u64,
    fee_bps: u64,
) {
    check_swap_output_is_bounded_and_k_never_decreases(amount_in, reserve_in, reserve_out, fee_bps)
}
