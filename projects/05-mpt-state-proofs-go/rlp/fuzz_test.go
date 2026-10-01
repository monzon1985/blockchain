// SPDX-License-Identifier: MIT

package rlp

import (
	"bytes"
	"testing"

	gethrlp "github.com/ethereum/go-ethereum/rlp"
)

// FuzzRLPRoundTrip checks the two directions of the codec on arbitrary bytes:
//
//  1. as an encoding: if Decode accepts the input, re-encoding the tree reproduces the input
//     byte for byte (canonical decoding means encode∘decode is the identity), and
//     go-ethereum's decoder accepts exactly the same inputs with the same tree;
//  2. as a generator seed: the tree built from the bytes encodes to what go-ethereum
//     encodes, and decodes back to the same tree.
func FuzzRLPRoundTrip(f *testing.F) {
	for _, seed := range [][]byte{
		{0x80}, {0x00}, {0x7f}, {0x81, 0x80}, {0xc0}, {0xc2, 0x80, 0xc0},
		{0x81, 0x05}, {0xb8, 0x05}, {0xf8, 0x01, 0x80}, {0xbf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff},
		append([]byte{0xb8, 0x38}, bytes.Repeat([]byte{'a'}, 56)...),
		EncodeList(EncodeString([]byte("dog")), EncodeList(EncodeUint64(1024))),
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		if v, err := Decode(data); err == nil {
			if got := v.Encode(); !bytes.Equal(got, data) {
				t.Fatalf("encode(decode(%x)) = %x", data, got)
			}
		}
		checkAgainstGeth(t, data)

		v := (&genValue{data: data}).value(0)
		enc := v.Encode()
		want, err := gethrlp.EncodeToBytes(toGeth(v))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(enc, want) {
			t.Fatalf("encoding differs from go-ethereum: ours=%x theirs=%x", enc, want)
		}
		back, err := Decode(enc)
		if err != nil {
			t.Fatalf("decode of our own encoding %x: %v", enc, err)
		}
		if !back.Equal(v) {
			t.Fatalf("decode(encode(v)) != v for %x", enc)
		}
	})
}
