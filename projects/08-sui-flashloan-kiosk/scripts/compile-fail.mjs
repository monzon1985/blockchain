#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// @ts-check
//
// Compile-fail harness. Every package under fixtures/compile-fail/ is an
// exploit that the type system must reject: break the FlashReceipt (or Kiosk
// TransferRequest) hot potato (drop, copy, store, transfer, forge or rewrite
// it), move a shared Pool out of shared ownership, reach the cooldown stamp
// (forge its key, borrow the item's UID), use the TransferPolicyCap wrapped in
// PolicyAdmin, or register a pool's LP coin from outside `pool` (to regulate
// it). Each one must FAIL `sui move build` with the exact diagnostic code and
// message recorded in fixtures/compile-fail/expected.json. The positive control under
// fixtures/compile-pass/ uses the identical setup correctly and must SUCCEED,
// so a broken dependency path can never masquerade as a "compile failure".
//
// Usage: node scripts/compile-fail.mjs [--concurrency 3]

import { cp, mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseFlags, runSui } from './lib/sui-cli.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const FAIL_DIR = join(ROOT, 'fixtures', 'compile-fail');
const PASS_DIR = join(ROOT, 'fixtures', 'compile-pass');

/**
 * @typedef {{ code: string, message: string }} Expectation
 * @typedef {{ name: string, kind: 'fail' | 'pass', dir: string, expect?: Expectation }} Fixture
 * @typedef {{ fixture: Fixture, ok: boolean, detail: string }} Outcome
 */

/**
 * Copies a fixture into a scratch directory and points its `flash_kiosk`
 * dependency at the project root by absolute path, so builds leave no
 * `build/` or `Move.lock` behind in the repository.
 * @param {Fixture} fixture
 * @param {string} scratch
 * @returns {Promise<string>}
 */
async function stage(fixture, scratch) {
    const target = join(scratch, `${fixture.kind}-${fixture.name}`);
    await cp(fixture.dir, target, { recursive: true });
    const manifestPath = join(target, 'Move.toml');
    const manifest = await readFile(manifestPath, 'utf8');
    const rootPath = ROOT.replaceAll('\\', '/');
    const rewritten = manifest.replace(/local\s*=\s*"\.\.\/\.\.\/\.\."/, `local = "${rootPath}"`);
    if (rewritten === manifest) {
        throw new Error(`${fixture.name}: Move.toml must depend on flash_kiosk via local = "../../.."`);
    }
    await writeFile(manifestPath, rewritten);
    return target;
}

/**
 * @param {Fixture} fixture
 * @param {string} scratch
 * @returns {Promise<Outcome>}
 */
async function check(fixture, scratch) {
    const path = await stage(fixture, scratch);
    const { code, output } = await runSui(['move', 'build', '--path', path]);
    if (fixture.kind === 'pass') {
        return code === 0
            ? { fixture, ok: true, detail: 'compiles' }
            : { fixture, ok: false, detail: `positive control failed to build:\n${output}` };
    }
    const expect = /** @type {Expectation} */ (fixture.expect);
    if (code === 0) return { fixture, ok: false, detail: 'build SUCCEEDED; the exploit compiles' };
    if (!output.includes(`error[${expect.code}]`)) {
        return { fixture, ok: false, detail: `missing diagnostic ${expect.code}:\n${output}` };
    }
    if (!output.includes(expect.message)) {
        return { fixture, ok: false, detail: `missing message "${expect.message}":\n${output}` };
    }
    return { fixture, ok: true, detail: `${expect.code} ${expect.message}` };
}

/**
 * Runs `worker` over `items` with at most `limit` in flight.
 * @template T, R
 * @param {T[]} items
 * @param {number} limit
 * @param {(item: T) => Promise<R>} worker
 * @returns {Promise<R[]>}
 */
async function pool(items, limit, worker) {
    /** @type {R[]} */
    const results = new Array(items.length);
    let next = 0;
    async function lane() {
        while (next < items.length) {
            const index = next++;
            results[index] = await worker(/** @type {T} */ (items[index]));
        }
    }
    await Promise.all(Array.from({ length: Math.min(limit, items.length) }, lane));
    return results;
}

async function main() {
    const flags = parseFlags(process.argv.slice(2));
    const concurrency = Number(flags.get('concurrency') ?? '3');

    /** @type {unknown} */
    const raw = JSON.parse(await readFile(join(FAIL_DIR, 'expected.json'), 'utf8'));
    const expected = /** @type {Record<string, Expectation>} */ (raw);
    delete expected['$comment'];

    const failDirs = (await readdir(FAIL_DIR, { withFileTypes: true }))
        .filter((e) => e.isDirectory())
        .map((e) => e.name)
        .sort();
    const passDirs = (await readdir(PASS_DIR, { withFileTypes: true }))
        .filter((e) => e.isDirectory())
        .map((e) => e.name)
        .sort();

    const orphans = Object.keys(expected).filter((name) => !failDirs.includes(name));
    const unlisted = failDirs.filter((name) => !(name in expected));
    if (orphans.length > 0 || unlisted.length > 0) {
        console.error(
            `expected.json out of sync. orphans=${orphans.join(',')} unlisted=${unlisted.join(',')}`,
        );
        process.exit(1);
    }

    /** @type {Fixture[]} */
    const fixtures = [
        ...passDirs.map((name) => ({ name, kind: /** @type {const} */ ('pass'), dir: join(PASS_DIR, name) })),
        ...failDirs.map((name) => ({
            name,
            kind: /** @type {const} */ ('fail'),
            dir: join(FAIL_DIR, name),
            expect: /** @type {Expectation} */ (expected[name]),
        })),
    ];

    const scratch = await mkdtemp(join(tmpdir(), 'flash-kiosk-compile-fail-'));
    try {
        // The positive control runs first and alone: it also warms the dependency cache.
        const control = fixtures.filter((f) => f.kind === 'pass');
        const negatives = fixtures.filter((f) => f.kind === 'fail');
        const outcomes = [
            ...(await pool(control, 1, (f) => check(f, scratch))),
            ...(await pool(negatives, concurrency, (f) => check(f, scratch))),
        ];

        let failed = 0;
        for (const { fixture, ok, detail } of outcomes) {
            const label = fixture.kind === 'pass' ? 'compile-pass' : 'compile-fail';
            if (ok) {
                console.log(`  ok    ${label}/${fixture.name}  (${detail})`);
            } else {
                failed++;
                console.log(`  FAIL  ${label}/${fixture.name}\n${detail}`);
            }
        }
        const negativesOk = outcomes.filter((o) => o.ok && o.fixture.kind === 'fail').length;
        console.log(
            `\n${negativesOk}/${negatives.length} exploits rejected by the compiler, ` +
                `${control.length} positive control(s) compiled.`,
        );
        if (failed > 0) process.exit(1);
    } finally {
        await rm(scratch, { recursive: true, force: true });
    }
}

await main();
