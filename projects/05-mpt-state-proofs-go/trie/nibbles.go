// SPDX-License-Identifier: MIT

package trie

import (
	"errors"
	"fmt"
)

// ErrHexPrefix is returned by HexPrefixDecode for an invalid hex-prefix encoding.
var ErrHexPrefix = errors.New("trie: invalid hex-prefix encoding")

// KeyToNibbles splits each byte of key into its high and low 4-bit halves.
func KeyToNibbles(key []byte) []byte {
	out := make([]byte, 2*len(key))
	for i, b := range key {
		out[2*i] = b >> 4
		out[2*i+1] = b & 0x0f
	}
	return out
}

// NibblesToKey is the inverse of KeyToNibbles; it fails on an odd number of nibbles or on a
// value above 0x0f.
func NibblesToKey(nibbles []byte) ([]byte, error) {
	if len(nibbles)%2 != 0 {
		return nil, fmt.Errorf("trie: %d nibbles do not form whole bytes", len(nibbles))
	}
	out := make([]byte, len(nibbles)/2)
	for i := range out {
		hi, lo := nibbles[2*i], nibbles[2*i+1]
		if hi > 0x0f || lo > 0x0f {
			return nil, fmt.Errorf("trie: nibble out of range at %d", 2*i)
		}
		out[i] = hi<<4 | lo
	}
	return out, nil
}

// HexPrefixEncode packs a nibble path into bytes (Yellow Paper, Appendix C). The high nibble
// of the first byte is a flag: bit 1 marks a leaf, bit 0 an odd path length. An odd path
// stores its first nibble in the low half of the flag byte; an even path pads it with zero.
//
//	flag 0: extension, even    flag 1: extension, odd
//	flag 2: leaf, even         flag 3: leaf, odd
func HexPrefixEncode(nibbles []byte, leaf bool) []byte {
	var flag byte
	if leaf {
		flag = 2
	}
	out := make([]byte, len(nibbles)/2+1)
	i := 0
	if len(nibbles)%2 == 1 {
		flag |= 1
		out[0] = nibbles[0]
		i = 1
	}
	out[0] |= flag << 4
	for j := 1; i < len(nibbles); i, j = i+2, j+1 {
		out[j] = nibbles[i]<<4 | nibbles[i+1]
	}
	return out
}

// HexPrefixDecode is the inverse of HexPrefixEncode. It rejects empty input, flags above 3
// and a non-zero padding nibble, so every accepted input has exactly one decoding.
func HexPrefixDecode(b []byte) (nibbles []byte, leaf bool, err error) {
	if len(b) == 0 {
		return nil, false, fmt.Errorf("%w: empty", ErrHexPrefix)
	}
	flag := b[0] >> 4
	if flag > 3 {
		return nil, false, fmt.Errorf("%w: flag nibble %d", ErrHexPrefix, flag)
	}
	leaf = flag&2 != 0
	odd := flag&1 != 0
	if !odd && b[0]&0x0f != 0 {
		return nil, false, fmt.Errorf("%w: non-zero padding nibble", ErrHexPrefix)
	}
	n := 2 * (len(b) - 1)
	if odd {
		n++
	}
	nibbles = make([]byte, 0, n)
	if odd {
		nibbles = append(nibbles, b[0]&0x0f)
	}
	for _, c := range b[1:] {
		nibbles = append(nibbles, c>>4, c&0x0f)
	}
	return nibbles, leaf, nil
}

// commonPrefixLen returns the length of the longest common prefix of a and b.
func commonPrefixLen(a, b []byte) int {
	n := min(len(a), len(b))
	for i := range n {
		if a[i] != b[i] {
			return i
		}
	}
	return n
}

// hasPrefix reports whether path starts with prefix.
func hasPrefix(path, prefix []byte) bool {
	return len(path) >= len(prefix) && commonPrefixLen(path, prefix) == len(prefix)
}

// concat returns a new slice holding a followed by b; it never aliases either argument.
func concat(a, b []byte) []byte {
	out := make([]byte, 0, len(a)+len(b))
	return append(append(out, a...), b...)
}
