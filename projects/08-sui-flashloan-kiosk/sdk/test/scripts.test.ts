// SPDX-License-Identifier: MIT
// Unit tests for the pure helpers behind the Node gate scripts.
import { describe, expect, it } from 'vitest';
import { parseSummary } from '../../scripts/lib/coverage.mjs';
import { normalizeLock } from '../../scripts/lib/lockfile.mjs';
import { parseFlags, stripAnsi } from '../../scripts/lib/sui-cli.mjs';

const SUMMARY = `+-------------------------+
| Move Coverage Summary   |
+-------------------------+
Module 0000000000000000000000000000000000000000000000000000000000000000::math
>>> % Module coverage: 100.00
Module 0000000000000000000000000000000000000000000000000000000000000000::pool
>>> % Module coverage: 97.25
+-------------------------+
| % Move Coverage: 98.10  |
+-------------------------+
`;

describe('parseSummary', () => {
  it('extracts per-module and total coverage', () => {
    expect(parseSummary(SUMMARY)).toEqual({
      modules: [
        { name: 'math', pct: 100 },
        { name: 'pool', pct: 97.25 },
      ],
      total: 98.1,
    });
  });

  it('reports nothing for unrelated output', () => {
    expect(parseSummary('error: no coverage map')).toEqual({ modules: [], total: undefined });
  });
});

describe('script helpers', () => {
  it('strips ANSI colour codes', () => {
    expect(stripAnsi('\u001b[1m\u001b[38;5;9merror[EC06001]\u001b[0m')).toBe('error[EC06001]');
  });

  it('parses --flag value and boolean flags', () => {
    const flags = parseFlags(['--min', '90', '--check', '--concurrency', '4', 'stray']);
    expect(flags.get('min')).toBe('90');
    expect(flags.get('check')).toBe('true');
    expect(flags.get('concurrency')).toBe('4');
    expect(flags.has('stray')).toBe(false);
  });
});

describe('normalizeLock', () => {
  const linux =
    'source = { git = "https://github.com/MystenLabs/sui.git", subdir = "crates/sui-framework/packages/move-stdlib", rev = "abc" }';

  it('turns the Windows literal-string form into the form a Linux build writes', () => {
    const windows = [
      String.raw`source = { git = "https://github.com/MystenLabs/sui.git", subdir = 'crates\sui-framework\packages\move-stdlib', rev = "abc" }`,
      'manifest_digest = "C4FE"',
    ].join('\n');
    const portable = normalizeLock(windows);
    expect(portable).toBe([linux, 'manifest_digest = "C4FE"'].join('\n'));
  });

  it('is the identity on canonical lock files', () => {
    expect(normalizeLock(linux)).toBe(linux);
    expect(normalizeLock(normalizeLock(linux))).toBe(linux);
  });

  it('canonicalises a single-quoted forward-slash path too', () => {
    const literal = linux.replace(
      '"crates/sui-framework/packages/move-stdlib"',
      "'crates/sui-framework/packages/move-stdlib'",
    );
    expect(normalizeLock(literal)).toBe(linux);
  });

  it('leaves everything except subdir values untouched', () => {
    const other = String.raw`[pinned.testnet.flash_kiosk]
source = { root = true }
note = 'a\b'`;
    expect(normalizeLock(other)).toBe(other);
  });
});
