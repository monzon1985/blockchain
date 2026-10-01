# Design notes

This document backs the claims in the README with the arithmetic. Code references point to
`contracts/src`; property references point to the tests that enforce them.

## 1. Units

| Quantity | Unit | Example |
|---|---|---|
| USD amounts, collateral, fees | collateral token units, 18 decimals (1e18 = $1) | `sizeUsd`, `poolAmount` |
| Price | USD per index token, WAD | 3,000e18 |
| Index-token amounts | WAD | `sizeInTokens` |
| Funding and borrow rates | WAD per second | `maxFundingRate = 277_777_777_777` (0.1 %/h) |
| Funding velocity | WAD per second² | `maxFundingVelocity = 4_018_775` (3 %/day per day) |
| Impact factors | WAD per USD | impact = factor · d² / 1e36 |
| Impact-pool distribution | fraction of the impact pool per second | `min(dt, 7 days) / 7 days` per accrual |

The collateral must have 18 decimals (the constructor reverts with `UnsupportedCollateralDecimals` otherwise), so
USD values and token amounts are the same number and no decimal conversion can leak rounding dust.

## 2. Positions and PnL

A position stores `sizeUsd` (notional at entry prices) and `sizeInTokens`, as in GMX v2:

```
long  PnL = floor(tokens · price) − sizeUsd
short PnL = sizeUsd − ceil(tokens · price)
tokens    = floor(size / price) for longs, ceil(size / price) for shorts
```

**Same-price opens never show profit.** For a long, `floor(floor(s/p)·p) ≤ s`; for a short,
`ceil(ceil(s/p)·p) ≥ s`. Fuzzed in `testFuzz_pnl_sameOpenAndMarkPriceIsNeverPositive`.

**Partial decreases cannot farm rounding.** Removing `d` of size `S`:

* realised PnL = `floor(totalPnl · d / S)` (towards −∞);
* tokens removed = `ceil(T · d / S)` for longs, `floor(T · d / S)` for shorts.

For a long, the remaining slice's PnL is at most `(1 − d/S) · exact`, and the realised part is at most
`(d/S) · exact`, so realised plus remaining ≤ the exact total ≤ 0 at the entry price (shorts are symmetric).
`testFuzz_roundTrip_splitExitIsNeverProfitable` exits in 2–6 slices.

## 3. Quadratic price impact

With `d0 = |L − S|` before a trade and `d1` after it (`PerpMath.priceImpactUsd`):

| Case | Impact |
|---|---|
| imbalance shrinks, same side | `+kPos · (d0² − d1²)` |
| imbalance grows, same side | `−kNeg · (d1² − d0²)` |
| trade crosses balance | `+kPos · d0² − kNeg · d1²` |

**No free round trips.** Impact is a function of the squared imbalance, rewarded at `kPos` when it falls and
charged at `kNeg` when it rises. Along any sequence of trades that returns open interest to its starting point,
the total decrease in `d²` equals the total increase, so the net impact is `(kPos − kNeg) · Σ decreases ≤ 0`
whenever `kPos ≤ kNeg`. `setRiskParams` enforces that inequality (bound 6). Positive terms round down and
negative terms round up, so the rounded total is below the exact one.

Two details keep that argument intact in the implementation:

* Positive impact is capped by the impact-pool balance. The cap only lowers what the trader receives.
* There is **no cap on negative impact**. A symmetric magnitude cap would break path independence: open a large
  skew-reducing position at full `+c`, then exit in two halves each capped at `c/2`, and the round trip earns
  `c/4`. The unit test `test_impact_knownValues` and the fuzz tests `testFuzz_impact_roundTripIsNeverPositive`,
  `testFuzz_impact_closedLoopIsNeverPositive` and `testFuzz_impact_splitMatchesWhole` pin the behaviour.

One unit of rounding can go against a trader who rebalances (`floor(k·d0²) − ceil(k·d1²) ≥ −1`); the sign test
allows exactly that wei.

