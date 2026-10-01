// SPDX-License-Identifier: MIT

package rlp

import (
	"bytes"
	"errors"
	"math"
	"math/big"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestEncodeBoundaries(t *testing.T) {
	long55 := bytes.Repeat([]byte{0xaa}, 55)
	long56 := bytes.Repeat([]byte{0xaa}, 56)
	long256 := bytes.Repeat([]byte{0xaa}, 256)
	cases := []struct {
		name string
		got  []byte
		want []byte
	}{
		{"empty string", EncodeString(nil), []byte{0x80}},
		{"byte 0x00 is itself", EncodeString([]byte{0x00}), []byte{0x00}},
		{"byte 0x7f is itself", EncodeString([]byte{0x7f}), []byte{0x7f}},
		{"byte 0x80 gets a header", EncodeString([]byte{0x80}), []byte{0x81, 0x80}},
		{"55-byte string, short form", EncodeString(long55), append([]byte{0xb7}, long55...)},
		{"56-byte string, long form", EncodeString(long56), append([]byte{0xb8, 56}, long56...)},
		{"256-byte string, 2 length bytes", EncodeString(long256), append([]byte{0xb9, 0x01, 0x00}, long256...)},
		{"uint 0", EncodeUint64(0), []byte{0x80}},
		{"uint 1", EncodeUint64(1), []byte{0x01}},
		{"uint 0x7f", EncodeUint64(0x7f), []byte{0x7f}},
		{"uint 0x80", EncodeUint64(0x80), []byte{0x81, 0x80}},
		{"uint 0x0400", EncodeUint64(0x0400), []byte{0x82, 0x04, 0x00}},
		{"uint max", EncodeUint64(math.MaxUint64), []byte{0x88, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}},
		{"empty list", EncodeList(), []byte{0xc0}},
		{"list of empties", EncodeList(EncodeString(nil), EncodeList()), []byte{0xc2, 0x80, 0xc0}},
		{"56-byte list payload, long form", EncodeList(EncodeString(long55)), append([]byte{0xf8, 56, 0xb7}, long55...)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			require.Equal(t, tc.want, tc.got)
		})
	}
}

func TestEncodeBig(t *testing.T) {
	enc, err := EncodeBig(nil)
	require.NoError(t, err)
	require.Equal(t, []byte{0x80}, enc, "nil is zero")

	enc, err = EncodeBig(big.NewInt(0x7f))
	require.NoError(t, err)
	require.Equal(t, []byte{0x7f}, enc)

	two256 := new(big.Int).Lsh(big.NewInt(1), 256)
	enc, err = EncodeBig(two256)
	require.NoError(t, err)
	require.Equal(t, append([]byte{0xa1, 0x01}, make([]byte, 32)...), enc)

	_, err = EncodeBig(big.NewInt(-1))
	require.ErrorIs(t, err, ErrNegativeBig)

	v, err := Str(two256.Bytes()).Big()
	require.NoError(t, err)
	require.Zero(t, v.Cmp(two256))
}

func TestListHelpers(t *testing.T) {
	payload := append(EncodeString([]byte("dog")), EncodeUint64(1024)...)
	require.Equal(t, EncodeList(EncodeString([]byte("dog")), EncodeUint64(1024)), AppendListPayload(nil, payload))
	require.Equal(t, len(EncodeList(payload)), ListSize(len(payload)))
	long := bytes.Repeat([]byte{1}, 300)
	require.Equal(t, len(AppendListPayload(nil, long)), ListSize(len(long)))

	n, err := CountValues(payload)
	require.NoError(t, err)
	require.Equal(t, 2, n)
	_, err = CountValues([]byte{0x83, 'd'})
	require.ErrorIs(t, err, ErrTooLarge)
}

func TestSplitRejectsNonCanonical(t *testing.T) {
	cases := []struct {
		name string
		in   []byte
		want error
	}{
		{"empty input", nil, ErrUnexpectedEnd},
		{"single byte wrapped as string", []byte{0x81, 0x05}, ErrNonCanonicalSize},
		{"single byte 0x7f wrapped as string", []byte{0x81, 0x7f}, ErrNonCanonicalSize},
		{"long string form for 5 bytes", append([]byte{0xb8, 0x05}, "hello"...), ErrNonCanonicalSize},
		{"long string form for 55 bytes", append([]byte{0xb8, 55}, make([]byte, 55)...), ErrNonCanonicalSize},
		{"long string length with leading zero", append([]byte{0xb9, 0x00, 0x40}, make([]byte, 64)...), ErrNonCanonicalSize},
		{"long list form for short payload", []byte{0xf8, 0x01, 0x80}, ErrNonCanonicalSize},
		{"long list length with leading zero", append([]byte{0xf9, 0x00, 0x40}, make([]byte, 64)...), ErrNonCanonicalSize},
		{"short string past the end", []byte{0x83, 'd', 'o'}, ErrTooLarge},
		{"short list past the end", []byte{0xc3, 0x80, 0x80}, ErrTooLarge},
		{"missing long length bytes", []byte{0xba, 0x01}, ErrUnexpectedEnd},
		{"long length near 2^64", []byte{0xbf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00}, ErrTooLarge},
		{"long list length near 2^64", []byte{0xff, 0x80, 0, 0, 0, 0, 0, 0, 0}, ErrTooLarge},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, _, _, err := Split(tc.in)
			require.ErrorIs(t, err, tc.want)
			_, err = Decode(tc.in)
			require.ErrorIs(t, err, tc.want)
		})
	}
}

