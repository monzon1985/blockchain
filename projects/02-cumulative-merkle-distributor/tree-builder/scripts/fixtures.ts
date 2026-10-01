// SPDX-License-Identifier: MIT
/**
 * Writes the differential fixtures that the Foundry suite replays on-chain (test/differential/Fixtures.t.sol):
 *
 *   test/fixtures/example.json              the three hand-written epochs in tree-builder/examples/epochs
 *   test/fixtures/random.json               three seeded pseudo-random epochs (48 accounts x 3 tokens)
 *   test/fixtures/claim-authorization.json  an EIP-712 claim authorization signed by viem
 *
 *   npm run fixtures              regenerate
 *   npm run fixtures -- --check   exit 1 if the committed files differ from what the builder produces now
 */
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { keccak256, stringToBytes, type Address, type Hex } from 'viem';
import { privateKeyToAddress } from 'viem/accounts';
import {
  claimAuthorizationDomain,
  claimAuthorizationDomainSeparator,
  hashClaimAuthorization,
  signClaimAuthorization,
  type ClaimAuthorization,
} from '../src/claim-authorization.ts';
import { formatEpochCsv, parseEpochCsv, type EpochRow } from '../src/csv.ts';
import { buildEpochs, toJson, type EpochBuild, type EpochInput } from '../src/cumulative.ts';

const ROOT = resolve(import.meta.dirname, '..');
const FIXTURES = resolve(ROOT, '../test/fixtures');
const EXAMPLES = resolve(ROOT, 'examples/epochs');

/** Foundry's `makeAddrAndKey(label)`: the private key is keccak256(label). Test identities only. */
export function labelKey(label: string): Hex {
  return keccak256(stringToBytes(label));
}
export function labelAddress(label: string): Address {
  return privateKeyToAddress(labelKey(label));
}

/** splitmix64: tiny, well-known, and identical on every platform. */
function prng(seed: bigint): () => bigint {
  let state = seed & 0xffffffffffffffffn;
  return () => {
    state = (state + 0x9e3779b97f4a7c15n) & 0xffffffffffffffffn;
    let z = state;
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & 0xffffffffffffffffn;
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & 0xffffffffffffffffn;
    return z ^ (z >> 31n);
  };
}

/** Seeded dataset with carried-forward pairs, late joiners, duplicate rows, zero rows and wide amounts. */
function randomEpochCsvs(): string[] {
  const next = prng(0x02c0ffeen);
  const accounts = Array.from({ length: 48 }, (_, i) => labelAddress(`account-${i}`));
  const tokens = Array.from({ length: 3 }, (_, i) => labelAddress(`token-${i}`));
  const csvs: string[] = [];
  for (let epoch = 0; epoch < 3; epoch++) {
    const rows: Omit<EpochRow, 'line'>[] = [];
    accounts.forEach((account, a) => {
      if (a >= 36 && epoch === 0) return; // late joiners
      tokens.forEach((token) => {
        const r = next();
        if (r % 5n >= 2n) return; // ~40 % density per epoch
        let amount = next() % 10n ** 24n;
        if (r % 97n === 0n) amount = 10n ** 33n + (next() % 10n ** 30n); // an occasional whale
        if (r % 41n === 0n) amount = 0n; // a zero row still parses and changes nothing
        rows.push({ account, token, amount });
        if (r % 13n === 0n) rows.push({ account, token, amount: next() % 10n ** 18n }); // duplicate row, summed
      });
    });
    csvs.push(formatEpochCsv(rows));
  }
  return csvs;
}

function inputsFrom(texts: readonly string[], label: string): EpochInput[] {
  return texts.map((text, i) => ({ text, rows: parseEpochCsv(text, `${label}#${i + 1}`) }));
}

