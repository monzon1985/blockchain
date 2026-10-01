# Threat model: Resilient Oracle Router

Scope: `src/` (the router, its three libraries and its interfaces) and the permission layout in
`script/OracleRouterGovernance.sol`. The mocks under `test/mocks/` are test infrastructure and out of scope.
Vulnerability classes follow the [OWASP Smart Contract Top 10 (2026)](https://scs.owasp.org/sctop10/). Nothing here has
been professionally audited.

## Assets

| Asset | Why it matters |
|---|---|
| Correctness of every usable quote | Lending, perps and stablecoin consumers liquidate, mint and settle against it. An overvalued collateral price or an undervalued debt price is a direct loss. |
| Liveness of quotes | A consumer that reverts on every oracle hiccup freezes repayments and liquidations; bad debt accrues while it is frozen. |
| Asset configuration | Feed addresses, heartbeats, bounds, thresholds and mode decide what "valid" means. Changing them is equivalent to changing the price. |
| TWAP observation history | The only data the soft-mode fallback serves while the primary is stale. |

## Actors

| Actor | Capabilities | Trust |
|---|---|---|
| Consumer protocol | Calls `tryGetPrice` / `getPrice` | Untrusted caller; the router has no per-caller state. |
| Keeper | Calls `recordObservation` (permissionless) | Untrusted. Can only record an answer the router would serve as `OK` right now and, for a soft asset with a witness, one the witness can confirm; at most once per `twapWindow / 32`. A silence longer than `min(heartbeat, twapWindow)` restarts the history. |
| Feed operator (Chainlink-style network) | Publishes primary and secondary answers | Trusted to be honest *most* of the time; every answer is still validated. |
| L2 sequencer | Orders transactions; reported by the uptime feed | Trusted to be reported honestly by the uptime feed. |
| Governance (`CONFIG_ROLE`) | `setAssetConfig`, `setSequencerConfig`, after a 2-day delay | Trusted, but every action is public for 2 days and vetoable. |
| Guardian (`GUARDIAN_ROLE`) | `forceStrict` (instant), cancel scheduled config operations | Trusted for liveness only: it can tighten, never loosen. |
| AccessManager admin | Role and target administration, after a 2-day delay | Root of trust (see limitations). |

## Attack surface and mitigations

| # | Vector (OWASP class) | Mitigation | Evidence |
|---|---|---|---|
| T1 | Stale price used after a feed stops updating (SC03 Price Oracle Manipulation) | Per-feed heartbeat; `updatedAt == 0`, future `updatedAt` and `answeredInRound < roundId` all count as stale | `ValidationTest`, matrix rows `STALE`, `MISSING_TIMESTAMP`, `FUTURE_TIMESTAMP`, `CARRIED_OVER_ROUND`; property P2 |
| T2 | Aggregator circuit breaker pinned at its floor (LUNA, May 2022) (SC03 Price Oracle Manipulation, SC05 Lack of Input Validation) | Router-side `[minAnswer, maxAnswer]` set inside the aggregator's own range; out-of-bounds answers are refused in both modes and never bridged by the TWAP (a lagging average would overvalue a crashing asset) | matrix row `OUT_OF_BOUNDS`, `test_ActiveMalfunctions_AreNeverBridged`, mutant `fallback-any-failure` |
| T3 | Zero or negative answer (SC05 Lack of Input Validation) | Refused before any other check, never bridged | matrix rows `ZERO`, `NEGATIVE` |
| T4 | L2 sequencer outage: users cannot react while stale L1-posted prices liquidate them (SC03) | Uptime feed checked first; down, uninitialized (`startedAt == 0`), unreadable or invalid answers all fail closed; `GRACE_PERIOD` (1 h) after recovery; never bridged, no TWAP averages across an outage, and no answer observed before an outage is served after it (T8) | `SequencerTest`, matrix rows `SEQUENCER_*`, `GRACE_PERIOD`; property P5 |
| T5 | A single compromised or malfunctioning primary feed (SC03) | Optional secondary witness with a deviation breaker (gap measured against the lower price, rounded up); strict reverts, soft quotes the conservative side (min for collateral, max for debt) | `DeviationTest`, `BreakerFuzzTest`, matrix row `DEVIATION` |
| T6 | Feed that reverts, returns short data or return-bombs, to make consumers revert (SC06 Unchecked External Calls) | Raw `staticcall` copying at most 160 bytes, its success flag and return size checked; any abnormal outcome is a status, never a revert | `FeedReaderTest`, matrix rows `PRIMARY_REVERTS`, `PRIMARY_MALFORMED`, `SECONDARY_DEAD`; property P4 |
| T7 | TWAP poisoning by a keeper (SC03) | Only answers the router would serve as `OK` are recorded (sequencer, primary and breaker healthy). When the asset has a witness, it must be able to vote: a strict asset fails without it anyway, and a soft asset, which serves its primary alone while the witness is dead, stops recording until the witness is back. So every stored answer passed the breaker whenever a secondary is configured. Spacing `twapWindow / 32` means 64 slots always span 1.97 windows, so recording as fast as allowed cannot evict the history a TWAP needs | `test_Record_RejectsAnythingButOk`, `test_Record_SoftAssetWithDeadWitness_IsRefused`, `test_Record_SoftAssetWithUnhealthyWitness_IsRefused`, `test_RingRollover_KeepsAtLeastOneWindow`, mutants `record-deviating`, `record-without-witness` |
| T8 | TWAP serving ancient data (SC03) | No answer is carried forward across more than `min(heartbeat, twapWindow)` seconds, nor across a sequencer outage: the first observation after such a silence restarts the history, and the fallback needs a full new window before it serves again. Until that first observation, the fallback refuses any window whose newest observation predates the sequencer's last recovery (an outage and its grace period can fit inside a long window). The window ends at the newest observation and the fallback expires one window after it. So every second a `FALLBACK_USED` price averages lies within the last `2 x twapWindow` and is priced by an answer the router validated at most `min(heartbeat, twapWindow)` seconds earlier, under the sequencer's current up-period | `test_RecordingGap_DiscardsHistory_*`, `test_SequencerOutage_*` (including `test_SequencerOutage_PreOutageTwapIsNeverServed`), `test_MaxGap_IsTheShorterOfHeartbeatAndWindow`, `test_NewestObservationOlderThanWindow_Expires`, matrix rows `TWAP_GAP`, `TWAP_EXPIRED`, `TwapFuzzTest`, properties P7 and P8, mutants `twap-carries-across-gaps`, `gap-limit-ignores-heartbeat`, `outage-carried-over`, `twap-served-after-outage`, `twap-never-expires` |
| T9 | Lagging TWAP during a crash overvalues collateral (SC03) | The TWAP faces the same deviation breaker against a live secondary | matrix row `TWAP_DEVIATES` |
| T10 | Rounding exploited to extract value (SC07 Arithmetic Errors, rounding and precision) | `Collateral` rounds down, `Debt` rounds up, one rounding step per quote; both intents share one breaker decision | `NormalizationFuzzTest`, property P9, `test_DecisionIsIntentIndependent_ForHighDecimalFeeds` |
| T11 | Malicious or mistaken configuration change (SC01 Access Control) | `restricted` through an AccessManager with a 2-day execution delay; the router itself refuses any config call with a shorter delay, including one relayed by `AccessManager.execute`; the guardian can veto during the window | `GovernanceTest`, mutant `no-delay-floor` |
| T12 | Emergency: a feed is compromised and governance is 2 days away (SC01) | Guardian `forceStrict` takes effect immediately and can only tighten | `test_Guardian_ForcesStrictImmediately` |
| T13 | Overflow in normalization or accumulators (SC09 Integer Overflow and Underflow) | Answers capped at `2^192 - 1` (Chainlink's own `int192`), decimals at 36; 512-bit `mulDiv`; the ring's wrapping arithmetic is confined to documented `unchecked` blocks and tested across the 2^32 timestamp and 2^224 accumulator wraps | `ObservationRingTest`, `TwapFuzzTest` |
| T14 | An integrator prices with the diagnostic `consultTwap` (SC03) | `consultTwap` is documented as a diagnostic view, not a price source: it ignores the primary's health, the breaker and the mode. It does honor the sequencer (`(false, 0)` while it is down, unreadable or in its grace period, and nothing observed before the last recovery afterwards), so even misuse cannot price through an outage. `tryGetPrice` and `getPrice` are the only pricing entry points | `test_ConsultTwap_IsUnavailableWhileTheSequencerIsUnhealthy`, mutant `consult-ignores-sequencer` |

## Behavior when each feed dies

| Dies | Strict | Soft |
|---|---|---|
| Primary (stale, reverts, malformed, incomplete round, future timestamp, carried-over round) | Fails with `STALE` | TWAP (`FALLBACK_USED`) while the ring covers a full window since its last restart and its newest observation is at most one window old and was recorded after the sequencer's last recovery; otherwise `STALE` |
| Primary answers zero, negative or out of bounds | Fails | Fails (never bridged) |
| Secondary | Fails with the secondary's status (no cross-check, no price) | Primary served alone as `OK` (the witness cannot vote); keepers stop recording until the witness is back |
| Sequencer-uptime feed | `SEQUENCER_DOWN` | `SEQUENCER_DOWN`; after recovery nothing observed before the outage is served, and the first new observation restarts the history |
| Both primary and secondary | Fails | TWAP if available (it only holds answers recorded while the witness was alive), else `STALE` |

Every row is backed by an executable cell in the README's two matrices.

## Known limitations

1. **The AccessManager admin is the root of trust.** It can re-point the router to another authority
   (`updateAuthority`), which could report fake delays. The 2-day admin delay makes this public before it happens;
   monitoring `OperationScheduled` events is part of operating the router.
2. **The TWAP adds no information.** It averages what the primary already said; it cannot know where the market went
   after the primary went silent. With `twapWindow <= heartbeat / 2` and keepers recording until the primary goes
   stale, it collapses to the last validated answer. That is why it expires after one window and faces the breaker.
3. **Sampling bias.** The ring samples the primary when keepers call, and assumes each answer holds until the next
   observation. A keeper choosing when to record can shift the TWAP by at most the price movement within one
   observation interval. The spacing rule (`twapWindow / 32`) is the minimum interval; the gap rule is the maximum:
   an interval longer than `min(heartbeat, twapWindow)`, or one that spans a sequencer outage, restarts the history
   instead of being averaged. Honest keepers recording too keep intervals short.
4. **Cached decimals.** Decimals are read once at configuration. If a proxy is upgraded to an aggregator with other
   decimals, answers are misread by powers of ten; the bounds (T2) catch that as `OUT_OF_BOUNDS`, which is why sane
   bounds are mandatory. Reconfiguration is the fix.
5. **Soft mode drops the cross-check when the witness is dead.** Serving the primary alone is its purpose (liveness),
   and it is the reason a guardian can force strict mode instantly. Those unchecked answers are never recorded, so
   they cannot reach the TWAP.
6. **Out of gas.** `tryGetPrice` forwards all but 1/64 of the gas to each feed (the `staticcall` bounds the return
   data, not the gas). A feed that burns everything can make the caller run out of gas; feeds are governance-vetted
   contracts.
7. **Assets cannot be removed**, only reconfigured, and `tryGetPrice` reverts (`AssetNotConfigured`) for an asset that
   was never configured: that is a deployment error, not a runtime state.
8. **The gap and witness rules cost liveness.** After any keeper silence longer than `min(heartbeat, twapWindow)`,
   after any sequencer outage, and while a soft asset's witness is dead, the fallback cannot bridge until keepers
   have recorded a full new window; meanwhile soft behaves like strict on a stale primary. Keepers should record every
   few minutes, well within the gap limit.
9. **`consultTwap` is not a price.** It reports the average the fallback would start from, without the breaker or the
   mode (T14). Integrators must price through `tryGetPrice` / `getPrice`.
