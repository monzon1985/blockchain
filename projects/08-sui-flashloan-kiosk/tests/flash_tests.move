// SPDX-License-Identifier: MIT

#[test_only]
/// Flash loans: the happy paths, fee rounding, and the EVM-style attacks that
/// the receipt and the pool lock turn into aborts.
///
/// The attacks that fail at *compile* time (dropping, copying, storing,
/// transferring or forging the receipt) cannot be written as tests at all; they
/// live in `fixtures/compile-fail/` and are checked by `scripts/compile-fail.mjs`.
module flash_kiosk::flash_tests;

use flash_kiosk::pool::{Self, LpCoin};
use flash_kiosk::test_utils::{Self as tu, ALPHA, BETA, LP_L, LP_X, LP_Y, bob, carol};
use std::unit_test::assert_eq;
use sui::coin::Coin;

const RESERVE: u64 = 1_000_000_000;

// === happy paths ===

#[test]
fun borrow_and_repay_a_charges_the_fee_to_lps() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_L>(&scenario);

    let (mut loan, receipt) = pool.flash_borrow_a(100_000, scenario.ctx());
    assert_eq!(loan.value(), 100_000);
    assert!(pool.is_flash_loan_open());
    assert_eq!(receipt.receipt_pool_id(), object::id(&pool));
    assert_eq!(receipt.receipt_amount(), 100_000);
    assert_eq!(receipt.receipt_fee(), 300);
    assert!(receipt.receipt_is_a());
    assert_eq!(receipt.amount_due(), 100_300);

    loan.join(tu::mint<ALPHA>(&mut scenario, 300));
    pool.flash_repay_a(receipt, loan);
    assert!(pool.is_active());
    let (ra, rb) = pool.reserves();
    assert_eq!(ra, RESERVE + 300);
    assert_eq!(rb, RESERVE);

    tu::return_pool(pool);
    scenario.end();
}

#[test]
fun borrow_and_repay_b_charges_the_fee_to_lps() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_L>(&scenario);

    let (mut loan, receipt) = pool.flash_borrow_b(RESERVE, scenario.ctx());
    assert!(!receipt.receipt_is_a());
    let fee = pool.flash_fee(RESERVE);
    assert_eq!(fee, 3_000_000);
    loan.join(tu::mint<BETA>(&mut scenario, fee));
    pool.flash_repay_b(receipt, loan);
    let (ra, rb) = pool.reserves();
    assert_eq!(ra, RESERVE);
    assert_eq!(rb, RESERVE + fee);

    tu::return_pool(pool);
    scenario.end();
}

#[test]
fun a_pool_can_lend_again_after_repayment() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_L>(&scenario);
    3u64.do!(|_| {
        let (mut loan, receipt) = pool.flash_borrow_a(1_000, scenario.ctx());
        loan.join(tu::mint<ALPHA>(&mut scenario, 3));
        pool.flash_repay_a(receipt, loan);
    });
    let (ra, _) = pool.reserves();
    assert_eq!(ra, RESERVE + 9);
    tu::return_pool(pool);
    scenario.end();
}

/// A loan owes the fee quoted when it was taken: the receipt records it, and
/// fees cannot change while the loan is open
/// (`changing_fees_during_the_loan_aborts`). A new fee applies from the next loan.
#[test]
fun a_fee_change_applies_from_the_next_loan() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(tu::admin());
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let admin_cap = tu::take_admin_cap(&scenario);

    let (mut loan, receipt) = pool.flash_borrow_a(10_000, scenario.ctx());
    assert_eq!(receipt.receipt_fee(), 30);
    assert_eq!(receipt.amount_due(), 10_030);
    loan.join(tu::mint<ALPHA>(&mut scenario, 30));
    pool.flash_repay_a(receipt, loan);

    pool.set_fees(&admin_cap, 30, 100);
    let (mut loan, receipt) = pool.flash_borrow_a(10_000, scenario.ctx());
    assert_eq!(receipt.receipt_fee(), 100);
    loan.join(tu::mint<ALPHA>(&mut scenario, 100));
    pool.flash_repay_a(receipt, loan);
    let (ra, _) = pool.reserves();
    assert_eq!(ra, RESERVE + 130);

    tu::return_admin_cap(admin_cap);
    tu::return_pool(pool);
    scenario.end();
}

