// SPDX-License-Identifier: MIT
import * as fs from "node:fs";

/**
 * Strict `--flag value` parser shared by the CLIs: every flag must be in
 * `allowed`, every flag takes exactly one value, and positional arguments
 * other than the leading sub-command are rejected.
 */
export function parseFlags(argv: string[], allowed: readonly string[]): Map<string, string> {
  const out = new Map<string, string>();
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i] as string;
    if (!key.startsWith("--")) throw new Error(`unexpected argument "${key}"`);
    const name = key.slice(2);
    if (!allowed.includes(name)) throw new Error(`unknown flag --${name} (allowed: ${allowed.map((a) => `--${a}`).join(", ")})`);
    const value = argv[i + 1];
    if (value === undefined || value.startsWith("--")) throw new Error(`flag --${name} needs a value`);
    if (out.has(name)) throw new Error(`flag --${name} given twice`);
    out.set(name, value);
  }
  return out;
}

/** Required flag. */
export function required(flags: Map<string, string>, name: string): string {
  const v = flags.get(name);
  if (v === undefined) throw new Error(`missing --${name}`);
  return v;
}

/** Parse a decimal or 0x-hex integer flag. */
export function bigintFlag(flags: Map<string, string>, name: string): bigint {
  const raw = required(flags, name);
  if (!/^(0x[0-9a-fA-F]+|[0-9]+)$/.test(raw)) throw new Error(`--${name} must be a decimal or 0x-hex integer`);
  return BigInt(raw);
}

/** Write a JSON file readable only by the current user (secrets). */
export function writeSecretJson(file: string, data: unknown): void {
  fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`, { mode: 0o600 });
}

/** Write a JSON file. */
export function writeJson(file: string, data: unknown): void {
  fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`);
}

/** Read a JSON file. */
export function readJson<T>(file: string): T {
  return JSON.parse(fs.readFileSync(file, "utf8")) as T;
}

/** Run a CLI main, printing errors without a stack and setting the exit code. */
export function runCli(main: () => Promise<void>): void {
  main().then(
    // snarkjs keeps a curve worker pool alive; exit explicitly.
    () => process.exit(0),
    (err: unknown) => {
      console.error(err instanceof Error ? err.message : err);
      process.exit(1);
    },
  );
}
