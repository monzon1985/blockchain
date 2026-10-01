// SPDX-License-Identifier: MIT
/**
 * Write side (facilitator relayer) and independent confirmation (resource server, agent) of settlements.
 *
 * `confirmSettlement` is what makes the facilitator untrusted: whatever a facilitator claims in its
 * `SettlementResponse`, the server and the agent read the transaction receipt themselves and accept it only if a
 * `ReceiptRecorded` (or `EscrowOpened`) event from the expected contract carries the expected payer, payee, amount
 * and resource.
 */
import {
  isAddressEqual,
  parseEventLogs,
  type Address,
  type Chain,
  type Hex,
  type Log,
  type PublicClient,
  type Transport,
} from 'viem';
import { budgetExecutorAbi, paymentEscrowAbi, settlementLogAbi } from './abis.js';
import type { Deployment } from './deployment.js';
import type { RelayerClient, SettlementCall } from './reader.js';

/** What the settlement is expected to have produced. */
export interface SettlementExpectation {
  readonly kind: 'receipt' | 'escrow';
  readonly payer?: Address | undefined;
  readonly payee: Address;
  readonly amount: bigint;
  readonly resourceHash: Hex;
  /** Exact id, when known in advance (the facilitator always knows it). */
  readonly id?: Hex | undefined;
}

export interface SettlementOutcome {
  readonly transaction: Hex;
  /** Receipt id (exact / budget-exec) or escrow id (escrow). */
  readonly id: Hex;
  readonly payer: Address;
}

/** The facilitator's claim did not match the chain. */
export class SettlementMismatchError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SettlementMismatchError';
  }
}

/**
 * The transaction receipt could not be read (RPC error, or a hash the node does not know). Unlike a mismatch this
 * may be transient, so callers retry before giving up.
 */
export class SettlementUnavailableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SettlementUnavailableError';
  }
}

/** True if an on-chain record (receipt or escrow) carries exactly the expected terms. */
export function termsMatch(
  record: {
    readonly payer: Address;
    readonly payee: Address;
    readonly amount: bigint;
    readonly resourceHash: Hex;
  },
  expected: SettlementExpectation,
): boolean {
  return (
    (expected.payer === undefined || isAddressEqual(record.payer, expected.payer)) &&
    isAddressEqual(record.payee, expected.payee) &&
    record.amount === expected.amount &&
    record.resourceHash.toLowerCase() === expected.resourceHash.toLowerCase()
  );
}

/**
 * Finds, among `logs`, the settlement event emitted by the trusted contract that matches `expected`.
 * Pure function over already-fetched logs (unit-tested with synthetic logs).
 */
export function matchSettlementLogs(
  logs: readonly Log[],
  deployment: Deployment,
  expected: SettlementExpectation,
): SettlementOutcome | null {
  if (expected.kind === 'receipt') {
    const events = parseEventLogs({ abi: settlementLogAbi, eventName: 'ReceiptRecorded', logs: [...logs] });
    for (const event of events) {
      const a = event.args;
      if (
        isAddressEqual(event.address, deployment.settlementLog) &&
        isAddressEqual(a.payee, expected.payee) &&
        a.amount === expected.amount &&
        a.resourceHash === expected.resourceHash &&
        (expected.payer === undefined || isAddressEqual(a.payer, expected.payer)) &&
        (expected.id === undefined || a.receiptId === expected.id)
      ) {
        return { transaction: event.transactionHash, id: a.receiptId, payer: a.payer };
      }
    }
    return null;
  }
  const events = parseEventLogs({ abi: paymentEscrowAbi, eventName: 'EscrowOpened', logs: [...logs] });
  for (const event of events) {
    const a = event.args;
    if (
      isAddressEqual(event.address, deployment.paymentEscrow) &&
      isAddressEqual(a.payee, expected.payee) &&
      a.amount === expected.amount &&
      a.resourceHash === expected.resourceHash &&
      (expected.payer === undefined || isAddressEqual(a.payer, expected.payer)) &&
      (expected.id === undefined || a.escrowId === expected.id)
    ) {
      return { transaction: event.transactionHash, id: a.escrowId, payer: a.payer };
    }
  }
  return null;
}

/**
 * Reads the transaction receipt and checks it against the expectation. Throws {@link SettlementUnavailableError}
 * when the receipt cannot be read and {@link SettlementMismatchError} when it does not prove the expected payment.
 */
export async function confirmSettlement(
  publicClient: PublicClient<Transport, Chain>,
  deployment: Deployment,
  transaction: Hex,
  expected: SettlementExpectation,
): Promise<SettlementOutcome> {
  let receipt;
  try {
    receipt = await publicClient.getTransactionReceipt({ hash: transaction });
  } catch {
    throw new SettlementUnavailableError(`transaction ${transaction} not found`);
  }
  if (receipt.status !== 'success') throw new SettlementMismatchError(`transaction ${transaction} reverted`);
  const match = matchSettlementLogs(receipt.logs, deployment, expected);
  if (match === null) {
    throw new SettlementMismatchError(`transaction ${transaction} carries no matching settlement event`);
  }
  return match;
}