/// The PTB the TypeScript client builds, written as Move: borrow A from the
/// lender pool L, sell it on X (where A is expensive), buy it back on Y, repay
/// L, keep the profit. Every step is in one transaction.
#[test]
fun cross_pool_arbitrage_repays_and_keeps_the_profit() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    tu::create_pool<LP_X>(&mut scenario, 500_000_000, 1_000_000_000);
    tu::create_pool<LP_Y>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(carol());
    let mut lender = tu::take_pool<LP_L>(&scenario);
    let mut pool_x = tu::take_pool<LP_X>(&scenario);
    let mut pool_y = tu::take_pool<LP_Y>(&scenario);
    let (lx_a, lx_b) = pool_x.reserves();
    let (ly_a, ly_b) = pool_y.reserves();

    let (borrowed, receipt) = lender.flash_borrow_a(10_000_000, scenario.ctx());
    let b = pool_x.swap_a_for_b(borrowed, 0, scenario.ctx());
    let mut a = pool_y.swap_b_for_a(b, receipt.amount_due(), scenario.ctx());
    let repayment = a.split(receipt.amount_due(), scenario.ctx());
    lender.flash_repay_a(receipt, repayment);

    // Profit computed independently with BigInt (see test-vectors/): 9_088_862.
    assert_eq!(a.value(), 9_088_862);
    let (la, lb) = lender.reserves();
    assert_eq!(la, RESERVE + 30_000);
    assert_eq!(lb, RESERVE);
    // Neither arbitraged pool lost k.
    let (xa, xb) = pool_x.reserves();
    let (ya, yb) = pool_y.reserves();
    assert!(tu::k(xa, xb) >= tu::k(lx_a, lx_b));
    assert!(tu::k(ya, yb) >= tu::k(ly_a, ly_b));

    tu::burn(a);
    tu::return_pool(lender);
    tu::return_pool(pool_x);
    tu::return_pool(pool_y);
    scenario.end();
}

// === fee rounding ===

#[test]
fun flash_fee_rounds_up_so_tiny_loans_are_never_free() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    let pool = tu::take_pool<LP_L>(&scenario);
    assert_eq!(pool.flash_fee(1), 1); // 0.003 -> 1
    assert_eq!(pool.flash_fee(333), 1); // 0.999 -> 1
    assert_eq!(pool.flash_fee(334), 2); // 1.002 -> 2
    assert_eq!(pool.flash_fee(3_333), 10); // 9.999 -> 10
    assert_eq!(pool.flash_fee(10_000), 30); // exact, no rounding
    tu::return_pool(pool);
    scenario.end();
}

#[test, expected_failure(abort_code = pool::ERepayAmount)]
fun repaying_a_one_unit_loan_without_the_rounded_up_fee_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let (loan, receipt) = pool.flash_borrow_a(1, scenario.ctx());
    // Truncating fee math would owe 0 here; the pool demands 1 + 1.
    pool.flash_repay_a(receipt, loan);
    abort
}

// === unpaid / mis-paid receipts ===

#[test, expected_failure(abort_code = pool::ERepayAmount)]
fun repaying_principal_without_fee_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let (loan, receipt) = pool.flash_borrow_a(100_000, scenario.ctx());
    pool.flash_repay_a(receipt, loan);
    abort
}

#[test, expected_failure(abort_code = pool::ERepayAmount)]
fun repaying_less_than_the_principal_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let (mut loan, receipt) = pool.flash_borrow_b(100_000, scenario.ctx());
    let kept = loan.split(50_000, scenario.ctx());
    transfer::public_transfer(kept, bob());
    pool.flash_repay_b(receipt, loan);
    abort
}

