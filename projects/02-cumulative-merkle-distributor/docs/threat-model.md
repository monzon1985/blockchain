# Threat model: Cumulative Merkle Distributor

Scope: [`src/CumulativeMerkleDistributor.sol`](../src/CumulativeMerkleDistributor.sol), its interface, the deployment
script [`script/Deploy.s.sol`](../script/Deploy.s.sol) and the off-chain builder in [`tree-builder/`](../tree-builder)
insofar as it decides what the contract will pay. Test mocks and the benchmark-only baselines under `test/gas/` are out
of scope. Vulnerability classes follow the [OWASP Smart Contract Top 10 (2026)](https://scs.owasp.org/sctop10/).
Nothing here has been professionally audited.

## Assets

| Asset | Why it matters |
|---|---|
| ERC-20 balances held by the distributor | Everything funded and not yet claimed. A wrong payout is a direct loss to an eligible account or to the funder. |
| The active root (and the allocation it commits) | Decides who can withdraw what. Replacing it is equivalent to rewriting every balance. |
| `claimed[account][token]` | The only per-user state. Lowering it would re-open paid allocations; raising it without a transfer would burn them. |
| Claim authorizations (EIP-712 signatures) | A valid authorization moves an account's rewards to a third-party recipient. |
| Liveness of claims | Users must be able to withdraw what the active root allocates, whatever happens to the operators. |

## Actors

| Actor | Capabilities | Trust |
|---|---|---|
| Owner (`Ownable2Step`) | `setUpdater`, `setGuardian`, two-step ownership transfer, `renounceOwnership` | Root of trust. Expected to be a multisig behind a timelock (see limitations). |
| Updater | `proposeRoot(root, metadataHash)`; a new proposal displaces the pending one and restarts the 24 h timer | Trusted to publish correct roots, but every root is public for 24 h before it can be used. |
| Guardian | `revokePendingRoot` at any time before acceptance | Trusted for liveness only: it can stop a root, never create or speed one up. |
| Anyone (keeper) | `acceptRoot` after the timelock, `claim` for any account, `claimMany` for any batch | Untrusted. Can only trigger payouts to the leaf's own account. |
| Relayer | Submits `claimFor` with an account's signature | Untrusted. Amount, token, recipient, nonce and deadline are all signed. |
| Account (EOA, ERC-1271 wallet, EIP-7702 account) | Claims, signs authorizations, `invalidateNonce` | Owns its allocation; nothing else. |
| Reward token | Called with `safeTransfer` during every payout | Assumed to be a standard ERC-20 (see limitations). Hostile callbacks are contained by the reentrancy guard. |
| Off-chain builder (tree-builder) | Turns epoch CSVs into the root and proofs | Its output is reproducible from public inputs; the manifest hash is committed on-chain with every root. |

## Attack surface and mitigations

| # | Vector (OWASP class) | Mitigation | Evidence |
|---|---|---|---|
| T1 | Malicious or mistaken root from a compromised updater (SC01 Access Control) | Every root waits 24 h in `pendingRoot` (public `RootProposed` event); the guardian vetoes it. No bypass exists: the owner cannot set a root directly. A correction restarts the timer, so it never shortens the veto window. | `RootLifecycleTest`, invariants I-6/I-7 (the handler tries `acceptRoot` at arbitrary times, including one second before and exactly at the deadline, and requires success exactly when the model says 24 h have passed), mutants M02-M09 |
| T2 | Second-preimage forgery: an inner node presented as a leaf | Leaves are `keccak256(keccak256(abi.encode(account, token, amount)))` over 96 bytes; inner nodes hash exactly 64 bytes, so no leaf preimage is an inner node's. The 96-byte preimage is what rules the forgery out; the double hash keeps the `StandardMerkleTree` format. | `testFuzz_leafHash_isDoubleHashOf96ByteEncoding` (the encoding, for any input), `test_claim_leafHashMatchesStandardMerkleTreeEncoding`, mutant M01; `test_secondPreimage_innerNodeCannotBeClaimedAsLeaf` illustrates the attack on a naive 64-byte leaf (it is not evidence for the encoding: it also passes under M01) |
| T3 | Double claim / replay of an old proof (SC02 Business Logic) | A claim pays `cumulative - claimed` and stores the new total before transferring; a stale leaf no longer belongs to the new root; an equal or lower leaf reverts with `NothingToClaim` | `test_claim_revertsWhenNothingLeft`, `test_claim_oldRootProofsDieOnRotation`, invariants I-3/I-4/I-5, mutants M10/M11 |
| T4 | A root that lowers an allocation (bug or attempted claw-back) | `claimed` never decreases; a lower leaf pays nothing (`claim` reverts, `claimMany` skips it). Paid tokens cannot be clawed back. | `test_claim_clawbackRootCannotReduceClaimed`, `test_claimMany_skipsClaimedAndLoweredLeavesWithoutSideEffects`, invariants I-3 (stated for lowering roots: `claimed <= max(leaf, claimed at acceptance)`) and I-4, under a handler whose corrective roots lower pairs below what they claimed |
| T5 | Payout redirected by a third party | `claim` and `claimMany` always pay the leaf's account; `claimFor` pays only the signed recipient, and the recipient cannot be zero or the distributor | `test_claim_isPermissionlessButAlwaysPaysAccount`, `test_claimFor_signatureCannotBeRedirected`, `test_claimFor_revertsOnInvalidRecipient`, mutants M12/M18/M21/M22 |
| T6 | Signature replay across claims, roots, chains or contracts | EIP-712 domain (name, version, chain id, contract) with the domain separator rebuilt when `block.chainid` changes; sequential per-account nonce consumed by every successful `claimFor`; deadline inclusive; `invalidateNonce` cancels an outstanding authorization | `test_claimFor_replayIsRejectedByNonce`, `test_claimFor_signatureDoesNotReplayAcrossChains`, `test_domainSeparator_rebuiltWhenChainIdChanges`, invariant I-8, mutants M14/M15 |
| T7 | Malleable or malformed ECDSA signatures (SC05 Input Validation) | OpenZeppelin `ECDSA.tryRecoverCalldata` rejects high-s values, bad lengths and `v` values; a recovery error is rejected before addresses are compared, so the `address(0)` a failed recovery returns never matches an account, not even an `address(0)` leaf | `test_claimFor_rejectsHighSMalleableSignature`, `test_claimFor_rejectsGarbageSignatures`, `test_claimFor_zeroAddressAccountRejectsRecoveryFailures`, mutants M16/M25 |
| T8 | Smart-account signatures: ERC-1271 wallets and EIP-7702 accounts | ECDSA first (EOAs and 7702 accounts, whatever their delegate), then ERC-1271 through `SignatureChecker` for accounts with code. The ERC-1271 call is a `STATICCALL`: it cannot write state or re-enter. Reverting hooks, wrong magic values and contracts without the hook are rejected. | `ClaimForTest` ERC-1271 and EIP-7702 sections, mutant M17 |
| T9 | Reentrancy through a hostile token (SC08) | `ReentrancyGuardTransient` on all three claim entry points (`claim`, `claimFor`, `claimMany`); state written before the transfer | `ReentrancyTest` (a hostile token re-enters each entry point from inside the payout of each, nine cases, each also replayed from outside to show the call is otherwise valid), `test_claim_reentrantTokenIsBlocked`, mutants M13/M23/M24 |
| T10 | Front-running a `claimMany` batch to make it revert (denial of service through SC02 business logic) | Leaves already claimed are skipped (amount 0) instead of reverting; malformed multiproofs and empty batches revert before any payout | `test_claimMany_skipsAlreadyClaimedLeaves`, `test_claimMany_skipsClaimedAndLoweredLeavesWithoutSideEffects`, `test_claimMany_revertsOnEmptyBatch`, mutants M19/M20 |
| T11 | Multiproof abuse (forged or reordered leaves, empty set) | OpenZeppelin `multiProofVerifyCalldata` with every leaf consumed; empty batches refused, which rules out the "empty set proves `proof[0]`" edge case | `ClaimManyTest` revert paths, `testFuzz_claimMany_anySubset` |
| T12 | Overflow / underflow in accounting (SC09) | Solidity 0.8 checked arithmetic everywhere except one `unchecked` subtraction that both callers guard with `cumulative > claimed`; the builder refuses cumulative totals above `2^256 - 1` | `testFuzz_claim_cumulativeTopUps`, `cumulative.test.ts` overflow case |
| T13 | Wrong allocation computed off-chain (SC02) | Deterministic builder: `tree.json` and `proofs.json` are independent of row order and byte-identical to `StandardMerkleTree`; `manifest.json` (per-token totals, and `inputHash`, the keccak256 of the exact input bytes) is order-independent except for `inputHash`, and its keccak256 is the on-chain `metadataHash`, so a root commits to the CSV as written. `verify` requires exactly one proofs entry per leaf (normalized keys, recomputed leaf hashes, canonical amounts). Differential fixtures replayed on-chain; strict CSV parsing (checksums, no decimals, no exponents, line numbers in errors) | fast-check properties (`cumulative.test.ts`, `tree.test.ts`), `cli.test.ts`, `FixturesTest`, `npm run fixtures -- --check` |
| T14 | Under-funded vault | Claims revert atomically (no state change) when the vault cannot pay; other accounts and tokens are unaffected | `test_claim_revertsWhenUnderfunded`, invariants I-1/I-2 |

Classes with no attack surface here: SC03 (price oracles) and SC04 (flash loans), since no price or balance is read to
decide a payout; SC06 (unchecked external calls), since every token call goes through `SafeERC20` and the only other
call is the ERC-1271 static call whose result is checked; SC07 (rounding), since amounts are exact integers; SC10
(proxies and upgradeability), since the contract is deployed immutable.

## Role compromise: what each role can do

| Compromised role | Worst case | Bound |
|---|---|---|
| Updater | Proposes a root that pays everything to itself | Public for 24 h; the guardian vetoes it. Can keep re-proposing (griefing new epochs), never shorten the window. |
| Guardian | Vetoes every new root, freezing rewards at the current epoch | Already-accepted allocations stay claimable; the owner replaces the guardian. |
| Updater and guardian together | A malicious root goes live after 24 h | Monitoring of `RootProposed` gives users and the owner 24 h to react (replace both roles). Funds already claimed are safe. |
| Owner | Installs its own updater and a zero guardian (both instant), then any root after 24 h | The 24 h root delay still applies and is public. Mitigation: put the owner behind a timelock whose delay exceeds 24 h, so role changes are visible before they can matter. |
| Relayer | Nothing beyond what was signed | It can choose when to submit (before the deadline) or not submit at all. |

## Known limitations

- **No sweep.** Unallocated or unclaimed tokens can only leave through a claim. Recovering them means allocating them to a
  treasury leaf in a future root. This removes the classic "owner drains the vault" path at the cost of a slower
  recovery.
- **Instant role changes.** `setUpdater` and `setGuardian` are not delayed by the contract; the owner is expected to be
  a multisig behind its own timelock (see the role table).
- **Token assumptions.** Fee-on-transfer tokens pay less than `claimed` records; rebasing tokens break the
  `balance = funded - claimed` relation; tokens with blocklists can block one account's claims (and only that account's).
  Such tokens are out of scope.
- **A third party can front-run `claimFor` with `claim`.** The rewards then go to the account itself rather than to the
  signed recipient, and the pending `claimFor` reverts with `NothingToClaim` (its nonce is not consumed). The account
  loses nothing, but a relayer flow can be disrupted. Morpho's URD has the same permissionless-claim property.
- **Sequential nonces.** An account has one usable authorization at a time; authorizing two claims at once requires
  submitting them in nonce order. Unordered (bitmap) nonces would lift this at the cost of more storage per signature.
- **Signatures bind the cumulative amount, not the root.** An authorization stays valid across a root rotation only if
  the account's leaf for that token is unchanged; otherwise it simply fails the proof. This is deliberate: the signer
  approves an amount, not a tree.
- **ERC-1271 hooks run with all remaining gas.** A wallet whose hook burns gas only hurts its own claims.
- **The guardian is the only line of defence during the 24 h window.** Off-chain monitoring that recomputes every
  proposed root from the published inputs (the manifest carries the input hash) is what makes the veto meaningful.
