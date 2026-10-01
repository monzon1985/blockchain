// SPDX-License-Identifier: MIT

package trie

import (
	"bytes"
	"encoding/binary"
	"math/rand/v2"
	"testing"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
)

// opReader turns fuzzer bytes into trie operations.
type opReader struct{ data []byte }

func (r *opReader) byte() (byte, bool) {
	if len(r.data) == 0 {
		return 0, false
	}
	b := r.data[0]
	r.data = r.data[1:]
	return b, true
}

// palette keeps keys in a small space so that operations collide, keys share prefixes, and
// one key is often a prefix of another.
var palette = []byte{0x00, 0x01, 0x10, 0x11, 0x1f, 0xab, 0xf0, 0xff}

type fuzzOp struct {
	del   bool
	key   []byte
	value []byte
}

func parseOps(data []byte) []fuzzOp {
	r := &opReader{data: data}
	var ops []fuzzOp
	for len(ops) < 256 {
		c, ok := r.byte()
		if !ok {
			break
		}
		key := make([]byte, int(c>>5)%4) // 0..3 bytes
		for i := range key {
			b, _ := r.byte()
			key[i] = palette[b%byte(len(palette))]
		}
		if c&0x0f == 0 {
			ops = append(ops, fuzzOp{del: true, key: key})
			continue
		}
		n := int(c & 0x0f)
		if c&0x10 != 0 {
			n += 28 // pushes the node past 32 bytes: hashed instead of inline
		}
		value := make([]byte, n)
		for i := range value {
			value[i], _ = r.byte()
			value[i] |= 1 // keep values distinct from absent data
		}
		ops = append(ops, fuzzOp{key: key, value: value})
	}
	return ops
}

// FuzzTrieOrderIndependence applies an arbitrary sequence of insertions and deletions, then
// checks three roots that must coincide:
//
//   - the trie after the sequence;
//   - a fresh trie built from the surviving entries in a data-dependent shuffled order, with
//     extra keys inserted and deleted in between (so deletion paths run too);
//   - go-ethereum's trie after the same sequence.
//
// It also proves every touched key against the final root.
func FuzzTrieOrderIndependence(f *testing.F) {
	f.Add([]byte{0x21, 0x00, 0x22, 0x01, 0x23, 0x02, 0x20, 0x00})
	f.Add([]byte{0x41, 0x02, 0x03, 0x05, 0x31, 0x11, 0x01, 0x40, 0x02, 0x03})
	f.Add(bytes.Repeat([]byte{0x7f, 0x01, 0x02, 0x03}, 30))
	f.Fuzz(func(t *testing.T, data []byte) {
		ops := parseOps(data)
		a, g := New(), newGethTrie()
		model := map[string][]byte{}
		for _, op := range ops {
			if op.del {
				a.Delete(op.key)
				if err := g.Delete(op.key); err != nil {
					t.Fatal(err)
				}
				delete(model, string(op.key))
				continue
			}
			a.Put(op.key, op.value)
			if err := g.Update(op.key, op.value); err != nil {
				t.Fatal(err)
			}
			model[string(op.key)] = op.value
		}
		root := a.Hash()
		if common.Hash(root) != g.Hash() {
			t.Fatalf("root %s differs from go-ethereum's %s", root, g.Hash())
		}
		if a.Len() != len(model) {
			t.Fatalf("Len() = %d, want %d", a.Len(), len(model))
		}

		seed := keccak.Sum256(data)
		rng := rand.New(rand.NewPCG(binary.BigEndian.Uint64(seed[:8]), binary.BigEndian.Uint64(seed[8:16])))
		keys := make([]string, 0, len(model))
		for k := range model {
			keys = append(keys, k)
		}
		rng.Shuffle(len(keys), func(i, j int) { keys[i], keys[j] = keys[j], keys[i] })
		b := New()
		var junk [][]byte
		for i, k := range keys {
			b.Put([]byte(k), model[k])
			if i%3 == 0 {
				j := []byte{0xee, byte(i), 0x01} // outside the palette: never a real key
				b.Put(j, bytes.Repeat([]byte{byte(i) | 1}, 1+i%40))
				junk = append(junk, j)
			}
		}
		for _, j := range junk {
			if !b.Delete(j) {
				t.Fatalf("junk key %x vanished", j)
			}
		}
		if b.Hash() != root {
			t.Fatalf("shuffled rebuild root %s != %s", b.Hash(), root)
		}

		for _, op := range ops {
			got, err := VerifyProof(root, op.key, a.Prove(op.key))
			if err != nil {
				t.Fatalf("proof for %x: %v", op.key, err)
			}
			if want := model[string(op.key)]; !bytes.Equal(got, want) {
				t.Fatalf("proof for %x gives %x, want %x", op.key, got, want)
			}
		}
	})
}

// FuzzVerifyProof mutates a valid proof with fuzzer-chosen edits. Whatever the edit, the
// verifier must not panic, and if it still accepts the proof it must give the same answer as
// the original: a node's identity is its hash, so changing its bytes changes nothing the
// verifier can be fooled by.
func FuzzVerifyProof(f *testing.F) {
	f.Add([]byte("dog"), uint16(0), uint16(3), byte(0x01), byte(0))
	f.Add([]byte("horse"), uint16(1), uint16(0), byte(0xff), byte(1))
	f.Add([]byte("\x00"), uint16(0), uint16(40), byte(0x80), byte(2))
	tr, _ := sampleTrie()
	root := tr.Hash()
	f.Fuzz(func(t *testing.T, key []byte, node, pos uint16, delta, mode byte) {
		proof := tr.Prove(key)
		want, err := VerifyProof(root, key, proof)
		if err != nil {
			t.Fatalf("valid proof rejected: %v", err)
		}
		if len(proof) == 0 {
			return
		}
		i := int(node) % len(proof)
		m := cloneProof(proof)
		switch mode % 4 {
		case 0: // flip bits in one byte
			m[i][int(pos)%len(m[i])] ^= delta | 1
		case 1: // truncate a node
			m[i] = m[i][:int(pos)%len(m[i])]
		case 2: // append a byte
			m[i] = append(m[i], delta)
		case 3: // replace a node with junk
			m[i] = bytes.Repeat([]byte{delta}, 1+int(pos)%64)
		}
		got, err := VerifyProof(root, key, m)
		if err == nil && !bytes.Equal(got, want) {
			t.Fatalf("mutated proof accepted with a different answer: %x vs %x", got, want)
		}
	})
}

// FuzzHexPrefix checks that hex-prefix encoding is a bijection on its valid inputs.
func FuzzHexPrefix(f *testing.F) {
	f.Add([]byte{0x11, 0x23, 0x45})
	f.Add([]byte{0x20})
	f.Fuzz(func(t *testing.T, enc []byte) {
		nibbles, leaf, err := HexPrefixDecode(enc)
		if err != nil {
			return
		}
		if got := HexPrefixEncode(nibbles, leaf); !bytes.Equal(got, enc) {
			t.Fatalf("encode(decode(%x)) = %x", enc, got)
		}
		key := KeyToNibbles(enc)
		back, err := NibblesToKey(key)
		if err != nil || !bytes.Equal(back, enc) {
			t.Fatalf("nibble round trip of %x failed", enc)
		}
	})
}
