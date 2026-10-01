// SPDX-License-Identifier: MIT
import { describe, expect, it } from 'vitest';
import { ZodError } from 'zod';
import { receiptMetadata } from '../src/agent/agent.js';
import { createLogger, memorySink, redactFields } from '../src/logging.js';
import {
  EMAIL_PLACEHOLDER,
  PHONE_PLACEHOLDER,
  containsPii,
  onchainString,
  redactText,
  redactUrl,
  sanitizePaymentMetadata,
} from '../src/policy/pii.js';

describe('redactText', () => {
  it.each([
    ['contact alice.smith+x402@example.co.uk now', `contact ${EMAIL_PLACEHOLDER} now`],
    ['BOB@EXAMPLE.COM', EMAIL_PLACEHOLDER],
    ['call +34 612 345 678 today', `call ${PHONE_PLACEHOLDER} today`],
    ['call (555) 123-4567', `call ${PHONE_PLACEHOLDER}`],
    ['office 555.123.4567 ext', `office ${PHONE_PLACEHOLDER} ext`],
    ['mobile 5551234567', `mobile ${PHONE_PLACEHOLDER}`],
    ['intl +44 20 7946 0958', `intl ${PHONE_PLACEHOLDER}`],
  ])('redacts %j', (input, expected) => {
    expect(redactText(input)).toBe(expected);
  });

  it.each([
    'price 10000 base units',
    'year 2026, port 4021',
    'date 2026-09-29',
    'address 0x52908400098527886E0F7030069857D2E4169EE7',
    `hash 0x${'ab'.repeat(32)}`,
    'version 1.2.3',
    'localhost 127.0.0.1:8080',
    'short 12-34-56',
  ])('keeps non-PII %j', (input) => {
    expect(redactText(input)).toBe(input);
    expect(containsPii(input)).toBe(false);
  });

  it('handles several findings in one string', () => {
    expect(redactText('a@b.io or +1 212 555 0100, b@c.io')).toBe(
      `${EMAIL_PLACEHOLDER} or ${PHONE_PLACEHOLDER}, ${EMAIL_PLACEHOLDER}`,
    );
  });
});

describe('redactUrl', () => {
  it('drops userinfo and fragment, masks query values, redacts the path', () => {
    expect(
      redactUrl('http://user:pw@host:1/api/v1/users/jane@example.com?email=jane@example.com&k=5#x'),
    ).toBe(`http://host:1/api/v1/users/${EMAIL_PLACEHOLDER}?email=[redacted]&k=[redacted]`);
  });

  it('falls back to text redaction for non-URLs', () => {
    expect(redactUrl('not a url, mail me at x@y.org')).toBe(`not a url, mail me at ${EMAIL_PLACEHOLDER}`);
  });

  it('never throws on malformed percent-escapes: the raw path is redacted as text', () => {
    expect(redactUrl('http://evil.example/api%E0%A4%A/x')).toBe('http://evil.example/api%E0%A4%A/x');
    expect(redactUrl('http://evil.example/u/jane@example.com%E0%A4%A')).toBe(
      `http://evil.example/u/${EMAIL_PLACEHOLDER}%E0%A4%A`,
    );
  });

  it('keeps a clean URL intact', () => {
    expect(redactUrl('http://127.0.0.1:4021/api/v1/sentiment')).toBe(
      'http://127.0.0.1:4021/api/v1/sentiment',
    );
  });
});

describe('payment metadata schema', () => {
  it('redacts free text and URLs', () => {
    const meta = sanitizePaymentMetadata({
      resource: 'http://h/api?q=jane@example.com',
      description: 'invoice for jane@example.com, +34 612 345 678',
      memo: 'ok',
      tags: ['vip', 'tel 5551234567'],
    });
    expect(meta).toEqual({
      resource: 'http://h/api?q=[redacted]',
      description: `invoice for ${EMAIL_PLACEHOLDER}, ${PHONE_PLACEHOLDER}`,
      memo: 'ok',
      tags: ['vip', `tel ${PHONE_PLACEHOLDER}`],
    });
  });

  it('rejects unknown keys instead of passing them through', () => {
    expect(() => sanitizePaymentMetadata({ resource: 'http://h', email: 'a@b.io' })).toThrow(ZodError);
    expect(() => sanitizePaymentMetadata({ resource: 'http://h', phone: '+1 212 555 0100' })).toThrow(
      ZodError,
    );
  });

  it('rejects oversized fields', () => {
    expect(() => sanitizePaymentMetadata({ resource: 'http://h', description: 'x'.repeat(513) })).toThrow(
      ZodError,
    );
    expect(() => sanitizePaymentMetadata({ resource: 'http://h', tags: Array(9).fill('t') })).toThrow(
      ZodError,
    );
  });
});

