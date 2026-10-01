// SPDX-License-Identifier: MIT
/**
 * Strict parser for epoch CSVs:
 *
 *   account,token,amount
 *   0x328809Bc894f92807417D2dAD6b7C998c1aFdac6,0x2e234DAe75C793f67A35089C9d99245E1C58470b,1000000000000000000
 *
 * `amount` is what the epoch adds, in token base units (a non-negative integer, no decimals, no exponent). Anything
 * unexpected is an error with its line number: a rewards file is not the place to guess.
 */
import { getAddress, isAddress, maxUint256, zeroAddress, type Address } from 'viem';

export class CsvError extends Error {
  override name = 'CsvError';
}

export interface EpochRow {
  readonly account: Address;
  readonly token: Address;
  readonly amount: bigint;
  /** 1-based line number in the source file, for error messages. */
  readonly line: number;
}

export const CSV_HEADER = 'account,token,amount';

/** A UTF-8 byte-order mark, as spreadsheet exports often prepend. */
const BOM = String.fromCharCode(0xfeff);

function parseAddress(raw: string, what: string, where: string): Address {
  const shown: string = raw;
  if (!isAddress(raw, { strict: false })) throw new CsvError(`${where}: invalid ${what} address "${shown}"`);
  // Mixed-case input must carry a valid EIP-55 checksum; all-lowercase or all-uppercase input is accepted as is.
  const body = raw.slice(2);
  const mixedCase = body !== body.toLowerCase() && body !== body.toUpperCase();
  if (mixedCase && !isAddress(raw, { strict: true })) {
    throw new CsvError(`${where}: ${what} address "${shown}" has a bad EIP-55 checksum`);
  }
  const address = getAddress(raw.toLowerCase());
  if (address === zeroAddress) throw new CsvError(`${where}: ${what} cannot be the zero address`);
  return address;
}

function parseAmount(raw: string, where: string): bigint {
  if (!/^[0-9]+$/.test(raw)) throw new CsvError(`${where}: amount "${raw}" is not a non-negative integer`);
  const amount = BigInt(raw);
  if (amount > maxUint256) throw new CsvError(`${where}: amount ${raw} exceeds uint256`);
  return amount;
}

/** Parses one epoch file. `source` only labels error messages. */
export function parseEpochCsv(text: string, source = '<csv>'): EpochRow[] {
  const body = text.startsWith(BOM) ? text.slice(1) : text;
  const lines = body.split(/\r?\n/);
  while (lines.length > 0 && lines[lines.length - 1] === '') lines.pop();
  const header = lines[0]?.trim();
  if (header !== CSV_HEADER) {
    throw new CsvError(`${source}:1: expected header "${CSV_HEADER}", got "${header ?? ''}"`);
  }
  const rows: EpochRow[] = [];
  for (let i = 1; i < lines.length; i++) {
    const where = `${source}:${i + 1}`;
    const fields = (lines[i] ?? '').split(',').map((f) => f.trim());
    if (fields.length !== 3) throw new CsvError(`${where}: expected 3 fields, got ${fields.length}`);
    const [account, token, amount] = fields as [string, string, string];
    rows.push({
      account: parseAddress(account, 'account', where),
      token: parseAddress(token, 'token', where),
      amount: parseAmount(amount, where),
      line: i + 1,
    });
  }
  return rows;
}

/** Serializes rows back to the canonical CSV form (used to generate the random fixture dataset). */
export function formatEpochCsv(rows: readonly Omit<EpochRow, 'line'>[]): string {
  return [CSV_HEADER, ...rows.map((r) => `${r.account},${r.token},${r.amount.toString(10)}`)].join('\n') + '\n';
}
