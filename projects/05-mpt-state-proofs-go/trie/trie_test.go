// SPDX-License-Identifier: MIT

package trie

import (
	"bytes"
	"fmt"
	"maps"
	"math/rand/v2"
	"slices"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/rlp"
)

func TestHexPrefixYellowPaperExamples(t *testing.T) {
	cases := []struct {
		nibbles []byte
		leaf    bool
		want    []byte
	}{
		{[]byte{1, 2, 3, 4, 5}, false, []byte{0x11, 0x23, 0x45}},
		{[]byte{0, 1, 2, 3, 4, 5}, false, []byte{0x00, 0x01, 0x23, 0x45}},
		{[]byte{0, 0xf, 1, 0xc, 0xb, 8}, true, []byte{0x20, 0x0f, 0x1c, 0xb8}},
		{[]byte{0xf, 1, 0xc, 0xb, 8}, true, []byte{0x3f, 0x1c, 0xb8}},
		{[]byte{}, true, []byte{0x20}},
		{[]byte{}, false, []byte{0x00}},
		{[]byte{7}, false, []byte{0x17}},
	}
	for _, tc := range cases {
		t.Run(fmt.Sprintf("%x/%v", tc.nibbles, tc.leaf), func(t *testing.T) {
			got := HexPrefixEncode(tc.nibbles, tc.leaf)
			require.Equal(t, tc.want, got)
			nibbles, leaf, err := HexPrefixDecode(got)
			require.NoError(t, err)
			require.Equal(t, tc.nibbles, nibbles)
			require.Equal(t, tc.leaf, leaf)
		})
	}
}

func TestHexPrefixRejects(t *testing.T) {
	for _, in := range [][]byte{nil, {0x40}, {0xf1}, {0x01}, {0x2a, 0xbc}} {
		_, _, err := HexPrefixDecode(in)
		require.ErrorIs(t, err, ErrHexPrefix, "%x", in)
	}
}

func TestNibbles(t *testing.T) {
	require.Equal(t, []byte{0xa, 0xb, 0x0, 0x1}, KeyToNibbles([]byte{0xab, 0x01}))
	key, err := NibblesToKey([]byte{0xa, 0xb, 0x0, 0x1})
	require.NoError(t, err)
	require.Equal(t, []byte{0xab, 0x01}, key)
	_, err = NibblesToKey([]byte{1})
	require.Error(t, err)
	_, err = NibblesToKey([]byte{0x10, 0})
	require.Error(t, err)
	require.Equal(t, 2, commonPrefixLen([]byte{1, 2, 3}, []byte{1, 2}))
	require.True(t, hasPrefix([]byte{1, 2, 3}, []byte{1, 2}))
	require.False(t, hasPrefix([]byte{1}, []byte{1, 2}))
}

func TestEmptyTrie(t *testing.T) {
	var tr Trie // the zero value is usable
	require.Equal(t, keccak.EmptyRoot, tr.Hash())
	require.Zero(t, tr.Len())
	_, ok := tr.Get([]byte("x"))
	require.False(t, ok)
	require.False(t, tr.Delete([]byte("x")))
	require.Empty(t, tr.Prove([]byte("x")))

	v, err := VerifyProof(keccak.EmptyRoot, []byte("x"), nil)
	require.NoError(t, err)
	require.Nil(t, v)
	_, err = VerifyProof(keccak.EmptyRoot, []byte("x"), [][]byte{{0xc0}})
	require.ErrorIs(t, err, ErrUnusedProofNode)

	// The empty node itself, RLP("") = 0x80, is an accepted proof of the empty trie (anvil
	// sends it; go-ethereum sends nothing). It must come alone.
	v, err = VerifyProof(keccak.EmptyRoot, []byte("x"), [][]byte{{0x80}})
	require.NoError(t, err)
	require.Nil(t, v)
	_, err = VerifyProof(keccak.EmptyRoot, []byte("x"), [][]byte{{0x80}, {0x80}})
	require.ErrorIs(t, err, ErrDuplicateProofNode)
	_, err = VerifyProof(keccak.EmptyRoot, []byte("x"), [][]byte{{0x80}, {0xc0}})
	require.ErrorIs(t, err, ErrUnusedProofNode)
}

func TestPutGetDelete(t *testing.T) {
	tr := New()
	tr.Put([]byte("dog"), []byte("puppy"))
	tr.Put([]byte("do"), []byte("verb"))
	tr.Put([]byte("dog"), []byte("hound")) // overwrite
	require.Equal(t, 2, tr.Len())

	v, ok := tr.Get([]byte("dog"))
	require.True(t, ok)
	require.Equal(t, []byte("hound"), v)
	v[0] = 'X' // Get returns a copy
	v, _ = tr.Get([]byte("dog"))
	require.Equal(t, []byte("hound"), v)

	val := []byte("verb2")
	tr.Put([]byte("do"), val)
	val[0] = 'X' // Put copies its argument
	v, _ = tr.Get([]byte("do"))
	require.Equal(t, []byte("verb2"), v)

	for _, missing := range []string{"", "d", "doge", "cat", "dox"} {
		_, ok := tr.Get([]byte(missing))
		require.False(t, ok, missing)
		require.False(t, tr.Delete([]byte(missing)), missing)
	}

	tr.Put([]byte("do"), nil) // empty value deletes
	require.Equal(t, 1, tr.Len())
	_, ok = tr.Get([]byte("do"))
	require.False(t, ok)
	require.True(t, tr.Delete([]byte("dog")))
	require.Zero(t, tr.Len())
	require.Equal(t, keccak.EmptyRoot, tr.Hash())
}

