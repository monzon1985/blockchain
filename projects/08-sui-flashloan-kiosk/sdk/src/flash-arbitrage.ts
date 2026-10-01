// SPDX-License-Identifier: MIT
//
// PTB 1: flash-borrow from a lender pool, sell on pool X, buy back on pool Y,
// repay the lender and keep the profit, all in ONE programmable transaction.
//
//   0  MoveCall  pool::flash_borrow_{a|b}<A,B,LP_L>(lender, amount)      -> (loan, receipt)
//   1  MoveCall  pool::swap_{a_for_b|b_for_a}<A,B,LP_X>(sellOn, loan, minIntermediate)
//   2  MoveCall  pool::swap_{b_for_a|a_for_b}<A,B,LP_Y>(buyOn, coin, minFinal)
//   3  MoveCall  pool::amount_due(&receipt)                              -> due (u64)
//   4  SplitCoins(proceeds, [due])                                       -> repayment
//   5  MoveCall  pool::flash_repay_{a|b}<A,B,LP_L>(lender, receipt, repayment)
//   6  TransferObjects([proceeds], recipient)                            (the profit)
//
// The repayment amount is read from the receipt on chain (step 3), so it can
// never disagree with what the pool demands. If any step aborts, or if the
// receipt is not consumed, the whole transaction reverts: there is no state in
// which the borrower keeps the loan.

import { Transaction } from '@mysten/sui/transactions';
import { isValidSuiAddress, normalizeSuiAddress } from '@mysten/sui/utils';
import { feeUp, type Side } from './math.js';
import { type PoolRef, PtbInputError, nth, objectId, poolTypeArgs, sharedInput } from './refs.js';

/** Inputs of `buildFlashArbitrageTx`. */
export interface FlashArbitrageParams {
  /** Package id of `flash_kiosk`. */
  packageId: string;
  /** Pool the loan is taken from. Must differ from both swap pools. */
  lender: PoolRef & { flashFeeBps: bigint };
  /** Pool where the borrowed coin is sold. */
  sellOn: PoolRef;
  /** Pool where the borrowed coin is bought back. */
  buyOn: PoolRef;
  /** Which coin to borrow. */
  side: Side;
  /** Principal to borrow. */
  amount: bigint;
  /** Minimum profit, in the borrowed coin. The final swap aborts below it. */
  minProfit: bigint;
  /** Minimum output of the first swap (slippage guard). Defaults to 1. */
  minIntermediate?: bigint;
  /** Receiver of the profit. */
  recipient: string;
}

function checkParams(p: FlashArbitrageParams): void {
  if (p.amount <= 0n) throw new PtbInputError('amount must be positive');
  if (p.minProfit < 0n) throw new PtbInputError('minProfit must be non-negative');
  if (p.minIntermediate !== undefined && p.minIntermediate <= 0n) {
    throw new PtbInputError('minIntermediate must be positive');
  }
  if (!isValidSuiAddress(normalizeSuiAddress(p.recipient))) throw new PtbInputError('invalid recipient');
  const lender = objectId(p.lender.objectId, 'lender');
  if (lender === objectId(p.sellOn.objectId, 'sellOn') || lender === objectId(p.buyOn.objectId, 'buyOn')) {
    // The pool is locked (PoolState::FlashLoanOpen) until its loan is repaid.
    throw new PtbInputError(
      'the lender pool cannot also be a swap pool: it is locked while its loan is open',
    );
  }
  const [a, b] = poolTypeArgs(p.lender);
  for (const [label, pool] of [
    ['sellOn', p.sellOn],
    ['buyOn', p.buyOn],
  ] as const) {
    const [pa, pb] = poolTypeArgs(pool);
    if (pa !== a || pb !== b) throw new PtbInputError(`${label} must trade the same pair as the lender`);
  }
}

/** Builds the single-transaction flash-loan arbitrage (see the file header). */
export function buildFlashArbitrageTx(p: FlashArbitrageParams): Transaction {
  checkParams(p);
  const pkg = objectId(p.packageId, 'packageId');
  const tx = new Transaction();
  const lender = sharedInput(tx, p.lender, true, 'lender');
  const sellOn = sharedInput(tx, p.sellOn, true, 'sellOn');
  const buyOn = sharedInput(tx, p.buyOn, true, 'buyOn');
  const suffix = p.side === 'A' ? 'a' : 'b';
  const [sell, buy] = p.side === 'A' ? ['swap_a_for_b', 'swap_b_for_a'] : ['swap_b_for_a', 'swap_a_for_b'];

  const borrow = tx.moveCall({
    target: `${pkg}::pool::flash_borrow_${suffix}`,
    typeArguments: poolTypeArgs(p.lender),
    arguments: [lender, tx.pure.u64(p.amount)],
  });
  const loan = nth(borrow, 0);
  const receipt = nth(borrow, 1);
  const intermediate = tx.moveCall({
    target: `${pkg}::pool::${sell}`,
    typeArguments: poolTypeArgs(p.sellOn),
    arguments: [sellOn, loan, tx.pure.u64(p.minIntermediate ?? 1n)],
  });
  // Selling back must at least cover principal + fee + the requested profit.
  const minFinal = p.amount + feeUp(p.amount, p.lender.flashFeeBps) + p.minProfit;
  const proceeds = tx.moveCall({
    target: `${pkg}::pool::${buy}`,
    typeArguments: poolTypeArgs(p.buyOn),
    arguments: [buyOn, intermediate, tx.pure.u64(minFinal)],
  });
  const due = tx.moveCall({ target: `${pkg}::pool::amount_due`, arguments: [receipt] });
  const repayment = nth(tx.splitCoins(proceeds, [due]), 0);
  tx.moveCall({
    target: `${pkg}::pool::flash_repay_${suffix}`,
    typeArguments: poolTypeArgs(p.lender),
    arguments: [lender, receipt, repayment],
  });
  tx.transferObjects([proceeds], normalizeSuiAddress(p.recipient));
  return tx;
}
