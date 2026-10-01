// SPDX-License-Identifier: MIT
import { encodeAbiParameters, encodeEventTopics, getAddress, type Address, type Hex, type Log } from 'viem';
import { beforeEach, describe, expect, it } from 'vitest';
import { buildExactPayment } from '../src/agent/payments.js';
import { paymentEscrowAbi, settlementLogAbi } from '../src/chain/abis.js';
import type { SettlementCall } from '../src/chain/reader.js';
import {
  SettlementMismatchError,
  matchSettlementLogs,
  termsMatch,
  type ChainWriter,
  type SettlementExpectation,
  type SettlementOutcome,
} from '../src/chain/settlement.js';
import { Facilitator, createFacilitatorApp } from '../src/facilitator/facilitator.js';
import { encodeHeader } from '../src/x402/codec.js';
import type { FacilitatorRequest } from '../src/x402/types.js';
import {
  FakeChain,
  PRICE,
  RESOURCE_HASH,
  context,
  deployment,
  newAccount,
  payTo,
  requirements,
} from './fixtures.js';

/** In-memory writer that behaves like `createChainWriter`, including the terms check of `findExisting`. */
class FakeWriter implements ChainWriter {
  readonly address: Address = '0x00000000000000000000000000000000000fac17';
  sent: SettlementCall[] = [];
  onChain = new Map<Hex, { outcome: SettlementOutcome; terms: SettlementExpectation & { payer: Address } }>();
  fail: Error | null = null;
  private counter = 0;

  async execute(
    call: SettlementCall,
    expected: SettlementExpectation & { id: Hex },
  ): Promise<SettlementOutcome> {
    this.sent.push(call);
    await new Promise((resolve) => setTimeout(resolve, 5));
    if (this.fail !== null) throw this.fail;
    const outcome: SettlementOutcome = {
      transaction: `0x${(++this.counter).toString(16).padStart(64, '0')}`,
      id: expected.id,
      payer: expected.payer ?? payTo,
    };
    this.onChain.set(expected.id, { outcome, terms: { ...expected, payer: outcome.payer } });
    return outcome;
  }

  findExisting(expected: SettlementExpectation & { id: Hex }): Promise<SettlementOutcome | null> {
    const existing = this.onChain.get(expected.id);
    if (existing === undefined) return Promise.resolve(null);
    if (!termsMatch(existing.terms, expected)) {
      return Promise.reject(new SettlementMismatchError(`receipt ${expected.id} exists with other terms`));
    }
    return Promise.resolve(existing.outcome);
  }
}