#[test, expected_failure(abort_code = pool::ERepayAmount)]
fun overpaying_is_rejected_too() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let (mut loan, receipt) = pool.flash_borrow_a(100_000, scenario.ctx());
    loan.join(tu::mint<ALPHA>(&mut scenario, 301));
    pool.flash_repay_a(receipt, loan);
    abort
}

#[test, expected_failure(abort_code = pool::EWrongPool)]
fun repaying_to_another_pool_of_the_same_pair_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut lender = tu::take_pool<LP_L>(&scenario);
    let mut other = tu::take_pool<LP_X>(&scenario);
    let (mut loan, receipt) = lender.flash_borrow_a(100_000, scenario.ctx());
    loan.join(tu::mint<ALPHA>(&mut scenario, 300));
    // Same coin types, different pool: the receipt's pool id does not match.
    other.flash_repay_a(receipt, loan);
    abort
}

#[test, expected_failure(abort_code = pool::EWrongSide)]
fun repaying_a_b_loan_through_the_a_side_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let (loan_b, receipt) = pool.flash_borrow_b(100_000, scenario.ctx());
    transfer::public_transfer(loan_b, bob());
    // Pay the debt in the *other*, cheaper coin.
    let payment = tu::mint<ALPHA>(&mut scenario, 100_300);
    pool.flash_repay_a(receipt, payment);
    abort
}

// === borrow validation ===

#[test, expected_failure(abort_code = pool::EZeroAmount)]
fun borrowing_zero_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let (_loan, _receipt) = pool.flash_borrow_a(0, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EInsufficientLiquidity)]
fun borrowing_more_than_the_reserve_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let (_loan, _receipt) = pool.flash_borrow_b(RESERVE + 1, scenario.ctx());
    abort
}

// === EVM-style attacks, now aborts ===

/// Uniswap v2's `lock` exists because a flash-swap callback could re-enter the
/// same pair. Here the borrower holds the coins in the PTB and could call the
/// pool again: borrowing most of reserve A and then selling A into the drained
/// pool would buy B at a manipulated price. The pool refuses.
#[test, expected_failure(abort_code = pool::EFlashLoanOpen)]
fun swapping_on_the_lending_pool_during_the_loan_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let (mut loan, _receipt) = pool.flash_borrow_a(RESERVE - 1, scenario.ctx());
    let dump = loan.split(1_000_000, scenario.ctx());
    let _b = pool.swap_a_for_b(dump, 0, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EFlashLoanOpen)]
fun a_second_loan_on_the_same_pool_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let (_l1, _r1) = pool.flash_borrow_a(1_000, scenario.ctx());
    let (_l2, _r2) = pool.flash_borrow_b(1_000, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EFlashLoanOpen)]
fun depositing_during_the_loan_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let (loan, _receipt) = pool.flash_borrow_a(500_000_000, scenario.ctx());
    // LP minting at depleted reserves would mint too many shares.
    let b = tu::mint<BETA>(&mut scenario, 1_000_000);
    let (_lp, _ra, _rb) = pool.add_liquidity(loan, b, 0, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = pool::EFlashLoanOpen)]
fun withdrawing_during_the_loan_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let lp = sui::test_scenario::take_from_address<Coin<LpCoin<LP_L>>>(&scenario, tu::alice());
    let (_loan, _receipt) = pool.flash_borrow_a(500_000_000, scenario.ctx());
    let (_a, _b) = pool.remove_liquidity(lp, 0, 0, scenario.ctx());
    abort
}

/// Read-only reentrancy: an integrator pricing collateral off `reserves()` in the
/// middle of someone else's loan would see depleted reserves. The view aborts.
#[test, expected_failure(abort_code = pool::EFlashLoanOpen)]
fun reading_reserves_during_the_loan_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let (_loan, _receipt) = pool.flash_borrow_a(500_000_000, scenario.ctx());
    let (_ra, _rb) = pool.reserves();
    abort
}

#[test, expected_failure(abort_code = pool::EFlashLoanOpen)]
fun quoting_a_for_b_during_the_loan_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let (_loan, _receipt) = pool.flash_borrow_a(500_000_000, scenario.ctx());
    pool.quote_a_for_b(1_000);
    abort
}

