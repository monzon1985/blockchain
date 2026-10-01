// SPDX-License-Identifier: MIT

package keccak

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestSum256KnownVectors(t *testing.T) {
	cases := []struct {
		name string
		in   [][]byte
		want string
	}{
		{"empty", nil, "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"},
		{"abc", [][]byte{[]byte("abc")}, "0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"},
		{"abc in pieces", [][]byte{[]byte("a"), nil, []byte("bc")}, "0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			require.Equal(t, tc.want, Sum256(tc.in...).Hex())
		})
	}
}

func TestWellKnownConstants(t *testing.T) {
	require.Equal(t, EmptyRoot, Sum256([]byte{0x80}), "empty trie root is the hash of RLP(\"\")")
	require.Equal(t, EmptyList, Sum256([]byte{0xc0}), "empty ommers hash is the hash of RLP([])")
	require.Equal(t, EmptyCode, Sum256(), "empty code hash is the hash of no bytes")
}

func TestParse(t *testing.T) {
	h, err := Parse("0X" + "00000000000000000000000000000000000000000000000000000000000000ff")
	require.NoError(t, err)
	require.Equal(t, byte(0xff), h[31])
	require.False(t, h.IsZero())
	require.True(t, Hash{}.IsZero())
	require.Equal(t, h.Hex(), h.String())

	for _, bad := range []string{
		"",
		"0x",
		"56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b42100", // no 0x prefix
		"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b4",   // 31 bytes
		"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b4zz", // not hex
	} {
		_, err := Parse(bad)
		require.Error(t, err, "%q", bad)
	}
	require.Panics(t, func() { MustParse("0x00") })
}

func TestTextRoundTrip(t *testing.T) {
	want := EmptyRoot
	text, err := want.MarshalText()
	require.NoError(t, err)
	var got Hash
	require.NoError(t, got.UnmarshalText(text))
	require.Equal(t, want, got)
	require.Error(t, got.UnmarshalText([]byte("0x1234")))
}

func TestAddress(t *testing.T) {
	a, err := ParseAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")
	require.NoError(t, err)
	require.Equal(t, "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266", a.Hex())
	require.Equal(t, a.Hex(), a.String())

	text, err := a.MarshalText()
	require.NoError(t, err)
	var b Address
	require.NoError(t, b.UnmarshalText(text))
	require.Equal(t, a, b)

	for _, bad := range []string{"", "0x", "f39fd6e51aad88f6f4ce6ab8827279cfffb9226600", "0xf39fd6e51aad88f6f4ce6ab8827279cfffb922", "0xg39fd6e51aad88f6f4ce6ab8827279cfffb92266"} {
		_, err := ParseAddress(bad)
		require.Error(t, err, "%q", bad)
		require.Error(t, b.UnmarshalText([]byte(bad)))
	}
}
