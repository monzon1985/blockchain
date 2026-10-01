// SPDX-License-Identifier: MIT
// Transaction plumbing. The solver signs every side effect locally, journals the raw bytes, hash AND nonce (see
// journal.ts), and only then broadcasts, so a crash at any instruction can be recovered by re-sending exactly the
// journaled transaction. The helpers here are stateless; `sendAndWait` is for actors that keep no journal
// (relayers, watchtower, scripts).
import {
  type Address,
  type Hex,
  type TransactionReceipt,
  TransactionReceiptNotFoundError,
  keccak256,
} from "viem";

import type { ChainClients, Wallet } from "./chains.ts";

/** A signed, not necessarily broadcast, transaction. */
export interface SignedTx {
  /** keccak256 of `raw`: the transaction hash. */
  hash: Hex;
  /** Serialized signed transaction. */
  raw: Hex;
  /** Account nonce the transaction consumes. */
  nonce: number;
}

/** A contract call: target and calldata. */
export interface Call {
  to: Address;
  data: Hex;
}

/** Gas limit signed for a call whose execution was estimated at `estimate`: +50% and +25k of headroom. */
export function gasWithHeadroom(estimate: bigint): bigint {
  return (estimate * 3n) / 2n + 25_000n;
}

/**
 * Prepares (gas, fees, and the nonce unless given) and signs `call` without broadcasting it. The gas limit gets
 * headroom over the estimate: a journaled transaction can be (re)sent long after it was signed (after a crash, or
 * behind a nonce gap), and time-dependent code paths such as the Dutch decay cost more than at signing time.
 * @param nonce Nonce to use; the node's pending nonce when omitted.
 */
export async function signCall(wallet: Wallet, call: Call, nonce?: number): Promise<SignedTx> {
  const request = await wallet.prepareTransactionRequest({
    to: call.to,
    data: call.data,
    ...(nonce === undefined ? {} : { nonce }),
  });
  const raw = await wallet.signTransaction({ ...request, gas: gasWithHeadroom(request.gas) });
  return { hash: keccak256(raw), raw, nonce: request.nonce };
}

/**
 * What the node said about a (re)broadcast:
 * - `sent`: accepted now;
 * - `known`: this exact transaction is already in the node (mempool or chain);
 * - `nonce-too-low`: the sender's nonce has moved past this transaction's. Either this transaction was mined, or
 *   another one with the same nonce was (it was replaced); the caller tells them apart with the receipt.
 */
export type BroadcastResult = "sent" | "known" | "nonce-too-low";

const KNOWN = ["already known", "already imported", "known transaction", "transaction already exists"];
const NONCE_TOO_LOW = ["nonce too low", "nonce has already been used", "oldnonce"];

/** Classifies a sendRawTransaction error message; `undefined` for anything that is a real failure. */
export function classifyBroadcastError(message: string): Exclude<BroadcastResult, "sent"> | undefined {
  const lower = message.toLowerCase();
  if (KNOWN.some((k) => lower.includes(k))) return "known";
  if (NONCE_TOO_LOW.some((k) => lower.includes(k))) return "nonce-too-low";
  return undefined;
}

/** Broadcasts a signed transaction. Throws for any error other than the two benign answers of a re-send. */
export async function broadcast(clients: ChainClients, raw: Hex): Promise<BroadcastResult> {
  try {
    await clients.public.sendRawTransaction({ serializedTransaction: raw });
    return "sent";
  } catch (error) {
    const kind = classifyBroadcastError(error instanceof Error ? error.message : String(error));
    if (kind === undefined) throw error;
    return kind;
  }
}

/** Receipt of `hash`, or null while it is not mined. */
export async function receiptOf(clients: ChainClients, hash: Hex): Promise<TransactionReceipt | null> {
  try {
    return await clients.public.getTransactionReceipt({ hash });
  } catch (error) {
    if (error instanceof TransactionReceiptNotFoundError) return null;
    throw error;
  }
}

/**
 * Sends a non-journaled transaction and waits for it (relayers, watchtower, scripts). Throws if it reverts.
 * Not for the solver: its transactions go through the journal (journal.ts) so nonces cannot collide after a crash.
 */
export async function sendAndWait(clients: ChainClients, wallet: Wallet, call: Call): Promise<TransactionReceipt> {
  const signed = await signCall(wallet, call);
  await broadcast(clients, signed.raw);
  const receipt = await clients.public.waitForTransactionReceipt({ hash: signed.hash });
  if (receipt.status !== "success") throw new Error(`transaction ${signed.hash} reverted`);
  return receipt;
}