#[test, expected_failure(abort_code = pool::EFlashLoanOpen)]
fun quoting_b_for_a_during_the_loan_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let (_loan, _receipt) = pool.flash_borrow_b(500_000_000, scenario.ctx());
    pool.quote_b_for_a(1_000);
    abort
}

#[test, expected_failure(abort_code = pool::EFlashLoanOpen)]
fun pausing_during_the_loan_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(tu::admin());
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let cap = tu::take_admin_cap(&scenario);
    let (_loan, _receipt) = pool.flash_borrow_a(1_000, scenario.ctx());
    pool.pause(&cap);
    abort
}

// The capability-gated configuration calls are locked too: while a loan is
// open, the matching repay is the only state-changing call the pool accepts.

#[test, expected_failure(abort_code = pool::EFlashLoanOpen)]
fun changing_fees_during_the_loan_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(tu::admin());
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let cap = tu::take_admin_cap(&scenario);
    let (_loan, _receipt) = pool.flash_borrow_a(10_000, scenario.ctx());
    pool.set_fees(&cap, 30, 100);
    abort
}

/// Without the lock this would fail with `ENotPaused` instead.
#[test, expected_failure(abort_code = pool::EFlashLoanOpen)]
fun unpausing_during_the_loan_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(tu::admin());
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let cap = tu::take_admin_cap(&scenario);
    let (_loan, _receipt) = pool.flash_borrow_a(1_000, scenario.ctx());
    pool.unpause(&cap);
    abort
}

#[test, expected_failure(abort_code = pool::EFlashLoanOpen)]
fun toggling_flash_loans_during_the_loan_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let cap = tu::take_pool_cap(&scenario);
    let (_loan, _receipt) = pool.flash_borrow_a(1_000, scenario.ctx());
    pool.set_flash_loans_enabled(&cap, false);
    abort
}

/// A loan taken through one package version must be repaid through the same
/// one: `migrate` cannot move the pool under an open loan.
#[test, expected_failure(abort_code = pool::EFlashLoanOpen)]
fun migrating_during_the_loan_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(tu::admin());
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let cap = tu::take_admin_cap(&scenario);
    let (_loan, _receipt) = pool.flash_borrow_a(1_000, scenario.ctx());
    // Make the pool look stale, so only the lock can stop the migration.
    pool.set_version_for_testing(0);
    pool.migrate(&cap);
    abort
}

#[test, expected_failure(abort_code = pool::EFlashLoansDisabled)]
fun borrowing_from_a_pool_that_disabled_flash_loans_aborts() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    let mut pool = tu::take_pool<LP_L>(&scenario);
    let cap = tu::take_pool_cap(&scenario);
    pool.set_flash_loans_enabled(&cap, false);
    let (_loan, _receipt) = pool.flash_borrow_a(1_000, scenario.ctx());
    abort
}

/// Receipts from two different pools can be open at once (different objects),
/// and each must go back to its own pool.
#[test]
fun loans_from_two_pools_can_be_nested() {
    let mut scenario = tu::begin();
    tu::create_pool<LP_L>(&mut scenario, RESERVE, RESERVE);
    tu::create_pool<LP_X>(&mut scenario, RESERVE, RESERVE);
    scenario.next_tx(bob());
    let mut p1 = tu::take_pool<LP_L>(&scenario);
    let mut p2 = tu::take_pool<LP_X>(&scenario);

    let (mut l1, r1) = p1.flash_borrow_a(1_000_000, scenario.ctx());
    let (mut l2, r2) = p2.flash_borrow_a(2_000_000, scenario.ctx());
    l2.join(tu::mint<ALPHA>(&mut scenario, 6_000));
    p2.flash_repay_a(r2, l2);
    l1.join(tu::mint<ALPHA>(&mut scenario, 3_000));
    p1.flash_repay_a(r1, l1);
    assert!(p1.is_active() && p2.is_active());

    tu::return_pool(p1);
    tu::return_pool(p2);
    scenario.end();
}
