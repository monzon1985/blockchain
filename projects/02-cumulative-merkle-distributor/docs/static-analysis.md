# Static analysis triage

Two analyzers run on `src/` locally and in CI:

| Tool | Command | Result |
|---|---|---|
| Slither 0.11.6 | `FOUNDRY_PROFILE=slither slither . --config-file slither.config.json` | 0 findings (`fail_on: pedantic`, so any finding fails CI) |
| `forge lint` (Foundry 1.8.3) | `forge lint` (with `--report-unused-suppressions` to catch stale comments) | 0 diagnostics, 0 unused suppressions |

Slither is pointed at a dedicated Foundry profile (`out-slither/`, `cache-slither/`) because crytic-compile runs
`forge clean` before building; the default profile's artifacts are left alone. `test/`, `script/` and `dependencies/`
are filtered out (`filter_paths`), and `forge lint` ignores `test/**` and `script/**` (`[lint]` in `foundry.toml`).

Every finding that is silenced is silenced inline, at the exact line, and listed below with its justification.
`slither . --show-ignored-findings` prints the seven silenced Slither findings.

## Slither

| Detector | Location | Why it is a false positive or accepted |
|---|---|---|
| `timestamp` | `acceptRoot`: `block.timestamp >= pending.validAt` | The timelock is 24 hours; the few seconds a block producer can skew the timestamp cannot meaningfully shorten it. Comparing against `block.timestamp` is the point of a timelock. |
| `timestamp` | `claimFor`: `block.timestamp <= deadline` | The deadline is chosen and signed by the account; a few seconds of skew cannot extend an authorization in any useful way. |
| `unused-return` | `_isValidSignature`: `ECDSA.tryRecoverCalldata` | The third return value (`errArg`) only details *why* a signature is malformed. `err` already says whether recovery succeeded, which is all the check needs. |
| `naming-convention` (x4) | `ROOT_TIMELOCK()`, `CLAIM_AUTHORIZATION_TYPEHASH()`, `DOMAIN_SEPARATOR()` in the interface and the contract | Upper-case getters are the established ABI for constants and for EIP-2612-style `DOMAIN_SEPARATOR()`; renaming them would break integrations for style. |

## forge lint

| Lint | Location | Justification |
|---|---|---|
| `unsafe-typecast` | `proposeRoot`: `uint64(block.timestamp + ROOT_TIMELOCK)` | Timestamps fit in 64 bits for roughly 584 billion years. |
| `block-timestamp` (x2) | `acceptRoot`, `claimFor` | Same reasoning as Slither's `timestamp` above. |
| `reentrancy-events` | `_pay`: `emit Claimed` after the ERC-1271 check | On the `claimFor` path the only external call before the claim's effects is the ERC-1271 `STATICCALL`, which cannot write state, emit events or re-enter. Every claim entry point also holds `ReentrancyGuardTransient`. |

`forge lint` runs its default severities (high, medium, low). The opt-in `info`, `gas` and `code-size` notes were
reviewed once and deliberately not adopted: `modifier-used-only-once` and `unwrapped-modifier-logic` (on `onlyUpdater`
and `onlyGuardian`, kept as modifiers for readability; each is a single `require`) and `asm-keccak256` (on `_leafHash`;
hand-written assembly is reserved for places where it changes the design, and the leaf hash is a few dozen gas of a
claim that costs tens of thousands).

## Known analyzer limitation

Slither 0.11.6 logs `Impossible to generate IR` for three internal functions inherited from OpenZeppelin's
`ReentrancyGuardTransient` (`_nonReentrantBefore`, `_nonReentrantAfter`, `_reentrancyGuardEntered`). They use
`TransientSlot` user-defined value types that Slither's IR builder does not handle yet. Analysis of every other function
completes; the guard itself is covered dynamically by `ReentrancyTest` (a hostile token re-enters `claim`, `claimFor`
and `claimMany` from inside the payout of each, and every re-entry must fail with `ReentrancyGuardReentrantCall`), by
`test_claim_reentrantTokenIsBlocked`, and by mutants M13, M23 and M24 of the mutation spot-check (removing
`nonReentrant` from `claim`, `claimFor` or `claimMany` fails the suite).