// rootKind returns the kind of the root node and of each child of a root branch.
func shape(n node) string {
	switch x := n.(type) {
	case nil:
		return "-"
	case *leafNode:
		return fmt.Sprintf("leaf%x", x.path)
	case *extensionNode:
		return fmt.Sprintf("ext%x(%s)", x.path, shape(x.child))
	case *branchNode:
		s := "branch["
		for i, c := range x.children {
			if c != nil {
				s += fmt.Sprintf("%x:%s ", i, shape(c))
			}
		}
		if x.value != nil {
			s += "v"
		}
		return s + "]"
	}
	return "?"
}

func TestShapes(t *testing.T) {
	cases := []struct {
		name string
		keys []string
		want string
	}{
		{"single key is a leaf", []string{"\x12"}, "leaf0102"},
		{"keys diverging at the first nibble share no extension", []string{"\x12", "\x34"}, "branch[1:leaf02 3:leaf04 ]"},
		{"shared first nibble becomes an extension", []string{"\x61", "\x62"}, "ext06(branch[1:leaf 2:leaf ])"},
		{"key ending at a branch uses the value slot", []string{"\x61", "\x61\x62"}, "ext0601(branch[6:leaf02 v])"},
		{"empty key at the root", []string{"", "\x10"}, "branch[1:leaf00 v]"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tr := New()
			for _, k := range tc.keys {
				tr.Put([]byte(k), []byte("v"))
			}
			require.Equal(t, tc.want, shape(tr.root))
		})
	}
}

func TestDeleteCollapses(t *testing.T) {
	// Each case builds a trie, deletes some keys, and checks that the result has exactly the
	// shape (and root) of a trie built from the remaining keys alone.
	cases := []struct {
		name    string
		keys    []string
		deleted []string
		want    string
	}{
		{"branch with one leaf left becomes a leaf", []string{"\x12", "\x34"}, []string{"\x34"}, "leaf0102"},
		{"extension absorbs the collapsed branch", []string{"\x61", "\x62"}, []string{"\x62"}, "leaf0601"},
		{"branch with only its value left becomes an empty-path leaf, merged upward", []string{"\x61", "\x61\x62"}, []string{"\x61\x62"}, "leaf0601"},
		{"value removed, one child left", []string{"\x61", "\x61\x62"}, []string{"\x61"}, "leaf06010602"},
		{"branch child of a branch becomes an extension", []string{"\x11", "\x12", "\x21"}, []string{"\x21"}, "ext01(branch[1:leaf 2:leaf ])"},
		{"extension merges with an extension below", []string{"\x11\x11", "\x11\x12", "\x12"}, []string{"\x12"}, "ext010101(branch[1:leaf 2:leaf ])"},
		{"three-way branch keeps two", []string{"\x10", "\x20", "\x30"}, []string{"\x20"}, "branch[1:leaf00 3:leaf00 ]"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tr := New()
			for _, k := range tc.keys {
				tr.Put([]byte(k), []byte("v"))
			}
			for _, k := range tc.deleted {
				require.True(t, tr.Delete([]byte(k)))
			}
			require.Equal(t, tc.want, shape(tr.root))

			fresh := New()
			for _, k := range tc.keys {
				if !contains(tc.deleted, k) {
					fresh.Put([]byte(k), []byte("v"))
				}
			}
			require.Equal(t, fresh.Hash(), tr.Hash())
			require.Equal(t, shape(fresh.root), shape(tr.root))
		})
	}
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func TestInlineAndHashedChildren(t *testing.T) {
	tr := New()
	tr.Put([]byte{0x10}, []byte("a"))                 // leaf: RLP([0x30, "a"]) is 3 bytes: inline
	tr.Put([]byte{0x20}, bytes.Repeat([]byte{1}, 40)) // leaf over 32 bytes: hashed
	root := tr.root.(*branchNode)
	require.Len(t, root.encoding(), 1+3+33+14+1, "header, inline ref, hash ref, 14 empty slots, empty value")
	require.Equal(t, root.children[1].encoding(), reference(root.children[1]), "small child embedded")
	h := hashOf(root.children[2])
	require.Equal(t, rlp.EncodeString(h[:]), reference(root.children[2]), "large child hashed")

	// The root hash is the hash of the root encoding even when it is shorter than 32 bytes.
	small := New()
	small.Put([]byte{1}, []byte{2})
	require.Less(t, len(small.root.encoding()), 32)
	require.Equal(t, keccak.Sum256(small.root.encoding()), small.Hash())
	require.Len(t, small.Prove([]byte{1}), 1, "the root is always part of a proof")
}

