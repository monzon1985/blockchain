# Threat model

Scope: the `indexer` binary (sync engine, REST and SSE API, `verify`), its SQLite or PostgreSQL
database, and the JSON-RPC endpoint it reads from. The Solidity contracts in `contracts/` are test
fixtures that generate traffic; they are never deployed with value. Nothing here has been audited.

The indexer holds no keys and moves no funds. What it protects is **the correctness of what it
tells its consumers**: a service that credits deposits, settles trades or shows balances from
this API inherits every wrong row and every missed retraction.

## Assets

| Asset | Where it lives | Why it matters |
|---|---|---|
| Indexed data (logs, transfers, vault events, share prices, balances, supplies) | `logs`, `transfers`, `vault_events`, `share_prices`, `balances`, `supplies` | Consumers act on it |
| The retraction stream | `events` outbox, `/v1/stream` | A consumer that misses a `retract` keeps acting on orphaned data |
| Progress marker | `checkpoint` row, `blocks` window | A wrong tip means skipped or duplicated blocks |
| Availability of the API | the HTTP server | Consumers poll it for state and readiness |

## Actors and trust assumptions

| Actor | Trusted for | Not trusted for |
|---|---|---|
| JSON-RPC provider | Serving blocks that the chain's consensus produced; honest header hashes | Consistency between calls (reorgs, load-balanced replicas, lagging nodes), completeness of `eth_getLogs`, timeliness, well-formed responses, result-size limits |
| API clients | Nothing | Any query string, cursor or `Last-Event-ID` they send; how many connections they open |
| Operator | Configuration (`--token`, `--vault`, `--start-block`, `--confirmations`, `--reorg-window`), running one indexer per database, reacting to a halt | Not modelled as an adversary: file-system access implies access to the data |
| Other processes on the host | Nothing | They may open the same database (a second writer is detected and stops) |

The indexer does **not** verify consensus: it trusts the node-reported block hash and does not
check proofs of work, signatures or state roots. A fully malicious node that fabricates a
self-consistent chain will be indexed faithfully. Running against a node you operate, or against
several providers with cross-checks, is outside this project's scope.

## Attack surface and mitigations

