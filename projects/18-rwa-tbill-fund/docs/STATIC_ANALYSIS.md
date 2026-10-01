# Static analysis triage

Two analyzers run on `src/` in CI and must report zero findings:

- `forge lint --deny warnings` (Foundry 1.8.3, config in `foundry.toml` `[lint]`)
- `slither . --config-file slither.config.json` (Slither 0.11.6, `fail_on: low`)

Findings were triaged individually. Anything that was a real improvement was fixed in code (see "Fixed"); the rest
is suppressed either for a whole rule (config) or for one line (inline comment), each with the reason below.

## Fixed

| Tool / rule | Change |
|---|---|
| lint `unsafe-typecast` (12) | Every narrowing cast (`uint64(block.timestamp)`, document positions, country codes) now goes through `SafeCast`. |
| lint `non-reentrant-not-first` (3) | `nonReentrant` placed before `restricted` on custody and dividend-creation functions. |
| lint `reentrancy-no-eth` | The token's choke point `_checkedUpdate` is `nonReentrant` (transient storage), so a module cannot re-enter a movement before balances are written. Test: `test_moduleCannotReenterAMovement`. |
| lint `missing-zero-check` | Compliance modules reject a zero engine (`InvalidEngine`). |
| lint `boolean-cst` (4) | Boolean literals in tuple returns replaced by named return variables. |
| lint `unused-import` | Removed from `IERC7575.sol`. |
| Slither `shadowing-local` | `IERC7575Share.vault` return variable renamed to `vaultAddress`. |

## Rules excluded project-wide

| Rule (tool) | Why it does not apply |
|---|---|
| `reentrancy-events` (lint, Slither) | Almost every hit is an event emitted after the AccessManager `canCall` staticcall made by the `restricted` modifier, or after calls to the fund's own trusted contracts (registry, engine, modules, settlement asset). All entry points that move assets are `nonReentrant`; event order is not relied upon for accounting. |
| `block-timestamp` / `timestamp` (lint, Slither) | Timestamps are the specification: claim expiry, 2-day recovery timelock, lockups, trading windows, NAV staleness and forward pricing. Validator skew (seconds) is irrelevant at these granularities (hours to days). |
| `calls-loop` (lint, Slither) | The engine loops over at most 8 governance-approved modules by design (`MAX_MODULES`). |
| `require-revert-in-loop` (lint) | Reverting when any module rejects, or when a duplicate module is added, is the intended semantics. |
| `missing-events-access-control` (lint) | Flags internal accounting (`_fold` epoch counters, dust release totals). These are not access-control state; the enclosing public functions emit `DepositRequest`, `Deposit`, `Withdraw` and `EpochDustReleased`. |
| `costly-loop` (Slither) | `removeModule` pops once from an array of at most 8 entries. |
| `incorrect-equality` (Slither) | Strict equalities in the engine compare its own ledger (`investor.balance == amount`, `balance == 0`) and the share token's balance, which can only change through the engine itself (no donation path), so equality is exact by construction. |

## Inline suppressions (one line each)

| Location | Rule | Reason |
|---|---|---|
| `FundVault.requestDeposit` | `arbitrary-send-erc20` | `owner` is `msg.sender` or has approved `msg.sender` as its ERC-7540 operator (checked two lines above). |
| `FundVault.recallFromCustodian` | `arbitrary-send-erc20` | `from` is the governance-appointed custodian, which pre-approves the vault; the function is `FUND_ADMIN`-only. |
| `FundVault.setCustodian` | `missing-zero-check` | Zero is a valid value: it disables custody moves. |
| `FundShareToken.issueLawfulOrder` | `unused-return` | Only the document hash is recorded with the order; URI and timestamp are informational. |
| `FundShareToken._modulesAllow` (used by `canTransfer` and `canMint`) | `unused-return` (Slither) | The rejecting module address is irrelevant to the boolean answer. |
| `FundVault._checkController` | `unused-return` | Only whether a successor is scheduled matters; the recovery ETA and case reference are informational. |
| `FundShareToken._checkedUpdate` | `reentrancy-no-eth` (lint) | Guarded by `nonReentrant`; the analyzer does not model modifiers on private functions. |
| `TransferWindowModule.isOpenAt` | `weak-prng` (Slither) | Calendar arithmetic (`% 7`, `% 86400`), not randomness. |

## Informational lints not enforced

`forge lint --severity info` also reports `screaming-snake-case-immutable` for public immutables such as
`engine`, `identityRegistry` and `payoutToken`. Their names are part of the external ABI (`engine()` is in the
`IComplianceModule` interface), so they keep ABI-style names.
