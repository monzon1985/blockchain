# Threat model

Scope: the six L1 contracts in `contracts/src`, the VM/STF specification (`docs/VM_SPEC.md`) and the Rust services in
`crates/node`. Nothing here has been audited; this is a technical demonstration written to production standards.

## Assets

| Asset | Where | At risk if… |
|---|---|---|
| Bridged ETH | `Bridge` balance | an invalid state root finalizes (withdrawals against fake balances), or a withdrawal is paid twice |
| Bonds and credits | `OutputOracle` balance | bond accounting is wrong, or payouts can be re-entered |
| L2 balances | L2 state (committed by output roots) | the STF can be forged (minting, stolen transfers, replays) |
| Liveness of L1→L2 messages | `ForcedInclusionQueue` | the sequencer can censor deposits and forced transactions indefinitely |
| Liveness of finalization | `OutputOracle` | an attacker can delay finalization cheaply and indefinitely |

## Actors and privileged roles

| Actor | Powers | If compromised or malicious |
|---|---|---|
| Inbox owner (`Ownable2Step`) | `setSequencer` | can install a censoring or absent sequencer. Cannot touch funds or outputs: forced inclusion and `forceBatch` keep L1→L2 messages flowing, and outputs are still checked by disputes. |
| Sequencer | orders transactions, posts batches | can censor L2 transactions and delay queue messages by at most `INCLUSION_WINDOW` blocks; can post garbage (skipped by the STF). Cannot forge signatures, mint (deposit records are only honoured from the queue section, whose length the inbox writes), or skip overdue messages. |
| Proposer (permissionless, bonded) | claims an output per epoch | can claim a wrong root; loses its bond to the first honest challenger. Can delay (see T7). |
| Challenger (permissionless, bonded) | disputes outputs | can dispute a correct output; loses 90% of its bond to the defender and 10% to the burn. Delay is bounded (T5). |
| Users | deposit, sign L2 transactions, force transactions through L1 | can spam the queue (T13). |

No contract is upgradeable and only `BatchInbox` has an owner. `OutputOracle`, `DisputeGame`, `Bridge`,
`ForcedInclusionQueue` and `OneStepVM` have no admin functions.

## Trust assumptions

1. **One honest, online challenger** (1-of-N): someone re-derives every epoch from L1 and disputes a wrong output
   within the challenge window, and then moves within its chess clock.
2. **L1 liveness and inclusion**: dispute moves land within their clocks; forced transactions and `forceBatch` land on L1.
3. **Data availability**: every tape is reconstructible from L1 logs (`MessageEnqueued`, `BatchAppended` mirrors the
   calldata), so anyone can build any one-step witness.
4. **Specification agreement**: the Rust VM and `OneStepVM.sol` implement the same transition function. This is not
   assumed blindly; it is differential-tested on random programs and on real traces (`crates/diff`).
5. Standard cryptography: keccak256 collision resistance and secp256k1 ECDSA.

## Threats and mitigations

