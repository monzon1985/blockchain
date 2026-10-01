// SPDX-License-Identifier: MIT
import type { Hex } from 'viem';
import { beforeEach, describe, expect, it } from 'vitest';
import { buildBudgetPayment, buildEscrowPayment, buildExactPayment } from '../src/agent/payments.js';
import { preparePayment, requirementsMatch, verifyPayment } from '../src/facilitator/verify.js';
import { exactNonce } from '../src/x402/resource.js';
import type { FacilitatorRequest, PaymentPayload, PaymentRequirements } from '../src/x402/types.js';
import {
  FakeChain,
  NOW,
  PRICE,
  context,
  deployment,
  newAccount,
  payTo,
  requirements,
  smartAccount,
} from './fixtures.js';

function request(payload: PaymentPayload, req: PaymentRequirements = payload.accepted): FacilitatorRequest {
  return { x402Version: 2, paymentPayload: payload, paymentRequirements: req };
}

/** Returns a copy of `payload` with `mutate` applied to its scheme payload. */
function tamper(payload: PaymentPayload, mutate: (p: Record<string, any>) => void): PaymentPayload {
  const copy = structuredClone(payload);
  mutate(copy.payload as Record<string, any>);
  return copy;
}

async function reason(req: FacilitatorRequest, chain: FakeChain): Promise<string | undefined> {
  const result = await verifyPayment(req, deployment, chain);
  return result.isValid ? undefined : result.invalidReason;
}

