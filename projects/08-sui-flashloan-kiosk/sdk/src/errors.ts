// SPDX-License-Identifier: MIT
//
// Maps a failed transaction status to the Move abort that caused it. The Move
// modules use clever errors (`#[error(code = N)] const EName: vector<u8>`), so
// the node reports the constant name, not just a number.

import type { SuiClientTypes } from '@mysten/sui/client';

/** A Move abort, reduced to what callers branch on. */
export interface AbortInfo {
  /** Module that aborted, e.g. `pool` or `cooldown_rule`. */
  module: string | undefined;
  /** Clever-error constant name, e.g. `EFlashLoanOpen`, when available. */
  constant: string | undefined;
  /** Raw abort code as reported by the node. */
  code: string;
}

/** Returns the Move abort behind `status`, or `undefined` for other failures. */
export function moveAbort(status: SuiClientTypes.ExecutionStatus): AbortInfo | undefined {
  if (status.success) return undefined;
  const abort = status.error.MoveAbort;
  if (abort === undefined) return undefined;
  return {
    module: abort.location?.module,
    constant: abort.cleverError?.constantName,
    code: abort.abortCode,
  };
}

/** One-line human description of a transaction status. */
export function describeStatus(status: SuiClientTypes.ExecutionStatus): string {
  if (status.success) return 'success';
  const abort = moveAbort(status);
  if (abort === undefined) return `failed: ${status.error.$kind}: ${status.error.message}`;
  const where = abort.module ?? 'unknown module';
  return `aborted in ${where} with ${abort.constant ?? `code ${abort.code}`}`;
}
