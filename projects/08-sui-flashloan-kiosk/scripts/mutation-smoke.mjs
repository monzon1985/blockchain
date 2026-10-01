#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// @ts-check
//
// Mutation smoke test: plants one realistic bug at a time in a scratch copy of
// the Move package and requires the named test module to catch it. A mutant
// "survives" if the tests still pass; one that stops compiling is a broken
// mutant (the harness fails either way). The baseline (no mutation) must pass
// first, so a red suite cannot count as a kill.
//
// Every run pins the `#[random_test]` inputs with `--seed` (MOVE_TEST_SEED,
// default 20260929, the CI gate's seed), so a verdict never depends on luck.
//
// Usage: node scripts/mutation-smoke.mjs [--only <mutant-id>] [--seed <u64>]

import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseFlags, runSui } from './lib/sui-cli.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
/** Default seed for `#[random_test]`, the same one the CI gate pins. */
const DEFAULT_SEED = '20260929';

/**
 * @typedef {{ id: string, file: string, find: string, replace: string, tests: string, bug: string }} Mutant
 */

/** @type {Mutant[]} */
const MUTANTS = [
    {
        id: 'flash-fee-rounds-down',
        file: 'sources/pool.move',
        find: 'let fee = math::fee_up!(amount, pool.flash_fee_bps);\n    let pool_id = object::id(pool);',
        replace:
            'let fee = math::mul_div_down!(amount, pool.flash_fee_bps, 10_000);\n    let pool_id = object::id(pool);',
        tests: 'flash_tests',
        bug: 'flash fee truncated: small loans become free',
    },
    {
        id: 'no-flash-loan-lock',
        file: 'sources/pool.move',
        find: '    pool.state = PoolState::FlashLoanOpen;\n',
        replace: '',
        tests: 'flash_tests',
        bug: 'pool stays Active during a loan: same-pool price manipulation',
    },
    {
        id: 'repay-principal-only',
        file: 'sources/pool.move',
        find: 'assert!(paid == amount + fee, ERepayAmount);',
        replace: 'assert!(paid >= amount, ERepayAmount);',
        tests: 'flash_tests',
        bug: 'repay accepts principal without the fee',
    },
    {
        id: 'receipt-pool-unchecked',
        file: 'sources/pool.move',
        find: 'assert!(pool_id == object::id(pool), EWrongPool);',
        replace: 'assert!(pool_id == pool_id, EWrongPool);',
        tests: 'flash_tests',
        bug: 'receipt from pool A can be settled on pool B',
    },
    {
        id: 'withdraw-rounds-up',
        file: 'sources/pool.move',
        find: 'let amount_a = math::mul_div_down!(lp_burned, reserve_a, supply);',
        replace: 'let amount_a = math::mul_div_up!(lp_burned, reserve_a, supply);',
        tests: 'pool_tests',
        bug: 'withdrawal rounded in favour of the leaving LP',
    },
    {
        id: 'deposit-pull-rounds-down',
        file: 'sources/pool.move',
        find: 'let used_b = math::mul_div_up!(lp_minted, reserve_b, supply);',
        replace: 'let used_b = math::mul_div_down!(lp_minted, reserve_b, supply);',
        tests: 'pool_tests',
        bug: 'depositor under-pays by one unit per deposit',
    },
    {
        id: 'lp-mint-rounds-up',
        file: 'sources/pool.move',
        find: 'let lp_from_a = math::mul_div_down!(coin_a.value(), supply, reserve_a);',
        replace: 'let lp_from_a = math::mul_div_up!(coin_a.value(), supply, reserve_a);',
        tests: 'invariant_tests',
        bug: 'LP shares minted in favour of the depositor (dilution)',
    },
    {
        id: 'swap-fee-rounds-down',
        file: 'sources/math.move',
        find: '    let fee = fee_up!(amount_in, fee_bps);',
        replace: '    let fee = mul_div_down!(amount_in, fee_bps, 10_000);',
        tests: 'vectors_tests',
        bug: 'swap fee truncated (caught by the TypeScript differential vectors)',
    },
    {
        id: 'stale-version-accepted',
        file: 'sources/pool.move',
        find: 'assert!(pool.version == VERSION, EWrongVersion);',
        replace: 'assert!(pool.version <= VERSION, EWrongVersion);',
        tests: 'admin_tests',
        bug: 'old package versions keep operating on migrated objects',
    },
    {
        id: 'cooldown-off-by-one',
        file: 'sources/cooldown_rule.move',
        find: 'assert!(now >= *last + config.cooldown_ms, ECooldownActive);',
        replace: 'assert!(now + 1 >= *last + config.cooldown_ms, ECooldownActive);',
        tests: 'kiosk_tests',
        bug: 'resale allowed one millisecond early',
    },
    {
        id: 'royalty-without-floor',
        file: 'sources/royalty_rule.move',
        find: 'math::fee_up!(price, config.amount_bps).max(config.min_amount)',
        replace: 'math::fee_up!(price, config.amount_bps)',
        tests: 'kiosk_tests',
        bug: 'zero-price listings pay no royalty',
    },
    {
        id: 'lock-rule-accepts-placed-item',
        file: 'sources/kiosk_lock_rule.move',
        find: 'assert!(kiosk.has_item(item) && kiosk.is_locked(item), ENotLockedInKiosk);',
        replace: 'assert!(kiosk.has_item(item), ENotLockedInKiosk);',
        tests: 'kiosk_tests',
        bug: 'item can be placed unlocked, then taken out and moved without the policy',
    },
    {
        id: 'publisher-kept',
        file: 'sources/collectible.move',
        find: '    publisher.burn_publisher();',
        replace: '    transfer::public_transfer(publisher, ctx.sender());',
        tests: 'kiosk_tests',
        bug: 'deployer keeps the Publisher and can mint a rule-free TransferPolicy',
    },
    {
        id: 'lp-metadata-cap-kept',
        file: 'sources/pool.move',
        find: '    lp_currency.finalize_and_delete_metadata_cap(ctx);',
        replace: '    transfer::public_transfer(lp_currency.finalize(ctx), ctx.sender());',
        tests: 'pool_tests',
        bug: 'pool creator keeps a MetadataCap and can rewrite what wallets show for the LP coin',
    },
    {
        id: 'fee-change-mid-loan',
        file: 'sources/pool.move',
        find: '    pool.assert_version();\n    pool.assert_no_open_loan();\n    assert!(swap_fee_bps',
        replace: '    pool.assert_version();\n    assert!(swap_fee_bps',
        tests: 'flash_tests',
        bug: 'fees can be changed while a loan is open',
    },
    {
        id: 'policy-admin-unbounded-cooldown',
        file: 'sources/collectible.move',
        find: '    assert!(cooldown_ms <= MAX_COOLDOWN_MS, ECooldownAboveBound);\n',
        replace: '',
        tests: 'kiosk_tests',
        bug: 'PolicyAdmin can freeze resales for up to a year instead of 30 days',
    },
];

