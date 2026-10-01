// SPDX-License-Identifier: MIT
import type { Address } from "viem";

/** 2026-03-01T00:00:00Z. Every deterministic scenario is anchored here (the simulated chain starts on 2026-01-01). */
export const T0 = 1_772_323_200;
export const HOUR = 3_600;
export const DAY = 86_400;
export const MONTH = 30 * DAY;
export const YEAR = 365 * DAY;
export const E18 = 10n ** 18n;
export const E6 = 10n ** 6n;

/** Mirrors the Solidity `Shape` enum. */
export const Shape = { LinearCliff: 0, Tranched: 1, Segmented: 2 } as const;
/** Mirrors the Solidity `Status` enum. */
export const Status = { Pending: 0, Streaming: 1, Settled: 2, Canceled: 3, Depleted: 4 } as const;

export interface Milestone {
  amount: bigint;
  timestamp: number;
}

/** viem encoding of the Solidity `CreateParams` struct (uint40 fields are numbers in viem). */
export interface CreateParams {
  recipient: Address;
  shape: number;
  cancelable: boolean;
  startTime: number;
  cliffTime: number;
  endTime: number;
  depositAmount: bigint;
  milestones: readonly Milestone[];
}

export function linearParams(args: {
  recipient: Address;
  deposit: bigint;
  start: number;
  end: number;
  cliff?: number;
  cancelable?: boolean;
}): CreateParams {
  return {
    recipient: args.recipient,
    shape: Shape.LinearCliff,
    cancelable: args.cancelable ?? true,
    startTime: args.start,
    cliffTime: args.cliff ?? 0,
    endTime: args.end,
    depositAmount: args.deposit,
    milestones: [],
  };
}

export function milestoneParams(args: {
  recipient: Address;
  shape: typeof Shape.Tranched | typeof Shape.Segmented;
  start: number;
  milestones: readonly Milestone[];
  cancelable?: boolean;
}): CreateParams {
  return {
    recipient: args.recipient,
    shape: args.shape,
    cancelable: args.cancelable ?? true,
    startTime: args.start,
    cliffTime: 0,
    endTime: 0,
    depositAmount: args.milestones.reduce((sum, m) => sum + m.amount, 0n),
    milestones: args.milestones,
  };
}

/** `count` equal milestones of `amount`, one every `step` seconds after `start`. */
export function evenMilestones(count: number, amount: bigint, start: number, step: number): Milestone[] {
  return Array.from({ length: count }, (_, i) => ({ amount, timestamp: start + step * (i + 1) }));
}
