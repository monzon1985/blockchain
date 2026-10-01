# Threat model

The Trie Inspector checks data an Ethereum JSON-RPC node returns. Its job is to turn "the
node said so" into "the data is consistent with a block hash". This document states what that
guarantee covers, what it assumes, and where it stops.

Nothing in this repository has been professionally audited.

## Assets

| Asset | Why it matters |
|---|---|
| The verdict of `verify-block`, `verify-proof`, `storage-root` | A light client, bridge relayer or indexer acts on it. A false `VERIFIED` is the worst outcome. |
| The block hash the user trusts | Everything is verified *relative* to it. |
| The verifier's availability | Malformed input must produce an error, never a crash or a hang. |

## Actors

| Actor | Capabilities |
|---|---|
| Honest node | Answers correctly. |
| Lying or compromised node (or a man in the middle on the RPC connection) | Returns any bytes for any call: altered headers, raw transactions, receipts, proofs, claims; inconsistent answers across calls; malformed JSON; deeply nested RLP. |
| User | Chooses the RPC endpoint and the block, address and slots to check. |

## Trust assumptions

1. **Keccak-256 is collision resistant.** All commitments reduce to hashes. A proof node is
   identified by its hash, so altering it changes the hash it must match.
2. **The block hash is the trust anchor.** The tool proves that the data is consistent with
   the block hash it verified. It does **not** prove that this block is canonical, finalized,
   or on the chain you think it is. Finality requires a consensus-layer light client or a
   trusted checkpoint, which are out of scope. The CLI prints the block hash so you can compare
   it with a source you trust.
3. **The tool's own code.** The verification core (`keccak`, `rlp`, `trie`, `block`,
   `stateproof`) depends only on the Go standard library and `golang.org/x/crypto/sha3` (with its
   `golang.org/x/sys/cpu` dependency), which
   `internal/archtest` enforces. go-ethereum is a test-only oracle and the RPC transport.

## Attack surface and mitigations

| Threat | Mitigation | Test |
|---|---|---|
| Altered header field (e.g. `stateRoot`) | The block hash is recomputed from the header fields | `TestLyingNodeIsCaught/state_root_altered_in_the_header` |
| Altered block hash | Same recomputation | `.../block_hash_altered` |
| Altered or substituted raw transaction | `keccak(raw)` must equal the listed hash, and `transactionsRoot` is rebuilt | `.../raw_transaction_altered` |
| Altered receipt (status, gas, logs) | `receiptsRoot` rebuilt from consensus fields; per-receipt bloom rebuilt from its logs; header bloom = OR of receipt blooms; last cumulative gas = `gasUsed` | `.../cumulative_gas_inflated`, `.../a_log_dropped`, `.../a_reverted_transaction_reported_as_successful` |
| Receipts of another block or transaction | Each receipt's block hash, index, transaction hash and type are matched | `.../receipts_of_another_block` |
| Lying `eth_getProof` claims (balance, nonce, code hash, storage hash, slot values) | Claims are compared with the values the proofs establish | `.../balance_claimed_wrong`, `.../slot_value_claimed_wrong` |
| Forged or truncated proof | Strict verification: every node on the path must be present, hash-linked and canonical | `.../storage_proof_node_corrupted`, `.../account_proof_truncated`, `FuzzVerifyProof` |
| **Forged storage trie with a matching forged `storageHash`** | Storage proofs are verified against the storage root **inside the proven account leaf**, never against the claimed `storageHash` | `.../storage_hash_and_proof_forged_together`, `TestCheckGetProofInvalidProofs` |
| Proof padded with extra nodes | Rejected: every proof node must lie on the key's path (`ErrUnusedProofNode`) and appear once | `TestProofTamperingIsDetected` |
| Non-canonical encodings (hash and data malleability) | RLP decoding rejects non-minimal lengths, wrapped single bytes, leading zeros; node decoding rejects inlined nodes of 32+ bytes, hashed nodes under 32 bytes, extensions without a branch child, branches with fewer than 2 entries, empty leaf values; each node must re-encode to its input | `TestSplitRejectsNonCanonical`, `TestNonCanonicalProofsAreRejected`, `FuzzRLPRoundTrip` |
| Resource exhaustion through nesting | RLP nesting capped at 1024 levels (`MaxDepth`), inline trie nodes at 16 | `TestDecodeErrors` |
| Malformed JSON-RPC responses | Strict hex decoding (prefix, length, no leading zeros in quantities); a fuzz target feeds arbitrary bytes to every decoder | `TestDecodeBlockRejects`, `FuzzDecodeRPC` |
| A node answering for a different block between calls | Later calls target the block **number** of the first answer, and receipts must carry the verified block hash | `TestVerifyBlockDetectsInconsistencies` |
| Incomplete slot list for a storage rebuild | A missing non-zero slot or a wrong value changes the rebuilt root, which must equal the proven `storageRoot` | `TestStorageRootReconstruction`, `TestGoldenTamperedStorageValue` |

## Known limitations

- **No finality or chain-membership proof.** See assumption 2.
- **Requests (EIP-7685) and ommers are not fetched.** `requestsHash` is checked only in its
  empty form (`sha256("")`); a block with requests gets a warning. A block with ommers (only
  possible before the Merge) gets a warning instead of a recomputed `ommersHash`.
- **Blob contents are not verified.** The tool checks `blobGasUsed` against the number of
  versioned hashes in the block's blob transactions; it does not fetch blobs or KZG proofs
  (they live on the consensus layer).
- **`eth_getStorageAt` values are verified collectively, not individually**, by `storage-root`:
  the rebuilt root is the proof. Use `verify-proof` for per-slot proofs.
- **Amsterdam fields** (`blockAccessListHash`, `slotNumber`) follow go-ethereum 1.17.6's layout
  and are covered by differential tests only; no node in the test matrix produces them.
- **Pre-Byzantium receipts** (`root` instead of `status`) are encoded and differentially tested,
  but no anvil hardfork in the matrix produces them.
- **Warnings are not failures by default.** Header layout anomalies (see the README's anvil
  findings) and unknown header fields are warnings; `--strict` turns them into failures.
