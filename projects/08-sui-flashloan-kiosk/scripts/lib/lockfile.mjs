// SPDX-License-Identifier: MIT
// @ts-check
// Pure helper behind scripts/normalize-move-lock.mjs, kept separate for unit tests.

/**
 * Rewrites every git `subdir` of a Move.lock into its canonical, portable form:
 * forward slashes inside a double-quoted (basic) TOML string.
 *
 * The Sui CLI writes Move.lock with toml_edit, which infers the string style:
 * a value containing a backslash (a Windows path) becomes a single-quoted
 * literal string, anything else a double-quoted basic string. The canonical
 * form is therefore exactly what a Linux or macOS build writes, so a build on
 * those platforms leaves a normalised lock file byte-for-byte unchanged.
 * A canonical path holds no `"` or `\`, so no TOML escaping is needed.
 * @param {string} text
 * @returns {string}
 */
export function normalizeLock(text) {
    return text.replace(
        /subdir = (?:'([^']*)'|"([^"\\]*)")/g,
        (_match, /** @type {string | undefined} */ literal, /** @type {string | undefined} */ basic) => {
            const path = literal ?? basic ?? '';
            return `subdir = "${path.replaceAll('\\', '/')}"`;
        },
    );
}