describe('exact scheme verification', () => {
  const payer = newAccount();
  let chain: FakeChain;
  let payload: PaymentPayload;

  beforeEach(async () => {
    chain = new FakeChain();
    chain.balances.set(payer.address.toLowerCase(), 1_000_000n);
    payload = await buildExactPayment(context(requirements('exact')), payer);
  });

  it('accepts a well-formed payment and simulates the exact settlement call', async () => {
    const result = await verifyPayment(request(payload), deployment, chain);
    expect(result.isValid).toBe(true);
    expect(chain.simulated[0]?.kind).toBe('exact');
    if (result.isValid) {
      expect(result.payment.payer).toBe(payer.address);
      expect(result.payment.expected).toMatchObject({ kind: 'receipt', payee: payTo, amount: PRICE });
    }
  });

  it('rejects a tampered amount, payee or resource salt', async () => {
    expect(await reason(request(tamper(payload, (p) => (p.authorization.value = '20000'))), chain)).toBe(
      'invalid_exact_evm_payload_authorization_value_mismatch',
    );
    expect(
      await reason(
        request(tamper(payload, (p) => (p.authorization.to = '0x0000000000000000000000000000000000000bad'))),
        chain,
      ),
    ).toBe('invalid_exact_evm_payload_recipient_mismatch');
    expect(
      await reason(request(tamper(payload, (p) => (p.resourceSalt = `0x${'00'.repeat(32)}`))), chain),
    ).toBe('invalid_resource_binding');
  });

  it('rejects a nonce re-derived for another resource (signature no longer matches)', async () => {
    const forged = tamper(payload, (p) => {
      p.authorization.nonce = exactNonce(`0x${'42'.repeat(32)}`, p.resourceSalt as Hex);
    });
    const otherReq = requirements('exact', `0x${'42'.repeat(32)}`);
    forged.accepted = otherReq;
    expect(await reason(request(forged, otherReq), chain)).toBe('invalid_exact_evm_payload_signature');
  });

  it('rejects a signature by someone else', async () => {
    const other = await buildExactPayment(context(requirements('exact')), newAccount());
    const mixed = tamper(payload, (p) => (p.signature = (other.payload as { signature: string }).signature));
    expect(await reason(request(mixed), chain)).toBe('invalid_exact_evm_payload_signature');
  });

  it('rejects expired, not-yet-valid and over-long authorizations', async () => {
    chain.timestamp = NOW + 200n;
    expect(await reason(request(payload), chain)).toBe(
      'invalid_exact_evm_payload_authorization_valid_before',
    );
    chain.timestamp = NOW - 100n;
    expect(await reason(request(payload), chain)).toBe('invalid_exact_evm_payload_authorization_valid_after');
    chain.timestamp = NOW;
    const longLived = await buildExactPayment(
      context({ ...requirements('exact'), maxTimeoutSeconds: 86_400 }),
      payer,
    );
    expect(await reason(request(longLived, requirements('exact')), chain)).toBe(
      'invalid_payment_requirements',
    );
    expect(await reason(request({ ...longLived, accepted: requirements('exact') }), chain)).toBe(
      'invalid_exact_evm_payload_authorization_valid_before',
    );
  });

  it('rejects used nonces, insufficient balance and failing simulations', async () => {
    const auth = (payload.payload as { authorization: { nonce: Hex } }).authorization;
    chain.usedAuthorizations.add(`${payer.address.toLowerCase()}:${auth.nonce}`);
    expect(await reason(request(payload), chain)).toBe('nonce_already_used');
    chain.usedAuthorizations.clear();
    chain.balances.set(payer.address.toLowerCase(), PRICE - 1n);
    expect(await reason(request(payload), chain)).toBe('insufficient_funds');
    chain.balances.set(payer.address.toLowerCase(), PRICE);
    chain.simulation = { ok: false, reason: 'ERC3009InvalidSignature' };
    expect(await reason(request(payload), chain)).toBe('simulation_failed:ERC3009InvalidSignature');
  });

  it('rejects requirement mismatches and foreign contracts', async () => {
    expect(await reason(request(payload, { ...requirements('exact'), amount: '1' }), chain)).toBe(
      'invalid_payment_requirements',
    );
    const foreignLog = requirements('exact');
    const foreign = { ...foreignLog, extra: { ...foreignLog.extra, settlementLog: payTo } };
    expect(await reason(request({ ...payload, accepted: foreign }, foreign), chain)).toBe(
      'invalid_payment_requirements',
    );
    const otherAsset = { ...requirements('exact'), asset: payTo };
    expect(await reason(request({ ...payload, accepted: otherAsset }, otherAsset), chain)).toBe(
      'invalid_payment_requirements',
    );
    const otherNetwork = { ...requirements('exact'), network: 'eip155:8453' };
    expect(await reason(request({ ...payload, accepted: otherNetwork }, otherNetwork), chain)).toBe(
      'invalid_network',
    );
    const unknown = { ...requirements('exact'), scheme: 'upto' };
    expect(await reason(request({ ...payload, accepted: unknown }, unknown), chain)).toBe(
      'unsupported_scheme',
    );
    const zero = { ...requirements('exact'), amount: '0' };
    expect(await reason(request({ ...payload, accepted: zero }, zero), chain)).toBe(
      'invalid_payment_requirements',
    );
    expect(await reason(request(tamper(payload, (p) => delete p.resourceSalt)), chain)).toBe(
      'invalid_payload',
    );
  });
});

