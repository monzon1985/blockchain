#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// @ts-check
//
// Coverage gate for the Move package. Reads the report produced by the last
// `sui move test --coverage` run (via `sui move coverage summary`) and fails
// unless the package-wide instruction coverage is at least --min percent.
// `sui move coverage summary` only reports the package's own modules; the
// #[test_only] modules under tests/ are not part of the denominator.
//
// Usage: node scripts/check-move-coverage.mjs --min 90 [--module-min 85]

import { access } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseSummary } from './lib/coverage.mjs';
import { parseFlags, runSui } from './lib/sui-cli.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

async function main() {
    const flags = parseFlags(process.argv.slice(2));
    const min = Number(flags.get('min') ?? '90');
    const moduleMin = flags.has('module-min') ? Number(flags.get('module-min')) : undefined;

    try {
        await access(join(ROOT, '.coverage_map.mvcov'));
    } catch {
        console.error('No coverage data. Run `sui move test --coverage` first.');
        process.exit(1);
    }

    const { code, output } = await runSui(['move', 'coverage', 'summary'], { cwd: ROOT });
    if (code !== 0) {
        console.error(output);
        process.exit(1);
    }
    const { modules, total } = parseSummary(output);
    if (total === undefined || modules.length === 0) {
        console.error(`Could not parse coverage summary:\n${output}`);
        process.exit(1);
    }

    let failed = false;
    console.log('Move instruction coverage (sources/ only):');
    for (const { name, pct } of modules) {
        const below = moduleMin !== undefined && pct < moduleMin;
        failed ||= below;
        console.log(`  ${below ? 'LOW ' : '    '}${name.padEnd(18)} ${pct.toFixed(2)} %`);
    }
    console.log(`  total              ${total.toFixed(2)} %  (gate: >= ${min} %)`);
    if (total < min) {
        console.error(`Coverage ${total.toFixed(2)} % is below the ${min} % gate.`);
        failed = true;
    }
    if (failed) process.exit(1);
}

await main();
