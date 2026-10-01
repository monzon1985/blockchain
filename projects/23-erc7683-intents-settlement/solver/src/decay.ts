// SPDX-License-Identifier: MIT
// Mirror of src/libraries/DutchDecay.sol: flat at `start` until `decayStart`, linear to `end` at `decayEnd`.
// The decrease rounds down, so the amount owed rounds up in favour of the user, exactly like the contract.

/** Output owed at time `t` (all values in token base units and chain seconds), as DutchDecay.amountAt. */
export function amountAt(start: bigint, end: bigint, decayStart: bigint, decayEnd: bigint, t: bigint): bigint {
  if (end > start) throw new RangeError("decay curve must not increase");
  if (t <= decayStart || decayEnd <= decayStart) return start;
  if (t >= decayEnd) return end;
  return start - ((start - end) * (t - decayStart)) / (decayEnd - decayStart);
}

/**
 * Earliest timestamp >= `from` at which the owed amount is <= `maxAmount`, or null if never before `decayEnd`
 * (when `maxAmount < end`). Closed form of floor((start-end)(t-ds)/(de-ds)) >= start - maxAmount.
 */
export function earliestAffordable(
  start: bigint,
  end: bigint,
  decayStart: bigint,
  decayEnd: bigint,
  from: bigint,
  maxAmount: bigint,
): bigint | null {
  if (amountAt(start, end, decayStart, decayEnd, from) <= maxAmount) return from;
  if (maxAmount < end || decayEnd <= decayStart) return null;
  const needed = start - maxAmount; // > 0 here
  const span = decayEnd - decayStart;
  const range = start - end;
  const t = decayStart + (needed * span + range - 1n) / range;
  return t < from ? from : t;
}
