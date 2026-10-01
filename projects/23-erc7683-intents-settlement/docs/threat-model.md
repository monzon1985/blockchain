# Threat model

Scope: the contracts in [`src/`](../src), the deployment scripts in [`script/`](../script) and the off-chain actors in [`solver/src/`](../solver/src). Nothing here has been audited; this is a technical demonstration with production-grade engineering, not a deployed system.

## Assets

| Asset | Where | At risk from |
|---|---|---|
| User input escrowed by `open`/`openFor` | OriginSettler (origin chain) | Paying a filler who did not fill, paying twice, paying the wrong filler, never refunding |
| Solver output advanced by `fill` | DestinationSettler pays the user directly from the solver | The solver not being repaid (settlement fails, a false claim squats its repayment, or a refund wins the race) |
| Optimistic bonds | OptimisticSettlementModule | Honest claimants losing bonds to a forged dispute |
| Fill records | DestinationSettler storage slot `keccak256(orderId, 0)` | Being written for the wrong payload, overwritten, or read from the wrong contract |
| Relayed headers | HeaderStore | A non-canonical header being accepted or rewritten |
| The solver's nonces and journal | `node:sqlite` file of the solver | A crash or an RPC error leaving a signed transaction that can never be mined |

## Actors and trust

| Actor | Trusted for | Not trusted for |
|---|---|---|
| User | Nothing (signs the order it wants) | |
| Solvers | Nothing; any number, adversarial | |
| Watchers (mode 2) | At least one honest, live watcher per challenge window | Anything else |
| Header relayer (modes 2 and 3) | Relaying only canonical, **finalized** destination headers | Rewriting accepted headers (impossible, they are immutable) |
| Mailbox relayer (mode 1) | Delivering only messages dispatched on the destination chain | |
| AccessManager admin | Part of the trust base of **all three modes** (see Privileged roles): configuration cannot directly redirect an escrow, but an admin who grants itself a relayer role can forge repayment for every open order | Acting quickly or silently: the deployment scripts give it an execution delay and the relayer roles a grant delay |
| Tokens | Standard ERC-20 behaviour | Fee-on-transfer (rejected at open), rebasing and blocklisting (unsupported, see limitations) |
| Validators | Timestamps within a few seconds | Deadlines are minutes to hours long |

### Trust by settlement mode

| Mode | Safety of repayment ("solver paid implies user filled") relies on | Liveness of repayment relies on |
|---|---|---|
| 1 Mailbox | The mailbox relayer set (here: one permissioned role on the mock mailbox), and the admin | The mailbox relayer (the solver reports again if a report is not delivered in time) |
| 2 Optimistic | Header relayer safety, the admin, **and** one honest watcher online in every window | Nobody (claims finalize unless disproven; a false claim cannot block the true one) |
| 3 Storage proof | Header relayer safety and the admin; the state, account and slot are verified on-chain | The header relayer and anyone willing to submit the proof |

The modes are ordered by what a single compromised party below the admin can do: in mode 1 the relayer can forge any repayment; in mode 2 a forged repayment additionally needs every watcher to be absent; in mode 3 only a forged block header would do, and the relayer's headers are immutable once stored, so misbehaviour is permanently on-chain.

## Privileged roles

