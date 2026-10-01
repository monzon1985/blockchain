// SPDX-License-Identifier: MIT
/**
 * PII filter for payment metadata.
 *
 * Anything that leaves a process as metadata (receipt logs, structured logs, strings written on-chain such as
 * feedback tags or validation URIs) goes through two layers:
 *   1. a strict zod schema: only known keys, bounded lengths, so arbitrary user objects (with `email`, `phone`, ...)
 *      are rejected instead of being passed along;
 *   2. regex redaction of e-mail addresses and phone-number-like digit runs inside the remaining free text, and of
 *      URL userinfo, query values and fragments.
 *
 * Structured protocol values (0x-hex, and decimal amounts or counters under known numeric keys) are not run through
 * the redactor; the logger enforces that split (see `logging.ts`).
 */
import { z } from 'zod';

export const EMAIL_PLACEHOLDER = '[redacted-email]';
export const PHONE_PLACEHOLDER = '[redacted-phone]';

const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/g;

/**
 * Phone candidates: an optional `+`, then digits mixed with spaces, dots, dashes and parentheses, not glued to
 * letters, digits or `x` (so hex strings never match). A candidate is redacted when it has at least 9 digits, or at
 * least 7 digits and a leading `+` (international format). Shorter runs (prices, years, ports) are kept.
 */
const PHONE_CANDIDATE_RE = /(?<![\w+])\+?\(?\d[\d\s().-]{4,}\d(?![\w])/g;

function redactPhone(match: string): string {
  const digits = match.replace(/\D/g, '').length;
  const international = match.startsWith('+');
  return digits >= 9 || (international && digits >= 7) ? PHONE_PLACEHOLDER : match;
}

/** Redacts e-mail addresses and phone numbers in free text. */
export function redactText(text: string): string {
  return text.replace(EMAIL_RE, EMAIL_PLACEHOLDER).replace(PHONE_CANDIDATE_RE, redactPhone);
}

/** Returns true if `text` still contains something the redactor would remove. */
export function containsPii(text: string): boolean {
  return redactText(text) !== text;
}

/**
 * Redacts a URL for logging: drops userinfo, keeps query keys but replaces their values, drops the fragment, and
 * redacts PII in the path. Unparseable input is treated as free text.
 */
export function redactUrl(raw: string): string {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return redactText(raw);
  }
  url.username = '';
  url.password = '';
  url.hash = '';
  const keys = [...new Set(url.searchParams.keys())];
  const query = keys.map((key) => `${encodeURIComponent(key)}=[redacted]`).join('&');
  let decodedPath: string;
  try {
    decodedPath = decodeURIComponent(url.pathname);
  } catch {
    // Malformed percent-escapes (`%E0%A4%A`): redact the raw path instead of throwing after a payment settled.
    decodedPath = url.pathname;
  }
  const path = redactText(decodedPath);
  return `${url.origin}${path}${query.length > 0 ? `?${query}` : ''}`;
}

const freeText = (max: number) =>
  z
    .string()
    .max(max)
    .transform((value) => redactText(value));

/**
 * Metadata attached to a payment (what the agent logs and what may be written on-chain as feedback/validation
 * strings). Unknown keys are an error, not silently dropped: a caller passing `{ email }` gets a failure.
 */
export const paymentMetadataSchema = z.strictObject({
  resource: z
    .string()
    .max(2048)
    .transform((value) => redactUrl(value)),
  description: freeText(512).optional(),
  memo: freeText(512).optional(),
  tags: z.array(freeText(64)).max(8).optional(),
});
export type PaymentMetadata = z.infer<typeof paymentMetadataSchema>;

/** Validates and redacts payment metadata. Throws a `ZodError` on unknown keys or oversized fields. */
export function sanitizePaymentMetadata(input: unknown): PaymentMetadata {
  return paymentMetadataSchema.parse(input);
}

/**
 * Guard for strings that are about to be written on-chain (feedback tags, endpoint, URIs): they must be short and
 * PII-free after redaction. Returns the redacted value.
 */
export function onchainString(value: string, maxLength = 256): string {
  const redacted = redactText(value);
  if (redacted.length > maxLength) {
    throw new RangeError(`on-chain string longer than ${maxLength} characters`);
  }
  return redacted;
}
