// SPDX-License-Identifier: MIT

/** Safety margin applied to gas estimates, in basis points (+20 %, the margin Uniswap's interface uses). */
export const GAS_MARGIN_BPS = 2_000n

/**
 * Gas is estimated against the latest block, but the transaction executes in the next one, with a later timestamp.
 * The first trade of a block also pays for the TWAP accumulator writes in `AMMPair._update` (the elapsed time is
 * only non-zero in a new block), which an estimate made in the block of the previous trade does not include. Sent
 * with the bare estimate, such a transaction runs out of gas inside the pair's `swap`; `test/gas.anvil.test.ts`
 * reproduces this on anvil (blocks mined by hand) and shows the same transaction succeeding with this margin.
 */
export function withGasMargin(estimate: bigint): bigint {
  return (estimate * (10_000n + GAS_MARGIN_BPS)) / 10_000n
}
