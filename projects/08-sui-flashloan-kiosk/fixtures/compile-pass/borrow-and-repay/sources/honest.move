// SPDX-License-Identifier: MIT

// The legitimate use of the receipt: borrow, top the loan up with the fee from
// the caller's own coin, repay. This must compile.
module attacker::honest;

use flash_kiosk::pool::Pool;
use sui::coin::Coin;

public fun borrow_and_repay<A, B, LP>(
    pool: &mut Pool<A, B, LP>,
    amount: u64,
    mut top_up: Coin<A>,
    ctx: &mut TxContext,
): Coin<A> {
    let (mut loan, receipt) = pool.flash_borrow_a(amount, ctx);
    let fee = receipt.amount_due() - amount;
    loan.join(top_up.split(fee, ctx));
    pool.flash_repay_a(receipt, loan);
    top_up
}
