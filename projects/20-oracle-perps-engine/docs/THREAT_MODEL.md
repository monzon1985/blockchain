# Threat model

Scope: `contracts/src` (PerpsMarket, OrderBook, LPVault, OracleVerifier, PerpMath), the Go signer and keeper
services in `keeper/`, and their interaction. **Nothing here has been audited; this is a technical
demonstration and has never held real funds.**

## Assets

| Asset | Where it lives |
|---|---|
| LP liquidity (`poolAmount`) | `PerpsMarket` |
| Trader collateral (`totalCollateral`) | `PerpsMarket` |
| Negative price impact not yet paid back (`impactPoolAmount`) | `PerpsMarket` |
| Escrowed order collateral and execution fees | `OrderBook` |
| Escrowed LP deposits, execution fees and redeem shares | `LPVault` |
| Integrity of the median price | `OracleVerifier` + signer keys |

## Actors and trust assumptions

| Actor | Trust | If compromised |
|---|---|---|
| Trader / LP | Untrusted | Can only act on their own positions and requests |
| Oracle signer (1 of 3) | Honest majority assumed | Can move the median only inside the 50 bps dispersion band (see below). Halting settlement takes 2 of 3: the keeper drops a single bad report whatever the fault (clock skew either way, malformed or malleable signature, another signer's report served again, outlier, wrong market) |
| 2 of 3 signers | Trusted | Can report any price: liquidate or enrich positions arbitrarily. This is the core oracle trust assumption |
| Keeper (`KEEPER` role) | Semi-trusted for liveness and ADL ordering | Can delay or censor settlement, pick which profitable position is deleveraged, and pick among valid report batches; cannot use a price older than a request, forge prices, or cancel orders by under-supplying gas |
| Risk admin (`RISK_ADMIN`, 1-day AccessManager delay) | Trusted, timelocked | Can set risk parameters within hard bounds after a public 1-day delay: position fee ≤ 1 %, ordered margins and PnL factors, `kPos ≤ kNeg`, and ceilings at about 10x the defaults on every rate (borrow ≤ 500 % APR at full utilisation, funding ≤ 1 %/h with velocity ≤ 30 %/day per day, negative impact ≤ $5,000 on a $1M skew) and on the minimum execution fee ($10) and collateral ($1,000). It cannot sweep collateral through fees in a block or make requests unpayable |
| Oracle admin (`ORACLE_ADMIN`, 1-day delay) | Trusted, timelocked | Can rotate signers after a public 1-day delay, so a malicious rotation is visible for a day before it lands |
| Guardian (`GUARDIAN`) | Trusted | Can pause new increase orders and deposits; cannot block closes, cancellations, liquidations or redemptions |
| AccessManager admin (governor) | Trusted, timelocked | Holds the admin role with the same 1-day execution delay (`PerpsDeployment.lockAdmin`), so granting a role, remapping a function or changing a target's authority is a scheduled, public operation. It cannot bypass the risk and oracle timelocks: the fastest malicious signer rotation is a day after a visible `OperationScheduled` (`test_admin_cannotRotateSignersInLessThanADay`). `GOVERNOR` hands the role to a multisig at deployment |
| Collateral token | Assumed standard ERC-20, 18 decimals, no hooks or blocklists | A blocklisting token could block payouts to a listed address (see limitations) |

## Attack surface and mitigations (OWASP Smart Contract Top 10, 2026)

### SC03:2026 Price Oracle Manipulation

* **Signer compromise.** Reports are EIP-712 signed with `marketId`, chain id and verifying contract in the
  domain; at least 2 distinct signers are required, duplicates are rejected, and every included report must sit
  within `maxSpreadBps` (50) of the median. A single malicious signer either lands inside the band (and, with 3
  reports, the median ignores it) or makes the batch revert, in which case the keeper drops it. Tests:
  `test_compromisedSigner_boundedByMedian`, `test_revert_compromisedSignerOutlierIncluded`,
  `TestAggregateDropsOutlierAndChecksQuorum`.
* **One faulty signer cannot halt the keeper.** A review showed that a single signer could stop every keeper
  action without lying about prices: a clock 5 s ahead of the chain head (`ReportFromFuture`), 90 s behind
  (`StaleReport`), a raw 0/1 recovery id (`InvalidSignature`), or serving another signer's report (the duplicate
  made the keeper's aggregation fail). The keeper now applies the verifier's rules at the latest block before
  building a batch: membership, market, a timestamp no later than the head and still fresh `-freshness-margin`
  later, `v ∈ {27, 28}` and a low `s` for EOAs, `isValidSignature` through an `eth_call` for ERC-1271 signers, and
  one report per signer. It then submits the best in-band candidate batch that `OracleVerifier.verifyReports`
  accepts in an `eth_call`, falling back to the next one. `TestEngineSurvivesOneFaultySigner` covers nine faults,
  each caught by its own rule; `TestEngineFallsBackWhenTheChainRejectsABatch` covers the on-chain fallback.
* **Replay.** Reports carry no nonce; they are data, not authorisations. Cross-chain, cross-deployment and
  cross-market replays fail signature checks (`test_revert_replayAcross*`). Replay across time is bounded by the
  60 s age limit and by the requirement that reports be strictly newer than the request they settle.
* **Oracle latency arbitrage.** A user who sees a price off-chain cannot trade against it: orders and LP requests
  settle only with reports timestamped after their creation (`ReportPredatesRequest`), owners cannot cancel before
  `orderTimeout` (no free option), and LP entry is asynchronous for the same reason. Fuzzed in
  `testFuzz_latency_reportsBeforeOrderAlwaysRejected`; invariant I7 tries stale settlements throughout the
  campaigns.
* **Keeper optionality.** Within the 60 s window a keeper can choose among valid batches, including reports it
  asks signers to date at the latest block (`GET /report?notAfter=`, honoured at most 60 s back). It still cannot
  use a price older than the request it settles, the spread bound limits the choice within one batch to ±50 bps,
  and keepers are a permissioned role. Documented, not eliminated.

### SC02:2026 Business Logic Vulnerabilities

* **Price-impact manipulation.** Impact is a function of the squared imbalance with `kPos ≤ kNeg` (enforced by
  `setRiskParams`), positive impact is capped by the impact pool, and negative impact is uncapped (see
  DESIGN.md §3 for why a symmetric cap would be exploitable). Invariant I6 and three fuzz tests check that no
  same-price round trip returns the collateral.
* **Insolvency under adversarial paths.** Pro-rata profit cap, ADL above 45 % of the pool, reserve-factor OI caps,
  free-liquidity checks on LP exits, and the per-settlement payout backstop. Invariant I1 closes every position
  and redeems every share after each fuzzed call, over GBM paths with ±5–60 % shocks (Foundry) and week-long
  keeper outages (Medusa).
* **LP share inflation.** `totalAssets` is internal accounting (donations are ignored), fee income requires open
  interest and the reserve cap ties open interest to pool size, and deposits carry `minShares`.
  `test_inflationAttempt_hasNoLever`.

### SC01:2026 Access Control Vulnerabilities

All privileged entry points are `restricted` through one OpenZeppelin AccessManager. Component entry points
(`refreshPrice`, `fillOrder`, `addLiquidity`, `removeLiquidity`) check immutable addresses. Every unauthorised path
has a revert test (`test_revert_*_unauthorized`); governance delays are tested end to end with
`schedule`/`execute`.

### SC07:2026 Arithmetic Errors (Rounding & Precision)

Every rounding decision goes against the trader: fees and owed amounts round up, credits and positive impact round
down, token amounts round so that same-price PnL is ≤ 0, partial decreases round so that slices cannot farm
dust. DESIGN.md §2–3 has the arguments; the fuzz properties in `PerpMath.t.sol` (11) and `EconomicFuzz.t.sol` (4)
check them.

### SC09:2026 Integer Overflow and Underflow

Checked arithmetic everywhere; all downcasts go through `SafeCast`. Solady `fullMulDiv` keeps 512-bit
intermediates. `contracts/src` contains no `unchecked` block and no inline assembly; the only unchecked
arithmetic runs inside the OpenZeppelin and Solady dependencies.

### SC08:2026 Reentrancy Attacks / SC06:2026 Unchecked External Calls

All state-changing entry points are `nonReentrant` (transient-storage guard), token transfers use `SafeERC20`, and
external calls happen after state updates, except calls into the other immutable system contracts, which are
guarded too. The order book's try/catch reverts on empty revert data, so an out-of-gas fill cannot be turned into
a keeper-forced cancellation.

### SC04:2026 Flash Loan–Facilitated Attacks

Prices come only from signed reports, never from pool balances, and every price-sensitive action is two-step
(request, then keeper settlement in a later block). Nothing can be borrowed and repaid within one transaction to
move a price the protocol reads.

### SC05:2026 Lack of Input Validation

Every order, request and parameter update is validated with a specific custom error carrying the offending
values (`InvalidTriggerPrice`, `ExecutionFeeTooLow`, `InvalidRiskParams(bound)`, …); each has a revert test.

### SC10:2026 Proxy & Upgradeability Vulnerabilities

No proxies: all contracts are immutable. Changing logic means a new deployment and migration.

## Off-chain services

* **Signer keys** are loaded only from encrypted Web3 Secret Storage files plus a password file; raw keys are never
  accepted on the command line or from the environment.
* **Keeper downtime or censorship.** Users recover escrow after `orderTimeout` (execution fee refunded). Positions
  that should have been liquidated during an outage can create bad debt; the payout backstop keeps the pool
  solvent, LPs absorb the loss.
* **Keeper transaction failures** are retried with capped exponential backoff and jitter; reverts in simulation are
  not retried within a tick but re-evaluated on the next one. Gas limits carry 30 % + 250k headroom because
  estimates are taken one second before inclusion (see DESIGN.md §10).
* **Transactions that are never mined** (underpriced after a base-fee rise, evicted, lost by a restarting node)
  cannot stall the keeper: each wait is bounded by `-receipt-timeout`, then the same nonce is re-sent with both fee
  caps raised by 25 %, at most `-max-replacements` times per tick; the next tick reuses and outbids the stuck nonce,
  so later transactions do not queue behind it (`TestEngineReplacesATransactionThatIsNeverMined`,
  `TestEngineTickIsBoundedWhenNothingIsMined`).
* **Report timestamps vs. the chain head.** Nodes simulate (`eth_estimateGas`) against the latest block, whose
  timestamp lags wall time by up to a slot, and the verifier rejects reports from its future. Keepers therefore ask
  signers for reports dated no later than the head; tests run signers whose clocks lead the head, and the anvil
  integration test mines 1 s blocks.
* **Report validation.** See "One faulty signer cannot halt the keeper" above: the keeper checks every report
  against the verifier's rules at the latest block and the chosen batch against the deployed verifier before
  spending gas.

## Known limitations

* **Uncollectible fees in LP pricing.** Pending borrow and funding fees are counted in pool value before they are
  collected, and trader losses count in full even beyond a position's collateral. Bad debt is recognised only when
  realised (GMX v2 has the same behaviour).
* **Funding is fronted by the pool.** Receivers are paid when they settle; if payers default, the pool absorbs the
  difference (bounded by the payout backstop per settlement).
* **ADL fairness.** The contract does not verify that the deleveraged position is the most profitable; keepers
  rank off-chain. A malicious keeper can deleverage a less profitable (but profitable) position. It cannot pick
  one whose payout would raise the PnL-to-pool factor (a winner on a net-losing side): the market requires the
  factor to fall.
* **Liquidation incentives.** Rewards come from remaining collateral after pool claims, so deeply underwater
  positions pay no reward; the design relies on protocol-run keepers.
* **Collateral assumptions.** 18 decimals, no transfer hooks, no fees on transfer, no blocklists. A blocklisted
  trader would make their own payout revert (their order is cancelled; a liquidation of their position would
  revert until the token unblocks).
* **Single market.** One index asset per deployment; cross-margin and multi-market risk are out of scope.
