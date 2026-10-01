#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// @ts-check
//
// The Sui CLI (1.80.1) rewrites Move.lock on every build and serialises the
// `subdir` of git dependencies with the host's path separator, so a build on
// Windows turns
//   subdir = "crates/sui-framework/packages/sui-framework"
// into
//   subdir = 'crates\sui-framework\packages\sui-framework'
// which a Linux checkout would treat as a single directory name. This script
// rewrites those values into the canonical form (forward slashes, double
// quotes), which is exactly what a Linux build writes, so the committed lock
// files are portable and a CI build leaves them unchanged. It is idempotent
// and only touches `subdir` values.
//
// Usage: node scripts/normalize-move-lock.mjs [--check]
//   (no flag)  rewrite the lock files in place
//   --check    exit 1 if a lock file is not in canonical form

import { readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { normalizeLock } from './lib/lockfile.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const LOCKS = [join(ROOT, 'Move.lock'), join(ROOT, 'demo', 'coins', 'Move.lock')];

const check = process.argv.includes('--check');
let stale = 0;
for (const path of LOCKS) {
    const before = await readFile(path, 'utf8');
    const after = normalizeLock(before);
    if (after === before) continue;
    stale++;
    if (check) console.error(`${path} is not canonical; run node scripts/normalize-move-lock.mjs`);
    else await writeFile(path, after);
}
if (check && stale > 0) process.exit(1);
console.log(check ? 'Move.lock files are portable.' : `Normalised ${stale} lock file(s).`);
