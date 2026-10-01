// SPDX-License-Identifier: MIT
import type { SuiClientTypes } from '@mysten/sui/client';
import { describe, expect, it } from 'vitest';
import { describeStatus, moveAbort } from '../src/errors.js';

const ok: SuiClientTypes.ExecutionStatus = { success: true, error: null };

const abort = (cleverError?: SuiClientTypes.CleverError): SuiClientTypes.ExecutionStatus => ({
  success: false,
  error: {
    $kind: 'MoveAbort',
    message: 'MoveAbort(...) in command 2',
    MoveAbort: {
      abortCode: '9223372380452159491',
      location: { module: 'pool', functionName: 'swap_a_for_b' },
      ...(cleverError === undefined ? {} : { cleverError }),
    },
  },
});

const other: SuiClientTypes.ExecutionStatus = {
  success: false,
  error: {
    $kind: 'Unknown',
    message: 'UnusedValueWithoutDrop { result_idx: 0, secondary_idx: 1 }',
    Unknown: null,
  },
};

describe('moveAbort / describeStatus', () => {
  it('returns nothing for successful transactions', () => {
    expect(moveAbort(ok)).toBeUndefined();
    expect(describeStatus(ok)).toBe('success');
  });

  it('extracts the clever-error constant', () => {
    const status = abort({ constantName: 'EFlashLoanOpen', errorCode: 3 });
    expect(moveAbort(status)).toEqual({
      module: 'pool',
      constant: 'EFlashLoanOpen',
      code: '9223372380452159491',
    });
    expect(describeStatus(status)).toBe('aborted in pool with EFlashLoanOpen');
  });

  it('falls back to the raw code without clever-error data', () => {
    expect(describeStatus(abort())).toBe('aborted in pool with code 9223372380452159491');
  });

  it('describes non-abort failures', () => {
    expect(moveAbort(other)).toBeUndefined();
    expect(describeStatus(other)).toMatch(/^failed: Unknown: UnusedValueWithoutDrop/);
  });

  it('handles aborts without a location', () => {
    const status: SuiClientTypes.ExecutionStatus = {
      success: false,
      error: { $kind: 'MoveAbort', message: 'abort', MoveAbort: { abortCode: '0' } },
    };
    expect(describeStatus(status)).toBe('aborted in unknown module with code 0');
  });
});
