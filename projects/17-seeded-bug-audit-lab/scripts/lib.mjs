// SPDX-License-Identifier: MIT
// Shared helpers for the lab's Node tooling (no dependencies; Node 24).

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** Absolute path of the project root (the directory above scripts/). */
export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

/** Read a text file relative to the project root, normalizing line endings to LF. */
export function readText(rel) {
  return readFileSync(join(ROOT, rel), "utf8").replace(/\r\n/g, "\n");
}

/** Read and parse a JSON file relative to the project root. */
export function readJson(rel) {
  return JSON.parse(readText(rel));
}

/** Serialize JSON deterministically (2-space indent, trailing newline). */
export function stringify(value) {
  return JSON.stringify(value, null, 2) + "\n";
}

/** Write a text file relative to the project root (creating directories). */
export function writeText(rel, content) {
  const abs = join(ROOT, rel);
  mkdirSync(dirname(abs), { recursive: true });
  writeFileSync(abs, content);
}

/** True when the file exists relative to the project root. */
export function exists(rel) {
  return existsSync(join(ROOT, rel));
}

/**
 * Replace the content between `<!-- BEGIN:name -->` and `<!-- END:name -->` markers.
 * Throws when the markers are missing, so a renamed section cannot silently go stale.
 */
export function replaceBlock(text, name, body) {
  const begin = `<!-- BEGIN:${name} -->`;
  const end = `<!-- END:${name} -->`;
  const i = text.indexOf(begin);
  const j = text.indexOf(end);
  if (i < 0 || j < 0 || j < i) throw new Error(`missing markers for block "${name}"`);
  return text.slice(0, i + begin.length) + "\n" + body.trimEnd() + "\n" + text.slice(j);
}

/**
 * Generated-file manager: in write mode files are written; in --check mode every difference is
 * collected and reported, and the process exits non-zero.
 */
export class Outputs {
  constructor(check) {
    this.check = check;
    this.drift = [];
  }

  emit(rel, content) {
    const current = exists(rel) ? readText(rel) : null;
    if (current === content) return;
    if (this.check) this.drift.push(rel);
    else writeText(rel, content);
  }

  finish(label) {
    if (this.check && this.drift.length > 0) {
      console.error(`${label}: out of date:\n  - ${this.drift.join("\n  - ")}\nRun the script without --check and commit.`);
      process.exit(1);
    }
    console.log(`${label}: ${this.check ? "up to date" : "written"}.`);
  }
}

/** Fail with a list of messages. */
export function fail(label, errors) {
  console.error(`${label}:\n  - ${errors.join("\n  - ")}`);
  process.exit(1);
}

/** Parse `--flag value` pairs from argv. */
export function flags(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) {
      const key = argv[i].slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) out[key] = true;
      else {
        out[key] = next;
        i++;
      }
    }
  }
  return out;
}