**Impact-pool distribution.** With `kPos ≤ kNeg`, at least `1 − kPos/kNeg` of all negative impact is never paid back
as positive impact (half of it with the default factors). Without an exit that surplus would be stranded in the
market forever; replaying the six fixture paths left between $190 and $851 per one-day path in the market after
every position had closed and every LP share had been redeemed. Every accrual therefore moves
`impactPool · min(dt, T) / T` (with `T = IMPACT_POOL_DISTRIBUTION_PERIOD = 7 days`) from `impactPoolAmount` into
`poolAmount`, as GMX v2 distributes its position impact pool, and LP pricing includes the part pending since the
last accrual. It is logged as `ImpactPoolDistributed` and counted in `MarketStats.impactDistributed`. The cap on
positive impact only shrinks, so the no-free-round-trip argument above is unaffected (and within one block `dt = 0`).
`test_impactPool_distributesToLpsOverTime` checks the arithmetic, and the replay asserts that the market holds at
most 2 wei of dust once every position is closed, a week has passed and both LPs have redeemed everything.

## 4. Funding (velocity model)

The rate drifts with skew and is clamped:

```
v(t) = maxVelocity · clamp((L − S) / skewScale, −1, 1)
r(t) = clamp(r0 + v·t, −maxRate, +maxRate)
```

The accrued funding per unit of size over `dt` is the integral of `r`, in closed form (`PerpMath.fundingIntegral`):

```
no clamp hit      :  (r0 + r1) / 2 · dt
hits +maxRate     :  maxRate · dt − (maxRate − r0)² / (2v)
hits −maxRate     :  −maxRate · dt + (maxRate + r0)² / (2|v|)
```

The clamp form follows from integrating the ramp up to `t* = (maxRate − r0)/v` and the plateau after it. It
avoids computing the fractional crossing time. Additivity (`∫₀^{a+b} = ∫₀^a + ∫_a^{a+b}`, up to 3 wei) is fuzzed
in `testFuzz_fundingIntegral_isAdditive`.

One signed index serves both sides, as in Synthetix perps v2: longs owe `Δindex · size`, shorts owe
`−Δindex · size`, and the pool is the counterparty to the net. Owed amounts round up and credits round towards
zero (`PerpMath.mulWadOwed`).

## 5. Borrow fees

`rate(side) = borrowFactor · min(OI_side / poolAmount, 1)`, accrued into a monotonic per-side index. Pending
fees of a position are `ceil(size · (index − entry))`. Invariant I8 checks that the indices never decrease.

## 6. Aggregates and pool value

Each side keeps `Σ size`, `Σ tokens`, `Σ size · borrowEntry` and `Σ size · fundingEntry`, so pending fees and PnL
of the whole book are O(1):

```
pendingBorrow(side)  = (OI · borrowIndex − Σ size·entry) / 1e18
pendingFunding(pool) = floor(((OI_L − OI_S) · index − (Σ_L − Σ_S)) / 1e18)
pool                 = poolAmount + impactPool · min(dt, T) / T            (pending impact distribution)
poolValue            = pool + pendingBorrow + pendingFunding
                       − min(Σ positive side PnL, maxPnlFactor · pool) − Σ negative side PnL
```

Invariant I3 recomputes every aggregate from the positions after each fuzzed call.

## 7. Profit cap, payout backstop and ADL

**Pro-rata cap.** When aggregate positive PnL `P` exceeds `cap = maxPnlFactor · poolAmount`, each realised
profit is scaled by `cap / P`. LP pricing subtracts `min(P, cap)`.

**Payout backstop.** A single settlement may take at most `maxPnlFactor · poolAmount` of profit plus funding
credit from the pool. Anything beyond is forfeited and counted in `MarketStats.haircuts`. The backstop exists
because Medusa found a counterexample to the solvency property without it (see §10). Two cases escape the
pro-rata cap:

1. **Within-side netting.** A winner's PnL can exceed its side's netted PnL (a later long on the same side is
   losing), so `pnl_i · cap / P` can exceed the cap. Test: `test_payoutBackstop_nettedWinnerIsHaircut`.
