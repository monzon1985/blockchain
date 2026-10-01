# Static analysis triage

Both analyzers run in CI and must report zero findings. Every suppression below is an inline annotation at the exact
line (`// slither-disable-next-line`, `// slither-disable-start/end`, `// forge-lint: disable-next-line(...)`), next
to a comment that states why it is safe. Configuration: `slither.config.json` (only `dependencies/`, `test/` and
`script/` are filtered out) and the `[lint]` section of `foundry.toml` (no lints excluded globally).

Commands:

```bash
slither . --config-file slither.config.json   # 0 results (40 contracts, 102 detectors)
forge lint                                    # 0 warnings
```

## Slither 0.11.6

| Detector | Location | Triage |
|---|---|---|
| `divide-before-multiply` | `VolatilityMath.decayFactor` | Intended. Square-and-multiply in 18-decimal fixed point divides by WAD after each product. The accumulated error is bounded analytically (< 2^bitlen(k) wei) and checked against exact values (`test_differential_decayFactor`). |
| `unused-return` | `getSlot0` in `quoteFees`, `_beforeSwap`, `_extendRangeAndPrice` | Intended. Only `sqrtPriceX96` and `tick` are needed; `protocolFee` and the stored `lpFee` (always 0 for override-fee pools) are irrelevant. |
| `unused-return` | `poolManager.donate` in `_donateSurcharge` | Intended. The returned delta is exactly the debit booked against the hook, offset by the `afterSwap` return delta (checked after every swap by `BatchSwapRouter` and the Medusa harness). |
| `reentrancy-events` | `LiquidityNotificationDelivered` in `deliverNotification` | Intended. The event reports the outcome of the module call it follows. The notification's commitment is deleted before the call and no state is written after it, so a re-entrant module can neither replay the notification nor observe a half-updated hook. |
| `assembly` | `deliverNotification` | Intended. A low-level `call` with a fixed gas budget and zero-length output, so the module's return data is never copied (return-bomb protection) and no extcodesize check or ABI decoding can revert. The block is commented and marked `memory-safe`. |

`missing-zero-check` on `LiquidityTelemetry`'s constructor was fixed (it now reverts with `ZeroHook`), and the
`reentrancy-events` finding on `HookFee` was removed by emitting the event before the donation.

## forge lint (Foundry 1.8.3)

| Lint | Location | Triage |
|---|---|---|
| `unsafe-typecast` | `VolatilityMath.absTickDelta`, `VolatilityMath.lpFee`, `VolatilityFeeHook._abs` | Each cast is guarded by the branch it sits in (non-negative operand, or a value already compared against a 10,000 bound). The surcharge rate and every narrowing store into `PoolState` (EWMA to 88 bits, fee and rate to 16 bits) use `SafeCast` instead. |
| `reentrancy-events` | `PoolRegistered`, `VolatilityUpdated`, `HookFee` | False positives: no state-changing external call precedes them (only internal libraries, or the read-only `getSlot0`, which the PoolManager serves with a STATICCALL-safe `extsload`). |
| `reentrancy-events` | `LiquidityNotificationDelivered` | Same as the Slither finding above. |
| `unused-return` | `poolManager.donate` | Same as the Slither finding above. |
| `environment-read-across-mutation` | tests (`HookFixture.nextBlock`, `GbmReplay`) | Fixed: the tests read `vm.getBlockNumber()` instead of `block.number` around `vm.roll`. |
