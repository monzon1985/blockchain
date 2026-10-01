// SPDX-License-Identifier: MIT
/** Off-chain mirrors of the deterministic ids computed by the contracts. */
import { encodeAbiParameters, keccak256, type Address, type Hex } from 'viem';

/** Mirrors `ISettlementLog.Scheme`. */
export const ReceiptScheme = { None: 0, Exact: 1, BudgetExec: 2, Escrow: 3 } as const;
export type ReceiptSchemeId = (typeof ReceiptScheme)[keyof typeof ReceiptScheme];

/** Mirrors `SettlementLog.receiptIdFor(recorder, scheme, payer, paymentKey)`. */
export function receiptIdFor(
  recorder: Address,
  scheme: ReceiptSchemeId,
  payer: Address,
  paymentKey: Hex,
): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: 'address' }, { type: 'uint8' }, { type: 'address' }, { type: 'bytes32' }],
      [recorder, scheme, payer, paymentKey],
    ),
  );
}

/** Mirrors `PaymentEscrow.escrowIdFor(payer, nonce)`. */
export function escrowIdFor(payer: Address, nonce: Hex): Hex {
  return keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'bytes32' }], [payer, nonce]));
}

/** Mirrors `PaymentEscrow.Status`. */
export const EscrowStatus = { None: 0, Open: 1, Released: 2, Refunded: 3 } as const;
