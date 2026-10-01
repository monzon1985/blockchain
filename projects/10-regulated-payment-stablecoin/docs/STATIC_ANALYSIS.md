# Static analysis triage

Two analysers run on `src/` in CI: Slither 0.11.6 (`slither . --config-file slither.config.json --fail-medium`) and `forge lint --deny warnings` (Foundry 1.8.3). Tests, mocks and scripts are excluded from both. Every exclusion is listed here with its justification; there are no inline suppressions in `src/`.

## Slither

Result of the last run: `67 contracts with 100 detectors, 0 result(s) found` (102 detectors minus the two excluded below; the 8 results they produced before triage are all listed here).

| Detector | Impact | Findings before triage | Decision | Justification |
|---|---|---|---|---|
| `timestamp` | Low | 4 functions: `permit(bytes)` deadline, `submitReserveAttestation` (future / age checks), `mintHeadroom`, `_requireReserveHeadroom` | excluded | Time windows are the feature: EIP-2612 deadlines, the 26 h attestation freshness and the 24 h rolling limits. A block producer can skew `block.timestamp` by seconds, which is irrelevant against windows of hours (the ERC-3009 validity checks in OpenZeppelin's base contract use the same clock). |
| `assembly` | Informational | 4 functions, all `_get*Storage()` | excluded | The ERC-7201 accessor pattern: a single `$.slot := CONSTANT` assignment, commented at each site, identical to OpenZeppelin's own upgradeable contracts. The slot constants are recomputed from their namespace ids in `test_upgrade_namespacesFollowErc7201`. |

Everything else ran clean, in particular `reentrancy-*`, `arbitrary-send-*`, `uninitialized-*`, `unprotected-upgrade`, `missing-zero-check`, `events-access`, `events-maths` and `divide-before-multiply`.

## forge lint

`forge lint --deny warnings` passes with two rules excluded in `foundry.toml`:

| Rule | Why it fires | Justification |
|---|---|---|
| `reentrancy-events` | Events are emitted after the `restricted` modifier's call to the AccessManager (and, in the gasless paths, after the ERC-1271 `staticcall`). | The only external calls are (a) the AccessManager, which is the trusted authority and is called *before* any state change, and (b) `isValidSignature` through a `staticcall`, which cannot modify state or re-enter a state-changing path. The token makes no call to untrusted code and has no transfer hooks. |
| `block-timestamp` | Same sites as Slither's `timestamp`. | See above. |

## Why there is no reentrancy guard

The standards ask for `ReentrancyGuardTransient` "wherever external calls meet state". tPD never calls untrusted code with state pending: ERC-20 moves have no hooks, ERC-1271 checks are `staticcall`s performed before the state change, and the AccessManager call in `restricted` happens before the function body. Adding a guard would cost gas on every payment without closing a path, so the choice is documented instead (see the threat model, SC08).
