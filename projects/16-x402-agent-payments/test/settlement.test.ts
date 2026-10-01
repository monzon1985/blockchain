// SPDX-License-Identifier: MIT
/**
 * The real `createChainWriter.findExisting` and `confirmSettlementWithRetry`, run against a stubbed viem client (the
 * facilitator unit tests use an in-memory writer; this file covers the production code path).
 */
import {
  encodeAbiParameters,
  encodeEventTopics,
  getAddress,
  zeroAddress,
  type Address,
  type Chain,
  type Hex,
  type Log,
  type PublicClient,
  type Transport,
} from 'viem';
import { describe, expect, it } from 'vitest';
import { settlementLogAbi } from '../src/chain/abis.js';
import type { RelayerClient } from '../src/chain/reader.js';
import {
  SettlementMismatchError,
  SettlementUnavailableError,
  confirmSettlementWithRetry,
  createChainWriter,
  type SettlementExpectation,
} from '../src/chain/settlement.js';
import { PRICE, RESOURCE_HASH, deployment, payTo } from './fixtures.js';

const payer: Address = getAddress('0x00000000000000000000000000000000000000a1');
const receiptId: Hex = `0x${'11'.repeat(32)}`;
const escrowId: Hex = `0x${'55'.repeat(32)}`;
const TX: Hex = `0x${'22'.repeat(32)}`;
const relayer = { account: { address: getAddress('0x00000000000000000000000000000000000fac17') } };

type Stub = Partial<Record<'readContract' | 'getContractEvents' | 'getTransactionReceipt', unknown>>;

function writerWith(stub: Stub) {
  return createChainWriter(
    stub as unknown as PublicClient<Transport, Chain>,
    relayer as unknown as RelayerClient,
    deployment,
  );
}

const expectedReceipt: SettlementExpectation & { id: Hex } = {
  kind: 'receipt',
  id: receiptId,
  payer,
  payee: payTo,
  amount: PRICE,
  resourceHash: RESOURCE_HASH,
};

const onChainReceipt = {
  payer,
  settledAt: 1n,
  scheme: 1,
  payee: payTo,
  amount: PRICE,
  resourceHash: RESOURCE_HASH,
};

describe('ChainWriter.findExisting', () => {
  it('returns null when no receipt exists', async () => {
    const writer = writerWith({
      readContract: () => Promise.resolve({ ...onChainReceipt, payer: zeroAddress }),
    });
    expect(await writer.findExisting(expectedReceipt)).toBeNull();
  });

  it('returns the settling transaction of a receipt with the same terms', async () => {
    const writer = writerWith({
      readContract: () => Promise.resolve(onChainReceipt),
      getContractEvents: () => Promise.resolve([{ transactionHash: TX }]),
    });
    expect(await writer.findExisting(expectedReceipt)).toEqual({ transaction: TX, id: receiptId, payer });
  });

  it('returns null when the receipt exists but its event cannot be found', async () => {
    const writer = writerWith({
      readContract: () => Promise.resolve(onChainReceipt),
      getContractEvents: () => Promise.resolve([]),
    });
    expect(await writer.findExisting(expectedReceipt)).toBeNull();
  });

  it.each<[string, Partial<typeof onChainReceipt>]>([
    ['amount', { amount: 1n }],
    ['payee', { payee: payer }],
    ['resource', { resourceHash: `0x${'33'.repeat(32)}` }],
    ['payer', { payer: payTo }],
  ])('refuses a receipt with the same id but another %s', async (_field, override) => {
    const writer = writerWith({ readContract: () => Promise.resolve({ ...onChainReceipt, ...override }) });
    await expect(writer.findExisting(expectedReceipt)).rejects.toBeInstanceOf(SettlementMismatchError);
  });

  const expectedEscrow: SettlementExpectation & { id: Hex } = {
    ...expectedReceipt,
    kind: 'escrow',
    id: escrowId,
  };
  const onChainEscrow = {
    payer,
    deadline: 9n,
    status: 1,
    payee: payTo,
    amount: PRICE,
    resourceHash: RESOURCE_HASH,
    deliveryHash: `0x${'00'.repeat(32)}`,
  };

  it('handles escrows the same way', async () => {
    expect(
      await writerWith({ readContract: () => Promise.resolve({ ...onChainEscrow, status: 0 }) }).findExisting(
        expectedEscrow,
      ),
    ).toBeNull();
    expect(
      await writerWith({
        readContract: () => Promise.resolve(onChainEscrow),
        getContractEvents: () => Promise.resolve([{ transactionHash: TX }]),
      }).findExisting(expectedEscrow),
    ).toEqual({ transaction: TX, id: escrowId, payer });
    expect(
      await writerWith({
        readContract: () => Promise.resolve(onChainEscrow),
        getContractEvents: () => Promise.resolve([]),
      }).findExisting(expectedEscrow),
    ).toBeNull();
    await expect(
      writerWith({
        readContract: () => Promise.resolve({ ...onChainEscrow, amount: 2n * PRICE }),
      }).findExisting(expectedEscrow),
    ).rejects.toBeInstanceOf(SettlementMismatchError);
  });
});

