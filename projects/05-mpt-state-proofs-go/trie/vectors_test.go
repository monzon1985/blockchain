// SPDX-License-Identifier: MIT

package trie

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"sort"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
)

// Vectors vendored from ethereum/tests (TrieTests), MIT-licensed; see testdata/ethereum-tests.

// vectorBytes decodes the ethereum/tests notation: "0x..." is hex, anything else is the raw
// string, and null (a nil pointer) is no value, which deletes the key.
func vectorBytes(t *testing.T, s *string) []byte {
	t.Helper()
	if s == nil {
		return nil
	}
	if strings.HasPrefix(*s, "0x") {
		b, err := hex.DecodeString((*s)[2:])
		require.NoError(t, err)
		return b
	}
	return []byte(*s)
}

// kvTrie is the interface shared by Trie and SecureTrie, so vectors run against both.
type kvTrie interface {
	Put(key, value []byte)
	Get(key []byte) ([]byte, bool)
	Delete(key []byte) bool
	Hash() keccak.Hash
	Prove(key []byte) [][]byte
	Len() int
}

func newKV(secure bool) kvTrie {
	if secure {
		return NewSecure()
	}
	return New()
}

func verifyKV(secure bool, root keccak.Hash, key []byte, proof [][]byte) ([]byte, error) {
	if secure {
		return VerifySecureProof(root, key, proof)
	}
	return VerifyProof(root, key, proof)
}

// checkAllProofs proves every key that was ever touched: present keys by inclusion with the
// right value, deleted keys by exclusion.
func checkAllProofs(t *testing.T, tr kvTrie, secure bool, touched map[string]bool) {
	t.Helper()
	root := tr.Hash()
	for k := range touched {
		want, present := tr.Get([]byte(k))
		got, err := verifyKV(secure, root, []byte(k), tr.Prove([]byte(k)))
		require.NoError(t, err, "key %x", k)
		if present {
			require.Equal(t, want, got, "key %x", k)
		} else {
			require.Nil(t, got, "deleted key %x must be proven absent", k)
		}
	}
}

func TestEthereumTrieTestsInOrder(t *testing.T) {
	for _, file := range []string{"trietest.json", "trietest_secureTrie.json"} {
		secure := strings.Contains(file, "secure")
		raw, err := os.ReadFile("testdata/ethereum-tests/" + file)
		require.NoError(t, err)
		var vectors map[string]struct {
			In   [][2]*string `json:"in"`
			Root string       `json:"root"`
		}
		require.NoError(t, json.Unmarshal(raw, &vectors))
		require.NotEmpty(t, vectors)
		for name, tc := range vectors {
			t.Run(file+"/"+name, func(t *testing.T) {
				tr := newKV(secure)
				touched := map[string]bool{}
				for _, kv := range tc.In {
					key := vectorBytes(t, kv[0])
					tr.Put(key, vectorBytes(t, kv[1])) // a null value deletes
					touched[string(key)] = true
				}
				require.Equal(t, tc.Root, tr.Hash().Hex())
				checkAllProofs(t, tr, secure, touched)
			})
		}
	}
}

// permutations calls f with every ordering of 0..n-1 (Heap's algorithm).
func permutations(n int, f func([]int)) {
	p := make([]int, n)
	for i := range p {
		p[i] = i
	}
	var gen func(k int)
	gen = func(k int) {
		if k <= 1 {
			f(p)
			return
		}
		for i := range k {
			gen(k - 1)
			if k%2 == 0 {
				p[i], p[k-1] = p[k-1], p[i]
			} else {
				p[0], p[k-1] = p[k-1], p[0]
			}
		}
	}
	gen(n)
}

func TestEthereumTrieTestsAnyOrder(t *testing.T) {
	for _, file := range []string{"trieanyorder.json", "trieanyorder_secureTrie.json", "hex_encoded_securetrie_test.json"} {
		secure := strings.Contains(file, "secure")
		raw, err := os.ReadFile("testdata/ethereum-tests/" + file)
		require.NoError(t, err)
		var vectors map[string]struct {
			In   map[string]string `json:"in"`
			Root string            `json:"root"`
		}
		require.NoError(t, json.Unmarshal(raw, &vectors))
		require.NotEmpty(t, vectors)
		for name, tc := range vectors {
			t.Run(file+"/"+name, func(t *testing.T) {
				keys := make([]string, 0, len(tc.In))
				for k := range tc.In {
					keys = append(keys, k)
				}
				sort.Strings(keys)
				orders := 0
				// Every insertion order must produce the same root (n! orders, n <= 5 here).
				permutations(len(keys), func(p []int) {
					tr := newKV(secure)
					touched := map[string]bool{}
					for _, i := range p {
						k, v := keys[i], tc.In[keys[i]]
						key := vectorBytes(t, &k)
						tr.Put(key, vectorBytes(t, &v))
						touched[string(key)] = true
					}
					require.Equal(t, tc.Root, tr.Hash().Hex(), "order %v", p)
					require.Equal(t, len(keys), tr.Len())
					checkAllProofs(t, tr, secure, touched)
					orders++
				})
				require.Positive(t, orders)
			})
		}
	}
}
