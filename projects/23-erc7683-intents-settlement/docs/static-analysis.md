# Static analysis triage

Both analyzers run in CI on `src/` and must report nothing:

```bash
forge lint src --deny warnings --report-unused-suppressions   # Foundry 1.8.3 linter
slither . --config-file slither.config.json                    # Slither 0.11.6: "0 result(s) found"
```

Findings that were real were fixed in the code (for example: constructor zero-address checks, the `Open` event moved before the token pull, explicit initialization in the resolver adapter). What remains is suppressed either project-wide (below) or inline, and every inline suppression carries its justification in a comment on the line above it. `--report-unused-suppressions` makes a stale suppression fail the build.

## Project-wide exclusions

| Tool | Rule | Why it does not apply |
|---|---|---|
| forge lint | `block-timestamp` | Deadlines (open, fill, refund grace, challenge window) are minutes to hours long; the few seconds of validator leeway cannot change who may act. |
| Slither | `timestamp` | Same reason. |
| Slither | `naming-convention` | Immutables are SCREAMING_SNAKE_CASE (the style `forge lint` enforces), and the resolver-draft interfaces use PascalCase function names because the ERC defines them that way. |

## Inline suppressions

| Location | Rule | Justification |
|---|---|---|
| `IERC7683Resolver.sol` (17 functions) | `mixed-case-function` | Names are fixed by the ERC (`Call`, `PaymentRecipient`, `ERC20`, ...). |
| `OriginSettler._register` | `unsafe-typecast` (x2) | `uint96(inputAmount)` and `uint64(destinationChainId)` are range-checked in `_validate`. |
| `OriginSettler._checkReceived` | Slither `incorrect-equality` | Strict equality is the point: any other received amount means a non-standard token that would break escrow accounting. |
| `DestinationSettler._fill` | `unsafe-typecast` | `uint64(block.timestamp)` holds for about 584 billion years. |
| `OptimisticSettlementModule.claim` | `unsafe-typecast` | Same, for `block.timestamp + CHALLENGE_WINDOW` with a window below 2^32. |
| `FillProofLib.unpack` | `unsafe-typecast` (x2) | Truncation is the unpacking: bits 0..159 are the filler, 160..223 the fill time. |
| `MerklePatriciaExclusion._link` | `unsafe-typecast` | Takes the first byte of a loaded word on purpose (the RLP prefix). |
| `ERC7683ResolverAdapter._mailboxSteps`, `StorageProofSettlementModule._provenRecord` | `unused-return` (forge lint and Slither) | Deliberate partial destructuring of a two-value return. |
| `setSettlementModule`, `setRoute`, `setOriginModule`, `setDestinationSettler`, `MockMailbox.process`, `HeaderStore._store` | `reentrancy-events` | The only external call before the event is `AccessManager.canCall`, made by the `restricted` modifier to the trusted authority. |
| `MailboxFillReporter.report` | `reentrancy-events` (forge lint and Slither) | The event needs the message id returned by the mailbox; both callees are immutable protocol contracts and `report` keeps no state. |
| `OptimisticSettlementModule.challenge`, `StorageProofSettlementModule.proveFill` | `reentrancy-events` | Prior calls are view calls to immutable protocol contracts; `challenge` is also `nonReentrant`. (`finalize` needs no suppression: both analyzers accept it as is.) |
| `DestinationSettler._fill` | `reentrancy-events` | False positive: the event is emitted before the function's only external call. |

## Other analysis

- **Coverage**: `forge coverage` on production code (see the README for the numbers).
- **Mutation smoke test**: nine hand-written mutants of security-critical checks, committed as patches in [`test/mutants/`](../test/mutants) and run by `bash test/mutants/run.sh` (locally and in CI); every one must make `forge test` fail. See the README for which suites kill each.
- **Medusa**: the property harness in `test/medusa` runs for 300 seconds in CI.