func TestSplitAccepts(t *testing.T) {
	k, content, rest, err := Split([]byte{0x05, 0xff})
	require.NoError(t, err)
	require.Equal(t, String, k)
	require.Equal(t, []byte{0x05}, content)
	require.Equal(t, []byte{0xff}, rest)

	k, content, rest, err = Split([]byte{0x81, 0x80})
	require.NoError(t, err)
	require.Equal(t, String, k)
	require.Equal(t, []byte{0x80}, content)
	require.Empty(t, rest)

	k, content, _, err = Split([]byte{0xc2, 0x01, 0x02})
	require.NoError(t, err)
	require.Equal(t, List, k)
	require.Equal(t, []byte{0x01, 0x02}, content)
	require.Equal(t, "list", k.String())
	require.Equal(t, "string", String.String())
}

func TestSplitTyped(t *testing.T) {
	_, _, err := SplitString([]byte{0xc0})
	require.ErrorIs(t, err, ErrExpectedString)
	_, _, err = SplitList([]byte{0x80})
	require.ErrorIs(t, err, ErrExpectedList)
	_, _, err = SplitString(nil)
	require.ErrorIs(t, err, ErrUnexpectedEnd)
	_, _, err = SplitList(nil)
	require.ErrorIs(t, err, ErrUnexpectedEnd)

	content, rest, err := SplitList([]byte{0xc1, 0x80, 0x01})
	require.NoError(t, err)
	require.Equal(t, []byte{0x80}, content)
	require.Equal(t, []byte{0x01}, rest)
}

func TestIntegers(t *testing.T) {
	cases := []struct {
		name string
		in   []byte
		want uint64
		err  error
	}{
		{"zero", []byte{0x80}, 0, nil},
		{"one", []byte{0x01}, 1, nil},
		{"0x80", []byte{0x81, 0x80}, 0x80, nil},
		{"max uint64", []byte{0x88, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, math.MaxUint64, nil},
		{"zero as byte 0x00", []byte{0x00}, 0, ErrNonCanonicalInt},
		{"leading zero", []byte{0x82, 0x00, 0x80}, 0, ErrNonCanonicalInt},
		{"nine bytes", []byte{0x89, 0x01, 0, 0, 0, 0, 0, 0, 0, 0}, 0, ErrUintOverflow},
		{"a list", []byte{0xc0}, 0, ErrExpectedString},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, rest, err := SplitUint64(tc.in)
			if tc.err != nil {
				require.ErrorIs(t, err, tc.err)
				return
			}
			require.NoError(t, err)
			require.Empty(t, rest)
			require.Equal(t, tc.want, got)
			v, err := Decode(tc.in)
			require.NoError(t, err)
			got, err = v.Uint64()
			require.NoError(t, err)
			require.Equal(t, tc.want, got)
		})
	}

	_, err := ListOf().Uint64()
	require.ErrorIs(t, err, ErrExpectedString)
	_, err = ListOf().Big()
	require.ErrorIs(t, err, ErrExpectedString)
	_, err = Str([]byte{0x00, 0x01}).Big()
	require.ErrorIs(t, err, ErrNonCanonicalInt)
}

func TestUintValue(t *testing.T) {
	for _, v := range []uint64{0, 1, 0x7f, 0x80, 0xffff, math.MaxUint64} {
		val := Uint(v)
		require.Equal(t, EncodeUint64(v), val.Encode(), "%d", v)
		got, err := val.Uint64()
		require.NoError(t, err)
		require.Equal(t, v, got)
	}
}

func TestDecodeTree(t *testing.T) {
	// ["cat", ["dog", ""], 1024]
	enc := EncodeList(
		EncodeString([]byte("cat")),
		EncodeList(EncodeString([]byte("dog")), EncodeString(nil)),
		EncodeUint64(1024),
	)
	v, err := Decode(enc)
	require.NoError(t, err)
	want := ListOf(Str([]byte("cat")), ListOf(Str([]byte("dog")), Str(nil)), Uint(1024))
	require.True(t, v.Equal(want))
	require.False(t, v.Equal(ListOf()))
	require.False(t, v.Equal(Str(nil)))
	require.False(t, v.Items[0].Equal(Str([]byte("cap"))))
	require.False(t, v.Equal(ListOf(Str([]byte("cat")), ListOf(Str([]byte("dog")), Str(nil)), Uint(1025))))
	require.Equal(t, enc, v.Encode())
}

func TestDecodeErrors(t *testing.T) {
	_, err := Decode([]byte{0x80, 0x80})
	require.ErrorIs(t, err, ErrTrailingData)

	// A nested error reports the offset of the offending item.
	_, err = Decode([]byte{0xc4, 0x80, 0xc2, 0x81, 0x05})
	require.ErrorIs(t, err, ErrNonCanonicalSize)
	require.Contains(t, err.Error(), "offset 3")

	deep := bytes.Repeat([]byte{0xc0}, 1)
	for range MaxDepth + 1 {
		deep = AppendListPayload(nil, deep)
	}
	_, err = Decode(deep)
	require.ErrorIs(t, err, ErrTooDeep)

	ok := bytes.Repeat([]byte{0xc0}, 1)
	for range MaxDepth - 1 {
		ok = AppendListPayload(nil, ok)
	}
	_, err = Decode(ok)
	require.NoError(t, err, "MaxDepth nested lists are accepted")
}

func TestErrorsAreDistinct(t *testing.T) {
	all := []error{ErrUnexpectedEnd, ErrNonCanonicalSize, ErrNonCanonicalInt, ErrTooLarge, ErrTrailingData, ErrUintOverflow, ErrExpectedString, ErrExpectedList, ErrTooDeep, ErrNegativeBig}
	for i, a := range all {
		for j, b := range all {
			require.Equal(t, i == j, errors.Is(a, b))
		}
	}
}
