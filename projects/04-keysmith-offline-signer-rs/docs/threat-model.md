# Keysmith threat model

Keysmith splits signing across two machines. The **offline** machine runs `keysmith` (built on
`keysmith-core`) and holds key material. The **online** machine runs `keysmith-relay`, talks to an
Ethereum JSON-RPC node and never sees a key. Data crosses the gap as JSON files (USB stick, QR codes,
or anything else the operator trusts to carry bytes).

> Nothing in this repository has been professionally audited. Keysmith is a portfolio-grade
> implementation written to production standards, not a product holding real funds.

## Assets

| Asset | Where it lives | Impact if lost |
|---|---|---|
| BIP-39 mnemonic (+ optional passphrase) | file on the offline machine, `Zeroizing` buffers in RAM | every derived account |
| Raw private keys / keystore files and passwords | files on the offline machine | that account |
| Integrity of what gets signed | unsigned envelope or typed-data file, operator review and confirmation | arbitrary transfers, approvals, permits or delegations by a valid key |
| Availability of the signer | offline machine | operator cannot sign |

## Actors

| Actor | Capabilities | Trusted? |
|---|---|---|
| Operator | runs both halves, reads the review every signing command prints and confirms it before anything is signed | yes |
| Online machine | builds envelopes, carries signed envelopes back, broadcasts | **no**: assumed compromisable |
| RPC node | answers chain-state queries, receives raw transactions | **no** |
| Envelope or typed-data author (dApp, colleague, script) | proposes transactions, permits and other EIP-712 messages | **no** |
| Offline machine | holds keys, runs `keysmith` | yes, at signing time |
| Crate supply chain | code in `Cargo.lock` | partially: pinned, checked against the RustSec advisory database (`cargo deny`), and the signer's graph is checked for networking crates |

## Trust assumptions

1. The offline machine is not compromised while keys are in memory, and its OS RNG
   (`getrandom`) is sound (used only for mnemonic, keystore salt / IV / UUID generation; signing
   is RFC 6979 deterministic).
2. RustCrypto `k256`, `sha3`, `sha2`, `hmac`, `pbkdf2`, `scrypt`, `aes`, `ctr` implement their
   primitives correctly (they are tested here only through official vectors and differential
   tests, not re-verified).
3. The operator reads the review that every signing command (`sign`, `sign-auth`,
   `sign-message`, `sign-typed-data`, `permit`) prints to stderr **before** signing, and types
   `yes` only if it matches their intent. The review lists every signed field: for a transaction
   the full calldata (selector first, ERC-20 `transfer` / `approve` / `transferFrom` decoded), the
   access list and every authorization with its recovered authority; for typed data every hashed
   domain and message leaf and the digest. Keysmith refuses invalid or out-of-policy requests; it
   cannot judge intent. `--yes` skips the prompt (for scripts): whoever passes it accepts that no
   human confirms the review.

## Attack surface and mitigations

