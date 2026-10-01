# Threat model

Scope: the `custodyd` service (Go), its SQLite database, its hot-wallet key, and the
`ForwarderFactory` / `DepositForwarder` contracts. This is a technical demonstration of how an
exchange hot wallet can be built. It is not a licensed custody product, has not been audited, and
has never held real funds.

## Assets

| Asset | Where it lives | Why it matters |
|---|---|---|
| Hot-wallet private key | Encrypted keystore (scrypt, Web3 Secret Storage v3) plus a password file; decrypted into process memory at start-up | Controls every token and all the ETH in the hot wallet, and owns the forwarder factory |
| Customer balances | `ledger_*` tables (double-entry) | The exchange's liability to each customer |
| Deposits in forwarders | ERC-20 balances of CREATE2 clones | Customer funds not yet swept |
| In-flight withdrawals | `nonce_slots` / `tx_attempts` (signed raw transactions, write-ahead) | The database must know every transaction that could be on the network |
| API credentials | SHA-256 hashes in the config; bearer tokens held by the callers | Clients can request withdrawals; approvers can release large ones and cancel |
| Audit trail | `audit_events` table and the hash-chained `audit.jsonl` | Forensics and non-repudiation of operator actions |

## Actors and trust assumptions

| Actor | Trusted for | Not trusted for |
|---|---|---|
| API gateway (client token) | Authenticating the end customer before it calls the engine (2FA, session) | Anything else: the policy engine re-checks limits, allowlists and balances |
| Approvers (2 of 3 by default) | Approving withdrawals at or above the threshold; cancelling | Moving funds anywhere that is not an active allowlist entry |
| Ethereum node (RPC) | Liveness, and honest answers most of the time | Reorg-free answers: every receipt is re-checked against the canonical block hash, and credits wait for the confirmation depth |
| Operator with shell access | Configuration, key custody, restoring backups | Not modelled as an adversary: shell access implies access to the key |
| Customers | Nothing | They can send anything to their deposit address, including dust and tokens that are not configured |

The engine assumes it is the **only user of the hot-wallet key**. If the key signs something
elsewhere, the tracker detects the nonce drift and raises the nonce floor, reconciliation reports
the unexplained balance change, and both events are audited. The engine does not try to recover
from that automatically.

## Attack surface and mitigations