| Role | Held by (as deployed by `script/Deploy.s.sol`) | Can do | A compromised holder could |
|---|---|---|---|
| `ADMIN_ROLE` (0) of the origin AccessManager | `ADMIN` from the environment (a timelock or multisig; the deployer renounces the role), with execution delay `ADMIN_EXECUTION_DELAY` (default 3 days) | `OriginSettler.setSettlementModule`; `setRoute` / `setDestinationSettler` on modules (write-once per chain); grant and revoke roles; re-point functions to roles; move targets to another authority | Configuration alone cannot redirect an existing escrow: modules are fixed per order and registries are write-once. But the admin can grant itself the header or mailbox relayer role (or point `submitHeader` / `process` at a role it holds) and then forge headers or messages, stealing the escrows of **open orders in all three modes**. Every such operation must first be scheduled publicly (`OperationScheduled`) and wait the execution delay; a relayer grant then waits `RELAYER_GRANT_DELAY` more (default 3 days, effective after AccessManager's 5-day `minSetback` following deployment). `test_compromisedAdminNeedsExecutionPlusGrantDelayToForgeHeaders` walks through it. **The delay only protects users if it is longer than the longest order lifetime (open to `fillDeadline`) plus `REFUND_GRACE`**, so that every open order can be refunded before a malicious relayer becomes effective; frontends should not offer longer orders. |
| `HEADER_RELAYER` (1) | Header relayer | `HeaderStore.submitHeader` | Forge a header with a crafted state root and prove non-existent fills (steal mode-3 escrows), or disprove honest mode-2 claims (steal bonds, delay repayment). It cannot rewrite or delete headers already stored. |
| `MAILBOX_RELAYER` (2) on the origin mailbox | Mailbox relayer | `MockMailbox.process` | Forge a report and steal any mode-1 escrow. This is the security of a trusted bridge, and why mode 1 is the least trust-minimized. |
| `ADMIN_ROLE` of the destination AccessManager | Same `ADMIN` and execution delay, handed over by `ConfigureDestination` | `MailboxFillReporter.setOriginModule` (write-once), mailbox roles | Point a not-yet-configured origin chain's reports elsewhere. |
| none | | DestinationSettler has no owner and no privileged function | |

## Attack surface and mitigations (OWASP Smart Contract Top 10, 2026)

| Class | Relevant threat | Mitigation | Tests |
|---|---|---|---|
| SC01 Access Control | Any module, or anyone, releasing an escrow; a compromised admin | `settle` only from the order's own module, fixed at open; admin functions `restricted` by AccessManager; registries write-once; admin execution delay and relayer grant delays at deployment | `test_settle_onlyTheOrdersModule`, `*_isRestricted`, `*_routesAreWriteOnce*`, `test_compromisedAdminNeedsExecutionPlusGrantDelayToForgeHeaders`, INV-1 |
| SC02 Business Logic | Solver paid but user not filled; refund and repayment both; double fill; fill of a cheaper payload under the real id; refund while a claim is pending; a false claim squatting the real one | Status machine `Open -> Repaid / Refunded`; the destination recomputes `orderId` from `originData`; the origin re-checks `fillHash` against `orderId`; write-once FillRecord; claims keyed by `(orderId, filler, filledAt)`; pending claims block refunds | INV-1 to INV-8 (Foundry and Medusa), `SolverPaidUserNotFilled`, `test_claimSquatting_*`, fixture replays |
| SC03 Price Oracle Manipulation | none on-chain | No on-chain prices: the Dutch decay is a function of time; pricing lives in the solver | n/a |
| SC04 Flash Loan Attacks | none | No balance-derived prices or voting | n/a |
| SC05 Lack of Input Validation | Malformed orders, headers, proofs, `fillerData` | `_validate` (addresses, amounts, uint96 / uint64 ranges, deadlines, module and destination support); strict RLP decoding; hash-linked proof traversal; `fillerData` length check | `test_validate_*`, `test_crafted_*`, tampered-proof fuzzing |
| SC06 Unchecked External Calls | Silent token failures, Permit2 failures | `SafeERC20`; Permit2 reverts bubble up; exact balance-delta check on escrow | `test_open_revertsOnFeeOnTransferToken`, Permit2 revert tests |
| SC07 Arithmetic Errors | Decay rounding against the user | Decrease rounded down, owed amount rounded up; `Math.mulDiv` | `DutchDecay.t.sol` (fuzz + reference differential) |
| SC08 Reentrancy | Malicious output or bond token re-entering | `ReentrancyGuardTransient` on the settlers and the optimistic module; checks-effects-interactions (the Open event and every state write precede token transfers) | `test_fill_isNonReentrant` |
| SC09 Integer Overflow / Underflow | Packed fields, claim counters | Checked arithmetic; ranges validated before casts; `SafeCast` for relayed timestamps; `unchecked` only for a per-user nonce and the pending-claim counter (bounded by bonds held) | `test_validate_amounts`, `test_submitHeader_rejectsTimestampBeyond64Bits`, INV-6 |
| SC10 Proxy & Upgradeability | Storage layout drift breaking proofs | No proxies. The FillRecord slot is pinned by a test; a new DestinationSettler would need a new chain registration, which the write-once registries make explicit | `test_storageLayout_isPinned` |

IntentFuzz (Augusto et al.) defines six on-chain classes. Five apply and are covered: fill replay (FRP: `AlreadyFilled`, INV-5), deposit replay (DRP: `OrderAlreadyExists`, Permit2 nonces), origin chain binding (OCB: `WrongOriginChain`, `WrongOriginSettler`), destination chain binding (DCB: `WrongDestinationChain`, `WrongDestinationSettler`) and temporal binding (TB: `FillDeadlinePassed`). The sixth, access control (AC: "fill execution gated on single stored authority"), is **not applicable**: fills are permissionless by design, and the escrow is protected instead by the `orderId` recomputation and write-once fill records. IntentFuzz leaves "the fill matches the deposit" to off-chain settlement as a settlement exposure; this design closes it on-chain, because the fill is recorded under an id derived from the exact payload it paid for.

## Specific scenarios

- **Fraudulent optimistic claim** (claims a fill that did not happen, or misstates the filler or time). A watcher proves the recorded value at any destination block after the claimed fill time: an exclusion proof if the slot is empty, an inclusion proof of a different value otherwise. Fill records are write-once and fills stop at the deadline, so the proof is conclusive. The claimant's bond goes to the challenger.
- **Blinding the watcher with old headers** (found in review). `HeaderStore.submitAncestor` is permissionless, so anyone can import ancestors of a stored header down to blocks where the DestinationSettler did not exist yet (or that a non-archive node has no state for), and a false claim may state `filledAt = 0`. Three layers now handle it: the module accepts an **account exclusion proof** of the settler as "not filled" (an account that does not exist has no storage); the watchtower proves against the **newest** stored header and falls back to older ones when a proof cannot be produced or does not verify; and each claim is checked in isolation, so one claim that cannot be handled never stops the others. Tests: `test_challenge_withPreDeploymentAncestor_accountExclusionDisprovesClaim`, `test_challenge_preDeploymentAncestorCannotDisproveHonestClaim`, the watchtower unit tests, and the e2e "fraud proofs survive imported pre-deployment ancestors" (on anvil's real account exclusion proof).
- **Claim squatting** (found in review). With one claim slot per order, a user could keep it filled with false claims, each disproven in time, until its refund opened, then refund after challenging its own last claim: the real filler could never land its claim. Claims are now keyed by `(orderId, filler, filledAt)`, so a false claim cannot occupy the real one's key; the real claim lands next to any number of false ones, blocks the refund while pending, and finalizes. The solver never waits on someone else's claim. Tests: `test_claimSquatting_cannotBlockTheRealFillerNorWinTheRefund`, `test_claimSquatting_refundBlockedWhileRealClaimPending`, INV-8, the e2e "claim squatting".
- **Griefing with repeated false claims.** Each false claim costs a bond (taken by the watcher, which challenges as soon as it sees it) and blocks the refund only while it is pending, at most one challenge window.
- **Surviving claims after repayment.** Once one claim repaid the escrow, other pending claims can still be challenged; one that survives its window is voided (`ClaimVoided`: bond returned, nothing paid).
- **Forged fill payload.** A payload that does not hash to the order id is rejected on the destination (`OrderIdMismatch`), so no one can occupy an order's fill slot with a cheaper payload.
- **Late settlement.** A solver that fills near the deadline must settle within `REFUND_GRACE`; after that, a refund can win the race. The solver's pricing refuses fills whose settlement latency would not fit (`settlement-window`).
- **Solver crash or RPC failure.** Every transaction is signed with a nonce **assigned from the journal**, journaled in SQLite atomically with the order's state change, then broadcast. At the start of every tick, before anything new is signed, every journaled transaction without a receipt is re-sent in nonce order. A journaled transaction whose nonce was used by another transaction is marked replaced and its order re-evaluated; a fill still unmined at the fill deadline is abandoned (its reservation released) while the journal keeps re-sending it so its nonce does not become a gap. Signed gas limits carry headroom because a journaled transaction may execute later than it was signed (the Dutch decay path costs more). Tests: the solver unit tests on fake chains and three e2e crash tests (two with one order, one with two active orders).
- **Lost mailbox message.** The mailbox relayer only moves its cursor past a message once it is delivered or the origin chain rejects it; a transient failure is retried. The solver reports again if its report is not delivered within `mailboxRecheckSec`.
- **Clock skew between chains.** Claims cannot state a fill time later than the origin's current time or the fill deadline; the refund grace absorbs skew.

## Known limitations

- The mailbox is a mock with a single permissioned relayer role. A production deployment would plug in a messaging layer with its own security (the module and reporter would not change).
- Headers come from a permissioned relayer; there is no light client, and reorgs are not handled: the relayer must only relay finalized headers. Ancestors can be imported permissionlessly through `parentHash`, which reduces what must be trusted to occasional anchors.
- Mode 2 needs a live, honest watcher and live header relaying during every challenge window.
- The admin delays protect users only for orders shorter than the delay minus `REFUND_GRACE`; the contracts do not cap order lifetimes.
- The solver does not bump fees: a journaled transaction the node rejects outright (for example a fee below a spiking base fee) stops that chain's queue until an operator intervenes. It also reads `OrderSettled` events from block 0 to see who was repaid, which a production deployment would bound.
- One ERC-20 in, one ERC-20 out per order; no native ETH; no fee-on-transfer or rebasing tokens; a token that blocklists the user or the filler can make a refund or a repayment revert.
- Proof gas grows with trie depth. The measured numbers use anvil's shallow tries; mainnet account proofs are several nodes longer.
