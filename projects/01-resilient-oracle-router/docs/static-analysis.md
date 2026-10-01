# Static analysis triage

Both analyzers run in CI and must report zero untriaged findings.

## Slither 0.11.6 (`slither.config.json`)

`slither . --config-file slither.config.json --fail-medium` (CI additionally runs `--fail-pedantic`) reports
**0 results** over 100 detectors. Filtered paths: `dependencies/`, `test/`, `script/`.

Excluded detectors (`detectors_to_exclude`):

| Detector | Why it is a false positive here |
|---|---|
| `timestamp` | Staleness, heartbeat, grace-period and TWAP checks *are* time comparisons; that is the product. Slither also taints every value computed after a time comparison, so it flags enum comparisons such as `status == Status.OK`. A validator's few seconds of drift cannot turn a stale answer (heartbeats are minutes to hours) into a fresh one. |
| `incorrect-equality` | Fires on `status == Status.OK`, `reason == Reason.X` and `price == 0`, because those values are tainted by timestamp comparisons. None of them compares a balance or a timestamp; they are enum and sentinel checks. |

Inline suppressions (each with the justification next to it in the source):

| Location | Detector | Justification |
|---|---|---|
| `ObservationRing.consult` | `divide-before-multiply` | The division is exact by construction: between two consecutive observations the cumulative difference is exactly `answer * interval`. Covered by the differential `TwapFuzzTest`. |
| `OracleRouter._feedConfig` | `calls-loop` | `decimals()` is read at configuration time only (constructor loop or a delayed governance call), never on the pricing path. |
| `FeedReader.latestRound` | `assembly` | Deliberate return-data-bounded `staticcall` (see the safety comment): the only way to read a feed without reverting on short or oversized return data. |

## forge lint (Foundry 1.8.3, `foundry.toml` `[lint]`)

`forge lint` reports no findings. Excluded lints, with the same reasoning: `block-timestamp` (see above),
`reentrancy-events` (every external call before an event is a STATICCALL or the governing AccessManager's
`consumeScheduledOp`), `require-revert-in-loop` and `calls-loop` (the constructor's initial-asset loop must revert
atomically). Per-line exceptions (`unsafe-typecast`, `divide-before-multiply`) carry a comment explaining why the
cast or the operation order is safe. Tests and scripts are not linted.
