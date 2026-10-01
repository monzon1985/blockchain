// SPDX-License-Identifier: MIT
import { describe, expect, it } from 'vitest';
import { selectRequirements, type ChallengeContext, type ClientPolicy } from '../src/policy/clientPolicy.js';
import type { PaymentRequired, PaymentRequirements } from '../src/x402/types.js';
import { REQUEST, RESOURCE_HASH, deployment, payTo, requirements } from './fixtures.js';

const policy: ClientPolicy = { maxPricePerCall: 50_000n, schemes: ['budget-exec', 'exact'] };
const ctx: ChallengeContext = {
  deployment,
  expectedPayTo: payTo,
  expectedResourceHash: RESOURCE_HASH,
  requestUrl: REQUEST.url,
};

function challenge(...accepts: PaymentRequirements[]): PaymentRequired {
  return { x402Version: 2, resource: { url: REQUEST.url }, accepts };
}

describe('client acceptance policy', () => {
  it('picks the preferred scheme among acceptable offers', () => {
    const decision = selectRequirements(
      challenge(requirements('exact'), requirements('budget-exec')),
      policy,
      ctx,
    );
    expect(decision).toEqual({ ok: true, requirements: requirements('budget-exec') });
  });

  it('falls back to the next scheme', () => {
    const decision = selectRequirements(challenge(requirements('exact')), policy, ctx);
    expect(decision.ok && decision.requirements.scheme).toBe('exact');
  });

  it.each<[string, Partial<PaymentRequirements>, string]>([
    ['another network', { network: 'eip155:1' }, 'wrong_network'],
    ['an unknown asset', { asset: '0x0000000000000000000000000000000000009999' }, 'unknown_asset'],
    [
      'a payTo that is not the registered wallet',
      { payTo: '0x0000000000000000000000000000000000000bad' },
      'payto_not_registered_wallet',
    ],
    ['a price above the client cap', { amount: '50001' }, 'price_above_client_cap'],
    ['a zero price', { amount: '0' }, 'zero_price'],
  ])('refuses %s', (_label, override, reason) => {
    const decision = selectRequirements(challenge({ ...requirements('exact'), ...override }), policy, ctx);
    expect(decision).toEqual({ ok: false, reason });
  });

  it('refuses authorizations that would stay valid longer than the client allows', () => {
    const long = { ...requirements('exact'), maxTimeoutSeconds: 86_400 };
    expect(selectRequirements(challenge(long), policy, ctx)).toEqual({
      ok: false,
      reason: 'authorization_window_too_long',
    });
    // The default bound is 300 s; a policy can tighten or relax it.
    const at300 = { ...requirements('exact'), maxTimeoutSeconds: 300 };
    expect(selectRequirements(challenge(at300), policy, ctx).ok).toBe(true);
    expect(selectRequirements(challenge(at300), { ...policy, maxAuthorizationSeconds: 60 }, ctx)).toEqual({
      ok: false,
      reason: 'authorization_window_too_long',
    });
    expect(selectRequirements(challenge(long), { ...policy, maxAuthorizationSeconds: 86_400 }, ctx).ok).toBe(
      true,
    );
  });

  it('refuses escrows whose delivery window would lock funds longer than the client allows', () => {
    const e = requirements('escrow');
    const escrowPolicy: ClientPolicy = { ...policy, schemes: ['escrow'] };
    const month = { ...e, extra: { ...e.extra, deliveryWindowSeconds: 30 * 86_400 } };
    expect(selectRequirements(challenge(month), escrowPolicy, ctx)).toEqual({
      ok: false,
      reason: 'delivery_window_too_long',
    });
    expect(selectRequirements(challenge(e), escrowPolicy, ctx).ok).toBe(true);
    expect(
      selectRequirements(challenge(month), { ...escrowPolicy, maxDeliveryWindowSeconds: 30 * 86_400 }, ctx)
        .ok,
    ).toBe(true);
  });

  it('refuses unknown settlement contracts', () => {
    const r = requirements('exact');
    const tampered = {
      ...r,
      extra: { ...r.extra, settlementLog: '0x0000000000000000000000000000000000000bad' },
    };
    expect(selectRequirements(challenge(tampered), policy, ctx)).toEqual({
      ok: false,
      reason: 'unknown_settlement_contract',
    });
    const b = requirements('budget-exec');
    expect(
      selectRequirements(challenge({ ...b, extra: { ...b.extra, budgetExecutor: payTo } }), policy, ctx),
    ).toEqual({ ok: false, reason: 'unknown_settlement_contract' });
    const e = requirements('escrow');
    expect(
      selectRequirements(
        challenge({ ...e, extra: { ...e.extra, escrow: payTo } }),
        { ...policy, schemes: ['escrow'] },
        ctx,
      ),
    ).toEqual({ ok: false, reason: 'unknown_settlement_contract' });
  });

  it('refuses a resource hash the agent did not compute (server binding the payment elsewhere)', () => {
    const other = requirements('exact', `0x${'77'.repeat(32)}`);
    expect(selectRequirements(challenge(other), policy, ctx)).toEqual({
      ok: false,
      reason: 'resource_hash_mismatch',
    });
  });

  it('refuses a challenge for another URL and unsupported schemes', () => {
    expect(
      selectRequirements(
        { ...challenge(requirements('exact')), resource: { url: 'http://evil/x' } },
        policy,
        ctx,
      ),
    ).toEqual({
      ok: false,
      reason: 'resource_url_mismatch',
    });
    expect(selectRequirements(challenge(requirements('escrow')), policy, ctx)).toEqual({
      ok: false,
      reason: 'no_supported_scheme',
    });
    expect(
      selectRequirements(
        challenge({ ...requirements('exact'), scheme: 'upto' }),
        { ...policy, schemes: ['exact'] },
        ctx,
      ),
    ).toEqual({ ok: false, reason: 'no_supported_scheme' });
  });
});