func TestNodeKindString(t *testing.T) {
	require.Equal(t, "branch", Branch.String())
	require.Equal(t, "extension", Extension.String())
	require.Equal(t, "leaf", Leaf.String())
	require.Equal(t, "NodeKind(9)", NodeKind(9).String())
	require.Equal(t, NodeKind(0), kindOf(hashRef{}))
}

func TestUnresolvedNodePanics(t *testing.T) {
	tr := &Trie{root: hashRef{}}
	require.Panics(t, func() { tr.Get([]byte{1}) })
	require.Panics(t, func() { tr.Put([]byte{1}, []byte{1}) })
	require.Panics(t, func() { tr.Delete([]byte{1}) })
}

func TestSecureTrie(t *testing.T) {
	s := NewSecure()
	s.Put([]byte("key"), []byte("value"))
	require.Equal(t, 1, s.Len())
	v, ok := s.Get([]byte("key"))
	require.True(t, ok)
	require.Equal(t, []byte("value"), v)

	plain := New()
	h := keccak.Sum256([]byte("key"))
	plain.Put(h[:], []byte("value"))
	require.Equal(t, plain.Hash(), s.Hash(), "a secure trie is a trie keyed by keccak(key)")

	got, err := VerifySecureProof(s.Hash(), []byte("key"), s.Prove([]byte("key")))
	require.NoError(t, err)
	require.Equal(t, []byte("value"), got)
	require.True(t, s.Delete([]byte("key")))
	require.Equal(t, keccak.EmptyRoot, s.Hash())
}

// TestRandomOrderIndependence is the seeded counterpart of FuzzTrieOrderIndependence: random
// operation sequences, then the surviving entries reinserted in shuffled orders.
func TestRandomOrderIndependence(t *testing.T) {
	rng := rand.New(rand.NewPCG(1, 2026))
	for round := range 300 {
		tr := New()
		model := map[string][]byte{}
		ops := 1 + rng.IntN(120)
		for range ops {
			k := randomKey(rng)
			if rng.IntN(4) == 0 {
				_, had := model[k]
				require.Equal(t, had, tr.Delete([]byte(k)))
				delete(model, k)
				continue
			}
			v := randomValue(rng)
			tr.Put([]byte(k), v)
			model[k] = v
		}
		require.Equal(t, len(model), tr.Len(), "round %d", round)
		for range 3 {
			other := New()
			for _, k := range shuffledKeys(rng, model) {
				other.Put([]byte(k), model[k])
			}
			require.Equal(t, tr.Hash(), other.Hash(), "round %d", round)
		}
		for k, v := range model {
			got, ok := tr.Get([]byte(k))
			require.True(t, ok)
			require.Equal(t, v, got)
		}
	}
}

// shuffledKeys returns the keys of model in an order that is a pure function of rng's state.
// The keys are sorted before the shuffle because Go randomizes map iteration order on every
// run: shuffling them in iteration order would make the insertion order, and so any failure
// that depends on it, impossible to reproduce from the seed (or from a fuzz input).
func shuffledKeys(rng *rand.Rand, model map[string][]byte) []string {
	keys := slices.Sorted(maps.Keys(model))
	rng.Shuffle(len(keys), func(i, j int) { keys[i], keys[j] = keys[j], keys[i] })
	return keys
}

// TestShuffledKeysIsReproducible is the regression test for the order-independence property
// tests: the same seed must give the same insertion order every time, whatever order the map
// iterates in.
func TestShuffledKeysIsReproducible(t *testing.T) {
	model := map[string][]byte{}
	for i := range 64 {
		model[fmt.Sprintf("key-%02d", i)] = []byte{byte(i)}
	}
	want := shuffledKeys(rand.New(rand.NewPCG(7, 2026)), model)
	require.ElementsMatch(t, slices.Collect(maps.Keys(model)), want)
	for range 50 {
		require.Equal(t, want, shuffledKeys(rand.New(rand.NewPCG(7, 2026)), model))
	}
	require.NotEqual(t, want, shuffledKeys(rand.New(rand.NewPCG(8, 2026)), model), "the seed drives the order")
}

// randomKey draws from a small alphabet with short lengths, so keys often share prefixes and
// one key is often a prefix of another.
func randomKey(rng *rand.Rand) string {
	n := rng.IntN(4)
	b := make([]byte, n)
	for i := range b {
		b[i] = []byte{0x00, 0x01, 0x10, 0x11, 0xab, 0xff}[rng.IntN(6)]
	}
	return string(b)
}

// randomValue mixes values that keep nodes inline with values that force hashing.
func randomValue(rng *rand.Rand) []byte {
	n := 1 + rng.IntN(3)
	if rng.IntN(3) == 0 {
		n = 30 + rng.IntN(40)
	}
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(rng.Uint32())
	}
	return b
}
