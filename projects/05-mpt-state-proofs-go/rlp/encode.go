// SPDX-License-Identifier: MIT

package rlp

import (
	"errors"
	"math/big"
	"math/bits"
)

// ErrNegativeBig is returned when a negative integer is encoded: RLP integers are unsigned.
var ErrNegativeBig = errors.New("rlp: cannot encode a negative integer")

// Header bases of the four item forms (Yellow Paper, Appendix B).
const (
	shortString = 0x80 // 0x80..0xb7: string of 0..55 bytes, length in the header byte
	longString  = 0xb7 // 0xb8..0xbf: string of >55 bytes, 1..8 length bytes follow
	shortList   = 0xc0 // 0xc0..0xf7: list with a 0..55-byte payload
	longList    = 0xf7 // 0xf8..0xff: list with a >55-byte payload, 1..8 length bytes follow
	maxShort    = 55   // the largest payload length that fits in the header byte
)

// appendHeader appends the header of an item whose payload is size bytes long. base is
// shortString or shortList.
func appendHeader(dst []byte, base byte, size uint64) []byte {
	if size <= maxShort {
		return append(dst, base+byte(size))
	}
	n := byteLen(size)
	// base+maxShort+n is 0xb8..0xbf for strings and 0xf8..0xff for lists.
	dst = append(dst, base+maxShort+byte(n))
	return appendBigEndian(dst, size, n)
}

// byteLen returns the number of bytes in the minimal big-endian form of v (0 for v == 0).
func byteLen(v uint64) int { return (bits.Len64(v) + 7) / 8 }

// appendBigEndian appends the n low-order bytes of v, most significant first.
func appendBigEndian(dst []byte, v uint64, n int) []byte {
	for i := n - 1; i >= 0; i-- {
		dst = append(dst, byte(v>>(8*uint(i))))
	}
	return dst
}

// AppendString appends the encoding of the byte string b to dst. A single byte below 0x80 is
// its own encoding; anything else gets a string header.
func AppendString(dst, b []byte) []byte {
	if len(b) == 1 && b[0] < shortString {
		return append(dst, b[0])
	}
	dst = appendHeader(dst, shortString, uint64(len(b)))
	return append(dst, b...)
}

// AppendUint64 appends the encoding of the unsigned integer v: its minimal big-endian bytes
// as a string, so 0 encodes as the empty string 0x80.
func AppendUint64(dst []byte, v uint64) []byte {
	switch {
	case v == 0:
		return append(dst, shortString)
	case v < shortString:
		return append(dst, byte(v))
	default:
		n := byteLen(v)
		dst = append(dst, shortString+byte(n))
		return appendBigEndian(dst, v, n)
	}
}

// AppendBig appends the encoding of the non-negative integer v. A nil v encodes as 0.
func AppendBig(dst []byte, v *big.Int) ([]byte, error) {
	if v == nil {
		return append(dst, shortString), nil
	}
	if v.Sign() < 0 {
		return dst, ErrNegativeBig
	}
	if v.IsUint64() {
		return AppendUint64(dst, v.Uint64()), nil
	}
	return AppendString(dst, v.Bytes()), nil // big.Int.Bytes is minimal big-endian.
}

// AppendList appends a list whose payload is the concatenation of already-encoded items.
func AppendList(dst []byte, items ...[]byte) []byte {
	size := 0
	for _, it := range items {
		size += len(it)
	}
	dst = appendHeader(dst, shortList, uint64(size))
	for _, it := range items {
		dst = append(dst, it...)
	}
	return dst
}

// AppendListPayload wraps an already-concatenated list payload in a list header.
func AppendListPayload(dst, payload []byte) []byte {
	dst = appendHeader(dst, shortList, uint64(len(payload)))
	return append(dst, payload...)
}

// EncodeString returns the encoding of the byte string b.
func EncodeString(b []byte) []byte { return AppendString(make([]byte, 0, len(b)+9), b) }

// EncodeUint64 returns the encoding of the unsigned integer v.
func EncodeUint64(v uint64) []byte { return AppendUint64(make([]byte, 0, 9), v) }

// EncodeBig returns the encoding of the non-negative integer v.
func EncodeBig(v *big.Int) ([]byte, error) { return AppendBig(nil, v) }

// EncodeList returns a list whose payload is the concatenation of already-encoded items.
func EncodeList(items ...[]byte) []byte {
	size := 0
	for _, it := range items {
		size += len(it)
	}
	return AppendList(make([]byte, 0, size+9), items...)
}

// ListSize returns the total encoded size of a list whose payload is size bytes long.
func ListSize(size int) int {
	if size <= maxShort {
		return 1 + size
	}
	return 1 + byteLen(uint64(size)) + size
}