| # | Threat | Mitigation | Evidence |
|---|---|---|---|
| T1 | **Double spend through retries**: a client retries after a timeout and two withdrawals are created | Idempotency-Key with a request fingerprint. The withdrawal, fund reservation, outbox intent, audit event and stored response commit in one SQLite transaction. The same key with a different body gets 422 | `TestSimIdempotentReplay`, API tests, `TestChaos/after_request_commit` |
| T2 | **Double spend through crashes**: the process dies between signing and recording, and signs again on restart with a new nonce | Write-ahead: every signed transaction is persisted before any broadcast, and every transaction for a withdrawal reuses its single nonce. A nonce is released only if nothing was ever signed for it | 7 chaos tests on the real binary; the simulator (P1) over hundreds of seeds with a crash armed at every failpoint |
| T3 | **Replacement races**: a fee bump and the original are both mined | Impossible by construction: they share a nonce. The tracker finalizes whichever attempt is in the canonical chain | `TestAnvilFeeSpikeReplaceByFee`, simulator |
| T4 | **Reorgs**: a withdrawal counted as final disappears; a reorged deposit is credited, or a canonical one is never credited | The confirmation depth is configurable (12 by default). Inclusion is booked to `in_flight` and reversed when the receipt disappears or moves to another block. Deposits are credited only at depth, after a canonical-hash check | `TestAnvilReorg*`, `TestScenarioReorg*`, `TestAnvilDepositReorgOrphaned`; simulator P7 compares every deposit record with the chain's `Transfer` logs |
| T5 | **Deep reorgs** past the confirmation depth | Detected on both sides and not auto-resolved (the customer may already have withdrawn, so this needs a human): the deposit scanner flags credited deposits whose block left the chain, the tracker flags a finalized withdrawal whose nonce the chain no longer has (`custody_deep_reorgs_total`, `deposit.deep_reorg` and `tx.deep_reorg` audit events) | `TestScenarioDeepReorgIsFlagged`, `TestScenarioReorgDeeperThanTheScannerWindow`, `TestScenarioDeepReorgOfAFinalizedWithdrawalIsFlagged` |
| T6 | **Compromised or buggy upstream code** asks the signer for something unsafe | The signing firewall re-validates every transaction right before signing: chain ID, EIP-1559 type only, fee cap, no ETH value, no contract creation, strictly canonical ERC-20 `transfer` calldata to the configured token, per-transaction maximum, an active allowlist entry, and `flushMany` only for sweeps. If a fee bump fails the firewall (for example because the destination was removed from the allowlist), the bump becomes a cancellation | `signer` table tests (33 cases), `TestScenarioAllowlistRemovalTurnsBumpIntoCancellation` |
| T7 | **Account takeover**: an attacker adds a new destination and withdraws to it immediately | 24 h allowlist cool-down, rolling 24 h velocity limit, M-of-N approvals above a threshold | `policy` tests, `TestScenarioPolicyRejections`, `TestPropertyVelocityWindow` |
| T8 | **Race past a limit** with concurrent requests | Single SQLite connection with `BEGIN IMMEDIATE`: the velocity check and the write happen inside one serialised transaction | Design (store package); simulator runs requests interleaved with every other step; `TestServeUnderConcurrentLoad` runs the real loops and HTTP handlers concurrently (and under the race detector in CI) |
| T9 | **Ledger corruption or silent loss** | Every entry is balanced per asset; customer accounts cannot go negative; entries are idempotent by reference; reconciliation checks the chain against `hot_wallet + in_flight` and re-verifies the ledger itself with an incremental checker: new postings against the cached balances on every run, inside one read snapshot (so concurrent writes never look like a mismatch), and every old posting again from scratch in bounded chunks, so an edit made behind the ledger's back is reported even when the chain identity still holds | `ledger` property tests and fuzzing; `TestCheckDetectsTampering` (5 kinds), `TestCheckerDetectsTampering` (4 kinds, including an old posting edited and an old entry deleted); `TestScenarioReconciliationFlagsLedgerTamperingAndStaleHeads`; no false mismatch under load: `TestCheckerUnderConcurrentPosts`, `TestReconciliationUnderConcurrentWrites`, `TestServeUnderConcurrentLoad` |
| T10 | **Unexplained inflows or outflows** (tokens sent straight to the hot wallet, key used elsewhere) | Reconciliation reports a signed delta per asset, exported as a metric and audited on every transition between ok and mismatch | `TestAnvilReconciliationFlagsExternalInflow`, `TestScenarioNonceDrift...` |
| T11 | **Stuck queue**: a nonce released after a higher nonce was broadcast, or a nonce reserved by a step that will never sign it (a crash between reserving and persisting, after which the hot wallet can no longer cover the transfer) | Gap detection fills a hole with a zero-value self-send after a grace period. A reservation is never left behind: a retry whose gas estimate fails releases the reservation of the interrupted run, an abandoned gap-filler reservation is released by the next tracker round, and any reservation unsigned for 5 minutes across the grace period is released as a safety net (audit event, `custody_nonce_reservations_released_total`) | `TestScenarioNonceGapIsFilled`, `TestScenarioCrashBeforeSignThenLiquidityDrop`, `TestScenarioReservationDoesNotDeadlockSweeps`, `TestScenarioAbandonedFillerReservationIsReclaimed`, `TestScenarioStaleReservationIsReclaimed`, `TestScenarioReservationReclaimedWhileSigning` |
| T12 | **Fee griefing / runaway fees** | Bumps are ≥ 12.5 % and capped by `max_fee_wei`; transactions queued behind an unmined nonce are not bumped | `FuzzBump`, `TestScenarioFeeCapStopsBumpingUntilFeesFall` |
| T13 | **Forwarder abuse**: someone flushes deposits elsewhere or front-runs a deployment | Forwarders pay only the immutable `DESTINATION`, only the factory can call them, and only the owner can call the factory's mutating functions. CREATE2 addresses depend on the factory, so nobody else can deploy at them. The factory cannot be left without an owner | Foundry unit, fuzz and invariant tests (F1 to F5) |
| T14 | **Tampering with the audit log** | Events are written in the same transaction as the change they describe. Each line hashes the previous one, so `custodyd audit-verify` detects a line edited, deleted, inserted or reordered inside the file. The chain is not keyed: lines cut from the end, or a file rewritten with a recomputed chain, are detected only by `audit-verify -db`, which requires the file to hold exactly the database's events. The shipper refuses to append to a file that does not verify or does not end at a database event (it only repairs a torn final line), and counts each refusal (`custody_audit_ship_failures_total`). Someone who can rewrite both the database and the file consistently is not detected; anchoring checkpoints in a separate trust domain is future work | `audit` tests (`TestShipRefusesADamagedFile`, `TestVerifyAgainstTheDatabase`), `TestAuditVerify` |
| T15 | **Credential theft from the config** | Only SHA-256 hashes of bearer tokens are stored; they must be 64 hex digits (normalised to lower case at load time, so a pasted upper-case hash works and a malformed one stops the engine from starting instead of silently never matching) and are compared as bytes in constant time | `policy` and `config` tests |
| T16 | **Storage failures mid-operation**: a statement, BEGIN or COMMIT fails, or a COMMIT succeeds but reports failure (outcome unknown), and the engine keeps running on a state it misjudges | Each state change and its side-effect intent commit in one transaction; nothing external happens inside a transaction; every later step is idempotent (ledger references, `ON CONFLICT DO NOTHING`, write-ahead attempts re-sent as "already known"); post-commit hooks only touch metrics and wake-ups | `TestStorageFaultInjection`: every one of the 1,659 database operations of a full workload failed once, plus every COMMIT made ambiguous (1,811 runs), then the simulator's global properties (P1 to P7) are checked |
| T17 | **Information disclosure through errors**: a 500 or the unauthenticated `/readyz` echoes SQL text, file paths or an RPC URL carrying a provider API key | Internal errors are logged with the request id; the response carries a generic message and that id. `/readyz` names the dependency that is down, nothing more | `TestReadinessAndInternalErrorsDoNotLeakDetails` |
| T18 | **The node's head goes backwards** (a reorg to a shorter fork, or a load balancer answering from a node that is behind), possibly replacing blocks below the new head too | The tracker reverts inclusions whose receipts vanished. The deposit scanner rewinds to the highest block it knows (scan-range ends, an anchor it never prunes below the window, the blocks of recorded deposits) that is still canonical at or below the new head, not to the head itself, drops pending deposits above it and scans again. A pending deposit found at depth in a block that is no longer canonical triggers the same rewind and `custody_deposits_stale_pending_total`, instead of stalling every later credit | `TestScenarioHeadGoesBackwards`, `TestScenarioShorterForkReplacingBlocksBelowTheHead`, `TestScenarioReorgRightAfterALongScanRange`, `TestScenarioStalePendingDepositIsRescanned`; the simulator moves the head back, and combines a reorg with a shorter fork, at 3 and 6 confirmations, and checks P7 |
| T19 | **Stolen gateway (client) token** | A client token can create withdrawals for any account and manage any account's allowlist. Its holder can add its own address to every account, wait out the cool-down, then withdraw from each account up to that account's 24 h velocity limit in amounts below the approval threshold, which need no approver. Bounds today: the cool-down (24 h by default), per-account velocity, the approval threshold, and an alert window: every allowlist change is audited and counted by `custody_allowlist_changes_total`, so a burst can page someone within the cool-down. Not implemented (future work): a wallet-wide per-asset 24 h cap, and approver or end-user (2FA) confirmation of allowlist additions | `TestScenarioPolicyRejections`, `TestPropertyVelocityWindow` |
| T20 | **Deposits stranded in forwarders**: a sweep marks a deposit as swept although its flush did not move it, so no later sweep picks it up | A sweep attributes only deposits logged before its own transfers; when its flush moved nothing, none from its own block | `TestScenarioEmptySweepDoesNotClaimLaterDeposits`, `TestScenarioBatchSweep` |