describe('budget-exec scheme verification', () => {
  const session = newAccount();
  let chain: FakeChain;
  let payload: PaymentPayload;

  beforeEach(async () => {
    chain = new FakeChain();
    chain.installPolicy(session.address);
    payload = await buildBudgetPayment(context(requirements('budget-exec')), smartAccount, session);
  });

  it('accepts a session-key intent within policy', async () => {
    const result = await verifyPayment(request(payload), deployment, chain);
    expect(result.isValid).toBe(true);
    if (result.isValid) expect(result.payment.payer).toBe(smartAccount);
  });

  it('accepts a contract session key through ERC-1271', async () => {
    const contractKey = '0x0000000000000000000000000000000000c0ffee';
    chain.installPolicy(contractKey);
    chain.contractSigners.set(contractKey, session.address);
    expect((await verifyPayment(request(payload), deployment, chain)).isValid).toBe(true);
  });

  it.each<[string, (p: Record<string, any>) => void, string]>([
    [
      'payee',
      (p) => (p.intent.payee = '0x0000000000000000000000000000000000000bad'),
      'invalid_budget_exec_payee_mismatch',
    ],
    ['amount', (p) => (p.intent.amount = '9999'), 'invalid_budget_exec_amount_mismatch'],
    ['resource', (p) => (p.intent.resourceHash = `0x${'99'.repeat(32)}`), 'invalid_resource_binding'],
    ['nonce', (p) => (p.intent.nonce = `0x${'01'.repeat(32)}`), 'invalid_budget_exec_signature'],
    [
      'account',
      (p) => (p.intent.account = '0x000000000000000000000000000000000000acc1'),
      'budget_not_installed',
    ],
  ])('rejects a tampered %s', async (_field, mutate, expected) => {
    expect(await reason(request(tamper(payload, mutate)), chain)).toBe(expected);
  });

  it('enforces the on-chain policy state', async () => {
    const intentNonce = (payload.payload as { intent: { nonce: Hex } }).intent.nonce;
    chain.remaining.set(smartAccount.toLowerCase(), PRICE - 1n);
    expect(await reason(request(payload), chain)).toBe('budget_exhausted');
    chain.installPolicy(session.address);
    chain.usedIntentNonces.add(`${smartAccount.toLowerCase()}:${intentNonce}`);
    expect(await reason(request(payload), chain)).toBe('nonce_already_used');
    chain.usedIntentNonces.clear();
    chain.allowedPayees.clear();
    expect(await reason(request(payload), chain)).toBe('budget_payee_not_allowed');
    chain.installPolicy(session.address);
    chain.balances.set(smartAccount.toLowerCase(), 0n);
    expect(await reason(request(payload), chain)).toBe('insufficient_funds');
    chain.installPolicy(session.address);
    chain.policies.set(smartAccount.toLowerCase(), {
      sessionKey: session.address,
      validUntil: NOW - 1n,
      perCallCap: 50_000n,
      periodBudget: 100_000n,
    });
    expect(await reason(request(payload), chain)).toBe('budget_session_expired');
    chain.policies.set(smartAccount.toLowerCase(), {
      sessionKey: session.address,
      validUntil: NOW + 1n,
      perCallCap: PRICE - 1n,
      periodBudget: 100_000n,
    });
    expect(await reason(request(payload), chain)).toBe('budget_per_call_cap_exceeded');
  });

  it('rejects an intent whose window is over', async () => {
    chain.timestamp = NOW + 500n;
    expect(await reason(request(payload), chain)).toBe('invalid_budget_exec_intent_valid_before');
  });

  it('rejects foreign executors and malformed payloads', async () => {
    const r = requirements('budget-exec');
    const foreign = { ...r, extra: { ...r.extra, budgetExecutor: payTo } };
    expect(await reason(request({ ...payload, accepted: foreign }, foreign), chain)).toBe(
      'invalid_payment_requirements',
    );
    expect(await reason(request(tamper(payload, (p) => delete p.intent)), chain)).toBe('invalid_payload');
  });
});

