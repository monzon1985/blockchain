// SPDX-License-Identifier: MIT
//
// Differential test vectors: the BigInt reference in sdk/src/math.ts computes
// the expected outputs, and this script emits them twice:
//   * test-vectors/amm-math.json   (read back by the TypeScript unit tests)
//   * tests/vectors_tests.move     (a Move test module that replays every case
//                                    through the real pool / royalty code)
// `--check` regenerates in memory and fails if either committed file drifted.
// The Move module is formatted with the project's Prettier configuration (the
// Move plugin), so the generated file also passes `npm run lint`.
//
// Usage: tsx scripts/gen-vectors.ts [--check]

import { readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { format, resolveConfig } from 'prettier';
import {
  MINIMUM_LIQUIDITY,
  U64_MAX,
  amountOut,
  deposit,
  feeUp,
  isqrt,
  mulDivDown,
  mulDivUp,
  royaltyFee,
  withdraw,
} from '../sdk/src/math.js';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const JSON_PATH = join(ROOT, 'test-vectors', 'amm-math.json');
const MOVE_PATH = join(ROOT, 'tests', 'vectors_tests.move');
const SEED = 0x5eed08n;
const PER_KIND = 24;

/** xorshift64 over BigInt, masked to 64 bits. */
class Rng {
  private state: bigint;
  constructor(seed: bigint) {
    this.state = seed | 1n;
  }
  next(): bigint {
    let x = this.state;
    x ^= (x << 13n) & U64_MAX;
    x ^= x >> 7n;
    x ^= (x << 17n) & U64_MAX;
    this.state = x;
    return x;
  }
  /** Log-uniform value in [lo, hi]: exercises small and huge magnitudes alike. */
  logUniform(lo: bigint, hi: bigint): bigint {
    const bits = BigInt(hi.toString(2).length);
    const width = (this.next() % bits) + 1n;
    const raw = this.next() & ((1n << width) - 1n);
    const span = hi - lo + 1n;
    return lo + (raw % span);
  }
}

interface Vectors {
  seed: string;
  mulDiv: { a: string; b: string; d: string; down: string; up: string }[];
  swap: {
    amountIn: string;
    reserveIn: string;
    reserveOut: string;
    feeBps: string;
    amountOut: string;
    fee: string;
  }[];
  poolSwap: { amountIn: string; reserveA: string; reserveB: string; amountOut: string }[];
  deposit: {
    reserveA: string;
    reserveB: string;
    amountA: string;
    amountB: string;
    lp: string;
    usedA: string;
    usedB: string;
  }[];
  withdraw: { reserveA: string; reserveB: string; lp: string; amountA: string; amountB: string }[];
  flashFee: { amount: string; feeBps: string; fee: string }[];
  royalty: { price: string; bps: string; minAmount: string; fee: string }[];
}

const s = (x: bigint): string => x.toString();

function generate(): Vectors {
  const rng = new Rng(SEED);
  const v: Vectors = {
    seed: `0x${SEED.toString(16)}`,
    mulDiv: [],
    swap: [],
    poolSwap: [],
    deposit: [],
    withdraw: [],
    flashFee: [],
    royalty: [],
  };

  // mul_div: b <= d keeps the quotient within u64 for any a.
  const mulDivEdges: [bigint, bigint, bigint][] = [
    [U64_MAX, U64_MAX, U64_MAX],
    [U64_MAX, 1n, 2n],
    [1n, 1n, 3n],
    [0n, 5n, 7n],
  ];
  for (const [a, b, d] of mulDivEdges)
    v.mulDiv.push({ a: s(a), b: s(b), d: s(d), down: s(mulDivDown(a, b, d)), up: s(mulDivUp(a, b, d)) });
  while (v.mulDiv.length < PER_KIND) {
    const d = rng.logUniform(1n, U64_MAX);
    const b = rng.logUniform(0n, d);
    const a = rng.logUniform(0n, U64_MAX);
    v.mulDiv.push({ a: s(a), b: s(b), d: s(d), down: s(mulDivDown(a, b, d)), up: s(mulDivUp(a, b, d)) });
  }

  // math::amount_out on the full u64 domain.
  while (v.swap.length < PER_KIND) {
    const reserveIn = rng.logUniform(1n, U64_MAX / 2n);
    const reserveOut = rng.logUniform(1n, U64_MAX);
    const amountIn = rng.logUniform(1n, U64_MAX - reserveIn);
    const feeBps = (rng.next() % 100n) + 1n;
    const q = amountOut(amountIn, reserveIn, reserveOut, feeBps);
    v.swap.push({
      amountIn: s(amountIn),
      reserveIn: s(reserveIn),
      reserveOut: s(reserveOut),
      feeBps: s(feeBps),
      amountOut: s(q.amountOut),
      fee: s(q.fee),
    });
  }

  // Real pools (default 30 bps): reserves large enough for creation, trades
  // that produce a non-zero output.
  const poolReserve = (): bigint => rng.logUniform(1_000_000n, 1_000_000_000_000_000n);
  while (v.poolSwap.length < PER_KIND) {
    const reserveA = poolReserve();
    const reserveB = poolReserve();
    const amountIn = rng.logUniform(1n, reserveA * 4n);
    const q = amountOut(amountIn, reserveA, reserveB, 30n);
    if (q.amountOut === 0n) continue;
    v.poolSwap.push({
      amountIn: s(amountIn),
      reserveA: s(reserveA),
      reserveB: s(reserveB),
      amountOut: s(q.amountOut),
    });
  }

  while (v.deposit.length < PER_KIND) {
    const reserveA = poolReserve();
    const reserveB = poolReserve();
    const supply = isqrt(reserveA * reserveB);
    const amountA = rng.logUniform(1n, reserveA * 2n);
    const amountB = rng.logUniform(1n, reserveB * 2n);
    const q = deposit(reserveA, reserveB, supply, amountA, amountB);
    if (q.lp === 0n) continue;
    v.deposit.push({
      reserveA: s(reserveA),
      reserveB: s(reserveB),
      amountA: s(amountA),
      amountB: s(amountB),
      lp: s(q.lp),
      usedA: s(q.usedA),
      usedB: s(q.usedB),
    });
  }

  while (v.withdraw.length < PER_KIND) {
    const reserveA = poolReserve();
    const reserveB = poolReserve();
    const supply = isqrt(reserveA * reserveB);
    const lp = rng.logUniform(1n, supply - MINIMUM_LIQUIDITY);
    const q = withdraw(reserveA, reserveB, supply, lp);
    if (q.amountA === 0n || q.amountB === 0n) continue;
    v.withdraw.push({
      reserveA: s(reserveA),
      reserveB: s(reserveB),
      lp: s(lp),
      amountA: s(q.amountA),
      amountB: s(q.amountB),
    });
  }

  while (v.flashFee.length < PER_KIND) {
    const amount = rng.logUniform(1n, U64_MAX);
    const feeBps = (rng.next() % 100n) + 1n;
    v.flashFee.push({ amount: s(amount), feeBps: s(feeBps), fee: s(feeUp(amount, feeBps)) });
  }

  while (v.royalty.length < PER_KIND) {
    const price = rng.logUniform(0n, 10n ** 15n);
    const bps = rng.next() % 10_001n;
    const minAmount = rng.logUniform(0n, 10n ** 9n);
    v.royalty.push({
      price: s(price),
      bps: s(bps),
      minAmount: s(minAmount),
      fee: s(royaltyFee(price, bps, minAmount)),
    });
  }
  return v;
}

function moveModule(v: Vectors): string {
  /** LP marker of the `i`-th pool created inside one test. */
  const m = (i: number): string => `M${i}`;
  const markerDecls = Array.from({ length: PER_KIND }, (_, i) => `public struct ${m(i)} {}`).join('\n');
  const header = `// SPDX-License-Identifier: MIT
// @generated by scripts/gen-vectors.ts from test-vectors/amm-math.json. Do not edit.

#[test_only]
/// Differential tests: every expected value below was computed by the BigInt
/// reference in sdk/src/math.ts, and is replayed here through the Move code
/// (the math helpers, real pools in a test_scenario, and a real TransferPolicy).
module flash_kiosk::vectors_tests;

use flash_kiosk::collectible::Collectible;
use flash_kiosk::math;
use flash_kiosk::pool::{Pool, LpCoin};
use flash_kiosk::royalty_rule;
use flash_kiosk::test_utils::{Self as tu, ALPHA, BETA};
use std::unit_test::{assert_eq, destroy};
use sui::coin::Coin;
use sui::test_scenario::Scenario;
use sui::transfer_policy;

/// LP markers: the i-th pool created inside a test is \`Pool<ALPHA, BETA, Mi>\`.
${markerDecls}

/// Creates a fresh pool whose LP marker is \`M\` (a marker backs exactly one
/// pool, so every vector of a test uses its own) and returns it with the
/// creator's LP coin.
fun new_pool<M>(
    scenario: &mut Scenario,
    reserve_a: u64,
    reserve_b: u64,
): (Pool<ALPHA, BETA, M>, Coin<LpCoin<M>>) {
    scenario.next_tx(tu::alice());
    let (lp, cap) = tu::new_pool<M>(scenario, reserve_a, reserve_b);
    destroy(cap);
    scenario.next_tx(tu::alice());
    (tu::take_pool<M>(scenario), lp)
}

fun check_mul_div(a: u64, b: u64, d: u64, down: u64, up: u64) {
    assert_eq!(math::mul_div_down!(a, b, d), down);
    assert_eq!(math::mul_div_up!(a, b, d), up);
}

fun check_amount_out(amount_in: u64, reserve_in: u64, reserve_out: u64, fee_bps: u64, out: u64, fee: u64) {
    let (actual_out, actual_fee) = math::amount_out(amount_in, reserve_in, reserve_out, fee_bps);
    assert_eq!(actual_out, out);
    assert_eq!(actual_fee, fee);
}

fun check_flash_fee(amount: u64, fee_bps: u64, fee: u64) {
    assert_eq!(math::fee_up!(amount, fee_bps), fee);
}

fun check_pool_swap<M>(
    scenario: &mut Scenario,
    reserve_a: u64,
    reserve_b: u64,
    amount_in: u64,
    out: u64,
) {
    let (mut p, lp) = new_pool<M>(scenario, reserve_a, reserve_b);
    let coin_in = tu::mint<ALPHA>(scenario, amount_in);
    let coin_out = p.swap_a_for_b(coin_in, out, scenario.ctx());
    assert_eq!(tu::burn(coin_out), out);
    destroy(lp);
    tu::return_pool(p);
}

fun check_deposit<M>(
    scenario: &mut Scenario,
    reserve_a: u64,
    reserve_b: u64,
    amount_a: u64,
    amount_b: u64,
    lp_minted: u64,
    used_a: u64,
    used_b: u64,
) {
    let (mut p, lp0) = new_pool<M>(scenario, reserve_a, reserve_b);
    let a = tu::mint<ALPHA>(scenario, amount_a);
    let b = tu::mint<BETA>(scenario, amount_b);
    let (lp, refund_a, refund_b) = p.add_liquidity(a, b, lp_minted, scenario.ctx());
    assert_eq!(tu::burn(lp), lp_minted);
    assert_eq!(tu::burn(refund_a), amount_a - used_a);
    assert_eq!(tu::burn(refund_b), amount_b - used_b);
    destroy(lp0);
    tu::return_pool(p);
}

fun check_withdraw<M>(
    scenario: &mut Scenario,
    reserve_a: u64,
    reserve_b: u64,
    lp: u64,
    amount_a: u64,
    amount_b: u64,
) {
    let (mut p, mut lp0) = new_pool<M>(scenario, reserve_a, reserve_b);
    let burn = lp0.split(lp, scenario.ctx());
    let (a, b) = p.remove_liquidity(burn, amount_a, amount_b, scenario.ctx());
    assert_eq!(tu::burn(a), amount_a);
    assert_eq!(tu::burn(b), amount_b);
    destroy(lp0);
    tu::return_pool(p);
}

fun check_royalty(ctx: &mut TxContext, price: u64, bps: u64, min_amount: u64, fee: u64) {
    let (mut policy, cap) = transfer_policy::new_for_testing<Collectible>(ctx);
    royalty_rule::add(&mut policy, &cap, bps, min_amount);
    assert_eq!(royalty_rule::fee_amount(&policy, price), fee);
    destroy(policy.destroy_and_withdraw(cap, ctx));
}
`;
  const body: string[] = [];
  const scenario = ['let mut scenario = tu::begin();'];
  const test = (name: string, prelude: string[], calls: string[]): void => {
    body.push('', '#[test]', `fun ${name}() {`);
    body.push(...prelude.map((line) => `    ${line}`));
    body.push(...calls.map((c) => `    ${c};`));
    if (prelude === scenario) body.push('    scenario.end();');
    body.push('}');
  };
  test(
    'mul_div_vectors',
    [],
    v.mulDiv.map((c) => `check_mul_div(${c.a}, ${c.b}, ${c.d}, ${c.down}, ${c.up})`),
  );
  test(
    'amount_out_vectors',
    [],
    v.swap.map(
      (c) =>
        `check_amount_out(${c.amountIn}, ${c.reserveIn}, ${c.reserveOut}, ${c.feeBps}, ${c.amountOut}, ${c.fee})`,
    ),
  );
  test(
    'flash_fee_vectors',
    [],
    v.flashFee.map((c) => `check_flash_fee(${c.amount}, ${c.feeBps}, ${c.fee})`),
  );
  test(
    'pool_swap_vectors',
    scenario,
    v.poolSwap.map(
      (c, i) =>
        `check_pool_swap<${m(i)}>(&mut scenario, ${c.reserveA}, ${c.reserveB}, ${c.amountIn}, ${c.amountOut})`,
    ),
  );
  test(
    'deposit_vectors',
    scenario,
    v.deposit.map(
      (c, i) =>
        `check_deposit<${m(i)}>(&mut scenario, ${c.reserveA}, ${c.reserveB}, ${c.amountA}, ${c.amountB}, ${c.lp}, ${c.usedA}, ${c.usedB})`,
    ),
  );
  test(
    'withdraw_vectors',
    scenario,
    v.withdraw.map(
      (c, i) =>
        `check_withdraw<${m(i)}>(&mut scenario, ${c.reserveA}, ${c.reserveB}, ${c.lp}, ${c.amountA}, ${c.amountB})`,
    ),
  );
  test(
    'royalty_vectors',
    ['let mut ctx = tx_context::dummy();'],
    v.royalty.map((c) => `check_royalty(&mut ctx, ${c.price}, ${c.bps}, ${c.minAmount}, ${c.fee})`),
  );
  return `${header}${body.join('\n')}\n`;
}

/** Formats generated Move source with the project's Prettier config (Move plugin). */
async function formatMove(source: string): Promise<string> {
  const options = (await resolveConfig(MOVE_PATH)) ?? {};
  return format(source, { ...options, filepath: MOVE_PATH });
}

async function main(): Promise<void> {
  const check = process.argv.includes('--check');
  const vectors = generate();
  const json = `${JSON.stringify(vectors, null, 2)}\n`;
  const move = await formatMove(moveModule(vectors));
  if (check) {
    const [onDiskJson, onDiskMove] = await Promise.all([
      readFile(JSON_PATH, 'utf8'),
      readFile(MOVE_PATH, 'utf8'),
    ]);
    const stale = [onDiskJson !== json ? JSON_PATH : '', onDiskMove !== move ? MOVE_PATH : ''].filter(
      Boolean,
    );
    if (stale.length > 0) {
      console.error(`Stale generated files (run \`npm run vectors\`):\n  ${stale.join('\n  ')}`);
      process.exit(1);
    }
    console.log('Differential vectors are up to date.');
    return;
  }
  await writeFile(JSON_PATH, json);
  await writeFile(MOVE_PATH, move);
  console.log(`Wrote ${JSON_PATH} and ${MOVE_PATH}.`);
}

await main();