| # | Threat | Mitigation | Enforced by |
|---|---|---|---|
| T1 | Online machine rewrites `to`, `value`, `chainId` or fees in the unsigned envelope | The signer never signs a supplied hash or encoding: it rebuilds the transaction from typed fields, re-validates it and applies the local policy (`allowedRecipients`, `maxValueWei`, `allowedChainIds`, `maxFeePerGasWei`, `maxTotalCostWei`). The review prints the rebuilt transaction before the operator confirms. | `envelope::plan_envelope`, `policy.rs`; tests `refusals_exit_with_code_3_and_produce_nothing`, `refusals_never_reach_the_chain` |
| T2 | A dropped `to` field silently turns a payment into a contract deployment | `to` is mandatory; `null` must be written explicitly for a creation, and creations are denied by the default policy, which applies whenever no `--policy` file is given (`--no-policy` lifts it explicitly) | `EnvelopeError::MissingTo`, policy `allowContractCreation`; test `the_default_policy_applies_without_a_policy_file` |
| T3 | Envelope signed by the wrong key | `from` in the envelope must equal the key's address; `--expect-address` adds a second check | `EnvelopeError::FromMismatch`, `keysource.rs` |
| T4 | Malleable or non-canonical encodings (two byte strings, one transaction) | Strict RLP decoder (leading zeros, short-form, length-of-length, trailing bytes, depth); low-s signatures only; high-s twins are not recoverable | `rlp.rs`, `keys.rs`; property `corrupted_transactions_never_split_the_decoders` |
| T5 | Cross-chain replay | EIP-155 by default; pre-EIP-155 legacy needs `allowUnprotectedLegacy`; EIP-7702 `chainId = 0` is denied unless `allowAnyChainAuthorizations`. Both booleans default to deny, also without a policy file. A typed-data domain without `chainId` is flagged, and refused under `allowedChainIds` | `gas.rs` findings, `policy.rs`; tests `the_default_policy_applies_without_a_policy_file`, `typed_data_rules` |
| T6 | EIP-7702 tuples a node silently skips (the delegation never happens, the 25,000 gas is still charged) | Self-authorizations get consecutive nonces `tx.nonce + 1, + 2, ...` (EIP-7702 bumps the authority's nonce after every applied tuple), never a caller-supplied one. Every tuple of a type-4 transaction is checked before signing and the request is refused when a tuple would be skipped: a chain id that is neither 0 nor the transaction's, nonce `2^64 - 1`, an unrecoverable signature, a tuple of the sender that misses the sender's nonce at that point, or an authority repeated without the next nonce | `envelope::plan_envelope`, `gas::check_authorizations`; tests `several_self_authorizations_get_consecutive_nonces`, `sender_authorizations_must_follow_the_bumped_nonce`, e2e `several_self_authorizations_all_apply_and_skippable_tuples_are_refused` |
| T7 | Delegation to an attacker contract | `allowedDelegates` allow-list; every authorization in a type-4 transaction is policy-checked, not only the ones Keysmith signs. The review shows each tuple's recovered authority | `Policy::check_transaction` |
| T8 | EIP-712 "blind" fields: data shown to the operator but not hashed | Undeclared message members, missing values, wrong `bytesN` widths, out-of-range integers, lossy JSON floats, malformed type names (`uint+8`, `bytes01`) and non-identifier member names are errors | `eip712.rs`; tests `typed_data_and_permit_match_cast`, `type_names_follow_the_solidity_grammar_exactly` |
| T9 | A typo in the policy file disables a limit (`"maxValeuWei"`) | Unknown policy keys are rejected; booleans default to deny | `#[serde(deny_unknown_fields)]` on `Policy` |
| T10 | Hostile keystore exhausts the offline machine (`n = 2^30`, or a tiny `n` with a huge `r` and `p`) | KDF parameters are bounded by arithmetic **before** any allocation: scrypt's true footprint `128·r·(N + p + 2)` (the ROMix table plus the `B` and `T` buffers) <= 1 GiB + 1 MiB, `r <= 32`, `p <= 16`, work `N·r·p <= 2^24`, PBKDF2 `c <= 10^7` | `KdfLimits::check_scrypt`; tests `hostile_parameters_are_rejected_before_work`, `small_n_large_r_and_p_cannot_bypass_the_memory_bound` |
| T11 | Wrong keystore password accepted or timing oracle on the MAC | MAC compared in constant time (`subtle`); address field cross-checked after decryption | `keystore::decrypt` |
| T12 | Secrets leak through argv, shell history, logs or error messages | No flag takes a secret inline (key, mnemonic, passphrase and passwords come from files or a TTY prompt); errors name positions and lengths, never content; `Debug` of every secret type is redacted | `keysource.rs`, `hex.rs`, `bip39.rs`; test `secrets_cannot_be_passed_on_the_command_line_and_are_never_echoed` |
| T13 | A dependency update or code change quietly adds networking to the signer | `cargo xtask check-airgap` walks the normal + build dependency graph (all targets, all features) of `keysmith-core` and `keysmith-cli`, and scans their sources for socket APIs, process spawning (any `std::process` item but `ExitCode` / `exit`) and FFI declarations. `keysmith-relay` is a positive control that must be flagged through a transitive networking crate (ureq, rustls), not just its own name | `xtask/src/airgap.rs`, CI |
| T14 | Online machine broadcasts something other than what was signed, or to another chain | The relay decodes the raw bytes, recomputes `type`, `hash` and `from`, checks `eth_chainId`, and requires the node to echo the same hash | `keysmith_relay::broadcast`; tests `broadcast_refusals_send_nothing` |
| T15 | Malicious node returns a gas estimate below the intrinsic cost | The signer recomputes intrinsic gas and the EIP-7623 floor and refuses | `gas::check_transaction` |
| T16 | Online machine swaps the calldata of an allowed call (`transfer(alice, 1)` becomes `approve(attacker, MAX)` on the same token) or describes it misleadingly in the envelope `note` | The review prints the selector, the full calldata one ABI word per line and the decoded ERC-20 call (`APPROVE ... UNLIMITED`). The note is printed escaped and labelled as untrusted text, so it cannot add or fake review lines | `render::sign_review`, `render::quote_untrusted`, `calldata.rs`; tests `the_review_shows_calldata_authorities_and_the_untrusted_note`, `untrusted_text_cannot_forge_review_lines` |
| T17 | A dApp-supplied EIP-712 permit or order (unlimited allowance to an attacker, another chain, a lookalike token) is signed blind | `sign-typed-data` and `permit` print every hashed domain and message leaf and the digest before confirmation, and warn on a missing `chainId`, a `uint` at its maximum and a deadline more than a year away. `--policy` applies `allowedChainIds`, `allowedVerifyingContracts`, `allowedSpenders` and `maxPermitValue` | `render::typed_data_review`, `TypedData::review_findings`, `Policy::check_typed_data`; tests `typed_data_is_reviewed_and_policy_checked_before_signing`, `typed_data_rules` |
| T18 | Signing happens before the operator has decided (review printed after the fact) | The review is printed first; the transaction, message or typed data is signed and output only after the operator types `yes` (EIP-7702 self-authorizations are signed in memory beforehand, because the review shows them, and are discarded unless confirmed). Without a terminal, keysmith refuses unless `--yes` was passed, so a script cannot sign unattended by accident | `confirm.rs`, `envelope::SigningPlan`; tests `signing_waits_for_confirmation_and_never_signs_unattended`, `only_an_explicit_yes_confirms` |
| T19 | Hostile typed-data shapes crash the signer (20,000 `[]` suffixes, a chain of thousands of struct types) | At most 64 array dimensions per type, 256 declared types and 64 levels of value nesting; type validation and dependency collection are iterative, so the stack depth does not grow with the input | `eip712.rs`; test `hostile_type_shapes_are_errors_not_stack_overflows` |
| T20 | A plaintext mnemonic or keystore written by keysmith is readable by other local users | `mnemonic new --out` and `keystore export` create the file with mode `0600` on Unix at creation time (no `chmod` window), as `cast` and geth do for keystores | `commands::write_new_file`; test `secret_files_are_created_owner_only` (Unix) |

## Known limitations

- **Zeroisation is best-effort.** Keysmith zeroises its own buffers (`Zeroizing`), but `k256`
  may hold internal copies, allocator reallocation can leave residues, memory is not locked
  (`mlock`), and the OS may page secrets to swap or a hibernation file. Use full-disk
  encryption on the offline machine.
- **Not constant-time end to end.** Signing uses `k256`'s constant-time scalar arithmetic, but
  parsing (hex, Base58 for `xprv`, BIP-39 word lookup) branches on secret data. On a
  single-user, air-gapped machine this timing channel is not remotely observable; it is
  documented rather than engineered away.
- **The policy does not look inside calldata.** `allowedRecipients` constrains `to`; an ERC-20
  `transfer` or `approve` to an arbitrary address inside the calldata of an allowed token
  contract is not refused. The review prints the full calldata and decodes the three ERC-20
  calls, but any other call appears as raw ABI words, not decoded against an ABI. The operator's
  reading is the control.
- **Typed-data rules are schema conventions.** `allowedSpenders` looks at a top-level `spender`
  member and `maxPermitValue` at `value` of a `Permit`; other schemas (Seaport orders, Permit2
  batch details nested deeper) are reviewed leaf by leaf, but only `allowedChainIds` and
  `allowedVerifyingContracts` constrain them. `personal_sign` messages have no policy.
- **`--yes` removes the human from the loop.** It exists for scripts and tests; the review is
  still printed, but nobody confirms it.
- **The air-gap check is a static check, not a sandbox.** It proves that no known networking
  crate is in the signer's graph (all targets, all features) and that the signer's own sources
  name no socket API, no `std::process` item other than `ExitCode` / `exit`, and no FFI
  declaration. It is a substring scan: code that builds such a path through a macro would evade
  it, and a dependency could open a socket through FFI or raw syscalls without being on the
  list. FFI calls in the signer's own crates would additionally need `unsafe`, which the
  workspace lints forbid. The physical gap is the real control.
- **File permissions are enforced on Unix only.** On Windows a secret file inherits the ACL of
  its directory; keep it in a directory only the operator can read.
- **No hardware isolation.** Keys exist in process memory; there is no secure element, HSM or
  hardware-wallet integration.
- **Out of scope:** EIP-4844 blob transactions (type `0x03` is rejected), contract-wallet
  signatures (ERC-1271 / ERC-6492), multisig coordination, QR transport encoding.