describe('escrow scheme verification', () => {
  const payer = newAccount();
  let chain: FakeChain;
  let payload: PaymentPayload;

  beforeEach(async () => {
    chain = new FakeChain();
    chain.balances.set(payer.address.toLowerCase(), 1_000_000n);
    payload = await buildEscrowPayment(context(requirements('escrow')), payer);
  });

  it('accepts a receive-authorization bound to the escrow terms', async () => {
    const result = await verifyPayment(request(payload), deployment, chain);
    expect(result.isValid).toBe(true);
    if (result.isValid) expect(result.payment.expected.kind).toBe('escrow');
  });

  it.each<[string, (p: Record<string, any>) => void, string]>([
    [
      'escrow contract',
      (p) => (p.authorization.to = '0x0000000000000000000000000000000000000bad'),
      'invalid_escrow_contract',
    ],
    [
      'payee',
      (p) => (p.escrow.payee = '0x0000000000000000000000000000000000000bad'),
      'invalid_escrow_payee_mismatch',
    ],
    ['value', (p) => (p.authorization.value = '1'), 'invalid_escrow_value_mismatch'],
    ['resource', (p) => (p.escrow.resourceHash = `0x${'99'.repeat(32)}`), 'invalid_resource_binding'],
    ['deadline', (p) => (p.escrow.deliveryDeadline = String(NOW + 601n)), 'invalid_resource_binding'],
    ['salt', (p) => (p.escrow.salt = `0x${'00'.repeat(32)}`), 'invalid_resource_binding'],
  ])('rejects a tampered %s', async (_field, mutate, expected) => {
    expect(await reason(request(tamper(payload, mutate)), chain)).toBe(expected);
  });

  it('rejects a deadline outside the promised delivery window and a foreign signature', async () => {
    const late = await buildEscrowPayment(context(requirements('escrow'), NOW + 1_000n), payer);
    expect(await reason(request(late), chain)).toBe('invalid_escrow_authorization_valid_after');
    chain.timestamp = NOW + 100n;
    const early = await buildEscrowPayment(context(requirements('escrow'), NOW), payer);
    chain.timestamp = NOW + 700n;
    expect(await reason(request(early), chain)).toBe('invalid_escrow_authorization_valid_before');
    chain.timestamp = NOW;
    const foreign = await buildEscrowPayment(context(requirements('escrow')), newAccount());
    const mixed = tamper(
      payload,
      (p) => (p.signature = (foreign.payload as { signature: string }).signature),
    );
    expect(await reason(request(mixed), chain)).toBe('invalid_escrow_signature');
  });

  it('rejects when the escrow deadline is beyond the window the server offered', async () => {
    const r = requirements('escrow');
    const tight = { ...r, extra: { ...r.extra, deliveryWindowSeconds: 60 } };
    const p = await buildEscrowPayment(context(r), payer);
    expect(await reason(request({ ...p, accepted: tight }, tight), chain)).toBe('invalid_escrow_deadline');
  });

  it('rejects used nonces and insufficient funds', async () => {
    const nonce = (payload.payload as { authorization: { nonce: Hex } }).authorization.nonce;
    chain.usedAuthorizations.add(`${payer.address.toLowerCase()}:${nonce}`);
    expect(await reason(request(payload), chain)).toBe('nonce_already_used');
    chain.usedAuthorizations.clear();
    chain.balances.set(payer.address.toLowerCase(), 0n);
    expect(await reason(request(payload), chain)).toBe('insufficient_funds');
  });

  it('rejects foreign escrow contracts and malformed payloads', async () => {
    const r = requirements('escrow');
    const foreign = { ...r, extra: { ...r.extra, escrow: payTo } };
    expect(await reason(request({ ...payload, accepted: foreign }, foreign), chain)).toBe(
      'invalid_payment_requirements',
    );
    expect(await reason(request(tamper(payload, (p) => delete p.escrow)), chain)).toBe('invalid_payload');
  });
});

describe('requirementsMatch', () => {
  it('compares hex case-insensitively and everything else exactly', () => {
    const r = requirements('exact');
    const upper = {
      ...r,
      extra: {
        ...r.extra,
        resourceHash: (r.extra as { resourceHash: string }).resourceHash.toUpperCase().replace('0X', '0x'),
      },
    };
    expect(requirementsMatch(r, upper)).toBe(true);
    expect(requirementsMatch(r, { ...r, extra: { ...r.extra, name: 'testusd (local only)' } })).toBe(false);
    expect(requirementsMatch(r, { ...r, maxTimeoutSeconds: 121 })).toBe(false);
    expect(requirementsMatch({ ...r, extra: undefined }, { ...r, extra: undefined })).toBe(true);
  });

  it('prepares idempotency keys per payer and nonce', async () => {
    const payer = newAccount();
    const a = await buildExactPayment(context(requirements('exact')), payer);
    const b = await buildExactPayment(context(requirements('exact')), payer);
    const pa = preparePayment(request(a), deployment);
    const pb = preparePayment(request(b), deployment);
    expect(pa.isValid && pb.isValid && pa.payment.idempotencyKey !== pb.payment.idempotencyKey).toBe(true);
  });
});