| # | Threat | Mitigation | Evidence |
|---|---|---|---|
| T1 | **Orphaned data survives a reorg**: rows of a block that left the canonical chain stay in the database | Fork detection from stored (number, hash, parentHash); rows keyed by block hash; rollback deletes every row above the common ancestor and reverses balance deltas in the same transaction as the checkpoint move | `TestIncrementalEqualsReindex` (40 seeds, 400 in CI), `TestDifferentialAnvil`, `FuzzReorgStateMachine` |
| T2 | **Consumers keep orphaned data**: the database is right but an API client is not | Transactional outbox: one `retract` per removed record, with the exact published object, newest first, in the rollback transaction; contiguous sequence numbers; `410` / `reset` instead of silent gaps | `TestRetractionOrderAndPayloads`, SSE consumers in the property and anvil tests, `TestStreamPositionErrorsAndReset` |
| T3 | **Mixed-fork answers**: two calls answered by different forks or replicas produce a franken-segment | Four consistency checks per segment (header linkage, log block hash, bloom membership, uniqueness/order); by-hash log queries near the head | `TestFetchRejectsInconsistentAnswers` (10 cases) |
| T4 | **Silent data loss by the provider**: a well-formed `eth_getLogs` answer that omits logs | Whole-block omissions in range mode: `--bloom-check` re-reads by hash every range-mode block whose bloom admits a watched contract but that returned no logs at all. **Residual risk**: a block that lost only some of its logs, logs missing from by-hash answers near the head, and a provider that also drops them from the re-read (same endpoint) are not detected by the indexer; only `indexer verify` against an independent endpoint catches them | `TestSilentLogLossIsDetectedAndPrevented` (real binary, verify exits 1 without the check, 0 with it), `TestBloomCheckRecoversSilentlyDroppedLogs`; the residual risk: `TestBloomCheckMissesPartialLossVerifyCatchesIt` (the check misses a partial omission, verify exits 1) |
| T5 | **Provider limits and flakiness**: result caps, block-range caps, rate limits, timeouts, 5xx, truncated bodies, missing methods | Adaptive range splitting, receipt fallback for single oversized blocks, bounded retries with backoff; rate limits (HTTP 429, `-32005` throttling messages) backed off from, never split; permanent JSON-RPC errors (`-32601` "Method not found", ...) not retried and never read as "block orphaned"; inconsistent answers that persist for 10 iterations reported as sync errors with backoff instead of a silent re-fetch loop | `TestFetchSplitsAdaptivelyOnProviderLimits`, `TestRateLimitsAreRetriedNotSplit`, `TestMissingReceiptsMethodIsNotAnOrphanedBlock`, `TestPersistentFaultsSurfaceAsSyncErrors`, `TestErrorClassification`, `TestConcurrentFaultyNode`, anvil runs behind the fault proxy |
| T6 | **Crash mid-write**: power loss or SIGKILL between two writes, or a commit whose acknowledgement is lost | Every commit and rollback is one transaction including the checkpoint and the outbox; WAL journal with `synchronous=FULL` (SQLite) or `synchronous_commit=on` (PostgreSQL), so a streamed event is never un-committed by a power cut; resume from the stored headers, no repair step; a write that committed although it reported an error is recognised by its tip | SIGKILL crashes in `TestDifferentialAnvil`; `TestRunStopsGracefullyAndResumesFromTheCheckpoint`; `TestAmbiguousCommitIsNotMistakenForASecondWriter`; `TestDSNEnablesWALAndImmediateWrites` |
| T7 | **Two writers on one database** (a second `indexer index` by mistake) | Compare-and-swap on the checkpoint tip; the loser stops with `ErrTipConflict`, unless the stored tip is the one its own unacknowledged write set | `TestSecondWriterHaltsOnCheckpointConflict`, `TestAmbiguousCommitIsNotMistakenForASecondWriter`, `testCheckpointCAS` |
| T8 | **Wrong configuration on an existing database** (other chain, start block or contracts) | A configuration fingerprint stored on first use; any mismatch refuses to start | `TestFingerprintGuardsTheDatabase` |
| T9 | **Reorg deeper than the retained window** | Reorgs up to `--reorg-window` blocks deep are rolled back (the oldest retained header proves its parent); deeper ones stop with `ErrBeyondWindow` rather than guess; operator verifies and reindexes | `TestReorgExactlyAsDeepAsTheWindow`, `TestFindAncestorAtTheWindowDepth`, `TestReorgBeyondWindowHaltsRun`, `FuzzReorgStateMachine` |
| T10 | **Silent truncation or failure of query results**: a client believes it received everything, or a valid query fails on a busy token | Limits above 1,000 rejected (400), explicit `hasMore` + `nextCursor`, internal reads paged to completion; holder lookups for historical balances batched under the databases' bound-variable limits | `TestTransfersPaginationIsCompleteForEveryFilter`, `TestRequestValidation`, `TestHistoricalBalancesOfABusyToken` |
| T11 | **Cursor confusion**: a cursor replayed against other filters skips or repeats rows | Cursors bound to the endpoint and a hash of the filters; mismatch is a 400 | `TestRequestValidation` (`cursor_mismatch`) |
| T12 | **Malformed or hostile input**: bad addresses, negative or huge block numbers, garbage cursors, `Last-Event-ID` in the future | Strict parsing with error codes; values above int64 rejected before SQL; parameterised queries only | `TestRequestValidation` (35 cases plus a POST), `TestStreamPositionErrorsAndReset` |
| T13 | **Undecodable or look-alike events** (ERC-721 `Transfer`, dirty address topics) corrupting balances | Only the canonical ABI encoding decodes; everything else is stored raw and counted | `FuzzDecodeLog`, `TestUndecodableLogsAndAnomalies` |
| T14 | **Tokens that move balances without `Transfer` events** (rebasing, fee-on-transfer accounting quirks) | Not prevented: a negative derived balance is stored as is and counted in `indexer_balance_anomalies_total` instead of being clamped | `TestUndecodableLogsAndAnomalies` |

## Known limitations

- **No authentication, TLS or rate limiting** on the HTTP API. Run it behind a reverse proxy that
  provides them. Each SSE client holds a goroutine and polls the database every second when idle.
- **Historical balance queries cost** O(transfers above the requested block). A client asking for
  `?atBlock=` far in the past on a busy token can make the server work hard (they answer, in
  batches, but slowly); a proxy-side limit or a per-block balance history table (future work)
  addresses it.
- **`--bloom-check` covers whole-block omissions only** (see T4): partial omissions, by-hash
  answers and a provider that drops the same logs twice are left to `indexer verify` against an
  independent endpoint. On a busy chain the header bloom is mostly saturated, so most blocks
  match the watched addresses and the check costs about one extra sequential
  `eth_getLogs(blockHash)` call per block.
- **The safe view is depth-based** (`--confirmations`), not the consensus layer's `safe` or
  `finalized` tags.
- **A head below the indexed tip is waited for**, not obeyed (see `docs/design.md` §3): if a node
  rolls back without producing new blocks, the orphaned data stays visible until it does.
- **Share prices derive from events**: total assets are the asset balance held by the vault
  (OpenZeppelin's default `totalAssets`, donations included). A vault that deploys assets into
  strategies reports a different `totalAssets()` than its idle balance.
- **Backfill reads every header** to verify linkage, in JSON-RPC batches of `--header-batch`.
- **Outbox retention** (`--event-retention`, 100,000 events by default): a consumer that falls
  further behind must resync from the REST API.
