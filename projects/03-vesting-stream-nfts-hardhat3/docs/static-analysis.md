# Static analysis triage

Slither 0.11.6 (crytic-compile 0.4.2, solc 0.8.37) runs on the three deployable contracts with `npm run slither`:

```bash
slither contracts/VestingStreams.sol  --config-file slither.config.json
slither contracts/StreamRenderer.sol  --config-file slither.config.json
slither contracts/demo/DemoToken.sol  --config-file slither.config.json
```

Slither compiles each entry point with plain `solc` and the npm remappings from `slither.config.json`
(crytic-compile 0.4.2 does not read Hardhat 3 build-info files). The optimizer and EVM settings are the same as in
`hardhat.config.ts`. `fail_on` is `pedantic`: any finding of any severity, informational included, fails the run, locally
and in CI. Current result: **0 findings** on all three contracts. Findings inside `node_modules/` (OpenZeppelin, Solady)
are filtered out.

## Detectors excluded in `slither.config.json`

| Detector | What it reported without the exclusion | Why it is excluded |
|---|---|---|
| `timestamp` | 8 comparisons in 6 functions of `VestingStreams` and 2 in `StreamRenderer._xOf` | A vesting schedule *is* a function of time. Validators can skew `block.timestamp` by a few seconds, which moves a vesting curve by the same few seconds; no comparison guards anything that a few seconds of skew could exploit. |
| `assembly` | 3 blocks in `MilestoneCodec` | Packing 21-byte milestones is the point of the codec. Each block is `memory-safe` and carries a comment explaining why it stays inside its allocation; `testFuzz_codec_roundTrip` and `test_codec_packsTwentyOneBytesPerMilestone` cover it. |
| `naming-convention` | `RECIPIENT_HOOK_GAS`, `MAX_TRANCHES`, `MAX_SEGMENTS` getters in `IVestingStreams`; `HEAD_POINTER`, `FRAME_POINTER` immutables | These are constants and immutables, which the Solidity style guide names in `UPPER_CASE`. Slither expects `mixedCase` for the interface getters that expose them. |

## Inline suppressions

Every inline suppression was checked with `--show-ignored-findings`: each one silences a real finding, and none is
unused.

| Location | Detector | Justification |
|---|---|---|
| `VestingStreams.withdrawMax` (`amount == 0`) | `incorrect-equality` | Compares a computed amount (`streamed - withdrawn`), not a token balance that a third party could inflate with a donation. |
| `VestingStreams.cancel` (`streamed == depositAmount`) | `incorrect-equality` | Both sides are computed from stored state; every curve returns exactly `depositAmount` once fully vested (milestones are validated to sum to the deposit). |
| `VestingStreams.statusOf` (same comparison) | `incorrect-equality` | Same reasoning; view only. |
| `StreamRenderer._svg`, `_curvePoints`, `_json` | `uninitialized-local` | A zero-initialized `DynamicBufferLib.DynamicBuffer` is the library's documented empty starting state. |
| `StreamRenderer` rendering section (`slither-disable-start/end unused-return`) | `unused-return` | `DynamicBufferLib.p` appends in place and returns the same buffer for chaining; the return value carries no information. |

## Compiler warnings

`npx hardhat build` reports no warning in `contracts/`. It prints warnings from dependencies only: solc 0.8.37
deprecates the `/// @solidity memory-safe-assembly` NatSpec form that Solady 0.1.26 still uses (96 occurrences), and
OpenZeppelin's `TransientSlot` triggers solc's generic EIP-1153 notice (used here only by `ReentrancyGuardTransient`,
which clears the slot at the end of every call).
