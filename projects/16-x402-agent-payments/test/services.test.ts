// SPDX-License-Identifier: MIT
import { encodePacked, keccak256, toBytes, type Hex } from 'viem';
import { describe, expect, it } from 'vitest';
import {
  canonicalJson,
  executeService,
  keywords,
  merkleReport,
  resultHash,
  sentiment,
} from '../src/server/services.js';
import { scoreOutputs } from '../src/validator/validator.js';
import { decodeAgentUri, encodeAgentUri } from '../src/agent/discovery.js';

describe('sentiment', () => {
  it('scores positive, negative and neutral text', () => {
    expect(sentiment({ text: 'Fast, reliable and secure.' })).toEqual({
      label: 'positive',
      scoreBps: 10_000,
      positive: 3,
      negative: 0,
      tokens: 4,
    });
    expect(sentiment({ text: 'slow and buggy' }).label).toBe('negative');
    expect(sentiment({ text: 'the sky is blue' })).toMatchObject({ label: 'neutral', scoreBps: 0 });
  });

  it('applies one-word negation', () => {
    expect(sentiment({ text: 'not good' })).toMatchObject({ positive: 0, negative: 1, label: 'negative' });
    expect(sentiment({ text: 'never bad' })).toMatchObject({ positive: 1, negative: 0 });
  });

  it('is deterministic', () => {
    const input = { text: 'Great latency, stable throughput, but the SDK is buggy.' };
    expect(canonicalJson(sentiment(input))).toBe(canonicalJson(sentiment(input)));
  });
});

describe('keywords', () => {
  it('ranks by frequency then alphabetically and drops stopwords', () => {
    const out = keywords({ text: 'agents pay agents; the settlement settles settlement for agents', k: 2 });
    expect(out.keywords).toEqual([
      { term: 'agents', count: 3 },
      { term: 'settlement', count: 2 },
    ]);
    expect(out.distinctTerms).toBe(4);
  });

  it('defaults k to 5 and validates input', () => {
    expect(keywords({ text: 'one two three four five six seven' }).keywords).toHaveLength(5);
    expect(() => keywords({ text: 'x', k: 0 })).toThrow();
  });
});

describe('merkle report', () => {
  const leaf = (s: string): Hex => keccak256(toBytes(s));
  const pair = (a: Hex, b: Hex): Hex =>
    BigInt(a) < BigInt(b)
      ? keccak256(encodePacked(['bytes32', 'bytes32'], [a, b]))
      : keccak256(encodePacked(['bytes32', 'bytes32'], [b, a]));

  it('uses sorted-pair hashing and promotes odd nodes', () => {
    expect(merkleReport({ items: ['a'] }).root).toBe(leaf('a'));
    expect(merkleReport({ items: ['a', 'b'] }).root).toBe(pair(leaf('a'), leaf('b')));
    expect(merkleReport({ items: ['a', 'b', 'c'] })).toEqual({
      algorithm: 'keccak256-sorted-pairs',
      leafCount: 3,
      root: pair(pair(leaf('a'), leaf('b')), leaf('c')),
    });
  });

  it('is order-sensitive at the leaf level only through pairing', () => {
    expect(merkleReport({ items: ['a', 'b'] }).root).toBe(merkleReport({ items: ['b', 'a'] }).root);
  });
});

describe('canonical JSON and re-execution', () => {
  it('sorts keys, drops undefined and hashes stably', () => {
    expect(canonicalJson({ b: 1, a: [2, { d: undefined, c: 'x' }] })).toBe('{"a":[2,{"c":"x"}],"b":1}');
    expect(resultHash({ b: 1, a: 2 })).toBe(resultHash({ a: 2, b: 1 }));
  });

  it('dispatches by service id', () => {
    expect(executeService('sentiment', { text: 'good' })).toEqual(sentiment({ text: 'good' }));
    expect(executeService('keywords', { text: 'alpha beta alpha' })).toEqual(
      keywords({ text: 'alpha beta alpha' }),
    );
    expect(executeService('merkle-report', { items: ['x'] })).toEqual(merkleReport({ items: ['x'] }));
    expect(() => executeService('sentiment', { text: '' })).toThrow();
  });
});

describe('validator scoring', () => {
  const honest = sentiment({ text: 'fast and secure' });

  it('gives 100 only to byte-identical output', () => {
    expect(scoreOutputs(honest, honest)).toBe(100);
    expect(scoreOutputs({ ...honest, scoreBps: 1 }, honest)).toBe(80);
    expect(scoreOutputs({ ...honest, scoreBps: 1, label: 'negative' }, honest)).toBe(60);
  });

  it('never gives 100 to a partial match and 0 to garbage', () => {
    expect(scoreOutputs({ ...honest, extra: true }, honest)).toBe(99);
    expect(scoreOutputs('nonsense', honest)).toBe(0);
    expect(scoreOutputs([1, 2], honest)).toBe(0);
    expect(scoreOutputs({}, {})).toBe(100);
    expect(scoreOutputs({ a: 1 }, {})).toBe(0);
  });
});

describe('agent card data URIs', () => {
  const card = {
    type: 'https://eips.ethereum.org/EIPS/eip-8004#registration-v1',
    name: 'svc',
    services: [{ name: 'x402', endpoint: 'http://127.0.0.1:1' }],
    x402Support: true,
  };

  it('round-trips', () => {
    expect(decodeAgentUri(encodeAgentUri(card))).toMatchObject(card);
  });

  it('rejects other schemes and malformed content', () => {
    expect(decodeAgentUri('ipfs://bafy')).toBeNull();
    expect(decodeAgentUri('data:application/json;base64,bm90IGpzb24=')).toBeNull();
    expect(decodeAgentUri(encodeAgentUri({ name: 'missing fields' }))).toBeNull();
  });
});
