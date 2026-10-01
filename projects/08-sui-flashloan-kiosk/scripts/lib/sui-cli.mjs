// SPDX-License-Identifier: MIT
// @ts-check
// Small helpers shared by the Node scripts that drive the Sui CLI.

import { spawn } from 'node:child_process';

/** Sui CLI binary; override with SUI_BIN. */
export const SUI_BIN = process.env['SUI_BIN'] ?? 'sui';

/**
 * Removes ANSI colour sequences so diagnostics can be matched as plain text.
 * @param {string} text
 * @returns {string}
 */
export function stripAnsi(text) {
    // eslint-disable-next-line no-control-regex
    return text.replace(/\u001b\[[0-9;]*m/g, '');
}

/**
 * Runs the Sui CLI and resolves with its exit code and combined output.
 * Never rejects on a non-zero exit: callers decide what a failure means.
 * @param {string[]} args
 * @param {{ cwd?: string, timeoutMs?: number }} [options]
 * @returns {Promise<{ code: number, output: string }>}
 */
export function runSui(args, options = {}) {
    return new Promise((resolve, reject) => {
        const child = spawn(SUI_BIN, args, {
            cwd: options.cwd,
            env: { ...process.env, NO_COLOR: '1', CLICOLOR: '0' },
            stdio: ['ignore', 'pipe', 'pipe'],
        });
        let output = '';
        child.stdout.on('data', (chunk) => (output += String(chunk)));
        child.stderr.on('data', (chunk) => (output += String(chunk)));
        const timer = setTimeout(
            () => {
                child.kill();
                reject(new Error(`sui ${args.join(' ')} timed out after ${options.timeoutMs} ms`));
            },
            options.timeoutMs ?? 15 * 60_000,
        );
        child.on('error', (err) => {
            clearTimeout(timer);
            reject(err);
        });
        child.on('close', (code) => {
            clearTimeout(timer);
            resolve({ code: code ?? 1, output: stripAnsi(output) });
        });
    });
}

/**
 * Minimal `--flag value` parser for the scripts in this folder.
 * @param {string[]} argv
 * @returns {Map<string, string>}
 */
export function parseFlags(argv) {
    const flags = /** @type {Map<string, string>} */ (new Map());
    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        if (arg === undefined || !arg.startsWith('--')) continue;
        const next = argv[i + 1];
        if (next !== undefined && !next.startsWith('--')) {
            flags.set(arg.slice(2), next);
            i++;
        } else {
            flags.set(arg.slice(2), 'true');
        }
    }
    return flags;
}
