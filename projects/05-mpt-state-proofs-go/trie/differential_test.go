// SPDX-License-Identifier: MIT

package trie

import (
	"bytes"
	"math/rand/v2"
	"sort"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/ethdb/memorydb"
	gethtrie "github.com/ethereum/go-ethereum/trie"
	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
)

// go-ethereum's trie is the differential oracle: it is used only by tests.

func newGethTrie() *gethtrie.Trie {
	// A nil database is fine: the trie starts empty and is never committed, so it never
	// reads a node back.
	return gethtrie.NewEmpty(nil)
}

// gethProof returns go-ethereum's proof for key, sorted (the oracle returns a set).
func gethProof(t testing.TB, g *gethtrie.Trie, key []byte) [][]byte {
	db := memorydb.New()
	require.NoError(t, g.Prove(key, db))
	it := db.NewIterator(nil, nil)
	defer it.Release()
	var out [][]byte
	for it.Next() {
		out = append(out, bytes.Clone(it.Value()))
	}
	return sortedProof(out)
}

func sortedProof(p [][]byte) [][]byte {
	out := cloneProof(p)
	sort.Slice(out, func(i, j int) bool { return bytes.Compare(out[i], out[j]) < 0 })
	return out
}

func gethVerify(root keccak.Hash, key []byte, proof [][]byte) ([]byte, error) {
	db := memorydb.New()
	for _, n := range proof {
		h := keccak.Sum256(n)
		_ = db.Put(h[:], n) // memorydb.Put never fails
	}
	return gethtrie.VerifyProof(common.Hash(root), key, db)
}

func TestDifferentialRandomOperations(t *testing.T) {
	rng := rand.New(rand.NewPCG(11, 2026))
	for round := range 200 {
		ours, theirs := New(), newGethTrie()
		touched := map[string]bool{}
		for op := range 1 + rng.IntN(150) {
			k := []byte(randomKey(rng))
			if rng.IntN(5) == 0 {
				ours.Delete(k)
				require.NoError(t, theirs.Delete(k))
			} else {
				v := randomValue(rng)
				ours.Put(k, v)
				require.NoError(t, theirs.Update(k, v))
			}
			touched[string(k)] = true
			if op%10 == 0 {
				require.Equal(t, common.Hash(ours.Hash()), theirs.Hash(), "round %d op %d", round, op)
			}
		}
		root := ours.Hash()
		require.Equal(t, common.Hash(root), theirs.Hash(), "round %d", round)

		for k := range touched {
			key := []byte(k)
			ourProof := ours.Prove(key)
			require.Equal(t, sortedProof(ourProof), gethProof(t, theirs, key), "round %d key %x: proof node sets differ", round, key)

			want, _ := ours.Get(key)
			got, err := gethVerify(root, key, ourProof)
			require.NoError(t, err, "go-ethereum rejects our proof")
			require.Equal(t, want, got)

			got, err = VerifyProof(root, key, gethProof(t, theirs, key))
			require.NoError(t, err, "we reject go-ethereum's proof")
			require.Equal(t, want, got)
		}
	}
}

func TestDifferentialSecureStorageShape(t *testing.T) {
	// Storage-trie shaped data: 32-byte hashed keys, RLP-encoded 1..32-byte values.
	rng := rand.New(rand.NewPCG(12, 2026))
	ours, theirs := NewSecure(), newGethTrie()
	for i := range 2000 {
		var slot [32]byte
		slot[31] = byte(i)
		slot[30] = byte(i >> 8)
		v := make([]byte, 1+rng.IntN(32))
		for j := range v {
			v[j] = byte(rng.Uint32())
		}
		ours.Put(slot[:], v)
		h := keccak.Sum256(slot[:])
		require.NoError(t, theirs.Update(h[:], v))
		if rng.IntN(7) == 0 {
			ours.Delete(slot[:])
			require.NoError(t, theirs.Delete(h[:]))
		}
	}
	require.Equal(t, common.Hash(ours.Hash()), theirs.Hash())
}