2. **Funding fronted for defaulted payers.** Funding credits are paid by the pool when the receiver settles. If
   keepers are down long enough that the payers go bankrupt, their debt becomes bad debt while the receivers'
   credit keeps growing. Test: `test_payoutBackstop_haircutsFundingCreditFrontedForDefaultedPayers`.

With the backstop, `poolAmount_after ≥ (1 − maxPnlFactor) · poolAmount_before`, so the pool can never be
overdrawn and "close every position, then redeem every share" cannot revert. That alone would make invariant I1
vacuous, so I1 also checks that every close pays exactly what an independent model predicts (capped PnL, funding
by index delta, borrow fee, close fee, capped impact, the backstop and the zero floor), and that the backstop
forfeits exactly the predicted haircut. That model found two bugs in the backstop itself, both of the same kind:
when it cut a settlement's gains it also overwrote the components that were *debts*. Cutting a winner's profit set
the funding the winner owed to zero (found by the Foundry campaign), and cutting a loser's funding credit set its
realised loss to zero (found by Medusa after week-long keeper gaps). Only gains are cut now
(`test_payoutBackstop_keepsFundingOwedByAHaircutWinner`, `test_payoutBackstop_keepsLossOfAHaircutLoser`).

**ADL sizing.** With the factor `P / A` above the threshold, removing `y` of PnL paid at scale `s ≤ 1` moves the
factor to `(P − y) / (A − s·y)`. Solving for the target `t` gives

```
y = (P − t·A) / (1 − t·s)
```

and the market closes `ceil(size · y / pnl_position)`, capped at the full position (`_adlSizeDelta`). That
derivation assumes that removing `y` of the position's PnL removes `y` of aggregate positive PnL, i.e. that the
position's side nets to a profit. `P` sums *netted* side PnLs, so a winner on a side that nets to a loss
contributes nothing to `P`: deleveraging it pays its profit out of the pool (`A` falls) while `P` stays put, and the
factor rises. A review found exactly that (a $2M pool, a long at 500 on a long side netting −$650k and a short side
netting +$1.125M: the long ranked first by PnL per unit of size, and deleveraging it moved the factor from 56.2 %
to 58.8 %). The market now requires `factorAfter < factorBefore` (`AdlDoesNotReduceFactor`), and keepers rank
candidates only on sides whose netted PnL is positive (`RankForADL` with `SidePnl` in Go, and the Foundry and
Medusa handlers). Invariant I9 checks every successful ADL lowered the factor. The contract also checks the
threshold and that the position is profitable; it can still refuse a position on a profitable side whose
pool-fronted funding credit outweighs the PnL removed, and keepers then try the next candidate.

**The factor's denominator is `poolAmount`.** The spec phrases the ADL trigger as "trader PnL above 45 % of pool
value". Pool value (§6) already nets trader PnL, so a factor over pool value would be circular: it rises faster
the more traders win, and pending fees would move it. GMX v2 measures `pnlToPoolFactor` against the pool's token
value *without* PnL, which for a stable-collateral pool is `poolAmount`; this market does the same.

## 8. Two-step flows and the latency rule

Every user action that depends on a price is split into a request (order or LP request) and a keeper settlement
that must carry reports **strictly newer** than the request (`ReportPredatesRequest`). Liquidations and ADL
require reports newer than the position's last update. Owners can cancel only after `orderTimeout`, for every
order type: an order that could be cancelled at will would be a free option on the next oracle update.

The LP vault is ERC-4626 for accounting and previews, but entry and exit are asynchronous (ERC-7540 style). A
synchronous `deposit` would be priced at the last on-chain price and could be front-run by anyone who sees a newer
off-chain one. The synchronous functions revert, and `max*` return 0, which is how ERC-4626 signals that entry is
disabled.

## 9. Components and custody