describe('Facilitator', () => {
  const payer = newAccount();
  let chain: FakeChain;
  let writer: FakeWriter;
  let facilitator: Facilitator;
  let req: FacilitatorRequest;

  beforeEach(async () => {
    chain = new FakeChain();
    chain.balances.set(payer.address.toLowerCase(), 1_000_000n);
    writer = new FakeWriter();
    facilitator = new Facilitator({ deployment, reader: chain, writer });
    const payload = await buildExactPayment(context(requirements('exact')), payer);
    req = { x402Version: 2, paymentPayload: payload, paymentRequirements: payload.accepted };
  });

  it('advertises its schemes, network and signer', () => {
    const supported = facilitator.supported();
    expect(supported.kinds.map((k) => k.scheme)).toEqual(['exact', 'budget-exec', 'escrow']);
    expect(supported.kinds.every((k) => k.network === 'eip155:31337')).toBe(true);
    expect(supported.signers['eip155:31337']).toEqual([writer.address]);
  });

  it('settles once and returns the receipt id', async () => {
    const response = await facilitator.settle(req);
    expect(response).toMatchObject({
      success: true,
      payer: payer.address,
      network: 'eip155:31337',
      amount: PRICE.toString(),
    });
    expect(response.extensions?.receiptId).toMatch(/^0x[0-9a-f]{64}$/);
    expect(writer.sent).toHaveLength(1);
    expect(facilitator.transactionsSent).toBe(1);
  });

  it('is idempotent under concurrent and repeated settle calls', async () => {
    const [a, b, c] = await Promise.all([
      facilitator.settle(req),
      facilitator.settle(req),
      facilitator.settle(req),
    ]);
    const d = await facilitator.settle(req);
    expect(new Set([a.transaction, b.transaction, c.transaction, d.transaction]).size).toBe(1);
    expect(writer.sent).toHaveLength(1);
  });

  it('keeps nothing once a settlement is over: repeated calls are answered from the chain', async () => {
    const first = await facilitator.settle(req);
    expect(facilitator.pendingSettlements).toBe(0);
    const again = await facilitator.settle(req);
    expect(again.transaction).toBe(first.transaction);
    expect(writer.sent).toHaveLength(1);
    expect(facilitator.pendingSettlements).toBe(0);
  });

  it('refuses to report an on-chain settlement of the same nonce with other terms', async () => {
    // The payer signed a second authorization with the same nonce but another amount; that one was settled.
    const settled = await facilitator.settle(req);
    const entry = writer.onChain.get(settled.extensions?.receiptId as Hex);
    if (entry === undefined) throw new Error('not settled');
    writer.onChain.set(entry.outcome.id, { ...entry, terms: { ...entry.terms, amount: 1n } });
    expect(await facilitator.settle(req)).toMatchObject({
      success: false,
      errorReason: 'nonce_already_used_mismatch',
      transaction: '',
    });
    expect(writer.sent).toHaveLength(1);
  });

  it('reports unexpected errors while looking for an existing settlement', async () => {
    writer.findExisting = () => Promise.reject(new Error('rpc down'));
    expect(await facilitator.settle(req)).toMatchObject({
      success: false,
      errorReason: 'unexpected_settle_error:rpc down',
    });
  });

  it('answers from the chain after a restart instead of re-submitting', async () => {
    const first = await facilitator.settle(req);
    const restarted = new Facilitator({ deployment, reader: chain, writer });
    const again = await restarted.settle(req);
    expect(again.transaction).toBe(first.transaction);
    expect(restarted.transactionsSent).toBe(0);
    expect(writer.sent).toHaveLength(1);
  });

  it('does not cache failures, so a fixed payment can be retried', async () => {
    chain.balances.set(payer.address.toLowerCase(), 0n);
    expect(await facilitator.settle(req)).toMatchObject({
      success: false,
      errorReason: 'insufficient_funds',
    });
    chain.balances.set(payer.address.toLowerCase(), PRICE);
    expect((await facilitator.settle(req)).success).toBe(true);
  });

  it('reports settlement transaction failures', async () => {
    writer.fail = new Error('boom');
    expect(await facilitator.settle(req)).toMatchObject({
      success: false,
      errorReason: 'settlement_failed:boom',
    });
  });

  it('rejects mismatched requests without touching the chain', async () => {
    const response = await facilitator.settle({
      ...req,
      paymentRequirements: { ...req.paymentRequirements, amount: '1' },
    });
    expect(response).toMatchObject({
      success: false,
      errorReason: 'invalid_payment_requirements',
      transaction: '',
    });
    expect(writer.sent).toHaveLength(0);
  });

  it('verifies over HTTP and rejects malformed bodies', async () => {
    const app = createFacilitatorApp(facilitator);
    const post = (path: string, body: string) =>
      app.request(path, { method: 'POST', body, headers: { 'content-type': 'application/json' } });

    const ok = await post('/verify', JSON.stringify(req));
    expect(ok.status).toBe(200);
    expect(await ok.json()).toEqual({ isValid: true, payer: payer.address });

    const bad = await post('/verify', '{"x402Version":2}');
    expect(bad.status).toBe(400);
    expect(await bad.json()).toEqual({ isValid: false, invalidReason: 'invalid_payload' });

    const notJson = await post('/settle', 'nope');
    expect(notJson.status).toBe(400);

    const settled = await post('/settle', JSON.stringify(req));
    expect(((await settled.json()) as { success: boolean }).success).toBe(true);

    expect((await app.request('/supported')).status).toBe(200);
    expect(await (await app.request('/healthz')).json()).toEqual({ ok: true });
    const huge = await post('/verify', JSON.stringify({ pad: 'x'.repeat(70 * 1024) }));
    expect(huge.status).toBe(413);
    expect(encodeHeader(req).length).toBeGreaterThan(0);
  });

  it('returns invalid reasons from /verify with the payer when known', async () => {
    chain.balances.set(payer.address.toLowerCase(), 0n);
    expect(await facilitator.verify(req)).toEqual({
      isValid: false,
      invalidReason: 'insufficient_funds',
      payer: payer.address,
    });
    expect(
      await facilitator.verify({ ...req, paymentRequirements: { ...req.paymentRequirements, network: 'x' } }),
    ).toEqual({
      isValid: false,
      invalidReason: 'invalid_payment_requirements',
    });
  });
});

