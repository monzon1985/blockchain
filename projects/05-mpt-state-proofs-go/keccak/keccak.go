// SPDX-License-Identifier: MIT

// Package keccak provides the Keccak-256 hash used everywhere in Ethereum's data structures
// (the original Keccak padding, not the NIST SHA3-256 padding), the 32-byte Hash type the
// other packages of this module exchange, and the 20-byte Address derived from such hashes.
package keccak

import (
	"encoding/hex"
	"fmt"

	"golang.org/x/crypto/sha3"
)

// Hash is a 32-byte Keccak-256 digest: a trie root, a node reference or a block hash.
type Hash [32]byte

var (
	// EmptyRoot is the root of a trie with no entries: Keccak-256(RLP("")) = Keccak-256(0x80).
	EmptyRoot = MustParse("0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421")

	// EmptyCode is the code hash of an account without code: Keccak-256 of the empty string.
	EmptyCode = MustParse("0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")

	// EmptyList is Keccak-256(RLP([])) = Keccak-256(0xc0), the ommers hash of a block without
	// ommers (every block since the Merge).
	EmptyList = MustParse("0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347")
)

// Sum256 returns the Keccak-256 digest of the concatenation of its arguments.
func Sum256(data ...[]byte) Hash {
	h := sha3.NewLegacyKeccak256()
	for _, d := range data {
		h.Write(d) // hash.Hash.Write never returns an error.
	}
	var out Hash
	h.Sum(out[:0])
	return out
}

// Hex returns the 0x-prefixed lowercase hexadecimal form of h.
func (h Hash) Hex() string { return "0x" + hex.EncodeToString(h[:]) }

// String implements fmt.Stringer with the same output as Hex.
func (h Hash) String() string { return h.Hex() }

// IsZero reports whether every byte of h is zero.
func (h Hash) IsZero() bool { return h == Hash{} }

// Parse decodes a 0x-prefixed, 64-hex-digit string into a Hash.
func Parse(s string) (Hash, error) {
	var h Hash
	if len(s) != 66 || s[0] != '0' || (s[1] != 'x' && s[1] != 'X') {
		return h, fmt.Errorf("keccak: hash %q must be 0x followed by 64 hex digits", s)
	}
	if _, err := hex.Decode(h[:], []byte(s[2:])); err != nil {
		return h, fmt.Errorf("keccak: hash %q: %w", s, err)
	}
	return h, nil
}

// MustParse is Parse for compile-time constants; it panics on malformed input.
func MustParse(s string) Hash {
	h, err := Parse(s)
	if err != nil {
		panic(err)
	}
	return h
}

// MarshalText implements encoding.TextMarshaler (0x-prefixed hex, as in JSON-RPC).
func (h Hash) MarshalText() ([]byte, error) { return []byte(h.Hex()), nil }

// UnmarshalText implements encoding.TextUnmarshaler with the rules of Parse.
func (h *Hash) UnmarshalText(text []byte) error {
	v, err := Parse(string(text))
	if err != nil {
		return err
	}
	*h = v
	return nil
}

// Address is a 20-byte Ethereum account address: the low 20 bytes of the Keccak-256 hash of
// a public key (externally owned accounts) or of the creator and nonce (contracts).
type Address [20]byte

// Hex returns the 0x-prefixed lowercase hexadecimal form of a (no EIP-55 checksum).
func (a Address) Hex() string { return "0x" + hex.EncodeToString(a[:]) }

// String implements fmt.Stringer with the same output as Hex.
func (a Address) String() string { return a.Hex() }

// ParseAddress decodes a 0x-prefixed, 40-hex-digit string. The checksum case is not checked.
func ParseAddress(s string) (Address, error) {
	var a Address
	if len(s) != 42 || s[0] != '0' || (s[1] != 'x' && s[1] != 'X') {
		return a, fmt.Errorf("keccak: address %q must be 0x followed by 40 hex digits", s)
	}
	if _, err := hex.Decode(a[:], []byte(s[2:])); err != nil {
		return a, fmt.Errorf("keccak: address %q: %w", s, err)
	}
	return a, nil
}

// MarshalText implements encoding.TextMarshaler.
func (a Address) MarshalText() ([]byte, error) { return []byte(a.Hex()), nil }

// UnmarshalText implements encoding.TextUnmarshaler with the rules of ParseAddress.
func (a *Address) UnmarshalText(text []byte) error {
	v, err := ParseAddress(string(text))
	if err != nil {
		return err
	}
	*a = v
	return nil
}
