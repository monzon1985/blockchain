// SPDX-License-Identifier: MIT
/**
 * Renders snapshots/GasBench.json (written by `forge test --match-contract GasBench`) into the README, between the
 * `<!-- gas-table:begin -->` and `<!-- gas-table:end -->` markers.
 *
 *   npm run gas-table              rewrite the README section
 *   npm run gas-table -- --check   exit 1 if the README does not match the snapshot
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const PROJECT = resolve(import.meta.dirname, '../..');
const SNAPSHOT = resolve(PROJECT, 'snapshots/GasBench.json');
const README = resolve(PROJECT, 'README.md');
const BEGIN = '<!-- gas-table:begin -->';
const END = '<!-- gas-table:end -->';

type Snapshot = Record<string, string>;

function value(s: Snapshot, key: string): number {
  const raw = s[key];
  if (raw === undefined)
    throw new Error(`snapshots/GasBench.json has no "${key}"; run forge test --match-contract GasBench`);
  return Number(raw);
}

const fmt = (n: number): string => n.toLocaleString('en-US');
const pct = (a: number, b: number): string =>
  `${a <= b ? '−' : '+'}${Math.abs(Math.round((1 - a / b) * 1000) / 10).toFixed(1)} %`;

export function render(s: Snapshot): string {
  const flag = (design: string, metric: string): number => value(s, `flags.${design}.${metric}`);
  const designs: [string, string][] = [
    ['epoch_bool', 'Per-epoch roots, `mapping(uint256 => bool)` flags'],
    ['epoch_bitmap', 'Per-epoch roots, Solady `LibBitmap` flags'],
    ['cumulative', '**Cumulative root (this contract)**'],
  ];
  const lines: string[] = [];

  lines.push(
    '**Claimed-flag storage.** 256-leaf trees, one ERC-20, fresh recipients. Transaction gas, net of refunds.',
    '',
    '| Design | 1st claim | 2nd claim, same epoch | Mean of 100 claims, same epoch | Claim in the next epoch |',
    '|---|--:|--:|--:|--:|',
  );
  for (const [key, label] of designs) {
    lines.push(
      `| ${label} | ${fmt(flag(key, 'first_claim'))} | ${fmt(flag(key, 'second_claim'))} | ${fmt(flag(key, 'avg_of_100_claims'))} | ${fmt(flag(key, 'next_epoch_claim'))} |`,
    );
  }

  const catchup = (d: string): number => value(s, `catchup.${d}.four_epochs`);
  lines.push(
    '',
    '**Catch-up.** One account collects four epochs of rewards it never claimed.',
    '',
    '| Design | Transactions | Total gas | vs. cumulative |',
    '|---|--:|--:|--:|',
    `| Per-epoch roots, \`mapping(uint256 => bool)\` | 4 | ${fmt(catchup('epoch_bool'))} | ${(catchup('epoch_bool') / catchup('cumulative')).toFixed(2)}x |`,
    `| Per-epoch roots, \`LibBitmap\` | 4 | ${fmt(catchup('epoch_bitmap'))} | ${(catchup('epoch_bitmap') / catchup('cumulative')).toFixed(2)}x |`,
    `| **Cumulative root** | 1 | ${fmt(catchup('cumulative'))} | 1.00x |`,
  );

  lines.push(
    '',
    '**Single proofs vs. multiproof.** Leaves spread pseudo-randomly over a 4,096-leaf tree (12 hashes per single proof).',
    '',
    '| Claims | Separate `claim` txs | Single proofs, one tx | One `claimMany` (multiproof) | Multiproof vs. single proofs in one tx | Proof hashes sent (single → multi) |',
    '|--:|--:|--:|--:|--:|--:|',
  );
  for (const k of ['001', '010', '100']) {
    const sep = value(s, `batch.${k}.separate_txs`);
    const one = value(s, `batch.${k}.single_proofs_one_tx`);
    const multi = value(s, `batch.${k}.multiproof`);
    lines.push(
      `| ${Number(k)} | ${fmt(sep)} | ${fmt(one)} | ${fmt(multi)} | ${pct(multi, one)} | ${fmt(value(s, `batch.${k}.single_proof_hashes`))} → ${fmt(value(s, `batch.${k}.multiproof_hashes`))} |`,
    );
  }

  lines.push(
    '',
    '**Entry points.** 256-leaf tree; each claim pays a recipient that holds no tokens yet.',
    '',
    '| Call | Gas |',
    '|---|--:|',
    `| \`claim\` | ${fmt(value(s, 'paths.claim'))} |`,
    `| \`claimFor\`, EOA signature | ${fmt(value(s, 'paths.claimFor_eoa'))} |`,
    `| \`claimFor\`, ERC-1271 wallet | ${fmt(value(s, 'paths.claimFor_erc1271'))} |`,
    `| \`proposeRoot\` | ${fmt(value(s, 'lifecycle.proposeRoot'))} |`,
    `| \`acceptRoot\` | ${fmt(value(s, 'lifecycle.acceptRoot'))} |`,
    `| \`revokePendingRoot\` | ${fmt(value(s, 'lifecycle.revokePendingRoot'))} |`,
  );
  return lines.join('\n');
}

function main(): number {
  const check = process.argv.includes('--check');
  const snapshot = JSON.parse(readFileSync(SNAPSHOT, 'utf8')) as Snapshot;
  const readme = readFileSync(README, 'utf8');
  const start = readme.indexOf(BEGIN);
  const end = readme.indexOf(END);
  if (start < 0 || end < start) throw new Error(`README.md needs ${BEGIN} ... ${END} markers`);
  const next = `${readme.slice(0, start + BEGIN.length)}\n${render(snapshot)}\n${readme.slice(end)}`;
  if (check) {
    if (next !== readme) {
      console.error(
        'README gas tables are out of date; run `npm run gas-table` after `forge test --match-contract GasBench`',
      );
      return 1;
    }
    console.log('README gas tables match snapshots/GasBench.json');
    return 0;
  }
  writeFileSync(README, next);
  console.log('README gas tables updated');
  return 0;
}

process.exitCode = main();