describe('receipt metadata', () => {
  it('is sanitized like any payment metadata', () => {
    expect(receiptMetadata('http://h/api?email=a@b.io', 'for a@b.io')).toEqual({
      resource: 'http://h/api?email=[redacted]',
      description: `for ${EMAIL_PLACEHOLDER}`,
    });
    expect(receiptMetadata('http://h/api', undefined)).toEqual({ resource: 'http://h/api' });
  });

  it('never throws after a payment settled: odd URLs and oversized fields fall back to the redacted URL', () => {
    expect(receiptMetadata('http://evil.example/api%E0%A4%A/x', undefined)).toEqual({
      resource: 'http://evil.example/api%E0%A4%A/x',
    });
    const long = `http://h/${'a'.repeat(3000)}?phone=+34612345678`;
    const meta = receiptMetadata(long, 'x'.repeat(10_000));
    expect(meta.description).toBeUndefined();
    expect(meta.resource.length).toBe(2048);
    expect(meta.resource).not.toContain('612345678');
  });
});

describe('on-chain strings', () => {
  it('are redacted and length-bounded', () => {
    expect(onchainString('great service, ping me at a@b.io')).toBe(
      `great service, ping me at ${EMAIL_PLACEHOLDER}`,
    );
    expect(() => onchainString('x'.repeat(65), 64)).toThrow(RangeError);
  });
});

describe('logger', () => {
  it('redacts free text but keeps structured protocol values', () => {
    const { sink, lines } = memorySink();
    const logger = createLogger({ component: 'test', sink });
    logger.info('event', {
      note: 'user jane@example.com paid',
      amount: '10000',
      big: 123n,
      tx: `0x${'ab'.repeat(32)}`,
      url: 'http://h/p?email=jane@example.com',
      nested: { memo: 'call +1 212 555 0100', list: ['a@b.io'] },
    });
    const record = JSON.parse(lines[0] ?? '{}') as Record<string, unknown>;
    expect(record).toEqual({
      level: 'info',
      component: 'test',
      event: 'event',
      note: `user ${EMAIL_PLACEHOLDER} paid`,
      amount: '10000',
      big: '123',
      tx: `0x${'ab'.repeat(32)}`,
      url: 'http://h/p?email=[redacted]',
      nested: { memo: `call ${PHONE_PLACEHOLDER}`, list: [EMAIL_PLACEHOLDER] },
    });
  });

  it('honours the level threshold and child components', () => {
    const { sink, lines } = memorySink();
    const logger = createLogger({ component: 'root', sink, level: 'warn' });
    logger.debug('d');
    logger.info('i');
    logger.warn('w');
    logger.child('sub').error('e');
    expect(lines.map((l) => (JSON.parse(l) as { event: string; component: string }).event)).toEqual([
      'w',
      'e',
    ]);
    expect((JSON.parse(lines[1] ?? '{}') as { component: string }).component).toBe('root.sub');
  });

  it('is silent without a sink', () => {
    expect(() => {
      createLogger({ component: 'quiet' }).info('nothing');
    }).not.toThrow();
  });

  it('redacts digits-only strings unless their key is a known numeric field', () => {
    const { sink, lines } = memorySink();
    createLogger({ component: 'test', sink }).info('event', {
      note: '34612345678',
      phone: '5551234567',
      amount: '1000000000',
      nonce: '123456789012',
      remaining: '99000000000',
      list: ['34612345678'],
    });
    expect(JSON.parse(lines[0] ?? '{}')).toMatchObject({
      note: PHONE_PLACEHOLDER,
      phone: PHONE_PLACEHOLDER,
      amount: '1000000000',
      nonce: '123456789012',
      remaining: '99000000000',
      list: [PHONE_PLACEHOLDER],
    });
  });

  it('passes non-string scalars through', () => {
    expect(redactFields({ n: 1, b: true, z: null })).toEqual({ n: 1, b: true, z: null });
  });
});
