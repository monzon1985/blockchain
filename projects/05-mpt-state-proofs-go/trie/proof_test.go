// SPDX-License-Identifier: MIT

package trie

import (
	"bytes"
	"errors"
	"math/rand/v2"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/rlp"
)

// sampleTrie has every structural situation a proof can end in: branch values (keys that are
// prefixes of other keys), extensions, inline and hashed leaves.
func sampleTrie() (*Trie, map[string][]byte) {
	entries := map[string][]byte{
		"do":    []byte("verb"),
		"dog":   []byte("puppy"),
		"doge":  []byte("coin"),
		"horse": []byte("stallion"),
		"house": bytes.Repeat([]byte("h"), 40),
		"\x00":  []byte{0x01},
		"\x01":  bytes.Repeat([]byte{0xee}, 33),
	}
	tr := New()
	for k, v := range entries {
		tr.Put([]byte(k), v)
	}
	return tr, entries
}

func TestProofInclusion(t *testing.T) {
	tr, entries := sampleTrie()
	root := tr.Hash()
	for k, want := range entries {
		res, err := VerifyProofTrace(root, []byte(k), tr.Prove([]byte(k)))
		require.NoError(t, err, "%q", k)
		require.True(t, res.Exists())
		require.Equal(t, want, res.Value, "%q", k)

		// The walk consumes the whole key, and the first step is the hashed root.
		consumed := 0
		for _, s := range res.Steps {
			consumed += len(s.Consumed)
		}
		require.Equal(t, 2*len(k), consumed, "%q", k)
		require.False(t, res.Steps[0].Inline)
		require.Equal(t, root, res.Steps[0].Hash)
	}
}

func TestProofExclusion(t *testing.T) {
	tr, _ := sampleTrie()
	root := tr.Hash()
	cases := map[string]string{
		"d":      "key ends inside an extension",
		"dox":    "empty branch slot",
		"dogs":   "key runs past a leaf",
		"hors":   "key ends at a branch without a value",
		"horsey": "diverges from a leaf",
		"zebra":  "empty slot at the root",
		"":       "empty key at a root branch without a value",
		"\x02":   "empty slot under a root branch",
	}
	for k, why := range cases {
		res, err := VerifyProofTrace(root, []byte(k), tr.Prove([]byte(k)))
		require.NoError(t, err, "%q (%s)", k, why)
		require.False(t, res.Exists(), "%q (%s)", k, why)
		require.Nil(t, res.Value)
		require.NotEmpty(t, res.Steps)
	}
}

func TestProofOfAnotherKeyDoesNotLie(t *testing.T) {
	tr, entries := sampleTrie()
	root := tr.Hash()
	for a := range entries {
		proof := tr.Prove([]byte(a))
		for b := range entries {
			if a == b {
				continue
			}
			got, err := VerifyProof(root, []byte(b), proof)
			if err == nil {
				// A proof built for a can only ever say something true about b.
				want, ok := tr.Get([]byte(b))
				if ok {
					require.Equal(t, want, got, "proof(%q) used for %q", a, b)
				} else {
					require.Nil(t, got)
				}
			}
		}
	}
}

func TestProofTamperingIsDetected(t *testing.T) {
	tr, entries := sampleTrie()
	root := tr.Hash()
	rng := rand.New(rand.NewPCG(3, 2026))
	for k := range entries {
		proof := tr.Prove([]byte(k))
		for i := range proof {
			for range 20 {
				mutated := cloneProof(proof)
				mutated[i][rng.IntN(len(mutated[i]))] ^= byte(1 + rng.IntN(255))
				_, err := VerifyProof(root, []byte(k), mutated)
				require.Error(t, err, "flipped byte in node %d of proof(%q) was accepted", i, k)
			}
			dropped := append(cloneProof(proof[:i]), cloneProof(proof[i+1:])...)
			_, err := VerifyProof(root, []byte(k), dropped)
			require.ErrorIs(t, err, ErrMissingProofNode, "dropped node %d of proof(%q)", i, k)
		}
		dup := append(cloneProof(proof), bytes.Clone(proof[0]))
		_, err := VerifyProof(root, []byte(k), dup)
		require.ErrorIs(t, err, ErrDuplicateProofNode)

		extra := append(cloneProof(proof), rlp.EncodeList(rlp.EncodeString([]byte{0x20}), rlp.EncodeString(bytes.Repeat([]byte{7}, 40))))
		_, err = VerifyProof(root, []byte(k), extra)
		require.ErrorIs(t, err, ErrUnusedProofNode)

		_, err = VerifyProof(keccak.Sum256([]byte("another root")), []byte(k), proof)
		require.ErrorIs(t, err, ErrMissingProofNode)
	}
}

func cloneProof(p [][]byte) [][]byte {
	out := make([][]byte, len(p))
	for i, n := range p {
		out[i] = bytes.Clone(n)
	}
	return out
}

// leafEnc returns the encoding of a leaf node.
func leafEnc(nibbles []byte, value []byte) []byte {
	return rlp.EncodeList(rlp.EncodeString(HexPrefixEncode(nibbles, true)), rlp.EncodeString(value))
}

func hashRefEnc(enc []byte) []byte {
	h := keccak.Sum256(enc)
	return rlp.EncodeString(h[:])
}

// branchEnc returns a branch encoding with the given child references (nil = empty slot).
func branchEnc(children map[int][]byte, value []byte) []byte {
	items := make([][]byte, 17)
	for i := range 16 {
		if c, ok := children[i]; ok {
			items[i] = c
		} else {
			items[i] = []byte{0x80}
		}
	}
	items[16] = rlp.EncodeString(value)
	return rlp.EncodeList(items...)
}

