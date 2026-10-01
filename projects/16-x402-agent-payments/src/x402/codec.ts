// SPDX-License-Identifier: MIT
/**
 * x402 v2 HTTP header codec: every protocol header carries base64-encoded JSON (specs/transports-v2/http.md).
 * Decoding is strict: size-limited, canonical standard base64 only, JSON that must satisfy the zod schema.
 */
import type { z } from 'zod';
import {
  paymentPayloadSchema,
  paymentRequiredSchema,
  settlementResponseSchema,
  type PaymentPayload,
  type PaymentRequired,
  type SettlementResponse,
} from './types.js';

export const PAYMENT_REQUIRED_HEADER = 'PAYMENT-REQUIRED';
export const PAYMENT_SIGNATURE_HEADER = 'PAYMENT-SIGNATURE';
export const PAYMENT_RESPONSE_HEADER = 'PAYMENT-RESPONSE';

/** Upper bound on an encoded header. Real payloads are ~1-2 KiB; 16 KiB leaves room without inviting abuse. */
export const MAX_HEADER_BYTES = 16 * 1024;

const BASE64_RE = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

export type CodecErrorCode = 'empty' | 'too_large' | 'not_base64' | 'not_json' | 'schema';

/** Raised for any header that is not a valid encoding of the expected x402 object. */
export class X402CodecError extends Error {
  constructor(
    readonly code: CodecErrorCode,
    message: string,
  ) {
    super(message);
    this.name = 'X402CodecError';
  }
}

/** Serializes an x402 object to the header representation (standard base64 of compact JSON). */
export function encodeHeader(value: unknown): string {
  return Buffer.from(JSON.stringify(value), 'utf8').toString('base64');
}

/** Decodes and validates a header value against `schema`. Throws {@link X402CodecError}. */
export function decodeHeader<S extends z.ZodType>(schema: S, header: string | null | undefined): z.infer<S> {
  if (header === null || header === undefined || header.length === 0) {
    throw new X402CodecError('empty', 'header is missing or empty');
  }
  if (header.length > MAX_HEADER_BYTES) {
    throw new X402CodecError('too_large', `header exceeds ${MAX_HEADER_BYTES} bytes`);
  }
  if (!BASE64_RE.test(header)) {
    throw new X402CodecError('not_base64', 'header is not canonical standard base64');
  }
  let json: unknown;
  try {
    json = JSON.parse(Buffer.from(header, 'base64').toString('utf8'));
  } catch {
    throw new X402CodecError('not_json', 'header does not contain JSON');
  }
  const parsed = schema.safeParse(json);
  if (!parsed.success) {
    throw new X402CodecError(
      'schema',
      `header does not match schema: ${parsed.error.issues[0]?.message ?? ''}`,
    );
  }
  return parsed.data;
}

export const encodePaymentRequired = (value: PaymentRequired): string => encodeHeader(value);
export const decodePaymentRequired = (header: string | null | undefined): PaymentRequired =>
  decodeHeader(paymentRequiredSchema, header);

export const encodePaymentPayload = (value: PaymentPayload): string => encodeHeader(value);
export const decodePaymentPayload = (header: string | null | undefined): PaymentPayload =>
  decodeHeader(paymentPayloadSchema, header);

export const encodeSettlementResponse = (value: SettlementResponse): string => encodeHeader(value);
export const decodeSettlementResponse = (header: string | null | undefined): SettlementResponse =>
  decodeHeader(settlementResponseSchema, header);
