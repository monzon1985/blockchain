# Static analysis triage

Both analyzers run in CI (`.github/workflows/21-passkey-smart-account.yml`) with **no global exclusions**: neither
`foundry.toml` `[lint]` nor `slither.config.json` excludes a lint or detector. Every accepted finding is suppressed
inline at its own site, with the reason in a comment next to it, and listed below. A new finding of the same class
anywhere else in `src/` therefore still fails the gates.

## forge lint (Foundry 1.8.3)

Runs on every `forge build` (`lint_on_build`, and `deny = "warnings"` makes a finding fail the build) and as
`forge lint src --deny warnings`. The configured severities are high, medium and low; the naming lints are `info` and
not run, so the OpenZeppelin-style `$` storage pointers and SCREAMING_SNAKE_CASE immutables need no suppression.

| Lint | Site (`src/`) | Suppression | Reason |
|---|---|---|---|
| `block-timestamp` | `PasskeyAccount.initializeWithSig`, `cancelRecoveryWithSig`, `approveRecoveryWithSig` (signature deadlines) | `disable-line` on the `require` | Second-granularity deadlines; proposer timestamp drift (~12 s) is irrelevant. |
| `block-timestamp` | `PasskeyAccount._requireNotFrozen`, `_isFrozenNow` (7-day freeze) | `disable-line` | Day granularity. The validation phase never reads `TIMESTAMP`: the freeze is returned as `validAfter`. |
| `block-timestamp` | `PasskeyAccount.executeRecovery` (48 h timelock) | `disable-next-item` on the function | Hour granularity. |
| `reentrancy-events` | `PasskeyAccount.removeGuardian`, `freeze`, `executeRecovery`, `_initialize`, `_setPasskey`, `_addGuardian`, `_setThreshold`, `_approveRecovery`, `_bumpRecoveryEpoch` | `disable-next-item` on each function | False positive: the preceding "calls" are internal library functions (`EnumerableSet`, `P256.isValidPublicKey`), not external calls. |
| `reentrancy-events` | `PasskeyAccountFactory.createAccount` | `disable-next-line` on the `emit` | Only the clone's own CREATE2 precedes the event, which is emitted before the one external call (`initialize`). |
| `require-revert-in-loop` | `PasskeyAccount._addGuardian` (called in the init loop) | `disable-next-item` | Initialization must be all-or-nothing: one bad guardian aborts the whole init. |
| `unsafe-typecast` | `uint48(block.timestamp)` in `freeze` and `_approveRecovery` | `disable-next-line` | uint48 timestamps overflow in the year 8.9 million. |
| `missing-zero-check` | `PasskeyAccount` constructor (`factory_`), `TokenPaymaster.setSponsorSigner` | `disable-next-line` | Zero is meaningful: a delegation-only implementation; guaranteed mode disabled. |

## Slither 0.11.6

`slither . --config-file slither.config.json --fail-low`; the config only filters `dependencies/`, `test/` and
`script/`. Result: 82 contracts analyzed with all 102 detectors, **0 results**. Suppressions are
`// slither-disable-next-line <detector>` on the line before the flagged node.

| Detector | Site (`src/`) | Reason |
|---|---|---|
| `timestamp` | The six `block.timestamp` comparisons listed under forge lint | Same as `block-timestamp` above. |
| `missing-zero-check` | `FACTORY = factory_` (PasskeyAccount constructor), `sponsorSigner = newSigner` | Same as forge lint above. |
| `unused-return` | `TokenPaymaster._fetchDetails`: third return of `ECDSA.tryRecoverCalldata` | The `RecoverError` enum is checked instead of the error argument. |
| `assembly` | `PasskeyAccount._s()` | The only assembly block: points a storage reference at the constant ERC-7201 slot. |
| `dead-code` | `PasskeyAccount._erc7821AuthorizedExecutor` | False positive: it overrides an OpenZeppelin hook called by `ERC7821.execute`, and Slither 0.11.6 logs `Impossible to generate IR` for that caller, so it cannot see the call edge. |
| `naming-convention` | Immutables `_ENTRY_POINT` (account, paymaster), `FACTORY`, `TOKEN`, `ACCOUNT_IMPLEMENTATION` | OpenZeppelin 5 style (SCREAMING_SNAKE_CASE immutables); the public getters are part of the ABI. |

Findings fixed instead of suppressed: `unused-return` on `Clones.cloneDeterministic` in the factory (the returned
address is now used).