export interface RetryOptions {
  /** Total number of reads (1 = no retry). */
  readonly attempts: number;
  /** Delay before the first retry; doubles on every further retry. */
  readonly delayMs: number;
}

/**
 * {@link confirmSettlement} that retries, with exponential backoff, while the receipt cannot be read. A mismatch is
 * final and is thrown at once. Used by the resource server so that a transient RPC error right after a settlement
 * does not turn a paid call into a refusal.
 */
export async function confirmSettlementWithRetry(
  publicClient: PublicClient<Transport, Chain>,
  deployment: Deployment,
  transaction: Hex,
  expected: SettlementExpectation,
  retry: RetryOptions,
): Promise<SettlementOutcome> {
  for (let attempt = 1; ; attempt++) {
    try {
      return await confirmSettlement(publicClient, deployment, transaction, expected);
    } catch (error) {
      if (!(error instanceof SettlementUnavailableError) || attempt >= retry.attempts) throw error;
      await new Promise((resolve) => setTimeout(resolve, retry.delayMs * 2 ** (attempt - 1)));
    }
  }
}

export interface ChainWriter {
  readonly address: Address;
  /** Sends the settlement transaction and returns the confirmed outcome. Calls are serialized (one nonce stream). */
  execute(call: SettlementCall, expected: SettlementExpectation & { id: Hex }): Promise<SettlementOutcome>;
  /**
   * Finds a settlement that already happened on-chain (idempotency across facilitator restarts). Returns `null` if
   * there is none, and throws {@link SettlementMismatchError} if a receipt or escrow with the same id exists but
   * records other terms (the payer signed two authorizations with one nonce and a different one was settled).
   */
  findExisting(expected: SettlementExpectation & { id: Hex }): Promise<SettlementOutcome | null>;
}

export function createChainWriter(
  publicClient: PublicClient<Transport, Chain>,
  wallet: RelayerClient,
  deployment: Deployment,
): ChainWriter {
  let queue: Promise<unknown> = Promise.resolve();
  const serialize = <T>(task: () => Promise<T>): Promise<T> => {
    const run = queue.then(task, task);
    queue = run.catch(() => undefined);
    return run;
  };

  const send = async (call: SettlementCall): Promise<Hex> => {
    switch (call.kind) {
      case 'exact':
        return wallet.writeContract({
          address: deployment.settlementLog,
          abi: settlementLogAbi,
          functionName: 'settleExact',
          args: [call.args.auth, call.args.resourceHash, call.args.resourceSalt, call.args.signature],
        });
      case 'budget-exec':
        return wallet.writeContract({
          address: deployment.budgetExecutor,
          abi: budgetExecutorAbi,
          functionName: 'pay',
          args: [call.intent, call.signature],
        });
      case 'escrow':
        return wallet.writeContract({
          address: deployment.paymentEscrow,
          abi: paymentEscrowAbi,
          functionName: 'open',
          args: [call.args.request, call.args.signature],
        });
    }
  };

  return {
    address: wallet.account.address,

    execute(call, expected) {
      return serialize(async () => {
        const hash = await send(call);
        await publicClient.waitForTransactionReceipt({ hash });
        return confirmSettlement(publicClient, deployment, hash, expected);
      });
    },

    async findExisting(expected) {
      if (expected.kind === 'receipt') {
        const receipt = await publicClient.readContract({
          address: deployment.settlementLog,
          abi: settlementLogAbi,
          functionName: 'receiptOf',
          args: [expected.id],
        });
        if (receipt.payer === '0x0000000000000000000000000000000000000000') return null;
        if (!termsMatch(receipt, expected)) {
          throw new SettlementMismatchError(`receipt ${expected.id} exists with other terms`);
        }
        const events = await publicClient.getContractEvents({
          address: deployment.settlementLog,
          abi: settlementLogAbi,
          eventName: 'ReceiptRecorded',
          args: { receiptId: expected.id },
          fromBlock: 0n,
        });
        const first = events[0];
        return first === undefined
          ? null
          : { transaction: first.transactionHash, id: expected.id, payer: receipt.payer };
      }
      const escrow = await publicClient.readContract({
        address: deployment.paymentEscrow,
        abi: paymentEscrowAbi,
        functionName: 'escrowOf',
        args: [expected.id],
      });
      if (escrow.status === 0) return null;
      if (!termsMatch(escrow, expected)) {
        throw new SettlementMismatchError(`escrow ${expected.id} exists with other terms`);
      }
      const events = await publicClient.getContractEvents({
        address: deployment.paymentEscrow,
        abi: paymentEscrowAbi,
        eventName: 'EscrowOpened',
        args: { escrowId: expected.id },
        fromBlock: 0n,
      });
      const first = events[0];
      return first === undefined
        ? null
        : { transaction: first.transactionHash, id: expected.id, payer: escrow.payer };
    },
  };
}