/**
 * @param {string} scratch
 * @param {string} filter
 * @param {string} seed
 * @returns {Promise<'pass' | 'fail' | 'compile-error'>}
 */
async function runTests(scratch, filter, seed) {
    const { code, output } = await runSui(['move', 'test', '--path', scratch, '--seed', seed, filter]);
    // Test failures are also reported as `error[EC11001]`; only a failed build
    // (no test run at all) counts as a broken mutant.
    if (!output.includes('Running Move unit tests')) return 'compile-error';
    if (code === 0 && output.includes('Test result: OK')) return 'pass';
    if (output.includes('Test result: FAILED')) return 'fail';
    return 'compile-error';
}

async function main() {
    const flags = parseFlags(process.argv.slice(2));
    const only = flags.get('only');
    const seed = flags.get('seed') ?? process.env['MOVE_TEST_SEED'] ?? DEFAULT_SEED;
    if (!/^\d+$/.test(seed)) throw new Error(`--seed must be an unsigned integer, got ${seed}`);
    const mutants = only === undefined ? MUTANTS : MUTANTS.filter((m) => m.id === only);
    if (mutants.length === 0) throw new Error(`unknown mutant ${only}`);

    const scratch = await mkdtemp(join(tmpdir(), 'flash-kiosk-mutants-'));
    try {
        for (const entry of ['Move.toml', 'Move.lock', 'sources', 'tests']) {
            await cp(join(ROOT, entry), join(scratch, entry), { recursive: true });
        }
        const baseline = await runTests(scratch, '', seed);
        if (baseline !== 'pass') throw new Error(`baseline suite is not green (${baseline})`);
        console.log(`  baseline: all tests pass on the unmutated copy (--seed ${seed})`);

        let killed = 0;
        let problems = 0;
        for (const m of mutants) {
            const path = join(scratch, m.file);
            const original = await readFile(path, 'utf8');
            if (!original.includes(m.find)) throw new Error(`${m.id}: pattern not found in ${m.file}`);
            await writeFile(path, original.replace(m.find, m.replace));
            const verdict = await runTests(scratch, m.tests, seed);
            await writeFile(path, original);
            if (verdict === 'fail') {
                killed++;
                console.log(`  killed    ${m.id.padEnd(32)} by ${m.tests.padEnd(16)} ${m.bug}`);
            } else {
                problems++;
                const what = verdict === 'pass' ? 'SURVIVED' : 'BROKEN  ';
                console.log(`  ${what}  ${m.id.padEnd(32)} (${m.tests}) ${m.bug}`);
            }
        }
        console.log(`\n${killed}/${mutants.length} mutants killed.`);
        if (problems > 0) process.exit(1);
    } finally {
        await rm(scratch, { recursive: true, force: true });
    }
}

await main();
