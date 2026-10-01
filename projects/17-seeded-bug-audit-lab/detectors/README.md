# Kestrel custom Slither detectors

Three custom [Slither](https://github.com/crytic/slither) detectors, packaged as the `kestrel`
Slither plugin (entry point `slither_analyzer.plugin`), with a precision/recall test suite.

| Argument | Flags |
|---|---|
| `kestrel-spot-price-collateral` | a valuation function (collateral, price, health, …) that consumes, through an external call, a price one transaction can move: AMM reserves or spot, `balanceOf`, `totalAssets`, an ERC-4626 share price. One hit per (function, source); the AMM's own spot view is a source, not a consumer, and is not flagged. |
| `kestrel-unchecked-callback` | an external, state-changing low-level call to a destination other than `msg.sender` whose authorization is missing, or is derived from a flash-loanable balance (`balanceOf`, `totalSupply`, `getVotes`) instead of storage, historical checkpoints (`getPastVotes`) or caller identity. |
| `kestrel-div-before-mul-loop` | a division whose result is later multiplied, inside a loop (per-iteration truncation is amplified). |

Every result carries `additional_fields.site` (`<path>:Contract.function`, unique even when two trees
define the same contract) and `additional_fields.detail` (the source or reason), which the triage
gate and the scoreboard key on.

## Run

```bash
uv sync --locked
uv run solc-select install 0.8.37   # once, for the fixture compile
uv run ruff check . && uv run ruff format --check .
uv run pytest                       # precision/recall on tests/fixtures (7 tests)

# On the protocol, next to the standard detectors (from the project root):
FOUNDRY_PROFILE=fixed uv run --project detectors --locked slither . --config-file slither.config.json
```

## What the tests measure

`tests/test_detectors.py` compiles each fixture with plain solc 0.8.37 from a temporary directory
(`compile_force_framework="solc"`), so crytic-compile never detects the enclosing Foundry project
and never touches its build output. Ground truth is declared per detector; the fixtures include
adversarial negatives that a name-only heuristic would get wrong — a TWAP-priced valuation whose
name contains "price", a valuation from a stored price, a call gated by stored quorum votes, and a
call gated by historical checkpoints. On these fixtures precision and recall are both 1.0.

Fixtures written by the detector's author are an optimistic benchmark. The protocol-level
precision, measured on the real trees by the blind run, is reported in
[`../scoreboard/DETECTION_TABLE.md`](../scoreboard/DETECTION_TABLE.md): a hit counts as a true
positive only when it fires on the vulnerable tree at a bug site and not on the fixed tree.
