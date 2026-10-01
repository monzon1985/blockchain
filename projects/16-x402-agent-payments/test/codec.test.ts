// SPDX-License-Identifier: MIT
import { getAddress } from 'viem';
import { describe, expect, it } from 'vitest';
import {
  MAX_HEADER_BYTES,
  X402CodecError,
  decodePaymentPayload,
  decodePaymentRequired,
  decodeSettlementResponse,
  encodeHeader,
  encodePaymentPayload,
  encodePaymentRequired,
  encodeSettlementResponse,
} from '../src/x402/codec.js';
import type { PaymentPayload, PaymentRequired, SettlementResponse } from '../src/x402/types.js';
import { REQUEST, requirements } from './fixtures.js';

const challenge: PaymentRequired = {
  x402Version: 2,
  error: 'PAYMENT-SIGNATURE header is required',
  resource: { url: REQUEST.url, description: 'sentiment', mimeType: 'application/json' },
  accepts: [requirements('exact'), requirements('budget-exec')],
};

const payload: PaymentPayload = {
  x402Version: 2,
  resource: { url: REQUEST.url },
  accepted: requirements('exact'),
  payload: { signature: '0x1234', anything: 1 },
};

const settlement: SettlementResponse = {
  success: true,
  payer: getAddress('0x0000000000000000000000000000000000000abc'),
  transaction: `0x${'ab'.repeat(32)}`,
  network: 'eip155:31337',
  amount: '10000',
  extensions: { receiptId: `0x${'cd'.repeat(32)}` },
};

function expectCodecError(fn: () => unknown, code: string): void {
  try {
    fn();
    expect.unreachable('decoder accepted invalid input');
  } catch (error) {
    expect(error).toBeInstanceOf(X402CodecError);
    expect((error as X402CodecError).code).toBe(code);
  }
}

describe('x402 header codec', () => {
  it('round-trips PAYMENT-REQUIRED', () => {
    expect(decodePaymentRequired(encodePaymentRequired(challenge))).toEqual(challenge);
  });

  it('round-trips PAYMENT-SIGNATURE', () => {
    expect(decodePaymentPayload(encodePaymentPayload(payload))).toEqual(payload);
  });

  it('round-trips PAYMENT-RESPONSE', () => {
    expect(decodeSettlementResponse(encodeSettlementResponse(settlement))).toEqual(settlement);
  });

  it('uses standard base64 of compact JSON, as in the x402 v2 HTTP transport', () => {
    const header = encodeHeader({ x402Version: 2 });
    expect(header).toBe('eyJ4NDAyVmVyc2lvbiI6Mn0=');
    expect(Buffer.from(header, 'base64').toString('utf8')).toBe('{"x402Version":2}');
  });

  it('checksums addresses on decode', () => {
    const lower = { ...settlement, payer: '0x52908400098527886e0f7030069857d2e4169ee7' };
    expect(decodeSettlementResponse(encodeHeader(lower)).payer).toBe(
      '0x52908400098527886E0F7030069857D2E4169EE7',
    );
  });

  it('rejects a missing or empty header', () => {
    expectCodecError(() => decodePaymentPayload(undefined), 'empty');
    expectCodecError(() => decodePaymentPayload(null), 'empty');
    expectCodecError(() => decodePaymentPayload(''), 'empty');
  });

  it('rejects oversized headers before decoding', () => {
    expectCodecError(() => decodePaymentPayload('A'.repeat(MAX_HEADER_BYTES + 4)), 'too_large');
  });

  it('rejects non-canonical base64 (URL-safe alphabet, whitespace, bad padding)', () => {
    const header = encodePaymentPayload(payload);
    expectCodecError(
      () => decodePaymentPayload(header.replace(/\+/g, '-').replace(/\//g, '_') + '-'),
      'not_base64',
    );
    expectCodecError(() => decodePaymentPayload(` ${header}`), 'not_base64');
    expectCodecError(() => decodePaymentPayload('abc'), 'not_base64');
  });

  it('rejects base64 that does not contain JSON', () => {
    expectCodecError(() => decodePaymentPayload(Buffer.from('not json').toString('base64')), 'not_json');
  });

  it('rejects JSON that violates the schema', () => {
    expectCodecError(() => decodePaymentPayload(encodeHeader({ ...payload, x402Version: 1 })), 'schema');
    expectCodecError(
      () =>
        decodePaymentPayload(encodeHeader({ ...payload, accepted: { ...payload.accepted, amount: '-1' } })),
      'schema',
    );
    expectCodecError(
      () =>
        decodePaymentPayload(
          encodeHeader({ ...payload, accepted: { ...payload.accepted, payTo: '0x1234' } }),
        ),
      'schema',
    );
    expectCodecError(() => decodePaymentRequired(encodeHeader({ ...challenge, accepts: [] })), 'schema');
    expectCodecError(
      () =>
        decodePaymentRequired(
          encodeHeader({
            ...challenge,
            accepts: [{ ...challenge.accepts[0], amount: `1${'0'.repeat(78)}` }],
          }),
        ),
      'schema',
    );
  });
});
