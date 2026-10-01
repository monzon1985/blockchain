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
| Integrity of what gets signed | unsigned envelope, operator review | arbitrary transfers or delegations by a valid key |
| Availability of the signer | offline machine | operator cannot sign |

## Actors

| Actor | Capabilities | Trusted? |
|---|---|---|
| Operator | runs both halves, reads the review printed by `keysmith sign` | yes |
| Online machine | builds envelopes, carries signed envelopes back, broadcasts | **no**: assumed compromisable |
| RPC node | answers chain-state queries, receives raw transactions | **no** |
| Envelope author (dApp, colleague, script) | proposes transactions | **no** |
| Offline machine | holds keys, runs `keysmith` | yes, at signing time |
| Crate supply chain | code in `Cargo.lock` | partially: pinned, and the signer's graph is checked for networking crates |

## Trust assumptions

1. The offline machine is not compromised while keys are in memory, and its OS RNG
   (`getrandom`) is sound (used only for mnemonic, keystore salt / IV / UUID generation; signing
   is RFC 6979 deterministic).
2. RustCrypto `k256`, `sha3`, `sha2`, `hmac`, `pbkdf2`, `scrypt`, `aes`, `ctr` implement their
   primitives correctly (they are tested here only through official vectors and differential
   tests, not re-verified).
3. The operator reads the review that `keysmith sign` prints to stderr before carrying the
   signed envelope back. Keysmith refuses invalid or out-of-policy requests; it cannot judge
   intent.

## Attack surface and mitigations

| # | Threat | Mitigation | Enforced by |
|---|---|---|---|
| T1 | Online machine rewrites `to`, `value`, `chainId` or fees in the unsigned envelope | The signer never signs a supplied hash or encoding: it rebuilds the transaction from typed fields, re-validates it and applies the local policy (`allowedRecipients`, `maxValueWei`, `allowedChainIds`, `maxFeePerGasWei`, `maxTotalCostWei`). The review prints the decoded transaction. | `envelope::sign_envelope`, `policy.rs`; tests `refusals_exit_with_code_3_and_produce_nothing`, `refusals_never_reach_the_chain` |
| T2 | A dropped `to` field silently turns a payment into a contract deployment | `to` is mandatory; `null` must be written explicitly for a creation, and creations are denied by an empty policy | `EnvelopeError::MissingTo`, policy `allowContractCreation` |
| T3 | Envelope signed by the wrong key | `from` in the envelope must equal the key's address; `--expect-address` adds a second check | `EnvelopeError::FromMismatch`, `keysource.rs` |
| T4 | Malleable or non-canonical encodings (two byte strings, one transaction) | Strict RLP decoder (leading zeros, short-form, length-of-length, trailing bytes, depth); low-s signatures only; high-s twins are not recoverable | `rlp.rs`, `keys.rs`; property `corrupted_transactions_never_split_the_decoders` |
| T5 | Cross-chain replay | EIP-155 by default; pre-EIP-155 legacy needs `allowUnprotectedLegacy`; EIP-7702 `chainId = 0` is warned about and denied unless `allowAnyChainAuthorizations` | `gas.rs` findings, `policy.rs` |
| T6 | EIP-7702 nonce confusion (self-executed delegation silently invalid) | `Executor::SelfExecuting` signs `nonce + 1`; `selfAuthorizations` in the envelope never take a caller-supplied nonce | `authorization.rs`, `envelope.rs`; e2e test asserts the delegation is live |
| T7 | Delegation to an attacker contract | `allowedDelegates` allow-list; every authorization in a type-4 transaction is policy-checked, not only the ones Keysmith signs | `Policy::check_transaction` |
| T8 | EIP-712 "blind" fields: data shown to the operator but not hashed | Undeclared message members, missing values, wrong `bytesN` widths, out-of-range integers and lossy JSON floats are errors | `eip712.rs`; CLI test `typed_data_and_permit_match_cast` |
| T9 | A typo in the policy file disables a limit (`"maxValeuWei"`) | Unknown policy keys are rejected; booleans default to deny | `#[serde(deny_unknown_fields)]` on `Policy` |
| T10 | Hostile keystore (`n = 2^30`) exhausts the offline machine | KDF parameters are bounded **before** any allocation (1 GiB scrypt memory, `p <= 16`, PBKDF2 `c <= 10^7`) | `KdfLimits`; test `hostile_parameters_are_rejected_before_work` |
| T11 | Wrong keystore password accepted or timing oracle on the MAC | MAC compared in constant time (`subtle`); address field cross-checked after decryption | `keystore::decrypt` |
| T12 | Secrets leak through argv, shell history, logs or error messages | No flag takes a secret inline (key, mnemonic, passphrase and passwords come from files or a TTY prompt); errors name positions and lengths, never content; `Debug` of every secret type is redacted | `keysource.rs`, `hex.rs`, `bip39.rs`; test `secrets_cannot_be_passed_on_the_command_line_and_are_never_echoed` |
| T13 | A dependency update quietly adds networking to the signer | `cargo xtask check-airgap` walks the normal + build dependency graph (all targets) of `keysmith-core` and `keysmith-cli` and scans their sources for socket APIs; `keysmith-relay` is a positive control that must be flagged | `xtask/src/airgap.rs`, CI |
| T14 | Online machine broadcasts something other than what was signed, or to another chain | The relay decodes the raw bytes, recomputes `type`, `hash` and `from`, checks `eth_chainId`, and requires the node to echo the same hash | `keysmith_relay::broadcast`; tests `broadcast_refusals_send_nothing` |
| T15 | Malicious node returns a gas estimate below the intrinsic cost | The signer recomputes intrinsic gas and the EIP-7623 floor and refuses | `gas::check_transaction` |

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
  `transfer` to an arbitrary address inside the calldata of an allowed token contract is not
  caught. The review shows only the 4-byte selector, not an ABI-decoded call.
- **The air-gap check is a static check, not a sandbox.** It proves that no known networking
  crate and no `std::net` usage is compiled into the signer; code using raw syscalls or FFI to
  open sockets would not be detected. The physical gap is the real control.
- **No hardware isolation.** Keys exist in process memory; there is no secure element, HSM or
  hardware-wallet integration.
- **Out of scope:** EIP-4844 blob transactions (type `0x03` is rejected), contract-wallet
  signatures (ERC-1271 / ERC-6492), multisig coordination, QR transport encoding.
