// SPDX-License-Identifier: MIT

// Package trie implements Ethereum's Modified Merkle-Patricia Trie (Yellow Paper, Appendix D)
// in memory, with inclusion and exclusion proofs.
//
// A key is split into 4-bit nibbles, and the trie is a radix-16 tree over them built from
// three node kinds:
//
//   - a leaf holds the rest of a key's path and its value: RLP([HP(path, leaf), value]);
//   - an extension holds a shared path segment and one child, always a branch:
//     RLP([HP(path, ext), ref(child)]);
//   - a branch has sixteen child slots, one per nibble, and a value slot for a key that ends
//     at the branch: RLP([ref(c0), ..., ref(c15), value]).
//
// HP is the hex-prefix encoding of a nibble path (HexPrefixEncode). ref(n) embeds a child's
// encoding directly when it is shorter than 32 bytes (an inline node) and otherwise
// references it by its Keccak-256 hash. The root hash is always Keccak-256 of the root node's
// encoding, whatever its size; the empty trie's root is keccak.EmptyRoot.
//
// The structure is canonical: for a given set of key/value pairs there is exactly one trie,
// so the root does not depend on the order of insertions and deletions. Delete restores the
// canonical shape by collapsing a branch left with a single entry into a leaf or an extension
// and by merging an extension into its new child.
//
// SecureTrie hashes keys with Keccak-256 before using them, as Ethereum's account and storage
// tries do; this bounds paths at 64 nibbles and stops an attacker from building deep paths.
//
// VerifyProof checks a proof (the encoded nodes on a key's path, as returned by Prove or by
// eth_getProof) against a root and returns the value, or nil for a proof of absence. It is
// strict: it rejects malformed and non-canonical nodes, and proofs that carry nodes off the
// key's path.
//
// Tries are not safe for concurrent use: hashing memoizes node encodings in place.
package trie