func TestNonCanonicalProofsAreRejected(t *testing.T) {
	bigLeaf := leafEnc([]byte{0}, bytes.Repeat([]byte{9}, 40)) // >= 32 bytes, must be hashed
	smallLeaf := leafEnc([]byte{0}, []byte{9})                 // < 32 bytes, must be inline
	bigBranch := branchEnc(map[int][]byte{1: hashRefEnc(bigLeaf), 2: hashRefEnc(bigLeaf)}, nil)

	cases := []struct {
		name  string
		key   []byte
		proof [][]byte // proof[0] is the root
	}{
		{"node is an RLP string", []byte{0x10}, [][]byte{rlp.EncodeString([]byte("not a node"))}},
		{"list of 3 items", []byte{0x10}, [][]byte{rlp.EncodeList(rlp.EncodeString(nil), rlp.EncodeString(nil), rlp.EncodeString(nil))}},
		{"bad hex-prefix flag", []byte{0x10}, [][]byte{rlp.EncodeList(rlp.EncodeString([]byte{0x40}), rlp.EncodeString([]byte("v")))}},
		{"path is a list", []byte{0x10}, [][]byte{rlp.EncodeList(rlp.EncodeList(), rlp.EncodeString([]byte("v")))}},
		{"leaf with empty value", []byte{0x10}, [][]byte{leafEnc([]byte{1, 0}, nil)}},
		{"leaf value is a list", []byte{0x10}, [][]byte{rlp.EncodeList(rlp.EncodeString([]byte{0x20, 0x10}), rlp.EncodeList())}},
		{"extension with empty path", []byte{0x10}, [][]byte{rlp.EncodeList(rlp.EncodeString([]byte{0x00}), hashRefEnc(bigBranch)), bigBranch}},
		{"extension with a 20-byte child reference", []byte{0x10}, [][]byte{rlp.EncodeList(rlp.EncodeString([]byte{0x11}), rlp.EncodeString(make([]byte, 20)))}},
		{"extension with an empty child", []byte{0x10}, [][]byte{rlp.EncodeList(rlp.EncodeString([]byte{0x11}), rlp.EncodeString(nil))}},
		{"extension with an inline leaf child", []byte{0x10}, [][]byte{rlp.EncodeList(rlp.EncodeString([]byte{0x11}), smallLeaf)}},
		{"extension with a hashed leaf child", []byte{0x10}, [][]byte{rlp.EncodeList(rlp.EncodeString([]byte{0x11}), hashRefEnc(bigLeaf)), bigLeaf}},
		{"branch with a single entry", []byte{0x10}, [][]byte{branchEnc(map[int][]byte{1: hashRefEnc(bigLeaf)}, nil), bigLeaf}},
		{"branch value is a list", []byte{0x10}, [][]byte{rlp.EncodeList(append(bytes.Repeat([]byte{0x80}, 16), 0xc0))}},
		{"child reference of 20 bytes", []byte{0x10}, [][]byte{branchEnc(map[int][]byte{1: rlp.EncodeString(make([]byte, 20)), 2: smallLeaf}, nil)}},
		{"small node referenced by hash", []byte{0x10}, [][]byte{branchEnc(map[int][]byte{1: hashRefEnc(smallLeaf), 2: smallLeaf}, nil), smallLeaf}},
		{"large node inlined", []byte{0x10}, [][]byte{branchEnc(map[int][]byte{1: bigLeaf, 2: smallLeaf}, nil)}},
		{"trailing bytes after a node", []byte{0x10}, [][]byte{append(leafEnc([]byte{1, 0}, []byte("v")), 0x00)}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := keccak.Sum256(tc.proof[0])
			_, err := VerifyProof(root, tc.key, tc.proof)
			require.ErrorIs(t, err, ErrInvalidNode)
		})
	}
}

func TestDecodeNodeRejectsNonCanonicalReencoding(t *testing.T) {
	// Every accepted node re-encodes to its input (the property decodeNode double-checks).
	tr, entries := sampleTrie()
	for k := range entries {
		for _, enc := range tr.Prove([]byte(k)) {
			n, err := decodeNode(enc)
			require.NoError(t, err)
			require.Equal(t, enc, n.encoding())
		}
	}
	_, err := decodeNode([]byte{0x81, 0x05})
	require.ErrorIs(t, err, ErrInvalidNode, "RLP errors surface as invalid nodes")
}

func TestInlineNestingIsBounded(t *testing.T) {
	require.Positive(t, maxInlineDepth)
	// A legitimate inline chain: extension -> inline branch -> inline leaves.
	tr := New()
	tr.Put([]byte{0x11}, []byte{1})
	tr.Put([]byte{0x12}, []byte{2})
	ext, ok := tr.root.(*extensionNode)
	require.True(t, ok)
	require.Less(t, len(ext.child.encoding()), 32, "the branch is inline in the extension")
	for _, k := range [][]byte{{0x11}, {0x12}, {0x13}} {
		res, err := VerifyProofTrace(tr.Hash(), k, tr.Prove(k))
		require.NoError(t, err)
		require.Len(t, tr.Prove(k), 1, "everything is inside the root encoding")
		require.True(t, res.Steps[len(res.Steps)-1].Inline || len(res.Steps) == 1)
	}
}

func TestHashOfReference(t *testing.T) {
	require.Equal(t, keccak.Hash{7}, hashOf(hashRef{7}), "a hash reference is its own hash")
}

func TestErrorsWrapInvalidNode(t *testing.T) {
	err := invalid("x %d", 1)
	require.True(t, errors.Is(err, ErrInvalidNode))
	require.Contains(t, err.Error(), "x 1")
}