OWASP Smart Contract Top 10 (2026) classes covered by the contracts' design and tests: access
control (SC01: `onlyOwner` factory, factory-only forwarders, two-step ownership, renounce disabled),
unchecked external calls (SafeERC20 handles USDT-style and `false`-returning tokens), reentrancy
(no mutable state reachable by a reentrant token), and denial of service (owner-bounded batches;
a reverting token only reverts the owner's own sweep).

## Known limitations

- **Single hot key, in memory.** The `Signer` interface is where a KMS, HSM or MPC backend would
  go. None is implemented here.
- **Exclusive key use** is assumed. Drift is detected, not repaired.
- **A stolen gateway token** is bounded by the cool-down, per-account velocity and the approval
  threshold, not by a wallet-wide cap (T19).
- **The audit log is anchored to the database only.** A consistent rewrite of both is not
  detected; periodic checkpoints in a separate trust domain would be (T14).
- **One EVM chain per process, ERC-20 customer assets only.** ETH is the house asset that pays
  gas. Native-ETH deposits are not detected: ETH sent to a counterfactual deposit address can be
  recovered with `flushNativeMany`, but it is never credited to a customer.
- **Fee-on-transfer and rebasing tokens** are not supported. The ledger books the requested amount
  and reconciliation would flag the difference.
- **Hot-wallet rotation** needs a new factory and therefore new deposit addresses, because
  `DESTINATION` is immutable. That is deliberate: a compromised factory owner cannot redirect
  deposits.
- **L2 data fees** (OP-stack L1 fees and similar) are not booked. On such chains reconciliation
  would report them as outflows.
- **SQLite single-writer** throughput is enough for a hot wallet (withdrawals per second, not
  thousands). Scaling out would mean Postgres with row locks and one signer per key.
- **No cold-wallet rebalancing** and **no travel-rule or sanctions screening.** Both are out of
  scope.
