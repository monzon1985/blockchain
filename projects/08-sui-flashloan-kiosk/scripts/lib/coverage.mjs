// SPDX-License-Identifier: MIT
// @ts-check
// Parser for `sui move coverage summary`, kept separate so it can be unit-tested.

/**
 * Parses the human-readable summary. The CSV variant is avoided on purpose:
 * its header labels the total-instruction column as "Uncovered".
 * @param {string} output
 * @returns {{ modules: { name: string, pct: number }[], total: number | undefined }}
 */
export function parseSummary(output) {
    /** @type {{ name: string, pct: number }[]} */
    const modules = [];
    let current = '';
    let total;
    for (const line of output.split(/\r?\n/)) {
        const moduleMatch = /^Module\s+[0-9a-fA-Fx]+::(\w+)/.exec(line.trim());
        if (moduleMatch?.[1] !== undefined) current = moduleMatch[1];
        const pctMatch = />>> % Module coverage:\s*([\d.]+)/.exec(line);
        if (pctMatch?.[1] !== undefined && current !== '') {
            modules.push({ name: current, pct: Number(pctMatch[1]) });
        }
        const totalMatch = /% Move Coverage:\s*([\d.]+)/.exec(line);
        if (totalMatch?.[1] !== undefined) total = Number(totalMatch[1]);
    }
    return { modules, total };
}
