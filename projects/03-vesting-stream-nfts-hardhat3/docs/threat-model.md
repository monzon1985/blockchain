# Threat model

Scope: `contracts/VestingStreams.sol`, `contracts/StreamRenderer.sol` and the libraries under `contracts/libraries/`.
`contracts/demo/DemoToken.sol` is a local demo token and `contracts/mocks/` is test-only code; neither is in scope.

Nothing in this repository has been professionally audited. This document is the author's own analysis.

## Assets

| Asset | Where it lives | Why it matters |
|---|---|---|
| Escrowed ERC-20 balances | `VestingStreams` token balances | The only value the protocol holds. Every stream's deposit must be paid out to the NFT owner or refunded to the sender, never created, lost or stranded. |
| Withdrawal rights | ERC-721 ownership and approvals of each stream id | Whoever owns (or is approved for) the NFT decides where vested tokens go. |
| Cancellation rights | `Stream.sender` + `Stream.cancelable` | The sender can claw back the unvested part until it renounces or the stream settles. |
| Metadata integrity | `StreamRenderer` output | Marketplaces and wallets display it. Misleading art does not move funds, but it can mislead buyers of a stream NFT. |

## Actors and trust assumptions

| Actor | Trusted for | Can do | Cannot do |
|---|---|---|---|
| Stream sender | Nothing beyond its own streams | Create streams with any token, cancel its cancelable streams (refund of the unvested part only), renounce cancelability | Touch vested tokens, other senders' streams, or any stream after renouncing |
| NFT owner / approved operator | Its own stream | Withdraw vested tokens to any address, transfer or approve the NFT | Withdraw more than has vested, cancel, or affect other streams |
| Contract owner (`Ownable2Step`) | Metadata only | Replace the renderer (`setRenderer`), transfer or renounce ownership | Move, freeze or redirect tokens; block `withdraw` or `cancel` (neither reads the renderer) |
| ERC-20 token | Nothing: chosen by the sender, possibly hostile | Re-enter (blocked), lie about balances, revert, return garbage metadata | Affect streams of any other token (each stream's accounting is isolated) |
| Contract recipient (`IStreamRecipient`) | Nothing | Run code for at most 100,000 gas when its stream is canceled | Block or alter the cancellation, re-enter, or make the sender pay to copy revert data |
| Validators | Block timestamps within consensus bounds | Shift `block.timestamp` by a few seconds | Change a schedule; the impact is a few seconds of vesting either way |

## Attack surface and mitigations

Vulnerability classes are named after the [OWASP Smart Contract Top 10 (2026)](https://scs.owasp.org/sctop10/).

| # | Threat | Class | Mitigation | Enforced by |
|---|---|---|---|---|
| T1 | Fee-on-transfer token credits a stream with more than the contract received | SC02 Business Logic | `_pullExact` compares the balance delta with the requested amount and reverts with `UnsupportedToken(token, expected, received)` | `test_create_revertsForFeeOnTransferToken`, `test_createBatch_revertsForFeeOnTransferToken`, INV-5 |
| T2 | Share-based rebasing token (stETH-style) delivers a wei less than requested | SC07 Arithmetic | Same exact-delta check | `test_create_revertsWhenRebasingTokenDeliversLess`, handler `createWithUnsupportedToken` |
| T3 | Re-entrancy from a token callback (ERC-777/1363 style) or from the cancel hook | SC08 Reentrancy | `ReentrancyGuardTransient` on every state-changing entry point; effects before interactions | `test_reentrancy_fromTokenCallbacksIsBlocked`, `test_reentrancy_fromHookIsBlocked`, INV-7 |
| T4 | Recipient hook blocks `cancel` by reverting, burning gas or returning a huge revert payload | SC06 Unchecked External Calls | `try/catch` with a fixed 100,000 gas stipend; `catch {}` does not copy revert data; failure emits `RecipientHookFailed` | `test_hook_*` (6 tests) |
| T5 | Sender starves the hook on purpose by sending just enough gas for the rest of `cancel` (EIP-150 63/64 rule) | SC06 | `cancel` reverts with `InsufficientGasForHook` unless `100,000 * 64 / 63 + 5,000` gas is left before the call | `test_revert_insufficientGasForHook`, `test_hook_calledWithArgumentsAndFullStipend` |
| T6 | Unauthorized withdrawal | SC01 Access Control | `_isAuthorized(owner, caller, id)` (ERC-721 owner, token approval or operator approval) | `test_revert_notAuthorized`, INV-6 |
| T7 | Withdrawal to the zero address or to the vesting contract (tokens lost or double-counted) | SC05 Input Validation | `InvalidWithdrawalTarget` | `test_revert_invalidTarget` |
| T8 | NFT sent to the vesting contract itself, freezing the withdrawal right | SC05 | `_update` override reverts with `InvalidRecipient` | `test_revert_nftCannotBeSentToTheVestingContract` |
| T9 | Malformed schedules (unsorted milestones, cliff outside the range, sum different from the deposit, too many milestones) | SC05 | `_validate` / `_validateMilestones`, each with a dedicated custom error carrying the offending values | `test_revert_*` in `Create.t.sol` |
| T10 | Rounding that overstates what has vested | SC07 | Every division floors; the refund is `deposit - streamed`, so rounding favours the sender (see the README rounding table) | `test_cancel_roundingFavoursTheRefund`, `testFuzz_linear_boundedMonotonicFloor`, differential tests, INV-3 |
| T11 | Overflow in schedule math | SC09 | `uint256` intermediates (`uint128 * uint40` fits in 168 bits), checked arithmetic everywhere else; the only downcasts are proven bounded in comments | `test_linear_maxValuesDoNotOverflow`, fuzz tests |
| T12 | Hostile `symbol()`: markup or JSON injection into the metadata (stored XSS in marketplaces) | SC05 | `SafeText.sanitize` keeps printable ASCII only and at most 16 characters, then context-specific escaping (`escapeHTML` for SVG, `escapeJSON` for JSON) | `escaping.test.ts` (16 corpus + 150 random payloads through a strict XML validator and `JSON.parse`), `testFuzz_xml_*`, `testFuzz_json_*` |
| T13 | Hostile `symbol()` / `decimals()` that reverts, returns nothing or burns all gas, blanking the NFT everywhere | SC06 | Solady `MetadataReaderLib` with a 50,000 gas cap and a 64-byte read limit; fallbacks `UNKNOWN` and `0` decimals | `test_revertingSymbolRendersUnknown`, `test_gasBurningSymbolIsCappedAndRendersUnknown`, gas-budget tests |
| T14 | `tokenURI` too expensive for RPC `eth_call` limits | SC02 | Bounded milestone counts (32 / 16), static SVG fragments read from SSTORE2; worst case measured at 1,110,749 gas against a 3,000,000 budget | `gas-budget.test.ts` |
| T15 | Compromised owner swaps in a malicious renderer | SC01 | The renderer is a pure view dependency: `withdraw`, `cancel` and every view used for accounting ignore it. `setRenderer` emits `RendererUpdated` and ERC-4906 `BatchMetadataUpdate`. Recommended: owner behind a multisig | `test_setRenderer_*`, `test_revert_setRenderer_*` |

## Known limitations

- **Rebasing tokens are only rejected when the creating transfer is short.** A rebasing token whose transfer happens to
  be exact is accepted. A later positive rebase leaves surplus tokens in the contract that no stream can claim; a
  negative rebase makes the streams of that token insolvent (the last withdrawals revert). Other tokens are unaffected.
  Do not stream rebasing tokens; wrap them first (e.g. wstETH).
- **Tokens with blocklists or pausing** (USDC, USDT) can make a refund revert if the sender is blocklisted, which makes
  the stream uncancelable in practice. Withdrawals can always pick another `to` address.
- **Tokens that enable a transfer fee after creation** are not caught by the creation check. If the fee comes out of
  the transferred amount, recipients and refunds simply receive less. If the token charges the sender on top of the
  amount, the contract loses more than it records and the streams of that token become insolvent. Again, other tokens
  are unaffected.
- **Secondary-market races.** A seller can withdraw, and a sender can cancel a cancelable stream, in the same block as a
  sale of the NFT. Buyers must check `cancelable` and the withdrawable amount, and should use marketplaces that bind
  the sale to the state they saw. The art shows status and cancelability but cannot prevent the race.
- **The hook is best-effort.** It runs only on `cancel`, with 100,000 gas, and its failure is ignored by design.
  Contracts must treat the stream state, not the hook, as the source of truth.
- **The owner controls the art.** A malicious or careless renderer can show wrong amounts or revert in `tokenURI`. It
  cannot affect balances, withdrawals or cancellations. Ownership is two-step and can be renounced to freeze the renderer.
- **Bounds.** Amounts are `uint128` per stream and timestamps `uint40`; at most 32 tranches or 16 segments per stream.
- **No signatures.** There is no EIP-2612 `permit` flow or meta-transaction support; senders approve the contract first.
- **Not audited, not deployed.** This is portfolio code written to production standards, never used with real funds.