| # | Threat | OWASP SC 2026 | Mitigation | Evidence |
|---|---|---|---|---|
| T1 | Proposer claims a wrong state root | SC02 Business logic | Bisection over per-step state hashes down to one instruction, executed by `OneStepVM`; step 0 is computed on L1 from the parent root, the inbox's tape hash and the code root | `testFuzz_honestChallengerAlwaysWins`, e2e `fraud_caught_and_dishonest_bond_slashed` |
| T2 | Sequencer censors L1→L2 messages | SC02 | Inbox rejects batches that leave out an overdue message (`ForcedInclusionViolated`); anyone may `forceBatch` | `test_forcedInclusion_sequencerCannotSkipOverdueMessages`, e2e `censorship_defeated_by_forced_inclusion` |
| T3 | Sequencer mints by posting deposit records | SC05 Input validation | Kinds 1-3 are honoured only inside the first `Q` records, and the inbox writes `Q` itself | `sequencer_cannot_inject_l1_kinds`, `queue_cannot_carry_signed_kinds` |
| T4 | Forged, replayed or cross-chain L2 transactions | SC05 | ECDSA with an L2-chain-specific domain, per-account nonces bumped even on failed transfers. The domain does not bind a contract address and there is no deadline (see known limitations) | `replayed_forged_and_misnonced_transactions_are_rejected`, API tests |
| T5 | Griefing challenges against correct outputs | SC02 | Challenger bond (90% to the defender, 10% burned); games are concurrent and each ends within `2T`, so finalization moves from `W` to at most `W + 2T` | invariant I5, `testFuzz_honestDefenderAlwaysWins`, e2e `griefing_challenger_loses_on_time` |
| T6 | Block-timestamp manipulation | - | Windows and clocks are minutes to days; producers shift time by seconds | Slither `timestamp` suppressed inline at each comparison, with this justification |
| T7 | Delay by squatting the head epoch with invalid outputs (incl. self-dealing proposer + challenger) | SC02 | The 10% burn makes each round cost `0.1 * B_p`, and an independent honest challenger caps a round at `T + L`; see `ECONOMICS.md` for sizing and the bounded-delay variant | `crates/economics` (`zero_burn_makes_self_dealing_free`, `an_independent_challenger_roughly_halves_the_squat`) |
| T8 | Double withdrawal | SC02 | `finalized[id]` set before payout; withdrawal ids are unique in L2 state | `test_finalizeWithdrawal_singleLeaf`, e2e `withdrawal_after_finalization` |
| T9 | Reentrancy on payouts | SC08 Reentrancy | Pull-based credits; `ReentrancyGuardTransient` on `claimCredit` and `finalizeWithdrawal`; effects before interactions | `test_claimCredit_isReentrancySafe`, `test_reentrantRecipientCannotDoubleWithdraw` (same id re-entered, paid once), `test_reentrantRecipientSameIdRevertUndoesThePayout`, `test_reentrancyGuardBlocksNestedWithdrawalOfAnotherId` |
| T10 | Forged one-step witness | SC05 | Code: OZ Merkle proof with double-hashed, pc-bound leaves. Stack: hash chain. State: SMT proof. Tape: keccak256 | revert tests in `OneStepVM.t.sol`; `tampered_witnesses_never_change_the_post_state` (proptest mutating each witness component: every scalar field, a random element of each array, a random bit of the sibling bitmap, truncated arrays, and a random or extra tape word) |
| T11 | Rust and Solidity VMs disagree (an honest party could lose) | SC02 | Differential fuzzing inside revm, full post-state equality, including the ecrecover edge cases | `random_programs_agree_step_by_step`, `stf_program_traces_agree_on_every_step` |
| T12 | A trace that never halts (no defensible output) | SC02 | Inbox bounds the tape (32 + 64 records); worst case 11,832 steps vs 65,536 padded; STF is total | `worst_case_batch_fits_the_trace`, `arbitrary_tapes_halt_and_agree` |
| T13 | Queue spam delays forced messages | SC02 | FIFO with 32 messages per batch; `forceBatch` can be called repeatedly. No enqueue fee (limitation) | `test_forcedInclusion_capAllowsBacklog` |
| T14 | Arithmetic overflow in bond accounting | SC09 Overflow | Solidity 0.8 checked arithmetic; `unchecked` only for VM wrap-around semantics (commented) | invariants I1-I3 |
| T15 | Unchecked ETH transfers | SC06 Unchecked calls | `Address.sendValue` (reverts on failure) | Bridge / oracle tests |
| T16 | Upgrade or admin takeover | SC01 Access control, SC10 Proxy | No proxies, immutable wiring checked at deployment, `Ownable2Step` on the only owned contract | `test_setSequencer_ownerOnly`, `test_ownershipIsTwoStep`, `test_deployWiresEverything` |
| T17 | An honest service stalls: a persistent error in one duty (e.g. no balance for a new bond while bonds are locked) stops the duties that would fix it | SC02 | Every service tick runs independent stages (derive, defend/play, finalize, recover bonds, claim, propose/challenge); a failure is logged and never skips the next stage; proposing and challenging check the balance first | e2e `underfunded_proposer_still_finalizes_and_recovers_its_bond` |
| T18 | Bonds stuck after a restart (orphaned proposals forgotten) | SC02 | The proposer rebuilds its proposal set from `OutputProposed` logs (proposer is an indexed topic); the challenger rebuilds the set of proposals it disputed from `GameCreated` logs | e2e `restarted_proposer_reclaims_orphaned_bonds` |
| T19 | Node memory exhaustion as the chain grows | - | Derivation keeps two full states (head, latest finalized) plus the tapes of unfinalized epochs; other states are rebuilt on demand; traces and resolved games are evicted | `keeps_two_states_and_prunes_what_finalization_settles` |
| T20 | Sequencer spam: resubmitting included transactions copied from L1 calldata, far-future nonces, unspendable recipients | SC05 | The API checks nonces against the derived state (stale and more than 64 ahead are refused), refuses non-address recipients, evicts stale entries, and batches each sender's transactions in nonce order | `submissions_are_checked_against_the_derived_state`, `batches_follow_nonce_order_and_stop_at_gaps`, e2e `honest_run` |
| T21 | A stale or edited deployment descriptor makes honest parties bisect the wrong program or depth | - | Services check `CODE_ROOT`, `CODE_SIZE`, `MAX_DEPTH` and `GENESIS_STATE_ROOT` on L1 at start-up and refuse to run on a mismatch; `Deploy.s.sol` refuses non-empty genesis and depths below 14 | e2e `descriptors_that_disagree_with_l1_are_refused`, `binaries_e2e`, `test_revert_depthOutOfRange`, `test_revert_nonEmptyGenesis` |

SC03 (oracle manipulation), SC04 (flash loans) and SC07 (rounding) do not apply: there is no price input, no
same-transaction liquidity dependency, and the only division is the 10% burn of fixed bond amounts.

## Known limitations