function epochFixture(build: EpochBuild) {
  const { tree } = build;
  // A deterministic subset for claimMany: every third value, plus the last one.
  const subset = tree.values.map((_, i) => i).filter((i) => i % 3 === 0 || i === tree.length - 1);
  const mp = tree.getMultiProof(subset);
  return {
    epoch: build.epoch,
    root: tree.root,
    metadataHash: build.metadataHash,
    leafCount: tree.length,
    claims: tree.values.map(({ value }, i) => ({
      account: value[0],
      token: value[1],
      cumulativeAmount: value[2],
      leaf: tree.leafHashAt(i),
      proof: tree.getProof(i),
    })),
    multiproof: {
      claims: mp.values.map((v) => ({ account: v[0], token: v[1], cumulativeAmount: v[2] })),
      proof: mp.proof,
      proofFlags: mp.proofFlags,
    },
  };
}

function datasetFixture(name: string, builds: readonly EpochBuild[]) {
  const last = builds[builds.length - 1];
  if (last === undefined) throw new Error(`${name}: no epochs`);
  return {
    format: 'cumulative-merkle-distributor/fixture-v1',
    name,
    tokens: last.manifest.tokens.map((t) => t.token),
    finalTotals: last.manifest.tokens.map((t) => t.cumulativeTotal),
    epochs: builds.map(epochFixture),
  };
}

async function claimAuthorizationFixture(example: readonly EpochBuild[]) {
  const epoch = example[example.length - 1];
  if (epoch === undefined) throw new Error('example has no epochs');
  const alice = labelAddress('alice');
  const valueIndex = epoch.tree.values.findIndex(({ value }) => value[0] === alice);
  const allocation = epoch.tree.allocationAt(valueIndex);

  const chainId = 31337;
  const verifyingContract = labelAddress('distributor');
  const domain = claimAuthorizationDomain(chainId, verifyingContract);
  const message: ClaimAuthorization = {
    account: allocation.account,
    token: allocation.token,
    cumulativeAmount: allocation.cumulativeAmount,
    recipient: labelAddress('treasury'),
    nonce: 0n,
    deadline: 2_000_000_000n,
  };
  return {
    format: 'cumulative-merkle-distributor/claim-authorization-fixture-v1',
    signerLabel: 'alice',
    signer: alice,
    chainId,
    verifyingContract,
    domainSeparator: claimAuthorizationDomainSeparator(domain),
    epoch: epoch.epoch,
    root: epoch.tree.root,
    proof: epoch.tree.getProof(valueIndex),
    message: {
      account: message.account,
      token: message.token,
      cumulativeAmount: message.cumulativeAmount.toString(10),
      recipient: message.recipient,
      nonce: message.nonce.toString(10),
      deadline: message.deadline.toString(10),
    },
    digest: hashClaimAuthorization(domain, message),
    signature: await signClaimAuthorization(labelKey('alice'), domain, message),
  };
}

export async function renderFixtures(): Promise<Map<string, string>> {
  const exampleTexts = readdirSync(EXAMPLES)
    .filter((f) => f.endsWith('.csv'))
    .sort()
    .map((f) => readFileSync(join(EXAMPLES, f), 'utf8'));
  const example = buildEpochs(inputsFrom(exampleTexts, 'example'));
  const random = buildEpochs(inputsFrom(randomEpochCsvs(), 'random'));
  return new Map([
    ['example.json', toJson(datasetFixture('example', example))],
    ['random.json', toJson(datasetFixture('random', random))],
    ['claim-authorization.json', toJson(await claimAuthorizationFixture(example))],
  ]);
}

async function main(): Promise<number> {
  const check = process.argv.includes('--check');
  const files = await renderFixtures();
  if (!check) mkdirSync(FIXTURES, { recursive: true });
  const drifted: string[] = [];
  for (const [name, content] of files) {
    const path = join(FIXTURES, name);
    if (check) {
      const current = existsSync(path) ? readFileSync(path, 'utf8') : null;
      if (current !== content) drifted.push(name);
    } else {
      writeFileSync(path, content);
      console.log(`wrote ${path} (${content.length} bytes)`);
    }
  }
  if (drifted.length > 0) {
    console.error(`fixtures out of date: ${drifted.join(', ')}; run \`npm run fixtures\` and commit the result`);
    return 1;
  }
  if (check) console.log(`fixtures up to date (${files.size} files)`);
  return 0;
}

process.exitCode = await main();