| Contract | Holds | Trusts |
|---|---|---|
| `PerpsMarket` | pool, impact pool, position collateral | `OrderBook` (fills), `LPVault` (liquidity), `OracleVerifier` |
| `OrderBook` | order escrow + execution fees | market (immutable, deploys it) |
| `LPVault` | pending-deposit assets, escrowed shares, fees | market (immutable, deploys it) |
| `OracleVerifier` | signer set | AccessManager |

The market deploys the order book and the vault in its constructor, so every cross-component address is
immutable and no initializer exists. `PerpsMarket` alone would be 29.9 KB. Splitting the order and LP flows out
brings it to 23.8 KB (23,826 bytes, 750 bytes under EIP-170) without via-IR, with 46.0 KB of initcode (under
EIP-3860).

**Failed fills.** The order book calls `market.fillOrder` inside try/catch. A validation failure (slippage,
margin, caps, pool liquidity) cancels the order, refunds collateral and still pays the keeper. An out-of-gas fill
returns empty revert data, and the whole keeper transaction then reverts, so a keeper cannot force cancellations
by under-supplying gas. `test_executeOrder_underSuppliedGasNeverCancels` sweeps the gas limit from 150k to 700k in
1k steps and checks that every outcome is either "filled" or "still pending". OpenZeppelin 5.7's SafeERC20
bubbles raw return data, so an out-of-gas inside the token transfer also reaches the guard as empty data.

## 10. Findings made while building and reviewing this

| Found by | Issue | Resolution |
|---|---|---|
| Medusa (`property_I1_solvency`, a 53-call sequence shrunk to 6) | After about two months without keeper activity, a long's pool-fronted funding credit plus its capped profit exceeded the pool, so closing it reverted; analysis showed within-side netting can do the same | Per-settlement payout backstop (§7), with a unit test for each cause (`test_payoutBackstop_nettedWinnerIsHaircut`, `test_payoutBackstop_haircutsFundingCreditFrontedForDefaultedPayers`). The shrunk sequence was not kept, so no dollar figures are quoted for it |
| Strengthened I1 (payout model), Foundry | The backstop overwrote funding *owed* by a haircut winner with zero | Only gains are cut (§7) |
| Strengthened I1 (payout model), Medusa | The backstop overwrote the realised *loss* of a loser whose funding credit it cut with zero | Same fix (§7) |
| Review | ADL of a winner on a net-losing side raised the PnL-to-pool factor; keepers ranked such winners first | `factorAfter < factorBefore` enforced; ranking within net-profitable sides; invariant I9 (§7) |
| Review | Negative impact never paid back stayed in the market forever | Impact-pool distribution to LPs (§3) |
| Review | One faulty signer out of three (clock skew, raw recovery id, an echoed report) halted every keeper action, because the keeper included its report and every transaction reverted | Keeper drops reports outside the verifier's window at the latest block, checks v and low s, deduplicates by signer and falls back to the next candidate batch the verifier accepts in an `eth_call` (THREAT_MODEL.md) |
| Review | Signers dated reports at wall time; nodes simulate against the latest block, whose timestamp lags it, so every simulation hit `ReportFromFuture` on geth-backed chains | Keepers request `GET /report?notAfter=<head timestamp>`; tests run signers with clocks ahead of the head and the integration test mines 1 s blocks |
| Review | A transaction that was never mined blocked the keeper forever | Bounded receipt wait, same-nonce replacement with bumped fees, and a stuck nonce reused by the next tick |
| Review | The AccessManager admin could bypass the 1-day governance delays | The admin role is held with the same 1-day execution delay (`PerpsDeployment.lockAdmin`) |
| Unit test `test_funding_rateDriftsWithSkewAndLongsPay` | `maxFundingRate` default was 1000× too small | Corrected to 0.1 %/h |
| Go engine test (simulated backend) | Gas estimated in the same second as the previous accrual under-supplies the fill one second later | Keeper adds 30 % + 250k gas headroom; out-of-gas guard keeps the order pending instead of cancelling it |
| Invariant I5 | Flow equation underflowed once LPs withdrew their profits | Equation rewritten without subtraction |
