// SPDX-License-Identifier: MIT
/**
 * Minimal structured logger (JSON lines). Every string field is passed through the PII redactor before it is
 * written, so free text from requests can never reach the logs verbatim. Only two kinds of strings are exempt:
 * 0x-hex values (addresses, hashes: never PII, and the phone pattern cannot match inside them) and plain decimal
 * strings under keys known to hold numbers (`amount`, `nonce`, ...). A digits-only string under any other key (a
 * phone number typed without separators, say) is redacted like any other text.
 */
import { redactText, redactUrl } from './policy/pii.js';

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';
export type LogFields = Record<string, unknown>;
export type LogSink = (line: string) => void;

export interface Logger {
  debug(event: string, fields?: LogFields): void;
  info(event: string, fields?: LogFields): void;
  warn(event: string, fields?: LogFields): void;
  error(event: string, fields?: LogFields): void;
  child(component: string): Logger;
}

const HEX_RE = /^0x[0-9a-fA-F]*$/;
const DECIMAL_RE = /^[0-9]+$/;
/** Keys whose decimal-string values are protocol numbers (amounts, counters, timestamps), not free text. */
const NUMERIC_KEY_RE =
  /^(amount|value|price|remaining|spent|balance|budget|calls|count|score|nonce|deadline|timestamp|blockNumber|gas|chainId|agentId|attempts)$/i;

/** Recursively redacts free-text strings; URL-looking fields (`url`, `resource`) get URL-aware redaction. */
export function redactFields(value: unknown, key = ''): unknown {
  if (typeof value === 'string') {
    if (HEX_RE.test(value) || (DECIMAL_RE.test(value) && NUMERIC_KEY_RE.test(key))) return value;
    if (/url|resource|uri/i.test(key)) return redactUrl(value);
    return redactText(value);
  }
  if (typeof value === 'bigint') return value.toString();
  if (Array.isArray(value)) return value.map((item) => redactFields(item, key));
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, redactFields(v, k)]));
  }
  return value;
}

const LEVELS: Record<LogLevel, number> = { debug: 10, info: 20, warn: 30, error: 40 };

export interface LoggerOptions {
  readonly component: string;
  readonly sink?: LogSink;
  readonly level?: LogLevel;
}

/** Creates a logger. The default sink discards output so library code is silent unless a sink is supplied. */
export function createLogger(options: LoggerOptions): Logger {
  const sink: LogSink = options.sink ?? (() => undefined);
  const threshold = LEVELS[options.level ?? 'info'];
  const write = (level: LogLevel, event: string, fields: LogFields = {}): void => {
    if (LEVELS[level] < threshold) return;
    const record = { level, component: options.component, event, ...(redactFields(fields) as LogFields) };
    sink(JSON.stringify(record));
  };
  return {
    debug: (event, fields) => {
      write('debug', event, fields);
    },
    info: (event, fields) => {
      write('info', event, fields);
    },
    warn: (event, fields) => {
      write('warn', event, fields);
    },
    error: (event, fields) => {
      write('error', event, fields);
    },
    child: (component) => createLogger({ ...options, component: `${options.component}.${component}` }),
  };
}

/** A sink that collects lines in memory (used by tests and the demo transcript). */
export function memorySink(): { sink: LogSink; lines: string[] } {
  const lines: string[] = [];
  return {
    sink: (line) => {
      lines.push(line);
    },
    lines,
  };
}
