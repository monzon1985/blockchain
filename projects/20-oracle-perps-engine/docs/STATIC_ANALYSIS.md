# Static analysis triage

Both analysers run in CI on `contracts/src` and must report zero untriaged findings.

## Slither 0.11.6 (`contracts/slither.config.json`)

`slither . --config-file slither.config.json` reports **0 results** with `fail_on: low`. The excluded detectors
and the inline suppressions are listed here with their justification.

### Excluded detectors

| Detector | Why it does not apply |
|---|---|
| `timestamp` | `block.timestamp` is part of the protocol: report freshness (60 s), orders newer than their reports, cancellation timeouts and funding/borrow accrual. Validator skew of a few seconds is inside the 60 s report window and cannot select a price. Slither also flags every comparison in functions that merely touch `block.timestamp`-derived values. |
| `incorrect-equality` | All flagged strict equalities compare enums (`OrderType`, `DecreaseKind`) or check for zero (`dt == 0`, `amount == 0`, `price == 0`). None compares a balance an attacker can move. |
| `cyclomatic-complexity` | Informational: `_settle` is a linear waterfall with one branch per settlement component. |

### Inline suppressions (`// slither-disable-next-line`)

| Location | Detector | Justification |
|---|---|---|
| `OracleVerifier.verifyReports` spread check | `divide-before-multiply` | The median of an even batch is floored by definition (it is the price the market uses); flooring makes the dispersion check stricter by at most one wei. |
| `PerpsMarket._increase` `Settlement memory s` | `uninitialized-local` | Memory structs are zero-initialised; only the fields that apply to an increase are set. |
| `OrderBook` / `LPVault` `market.requestConfig()`, `LPVault.executeRequest` `market.refreshPrice()` | `unused-return` | Tuple destructuring deliberately ignores fields the caller does not need. |
| `LPVault.requestRedeem` `escrowedAssets += executionFee` | `events-maths` | The change is carried by the `LpRequestCreated` event emitted in `_storeRequest`. |

## forge lint (Foundry 1.8.3, `[lint]` in `foundry.toml`)

`forge lint` runs on `src/` with severities high/medium/low and reports nothing. Test and script files are not
linted. In Foundry 1.8.3 `forge lint` always exits 0, so CI gates on `forge build --deny warnings` instead:
`lint_on_build` lints `src/` during the build and `--deny warnings` turns any lint finding or compiler warning
into a failed build (checked by adding a `(a / b) * c` function to `src/`: the build aborts with
`divide-before-multiply`). Excluded lints:

| Lint | Why it does not apply |
|---|---|
| `block-timestamp` | Same reasoning as Slither `timestamp`. |
| `require-revert-in-loop` | `OracleVerifier.verifyReports` must reject the whole batch when any report is invalid; that is the point of the loop. |
| `reentrancy-events`, `reentrancy-no-eth` | The flagged external calls go to the immutable system contracts (market, order book, vault, oracle) or to the collateral token via SafeERC20, under `nonReentrant` guards in every contract. Event ordering after those calls cannot be abused. |
| `unused-return` | Same as Slither. |
| `unsafe-typecast` | Every flagged cast is dominated by a sign check on the same expression (`x > 0 ? uint256(x) : …`, `if (x >= 0)`), or is `uint64(block.timestamp)` (safe until year 5.8·10¹¹). Downcasts of values that can overflow use OpenZeppelin `SafeCast`. |
| `missing-events-arithmetic` | `poolAmount` and `totalCollateral` change in the settlement waterfall; each change is reported by the position event of the calling action (`PositionIncreased`, `PositionDecreased`, `PositionLiquidated`, `PositionAutoDeleveraged`) or by `LiquidityAdded`/`LiquidityRemoved`. |

## Medusa and Foundry invariants

Dynamic analysis is described in the README (Testing). Medusa's first campaign found a solvency counterexample,
fixed by the payout backstop (DESIGN.md §7, §10).