describe('confirmSettlementWithRetry', () => {
  const log: Log = {
    address: deployment.settlementLog,
    topics: encodeEventTopics({
      abi: settlementLogAbi,
      eventName: 'ReceiptRecorded',
      args: { receiptId, payer, payee: payTo },
    }) as [Hex, ...Hex[]],
    data: encodeAbiParameters(
      [{ type: 'uint8' }, { type: 'uint256' }, { type: 'bytes32' }],
      [1, PRICE, RESOURCE_HASH],
    ),
    blockHash: `0x${'00'.repeat(32)}`,
    blockNumber: 1n,
    logIndex: 0,
    transactionHash: TX,
    transactionIndex: 0,
    removed: false,
  };

  function flakyClient(failures: number, status: 'success' | 'reverted' = 'success') {
    let calls = 0;
    const client = {
      getTransactionReceipt: () => {
        calls += 1;
        return calls <= failures
          ? Promise.reject(new Error('ECONNRESET'))
          : Promise.resolve({ status, logs: [log] });
      },
    } as unknown as PublicClient<Transport, Chain>;
    return { client, calls: () => calls };
  }

  it('absorbs transient read failures with backoff', async () => {
    const { client, calls } = flakyClient(2);
    const outcome = await confirmSettlementWithRetry(client, deployment, TX, expectedReceipt, {
      attempts: 3,
      delayMs: 1,
    });
    expect(outcome).toEqual({ transaction: TX, id: receiptId, payer });
    expect(calls()).toBe(3);
  });

  it('gives up after the configured number of reads', async () => {
    const { client, calls } = flakyClient(10);
    await expect(
      confirmSettlementWithRetry(client, deployment, TX, expectedReceipt, { attempts: 3, delayMs: 1 }),
    ).rejects.toBeInstanceOf(SettlementUnavailableError);
    expect(calls()).toBe(3);
  });

  it('does not retry a mismatch', async () => {
    const reverted = flakyClient(0, 'reverted');
    await expect(
      confirmSettlementWithRetry(reverted.client, deployment, TX, expectedReceipt, {
        attempts: 5,
        delayMs: 1,
      }),
    ).rejects.toBeInstanceOf(SettlementMismatchError);
    expect(reverted.calls()).toBe(1);
    const other = flakyClient(0);
    await expect(
      confirmSettlementWithRetry(
        other.client,
        deployment,
        TX,
        { ...expectedReceipt, amount: 1n },
        {
          attempts: 5,
          delayMs: 1,
        },
      ),
    ).rejects.toBeInstanceOf(SettlementMismatchError);
    expect(other.calls()).toBe(1);
  });
});
