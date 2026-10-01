// SPDX-License-Identifier: MIT
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { getAddress, keccak256, toBytes, zeroAddress, type Address, type Hex } from 'viem';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { canonicalJson, sentiment } from '../src/server/services.js';
import {
  fileCursor,
  judgeWorkDocument,
  memoryCursor,
  originOf,
  readBody,
  type ValidationChainView,
} from '../src/validator/validator.js';
import { resourceHash } from '../src/x402/resource.js';
import { REQUEST } from './fixtures.js';

const ENDPOINT = new URL(REQUEST.url).origin;
const AGENT = 7n;
const wallet: Address = getAddress('0x000000000000000000000000000000000000beef');
const client: Address = getAddress('0x00000000000000000000000000000000000000a1');
const receiptId: Hex = `0x${'11'.repeat(32)}`;

interface Doc {
  service: string;
  resource: string;
  body: string;
  receiptId: string;
  output: unknown;
}

const honest: Doc = {
  service: 'sentiment',
  resource: REQUEST.url,
  body: REQUEST.body,
  receiptId,
  output: sentiment({ text: 'good' }),
};

/** Chain with one receipt: `client` paid `wallet` (the agent's wallet) for the honest request. */
function chainFor(paidRequest: { url: string; body: string } = REQUEST): ValidationChainView {
  return {
    receiptOf: (id) =>
      Promise.resolve(
        id === receiptId
          ? {
              payer: client,
              payee: wallet,
              settledAt: 100n,
              resourceHash: resourceHash({ method: 'POST', ...paidRequest }),
            }
          : { payer: zeroAddress, payee: zeroAddress, settledAt: 0n, resourceHash: `0x${'00'.repeat(32)}` },
      ),
    wasAgentWalletAt: (agentId, w) => Promise.resolve(agentId === AGENT && w === wallet),
  };
}

function judge(doc: Doc | string, chain = chainFor(), hash?: Hex) {
  const bytes = toBytes(typeof doc === 'string' ? doc : canonicalJson(doc));
  return judgeWorkDocument(bytes, hash ?? keccak256(bytes), AGENT, ENDPOINT, chain);
}

describe('judgeWorkDocument', () => {
  it('scores 100 when the paid request re-executes to the recorded output', async () => {
    expect(await judge(honest)).toMatchObject({ score: 100, reason: 'reproduced', service: 'sentiment' });
  });

  it('scores the share of agreeing fields when only the output was tampered with', async () => {
    const tampered = { ...honest, output: { ...(honest.output as object), label: 'negative', scoreBps: -1 } };
    expect(await judge(tampered)).toMatchObject({ score: 60, reason: 'output_differs' });
  });

  it('scores 0 for a document that does not hash to the request', async () => {
    expect(await judge(honest, chainFor(), `0x${'99'.repeat(32)}`)).toEqual({
      score: 0,
      reason: 'document_hash_mismatch',
    });
  });

  it.each([
    ['not JSON', 'not json at all'],
    ['unknown keys', canonicalJson({ ...honest, input: { text: 'x' } })],
    ['no receipt id', canonicalJson({ ...honest, receiptId: 'none' })],
  ])('scores 0 for a malformed document (%s)', async (_label, text) => {
    expect(await judge(text)).toEqual({ score: 0, reason: 'malformed_document' });
  });

  it('scores 0 for bytes that are not UTF-8', async () => {
    const bytes = new Uint8Array([0xff, 0xfe, 0x00]);
    expect(await judgeWorkDocument(bytes, keccak256(bytes), AGENT, ENDPOINT, chainFor())).toEqual({
      score: 0,
      reason: 'malformed_document',
    });
  });

  it('scores 0 when the resource is not the claimed service on the agent endpoint', async () => {
    expect(await judge({ ...honest, resource: 'http://elsewhere.example/api/v1/sentiment' })).toMatchObject({
      score: 0,
      reason: 'resource_not_agent_service',
    });
    expect(await judge({ ...honest, service: 'keywords' })).toMatchObject({
      score: 0,
      reason: 'resource_not_agent_service',
    });
  });

  it('scores 0 for a receipt that does not exist (fabricated work)', async () => {
    expect(await judge({ ...honest, receiptId: `0x${'ab'.repeat(32)}` })).toMatchObject({
      score: 0,
      reason: 'unknown_receipt',
    });
  });

  it('scores 0 for a receipt that did not pay this agent', async () => {
    const otherAgent: ValidationChainView = { ...chainFor(), wasAgentWalletAt: () => Promise.resolve(false) };
    expect(await judge(honest, otherAgent)).toMatchObject({ score: 0, reason: 'receipt_not_paid_to_agent' });
  });

  it('scores 0 when input and output were both fabricated for a real receipt', async () => {
    const fabricated = { ...honest, body: '{"text":"bad"}', output: sentiment({ text: 'bad' }) };
    expect(await judge(fabricated)).toMatchObject({ score: 0, reason: 'receipt_for_another_request' });
  });

  it('scores 0 when the paid input cannot be executed', async () => {
    const body = '{"text":""}';
    const doc = { ...honest, body, output: {} };
    expect(await judge(doc, chainFor({ url: REQUEST.url, body }))).toMatchObject({
      score: 0,
      reason: 'input_not_executable',
    });
  });
});

describe('document fetching helpers', () => {
  it('originOf accepts only http(s) URLs', () => {
    expect(originOf('http://127.0.0.1:1/x?y')).toBe('http://127.0.0.1:1');
    expect(originOf('https://a.example/p')).toBe('https://a.example');
    expect(originOf('file:///etc/passwd')).toBeNull();
    expect(originOf('not a url')).toBeNull();
  });

  it('readBody returns the bytes and enforces the size cap', async () => {
    expect(new TextDecoder().decode(await readBody(new Response('abc'), 3))).toBe('abc');
    expect(await readBody(new Response(null), 3)).toEqual(new Uint8Array());
    await expect(readBody(new Response('abcd'), 3)).rejects.toThrow('document_too_large');
    const declared = new Response('a', { headers: { 'content-length': '1000000' } });
    await expect(readBody(declared, 1024)).rejects.toThrow('document_too_large');
    const chunked = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(new Uint8Array(10));
          controller.enqueue(new Uint8Array(10));
          controller.close();
        },
      }),
    );
    await expect(readBody(chunked, 15)).rejects.toThrow('document_too_large');
  });
});

describe('block cursors', () => {
  let dir: string;

  beforeAll(async () => {
    dir = await mkdtemp(join(tmpdir(), 'x402-cursor-'));
  });

  afterAll(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it('memory cursor starts where told and remembers', async () => {
    const cursor = memoryCursor(5n);
    expect(await cursor.load()).toBe(5n);
    await cursor.save(9n);
    expect(await cursor.load()).toBe(9n);
  });

  it('file cursor survives a restart, starts at 0 without a file and rejects a corrupt one', async () => {
    const path = join(dir, 'nested', 'cursor.json');
    expect(await fileCursor(path).load()).toBe(0n);
    await fileCursor(path).save(1234n);
    expect(await fileCursor(path).load()).toBe(1234n);
    const corrupt = join(dir, 'corrupt.json');
    await writeFile(corrupt, '{"nextBlock":"-1"}');
    await expect(fileCursor(corrupt).load()).rejects.toThrow();
    await expect(fileCursor(dir).load()).rejects.toThrow();
  });
});
