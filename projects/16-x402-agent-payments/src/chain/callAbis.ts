// SPDX-License-Identifier: MIT
/**
 * Call ABIs extended with the custom errors of the contracts they call into, so that a revert bubbling up from a
 * nested call (for example `ERC3009InvalidSignature` from the token inside `SettlementLog.settleExact`) is decoded
 * by viem instead of surfacing as an unknown selector.
 */
import {
  agentAccountAbi,
  budgetExecutorAbi,
  paymentEscrowAbi,
  settlementLogAbi,
  testUsdAbi,
} from './abis.js';

type ErrorItem<T extends readonly unknown[]> = Extract<T[number], { readonly type: 'error' }>;

function errorsOf<const T extends readonly { readonly type: string }[]>(abi: T): ErrorItem<T>[] {
  return abi.filter((item): item is ErrorItem<T> => item.type === 'error');
}

export const settlementLogCallAbi = [...settlementLogAbi, ...errorsOf(testUsdAbi)];
export const budgetExecutorCallAbi = [
  ...budgetExecutorAbi,
  ...errorsOf(testUsdAbi),
  ...errorsOf(agentAccountAbi),
  ...errorsOf(settlementLogAbi),
];
export const paymentEscrowCallAbi = [
  ...paymentEscrowAbi,
  ...errorsOf(testUsdAbi),
  ...errorsOf(settlementLogAbi),
];