- **The defender is the proposer.** If an honest proposer goes offline during a dispute, a griefing challenger wins by
  timeout and a correct output is invalidated (it can be re-proposed; no funds are lost, but the chain is delayed).
  Production systems let anyone defend (OP's permissionless games, Arbitrum BoLD).
- **Descendant bonds are refunded.** When an output is invalidated, later proposals built on it are orphaned and their
  bonds refunded, so an attacker pays for the first invalid output only.
- **Delay attacks are linear in budget** in this 1-vs-1 design (T7). `ECONOMICS.md` quantifies it and describes the
  bounded-delay (BoLD-style) alternative, which this repository models but does not implement.
- **The challenger disputes a proposal once.** If its own game is lost on time (it went offline), it does not retry that
  proposal; another challenger must.
- **No enqueue fee** on forced messages; a spammer can grow the FIFO backlog (inclusion is then delayed by
  `backlog / 32` batches, each of which anyone can post).
- **Raw-digest signatures** (no EIP-191/712 prefix), because `HASH` takes exactly two words. Wallets that only sign
  prefixed messages cannot produce L2 transactions without an extra opcode.
- **The signing domain is `H("MiniRollup.L2Transaction.v1", l2ChainId)` only, and signed transactions carry no
  deadline** (a deviation from the repository standard of nonce + deadline + chain id + verifying contract). Two
  deployments with the same L2 chain id accept each other's signatures (every `rollup-cli deploy` defaults to 901), and
  a signed transaction stays valid until its nonce is used. Binding the inbox address would make the program's code
  root deployment-specific; a deadline needs a ninth record word and an L1 time source in the tape header. Both are
  format changes left for future work; use a distinct `--l2-chain-id` per deployment.
- **Raw hex keys from environment variables** are accepted for local devnets (anvil's well-known keys). Every binary
  also takes `--keystore <file>` with the password in an environment variable, which is the path for anything holding
  value.
- **Recipient words above 2^160** in a raw signed record are debited by the STF but can never be withdrawn or spent.
  Honest clients cannot produce them (they sign `address` values) and the sequencer refuses them; a user who signs
  such a record by hand burns their own funds. The STF itself does not skip them, to keep the proven program unchanged.
- **Calldata data availability, mirrored in an event** for simple log-only derivation; blobs are out of scope.
- **Single-threaded service loops** poll L1; a production node would subscribe to heads and pipeline derivation.
- **No L1 reorg handling in derivation.** Services derive from the latest L1 head, which is safe on anvil (no reorgs);
  a production node derives from safe/finalized L1 blocks and rewinds on reorgs.
- **Node memory grows with unfinalized epochs**, not with history: each unfinalized epoch keeps its tape (at most
  24.6 KB), and rebuilding a disputed pre-state re-applies those tapes natively from the finalized checkpoint. A
  production node would use a persistent (structurally shared) state tree to make those rebuilds free.

## Static analysis triage

`slither . --config-file slither.config.json` reports 0 findings. Two informational detector classes are excluded for
the whole project, because they concern style rather than behaviour:

- `naming-convention`: immutables and constants use SCREAMING_SNAKE_CASE, the convention `forge lint` enforces
  (`screaming-snake-case-immutable`); Slither expects mixedCase.
- `cyclomatic-complexity`: `OneStepVM._execute` is the VM's opcode dispatch table (24 opcodes); splitting it would
  obscure the one-to-one mapping with `crates/vm/src/interp.rs` that the differential suite checks.

Every security-relevant detector stays enabled, and each known site is suppressed inline with
`// slither-disable-next-line <detector>` (or a `disable-start`/`disable-end` pair where a `forge-lint` directive
already occupies the preceding line) next to a one-line justification, so a new occurrence anywhere else still fails
CI:

| Detector | Sites | Justification |
|---|---|---|
| `reentrancy-benign`, `reentrancy-events` | `DisputeGame.challenge` (call to `ORACLE.openChallenge`), `DisputeGame._resolve` (`ORACLE.settleChallenge`), `Bridge.deposit` (`QUEUE.enqueueDeposit`) | The callee is the protocol's own immutable contract, which never calls back; the state written and the event emitted afterwards need its result. Untrusted recipients are only paid through `Address.sendValue` at the end of `nonReentrant` functions. |
| `incorrect-equality` | `BatchInbox._checkQueueRange` (`acc == expected`), `ForcedInclusionQueue._enqueue` (`index == 0`) | Hash-chain accumulator equality and an array-length check, not balance comparisons. |
| `timestamp` | `DisputeGame.step`, `claimTimeout`, `_move`, `_load`; `OutputOracle.finalize`, `reclaimOrphanedBond`, `openChallenge` | T6: windows and clocks are minutes to days. Four of the sites compare phases or statuses that Slither's taint reaches through a struct's timestamp fields. |
| `assembly` | `BatchInbox._tapeHash` | One memory-safe block that copies the calldata records and `txData` into a fresh buffer and hashes it; covered by `testFuzz_tapeHashMatchesReference`. |
