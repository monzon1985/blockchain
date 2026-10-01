// SPDX-License-Identifier: MIT
import { keccak256, toBytes } from 'viem';
import { describe, expect, it } from 'vitest';
import {
  ESCROW_BINDING_TAG,
  EXACT_BINDING_TAG,
  canonicalResource,
  escrowNonce,
  exactNonce,
  hasZeroSequence,
  randomBytes32,
  resourceHash,
} from '../src/x402/resource.js';

describe('canonical resources', () => {
  it('covers method, origin, path, sorted query and body hash', () => {
    const canonical = canonicalResource({
      method: 'post',
      url: 'http://127.0.0.1:4021/api/v1/sentiment?b=2&a=1&a=0#frag',
      body: '{"text":"hi"}',
    });
    // Fragment dropped, query sorted by key then value, method upper-cased; the body hash is checked below.
    expect(canonical).toMatch(
      /^POST http:\/\/127\.0\.0\.1:4021\/api\/v1\/sentiment\?a=0&a=1&b=2#sha256=[0-9a-f]{64}$/,
    );
  });

  it('matches an independent SHA-256 of the body', async () => {
    const { createHash } = await import('node:crypto');
    const body = '{"text":"hi"}';
    const expected = createHash('sha256').update(body).digest('hex');
    expect(canonicalResource({ method: 'POST', url: 'http://h/p', body })).toBe(
      `POST http://h/p#sha256=${expected}`,
    );
  });

  it('distinguishes bodies, paths, queries, methods and servers', () => {
    const base = { method: 'POST', url: 'http://127.0.0.1:1/api/v1/sentiment', body: '{"text":"a"}' };
    const variants = [
      base,
      { ...base, body: '{"text":"b"}' },
      { ...base, url: 'http://127.0.0.1:1/api/v1/keywords' },
      { ...base, url: 'http://127.0.0.1:1/api/v1/sentiment?x=1' },
      { ...base, method: 'PUT' },
      { ...base, url: 'http://127.0.0.1:2/api/v1/sentiment' },
    ];
    const hashes = new Set(variants.map(resourceHash));
    expect(hashes.size).toBe(variants.length);
  });

  it('is insensitive to query parameter order and hashes an empty body', () => {
    expect(resourceHash({ method: 'GET', url: 'http://h/p?a=1&b=2' })).toBe(
      resourceHash({ method: 'GET', url: 'http://h/p?b=2&a=1' }),
    );
    expect(canonicalResource({ method: 'GET', url: 'http://h/p' })).toBe(
      'GET http://h/p#sha256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
  });

  it('accepts binary bodies', () => {
    expect(resourceHash({ method: 'POST', url: 'http://h/p', body: new TextEncoder().encode('x') })).toBe(
      resourceHash({ method: 'POST', url: 'http://h/p', body: 'x' }),
    );
  });
});

describe('nonce commitments', () => {
  it('uses the same domain tags as ResourceBinding.sol', () => {
    expect(EXACT_BINDING_TAG).toBe(keccak256(toBytes('x402-local/exact/resource-binding/v1')));
    expect(ESCROW_BINDING_TAG).toBe(keccak256(toBytes('x402-local/escrow/terms-binding/v1')));
  });

  it('always yields sequence 0 of a non-zero 192-bit key', () => {
    for (let i = 0; i < 200; i++) {
      const nonce = exactNonce(randomBytes32(), randomBytes32());
      expect(hasZeroSequence(nonce)).toBe(true);
      expect(BigInt(nonce) >> 64n).not.toBe(0n);
    }
  });

  it('changes with any committed field', () => {
    const r = randomBytes32();
    const s = randomBytes32();
    const payee = '0x00000000000000000000000000000000000000aa';
    expect(exactNonce(r, s)).not.toBe(exactNonce(randomBytes32(), s));
    expect(exactNonce(r, s)).not.toBe(exactNonce(r, randomBytes32()));
    const e = escrowNonce(payee, r, 100n, s);
    expect(hasZeroSequence(e)).toBe(true);
    expect(e).not.toBe(escrowNonce('0x00000000000000000000000000000000000000bb', r, 100n, s));
    expect(e).not.toBe(escrowNonce(payee, r, 101n, s));
    expect(e).not.toBe(exactNonce(r, s));
  });

  it('detects a non-zero sequence', () => {
    expect(hasZeroSequence(`0x${'11'.repeat(24)}${'00'.repeat(7)}01`)).toBe(false);
  });
});
