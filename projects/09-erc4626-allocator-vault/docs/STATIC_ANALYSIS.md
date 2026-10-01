# Static analysis triage

Two analyzers run in CI on production code (`src/`): Slither 0.11.6 and `forge lint` (Foundry 1.8.3). Tests, mocks
and scripts are excluded from both. After the triage below, both report **zero findings at every severity**. Slither
is gated with `--fail-medium`, the equivalent of the spec's `--fail-on medium` (a flag Slither 0.11.6 does not accept);
the code also passes `--fail-low`.

## Slither

Configuration: [`slither.config.json`](../slither.config.json). **Every Medium and High detector is enabled.** The
instances that are false positives are suppressed in place, on the line before the flagged code and with the reason
on the line above that, so a new instance anywhere else still fails the gate. Only three Low-severity detectors are
excluded project-wide.

### Excluded detectors (Low only)

| Detector | Severity | Why it does not apply |
|---|---|---|
| `calls-loop` | Low | Looping over strategies is the product, bounded by `MAX_STRATEGIES = 20`. Strategy **views** (`balanceOf`, `previewRedeem`, `maxRedeem`, `maxWithdraw`) are called through `try`/`catch`, so a strategy whose views revert (a paused strategy, which EIP-4626 allows) blocks nothing: the vault counts the position at 0, keeps working at the conservative price, pauses deposits, and the curator can force-remove it ([`test/unit/Impairment.t.sol`](../test/unit/Impairment.t.sol)). An out-of-gas failure is not accepted as a failing strategy (the call reverts instead), so under-funding a transaction cannot fake one. What Slither still flags are state-changing calls inside loops: `withdraw` while walking the withdraw queue, and `deposit` / `withdraw` / `redeem` in `reallocate`. A strategy that reverts there blocks only the operations that reach it: allocations to or from it, and withdrawals that need its liquidity before another strategy's in queue order. A compliant strategy reports `maxWithdraw = 0` while it cannot pay, so withdrawals skip it; for a non-compliant one the allocator can move it to the end of the queue at once (no timelock), as `test_strategyThatRefusesWithdrawalsOnlyBlocksWithdrawalsThatReachIt` shows. |
| `reentrancy-events` | Low | Every function that makes external calls is `nonReentrant`, and every price view is `nonReentrantView` (each one probed by a hostile strategy in [`test/unit/Reentrancy.t.sol`](../test/unit/Reentrancy.t.sol)), so events cannot be reordered by reentrancy. `Deposit` / `Withdraw` follow OpenZeppelin's ERC-4626 ordering (transfer, then event). |
| `timestamp` | Low | The flagged comparisons (`shares == 0`, `shares > ownerShares`, ...) do not involve `block.timestamp`; Slither taints them through the accrual. The only real timestamp comparisons are the 3-day timelock and the 7-day unlock, where validator drift of seconds is irrelevant. |

`reentrancy-balance` and `incorrect-equality` (Medium) used to be excluded project-wide; they are now enabled, and
each current instance is suppressed individually below.

### Inline suppressions

| Location | Detector | Justification |
|---|---|---|
| `AllocatorVault._redeemRedeemable` (`slither-disable-start/end`), used by `submitStrategyRemoval` and `removeStrategy` | `unused-return` | The return value of `strategy.redeem` is ignored on purpose: forced deallocation books the balance delta that actually arrived (and a removal writes off the rest), so a strategy that claims more than it delivers cannot inflate the vault. |
| `AllocatorVault.reallocate`: the two balance reads (`shares`, `idle`) | `reentrancy-balance` | Read fresh for every allocation inside a `nonReentrant` function and used only to size that allocation's own move, before its own external call; no reentrant call can change them before they are used. |
| `AllocatorVault._pullLiquidity`: `idle` | `reentrancy-balance` | `needed` is reduced by what each strategy actually delivered (`_withdrawFromStrategy` reverts on a short delivery), and the function is only reached from `nonReentrant` entry points. |
| `AllocatorVault._withdrawFromStrategy`, `_redeemAllFromStrategy`: `balanceBefore` | `reentrancy-balance` | A balance delta around exactly one external call; the read after the call is fresh, and both are only reached from `nonReentrant` entry points. |
| `deposit` (`shares == 0`), `reallocate` (`shares == 0`, `amount == 0`), `_pullLiquidity` (`amount == 0`) | `incorrect-equality` | Zero checks on computed amounts or on the vault's own share count, not equalities on a balance someone else can move. |
| `_checkTimelock`, `_clearPendingCap` (`validAt == 0`) | `incorrect-equality` | 0 is the "nothing pending" sentinel of a timestamp field. |

## forge lint

Configuration: `[lint]` in `foundry.toml`; run as `forge lint --deny warnings`.

### Excluded lints

| Lint | Why it does not apply |
|---|---|
| `reentrancy-events` | Same as Slither above. |
| `calls-loop` | Same as Slither above. |
| `require-revert-in-loop` | The reverts inside loops are the intended behavior: a duplicate in a submitted withdraw queue, a strategy that under-delivers, or an allocation above its cap must abort the whole call. |
| `block-timestamp` | Timelock (3 days) and unlock (7 days) comparisons; second-level drift is irrelevant. |

### Inline suppressions

| Location | Lint | Justification |
|---|---|---|
| `AllocatorVault._redeemRedeemable` | `unused-return`, `reentrancy-no-eth` | As for Slither: the `redeem` return value is deliberately replaced by the measured balance delta; both callers are `nonReentrant`. |
| `AllocatorVault.setFeeRecipient` | `missing-zero-check` | Zero is allowed deliberately and checked in the body: it is only accepted while both fees are zero (`ZeroFeeRecipient` otherwise), which is covered by `test_feeRecipient_canBeClearedWhenFeesAreZeroButNotReused`. |

Findings that were fixed rather than suppressed: unsafe typecasts (now `SafeCast`), modifier order
(`nonReentrant` first), uninitialized locals, contract-type comparisons (deprecated in solc 0.8.37), dead code (the
ERC-4626 view overrides now call the internal conversions directly), and `boolean-cst` (the `try`/`catch` helpers
assign their named return values instead of returning boolean literals).