describe('matchSettlementLogs (how servers and agents check a facilitator claim)', () => {
  const payer: Address = getAddress('0x00000000000000000000000000000000000000a1');
  const receiptId: Hex = `0x${'11'.repeat(32)}`;

  function receiptLog(
    emitter: Address,
    overrides: Partial<{ payee: Address; amount: bigint; resourceHash: Hex }> = {},
  ): Log {
    const topics = encodeEventTopics({
      abi: settlementLogAbi,
      eventName: 'ReceiptRecorded',
      args: { receiptId, payer, payee: overrides.payee ?? payTo },
    });
    return {
      address: emitter,
      topics: topics as [Hex, ...Hex[]],
      data: encodeAbiParameters(
        [{ type: 'uint8' }, { type: 'uint256' }, { type: 'bytes32' }],
        [1, overrides.amount ?? PRICE, overrides.resourceHash ?? RESOURCE_HASH],
      ),
      blockHash: `0x${'00'.repeat(32)}`,
      blockNumber: 1n,
      logIndex: 0,
      transactionHash: `0x${'22'.repeat(32)}`,
      transactionIndex: 0,
      removed: false,
    };
  }

  const expected: SettlementExpectation = {
    kind: 'receipt',
    payee: payTo,
    amount: PRICE,
    resourceHash: RESOURCE_HASH,
  };

  it('accepts the genuine event', () => {
    expect(
      matchSettlementLogs([receiptLog(deployment.settlementLog)], deployment, {
        ...expected,
        payer,
        id: receiptId,
      }),
    ).toEqual({
      transaction: `0x${'22'.repeat(32)}`,
      id: receiptId,
      payer,
    });
  });

  it('rejects look-alike events from another contract (a facilitator-deployed fake log)', () => {
    expect(matchSettlementLogs([receiptLog(payTo)], deployment, expected)).toBeNull();
  });

  it('rejects events for another payee, amount, resource, payer or id', () => {
    const log = deployment.settlementLog;
    expect(matchSettlementLogs([receiptLog(log, { payee: payer })], deployment, expected)).toBeNull();
    expect(matchSettlementLogs([receiptLog(log, { amount: PRICE - 1n })], deployment, expected)).toBeNull();
    expect(
      matchSettlementLogs([receiptLog(log, { resourceHash: `0x${'33'.repeat(32)}` })], deployment, expected),
    ).toBeNull();
    expect(matchSettlementLogs([receiptLog(log)], deployment, { ...expected, payer: payTo })).toBeNull();
    expect(
      matchSettlementLogs([receiptLog(log)], deployment, { ...expected, id: `0x${'44'.repeat(32)}` }),
    ).toBeNull();
  });

  it('matches escrow openings only from the escrow contract', () => {
    const escrowId: Hex = `0x${'55'.repeat(32)}`;
    const topics = encodeEventTopics({
      abi: paymentEscrowAbi,
      eventName: 'EscrowOpened',
      args: { escrowId, payer, payee: payTo },
    });
    const base: Log = {
      address: deployment.paymentEscrow,
      topics: topics as [Hex, ...Hex[]],
      data: encodeAbiParameters(
        [{ type: 'uint256' }, { type: 'bytes32' }, { type: 'uint64' }],
        [PRICE, RESOURCE_HASH, 123n],
      ),
      blockHash: `0x${'00'.repeat(32)}`,
      blockNumber: 1n,
      logIndex: 0,
      transactionHash: `0x${'66'.repeat(32)}`,
      transactionIndex: 0,
      removed: false,
    };
    const escrowExpected: SettlementExpectation = { ...expected, kind: 'escrow' };
    expect(matchSettlementLogs([base], deployment, escrowExpected)?.id).toBe(escrowId);
    expect(matchSettlementLogs([{ ...base, address: payTo }], deployment, escrowExpected)).toBeNull();
    expect(matchSettlementLogs([base], deployment, { ...escrowExpected, amount: 1n })).toBeNull();
  });
});
