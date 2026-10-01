// SPDX-License-Identifier: MIT

package rlp

import (
	"bytes"
	"errors"
	"math/rand/v2"
	"testing"

	gethrlp "github.com/ethereum/go-ethereum/rlp"
	"github.com/stretchr/testify/require"
)

// go-ethereum's rlp package is the differential oracle: it is used only by tests.

// toGeth converts a Value to the generic form go-ethereum encodes and decodes: []byte for
// strings, []interface{} for lists.
func toGeth(v Value) any {
	if v.Kind == String {
		if v.Bytes == nil {
			return []byte{}
		}
		return v.Bytes
	}
	out := make([]any, len(v.Items))
	for i, it := range v.Items {
		out[i] = toGeth(it)
	}
	return out
}

// fromGeth is the inverse of toGeth.
func fromGeth(t testing.TB, x any) Value {
	switch v := x.(type) {
	case []byte:
		return Str(v)
	case []any:
		items := make([]Value, len(v))
		for i, it := range v {
			items[i] = fromGeth(t, it)
		}
		return ListOf(items...)
	default:
		t.Fatalf("unexpected go-ethereum value %T", x)
		return Value{}
	}
}

// genValue builds a pseudo-random item tree from a byte stream (used by both the seeded
// property test and the fuzzer, which gives the generator its bytes).
type genValue struct{ data []byte }

func (g *genValue) next() byte {
	if len(g.data) == 0 {
		return 0
	}
	b := g.data[0]
	g.data = g.data[1:]
	return b
}

func (g *genValue) value(depth int) Value {
	c := g.next()
	if depth < 6 && c%4 == 0 {
		n := int(g.next() % 6)
		items := make([]Value, n)
		for i := range items {
			items[i] = g.value(depth + 1)
		}
		return ListOf(items...)
	}
	var n int
	switch c % 4 {
	case 1:
		n = 1 // single bytes exercise the < 0x80 rule
	case 2:
		n = int(g.next() % 60) // around the 55-byte short/long boundary
	default:
		n = int(g.next())
	}
	b := make([]byte, n)
	for i := range b {
		b[i] = g.next()
	}
	return Str(b)
}

// checkAgainstGeth asserts that our decoder and go-ethereum's accept exactly the same inputs
// and produce the same trees.
func checkAgainstGeth(t testing.TB, input []byte) {
	ours, err := Decode(input)
	if errors.Is(err, ErrTooDeep) {
		return // documented divergence: go-ethereum has no nesting limit
	}
	var theirs any
	gerr := gethrlp.DecodeBytes(input, &theirs)
	if (err == nil) != (gerr == nil) {
		t.Fatalf("acceptance differs on %x: ours=%v go-ethereum=%v", input, err, gerr)
	}
	if err == nil {
		require.True(t, ours.Equal(fromGeth(t, theirs)), "trees differ on %x", input)
	}
}

func TestDifferentialEncodeRandomTrees(t *testing.T) {
	rng := rand.New(rand.NewPCG(5, 2026))
	for i := range 5000 {
		seed := make([]byte, 64+rng.IntN(2048))
		for j := range seed {
			seed[j] = byte(rng.Uint32())
		}
		v := (&genValue{data: seed}).value(0)
		want, err := gethrlp.EncodeToBytes(toGeth(v))
		require.NoError(t, err)
		got := v.Encode()
		require.Equal(t, want, got, "case %d", i)
		checkAgainstGeth(t, got)
	}
}

func TestDifferentialDecodeMutations(t *testing.T) {
	// Single-byte mutations of valid encodings are a dense source of nearly-valid inputs:
	// length off by one, short/long boundary crossings, wrapped single bytes.
	rng := rand.New(rand.NewPCG(7, 2026))
	for range 3000 {
		seed := make([]byte, 32+rng.IntN(256))
		for j := range seed {
			seed[j] = byte(rng.Uint32())
		}
		enc := (&genValue{data: seed}).value(0).Encode()
		for range 8 {
			m := bytes.Clone(enc)
			m[rng.IntN(len(m))] = byte(rng.Uint32())
			checkAgainstGeth(t, m)
			checkAgainstGeth(t, m[:rng.IntN(len(m)+1)])
		}
	}
}

func TestGethAgreesOnCanonicalRejections(t *testing.T) {
	for _, in := range [][]byte{
		{0x81, 0x05},
		append([]byte{0xb8, 0x05}, "hello"...),
		append([]byte{0xb9, 0x00, 0x40}, make([]byte, 64)...),
		{0xf8, 0x01, 0x80},
		{0x80, 0x80},
		{},
	} {
		checkAgainstGeth(t, in)
		_, err := Decode(in)
		require.Error(t, err, "%x", in)
	}
}
