# Threat model

Scope: `src/` (engine, adaptive IRM, oracle adapter, flash liquidator), the Rust keeper and the risk tooling.
Invariant numbers refer to the table in the README. Vulnerability classes are named after the [OWASP Smart Contract Top 10 (2026)](https://scs.owasp.org/sctop10/), with the same numbering as the other projects in this repository.
Nothing here has been audited; this is a technical demonstration, not a deployed protocol.

## Assets

| Asset | Where it lives | Who can move it |
|---|---|---|
| Supplied loan tokens | Engine balance, accounted per market (`totalSupplyAssets - totalBorrowAssets` is idle) | Suppliers via `withdraw`, borrowers via `borrow`, flash borrowers for one transaction |
| Posted collateral | Engine balance, accounted per position | The owner (or an authorized manager) while healthy; liquidators once unhealthy |
| Supply-share value | `(totalSupplyAssets + 1) / (totalSupplyShares + 1e6)` | Only interest (up) and that market's bad debt (down) |
| Keeper hot wallet and profits | Keeper EOA, `FlashLiquidator` owner | The keystore holder |

## Actors and trust

| Actor | Trust | Can | Cannot |
|---|---|---|---|
| Supplier / borrower | Untrusted | Create markets from allowlisted parts, supply, borrow, delegate via EIP-712, deposit collateral or repay for any account | Touch other positions without authorization; block a close request with a dust deposit or repayment |
| Liquidator | Untrusted | Liquidate unhealthy positions for the scheduled bonus (capped at the borrower's equity while the collateral still covers the debt) | Liquidate healthy positions, lower a health factor without closing the position, realize bad debt on a position that is not under water, seize collateral for free (zero price reverts) |
| Governance (`Ownable2Step` owner) | Trusted, bounded | Allowlist IRMs and LLTV schedules, set a fee up to 25 % of interest, change the fee recipient | Move funds, pause, change an existing market's oracle, IRM, LLTV or liquidation schedule |
| Market oracle | Trusted per market (chosen by the market creator) | Set the price used for borrows, withdrawals and liquidations | Affect other markets |
| Interest rate model | Allowlisted by governance | Set the rate of markets that chose it | Re-enter a market (lock), affect markets that chose another IRM |
| Keeper | Untrusted by the protocol | Call the liquidator it owns | Spend the liquidator's funds through an unsolicited callback |

A compromised governance key can allowlist a malicious IRM or an aggressive LLTV schedule; both only affect markets
created afterwards, and suppliers opt into a market by its id. It can also raise the fee of an existing market to at
most 25 % of future interest (accrued interest is charged at the old fee).

## Attack surface and mitigations

| Class (OWASP SC Top 10, 2026) | Vector | Mitigation | Evidence |
|---|---|---|---|
| SC03:2026 Price Oracle Manipulation | Stale, zero or deviating primary feed | Adapter falls back to an independent secondary, then to the primary's TWAP; zero prices rejected; the engine also reverts on a zero price | `RouterOracleAdapter.t.sol` (every status on every leg), `AdapterLiquidationTest` |
| SC03:2026 Price Oracle Manipulation | Liquidations right after an L2 sequencer outage | `SEQUENCER_DOWN` / `GRACE_PERIOD` halt pricing with no fallback | `test_sequencerStatusesHaltWithoutFallback`, `test_sequencerOutageFreezesLiquidations` |
| SC08:2026 Reentrancy | Callback re-enters the market mid-operation, or an operation leaves its market locked | Per-market transient lock on every entry point; flash loans stay unlocked so they can compose across markets | `FlashLoanReentrancy.t.sol` (8 entry points x same/other market; `LockReleaseTest` probes all 9 locking entry points inside the transaction), invariant 10 (checked inside each actor's transaction; a mutant that leaks the lock of `withdraw` alone fails it) |
| SC07:2026 Arithmetic Errors (rounding and precision) | Share-price inflation, rounding drift | 1e6 virtual shares; every conversion rounds against the caller | Halmos `SharesMathSymbolic` (3 proofs, under the Euclidean-division assumption), `SharesMathFuzz`, invariants 1-2 (all eight conversions exercised by the handler) |
| SC02:2026 Business Logic | Liquidation that worsens a position without closing it ("zombie" positions) | Health guard: a partial liquidation may neither lower the health factor nor exhaust the collateral; only a close can realize bad debt, and it writes it off in the same call | `LiquidationFuzz`, invariants 5, 6, 7, 100 shared vectors, `test_liquidate_partialCannotExhaustCollateral` |
| SC02:2026 Business Logic | Closeout of a position whose collateral still covers its debt (including a borrower closing their own position with a flash loan) shifting a loss to suppliers | While collateral value >= debt, a close repays the whole debt and the bonus is capped at the borrower's equity | Invariant 11, `testFuzz_noSupplierLossWhileCollateralCoversDebt`, Rust proptest `no_supplier_loss_while_collateral_covers_debt`, `test_liquidate_selfLiquidationCannotShiftLossToSuppliers` |
| SC02:2026 Business Logic | Liquidation griefing: a dust collateral deposit or dust repayment front-runs a closeout so it reverts, while bad debt grows | A request at or above the position's size (`type(uint256).max`) closes it, priced on the state at execution; the keeper and the invariant handler send close requests | `test_liquidate_dustDepositCannotBlockClose`, `test_liquidate_repayFrontRunCannotBlockFullRepay`, `testFuzz_dustFrontRunCannotBlockClose`, Rust proptest `close_requests_cannot_be_blocked_by_dust` |
| SC02:2026 Business Logic | Bad debt leaking across markets | Bad debt is subtracted only from the liquidated market's supply | Invariant 8, `test_liquidate_badDebtStaysInItsMarket` |
| SC01:2026 Access Control | Acting on someone else's position | `msg.sender == onBehalf` or an explicit authorization; EIP-712 with nonce, deadline, chain id and ERC-1271 | `Authorization.t.sol` (replay, expiry, wrong chain, tampering, 1271) |
| SC04:2026 Flash Loan-Facilitated Attacks | Flash liquidity used to manipulate state | Flash loans are fee-free and repaid in the same call; they cannot change any market's accounting | Invariants 4 and 8 run flash loans whose callbacks supply, withdraw and liquidate |
| SC05:2026 Lack of Input Validation | Inconsistent or zero amounts, unknown markets, zero addresses | `InconsistentInput`, `ZeroAmount`, `MarketNotCreated`, `ZeroAddress` checks with the offending values | Unit tests for every revert path |
| SC06:2026 Unchecked External Calls | Tokens that return `false` instead of reverting | `SafeERC20` for every transfer; the engine pulls owed tokens after callbacks and reverts on shortfall | `FlashLoanReentrancy.t.sol` (unpaid flash loan), `FlashLiquidator.t.sol` |
| SC09:2026 Integer Overflow and Underflow (denial of service) | Interest overflow bricks an idle market | Third-order Taylor accrual (polynomial growth); IRM exponent clamped before `expWad`; 512-bit `fullMulDiv` for price math | `AdaptiveCurveIrm.t.sol` clamp tests |
| SC10:2026 Proxy and Upgradeability | Not applicable | No proxies: every contract is immutable | n/a |

## Keeper

- The signer is loaded from an encrypted keystore; the password comes from the environment.
- Every liquidation is dry-run with `eth_call` first. The transaction carries an on-chain profit floor equal to the
  estimated gas cost plus the configured minimum profit, so a price move or a competing liquidation turns into a
  revert (which still costs gas), not a loss below the floor.
- Plans are close requests (`repaidShares = type(uint256).max`), so a dust deposit or repayment in front of the
  transaction does not make it revert.
- Each candidate is handled on its own: a dry-run revert, an RPC error, a mined revert or a receipt that does not
  arrive within the timeout is reported and the next candidate is still processed (tested on anvil with mining paused).
- Ctrl-C is honored while a tick runs.
- `FlashLiquidator.onFlashLoan` accepts only the engine and only while its own `liquidate` is in flight.
- The book is event-sourced. Blocks at least `confirmations` deep are committed chunk by chunk together with the block
  cursor (a failure part-way through a chunk never double-applies it); newer blocks are replayed onto a copy on every
  sync, so a reorg of them cannot leave stale events behind. An inconsistent stream (missed log) is detected as an
  underflow and surfaces as an error.

## Known limitations

- Governance is a single `Ownable2Step` owner; production would put it behind a timelock and a multisig.
- The engine does not cap how much of a solvent position one liquidation may repay (no close factor). Borrowers are
  protected by the reverse-Dutch schedule (small bonus near the threshold) rather than by partial-liquidation limits.
- Once a position is under water, the closeout pays the scheduled bonus and suppliers fund it through bad debt (the
  usual deficit-liquidation incentive; a borrower can collect it by liquidating their own under-water position). At
  the boundary where collateral value equals debt, the incentive jumps from about zero (equity-capped) to the
  scheduled bonus, so a liquidator may prefer to wait for a small position to slip under water. Low caps keep that
  jump small; the simulator shows the cost of high caps.
- A liquidation sized to the exact amounts observed off-chain can still be turned into a rejected partial by a dust
  deposit; only close requests (`>=` the position, e.g. `type(uint256).max`) are front-run-proof.
- Tokens with transfer fees, rebasing balances or callbacks are not supported (accounting assumes exact transfers).
- The `MockSwapVenue` used by tests and the anvil demo prices at the oracle; real venues add slippage the keeper must
  bound with `minAmountOut` (the keeper sends 0 and relies on the profit floor).
- The keeper does not handle reorgs deeper than its confirmation depth.
- The Halmos share-math proofs assume two arithmetic identities (Euclidean division, distributivity) explicitly; they
  confirm that each conversion is the floor or ceiling of the right quotient. The bonus cap is proved for every input
  without assumptions; bonus monotonicity is proved only for the 1x slope (other slopes time out) and is fuzzed for
  arbitrary slopes.
