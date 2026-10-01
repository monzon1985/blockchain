// SPDX-License-Identifier: MIT
import fc from 'fast-check';
import { maxUint256 } from 'viem';
import { describe, expect, it } from 'vitest';
import { CSV_HEADER, CsvError, formatEpochCsv, parseEpochCsv } from '../src/csv.ts';
import { address } from './arbitraries.ts';

const A = '0x328809Bc894f92807417D2dAD6b7C998c1aFdac6';
const T = '0x6e107075c50e05cAAc17c25FBc6c61389Da06961';

describe('parseEpochCsv', () => {
  it('round-trips formatEpochCsv', () => {
    fc.assert(
      fc.property(
        fc.array(fc.record({ account: address, token: address, amount: fc.bigInt({ min: 0n, max: maxUint256 }) }), {
          maxLength: 30,
        }),
        (rows) => {
          const parsed = parseEpochCsv(formatEpochCsv(rows));
          expect(parsed.map(({ account, token, amount }) => ({ account, token, amount }))).toEqual(rows);
          expect(parsed.map((r) => r.line)).toEqual(rows.map((_, i) => i + 2));
        },
      ),
    );
  });

  it('accepts CRLF, a BOM, padding and lowercase addresses', () => {
    const rows = parseEpochCsv(`${String.fromCharCode(0xfeff)}${CSV_HEADER}\r\n ${A.toLowerCase()} , ${T} , 42 \r\n`);
    expect(rows).toEqual([{ account: A, token: T, amount: 42n, line: 2 }]);
  });

  it.each([
    ['missing header', `${A},${T},1\n`, /expected header/],
    ['empty file', '', /expected header/],
    ['wrong field count', `${CSV_HEADER}\n${A},${T}\n`, /expected 3 fields/],
    ['blank line', `${CSV_HEADER}\n\n${A},${T},1\n`, /expected 3 fields/],
    ['bad address', `${CSV_HEADER}\n0x1234,${T},1\n`, /invalid account address/],
    ['bad checksum', `${CSV_HEADER}\n${A.replace('Bc', 'bC')},${T},1\n`, /checksum/],
    ['zero address', `${CSV_HEADER}\n0x0000000000000000000000000000000000000000,${T},1\n`, /zero address/],
    ['negative amount', `${CSV_HEADER}\n${A},${T},-1\n`, /non-negative integer/],
    ['decimal amount', `${CSV_HEADER}\n${A},${T},1.5\n`, /non-negative integer/],
    ['exponent amount', `${CSV_HEADER}\n${A},${T},1e18\n`, /non-negative integer/],
    ['hex amount', `${CSV_HEADER}\n${A},${T},0x10\n`, /non-negative integer/],
    ['uint256 overflow', `${CSV_HEADER}\n${A},${T},${(maxUint256 + 1n).toString()}\n`, /exceeds uint256/],
  ])('rejects %s', (_, text, message) => {
    expect(() => parseEpochCsv(text, 'epoch.csv')).toThrow(CsvError);
    expect(() => parseEpochCsv(text, 'epoch.csv')).toThrow(message);
  });

  it('reports the offending line', () => {
    expect(() => parseEpochCsv(`${CSV_HEADER}\n${A},${T},1\n${A},${T},x\n`, 'epoch-7.csv')).toThrow(/^epoch-7\.csv:3:/);
  });
});
