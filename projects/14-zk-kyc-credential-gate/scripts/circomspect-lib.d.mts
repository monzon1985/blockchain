// SPDX-License-Identifier: MIT
// Type declarations for scripts/circomspect-lib.mjs (used by test/lint.test.ts).
export interface Suppression {
  ruleId: string;
  file: string;
  match: string;
  justification: string;
}
export interface Finding {
  ruleId: string;
  level: string;
  file: string;
  line: number;
  message: string;
}
export function loadTriage(file: string): Suppression[];
export function normaliseUri(uri: string): string;
export function suppressionFor(
  triage: Suppression[],
  finding: Finding,
  readLine?: (file: string, line: number) => string | undefined,
): Suppression | undefined;
export function runCircomspect(
  entry: string,
  opts: { includeDir: string; sarifPath: string; binary?: string },
): Finding[];
