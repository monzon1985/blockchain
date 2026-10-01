# Static analysis triage

Both analysers run in CI and must report zero untriaged findings. Every suppression below is either configured in a checked-in file or written next to the code it concerns, with the reason.

## Slither 0.11.6

Command: `slither . --config-file slither.config.json` (in `contracts/`). Result: `0 result(s) found` with `fail_on: low`.

| Detector | Where | Decision | Reason |
|---|---|---|---|
| `timestamp` | escrow deadlines, EIP-3009 windows, session expiry, rolling budget | Excluded in `slither.config.json` | Time windows are the feature. Validators can skew timestamps by seconds; the shortest window is 60 s (`MIN_PERIOD`) and authorizations are bounded by `maxTimeoutSeconds`. |
| `naming-convention` | `immutable` variables in `UPPER_CASE` | Excluded in `slither.config.json` | Follows the Solidity style guide for constants/immutables. |
| `reentrancy-balance`, `incorrect-equality` | `SettlementLog.settleExact`, `PaymentEscrow.open` | `slither-disable-start/end` around each function | The balance is read before and after the call on purpose: it is the exact-delta check against a fixed asset, under `nonReentrant`. Strict equality is the property being enforced. |
| `uninitialized-state` | `BudgetExecutor._ring` | `slither-disable-next-line` | False positive: written through a storage pointer in `_consumeBudget`. |
| `unused-return` | `AgentAccount` `decodeMode` tuples; `IdentityRegistry._setWallet` (`Checkpoints.push`) | `slither-disable-next-line` | Only the call type is needed; `push` returns the previous and new wallet, and the function already holds both. |
| `dead-code` | `AgentAccount._rawSignatureValidation`, `TestUSD._useCheckedNonce` | `slither-disable-next-line` | False positive: both are reached through virtual dispatch from OpenZeppelin base contracts. |

Known tool limitation: Slither 0.11.6 prints `Impossible to generate IR` for a handful of OpenZeppelin 5.7 internals (`AccountERC7579` functions that compare `CallType` values with a user-defined `==` operator, `ReentrancyGuardTransient` helpers). Those functions are skipped by the IR-based detectors; they are library code covered by OpenZeppelin's own test suite and by this project's unit tests.

## forge lint (Foundry 1.8.3)

Command: `forge lint src script --deny warnings` (in `contracts/`). Result: no findings.

| Lint | Decision | Reason |
|---|---|---|
| `unsafe-typecast` | `forge-lint: disable-next-line` / `disable-next-item` at 6 sites | Each cast has a bound stated in the comment above it (a receipt-weighted average of values in [-100e18, 100e18], list lengths grown one per transaction, ring-buffer indices below 32, amounts below the per-call cap). |
| `block-timestamp` | `exclude_lints` in `foundry.toml` | Same reason as Slither `timestamp`. |
| `reentrancy-events` | `exclude_lints` | Events follow calls to contracts fixed at construction (settlement asset, sealed `SettlementLog`, a freshly cloned account) under `ReentrancyGuardTransient`, and need the receipt id those calls return. |
| `require-revert-in-loop` | `exclude_lints` | Registration and module-install loops are atomic by design: one invalid entry rejects the whole call. |
| `missing-events-access-control` | `exclude_lints` | False positive: `isRecorder` changes emit `RecorderSet`; `_policies` changes emit `PolicyInstalled` / `PolicyUninstalled` in the same function. |

Findings fixed rather than suppressed: `uninitialized-local` (explicit `= 0`), `missing-zero-check` (`AgentAccountFactory` constructor now rejects the zero executor), one `unsafe-typecast` replaced by `SafeCast.toUint64`.
