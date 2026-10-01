// SPDX-License-Identifier: MIT

package trie

import "github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"

// SecureTrie is a Trie keyed by the Keccak-256 hash of each key, as Ethereum's state trie
// (keyed by keccak(address)) and storage tries (keyed by keccak(slot)) are. The zero value is
// an empty trie.
type SecureTrie struct {
	t Trie
}

// NewSecure returns an empty secure trie.
func NewSecure() *SecureTrie { return &SecureTrie{} }

func hashKey(key []byte) []byte {
	h := keccak.Sum256(key)
	return h[:]
}

// Len returns the number of keys in the trie.
func (s *SecureTrie) Len() int { return s.t.Len() }

// Hash returns the root hash.
func (s *SecureTrie) Hash() keccak.Hash { return s.t.Hash() }

// Get returns the value stored under key.
func (s *SecureTrie) Get(key []byte) ([]byte, bool) { return s.t.Get(hashKey(key)) }

// Put stores value under key; an empty value deletes the key.
func (s *SecureTrie) Put(key, value []byte) { s.t.Put(hashKey(key), value) }

// Delete removes key and reports whether it was present.
func (s *SecureTrie) Delete(key []byte) bool { return s.t.Delete(hashKey(key)) }

// Prove returns the proof for key (the nodes on the path of keccak(key)).
func (s *SecureTrie) Prove(key []byte) [][]byte { return s.t.Prove(hashKey(key)) }

// VerifySecureProof is VerifyProof for a secure trie: it looks up keccak(key).
func VerifySecureProof(root keccak.Hash, key []byte, proof [][]byte) ([]byte, error) {
	return VerifyProof(root, hashKey(key), proof)
}
