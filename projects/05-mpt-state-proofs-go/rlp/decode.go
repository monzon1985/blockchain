// SPDX-License-Identifier: MIT

package rlp

import (
	"errors"
	"fmt"
	"math/big"
)

// Kind is the type of an RLP item.
type Kind uint8

const (
	// String is a byte array (including the single-byte form 0x00..0x7f).
	String Kind = iota
	// List is a sequence of items.
	List
)

// String implements fmt.Stringer.
func (k Kind) String() string {
	if k == List {
		return "list"
	}
	return "string"
}

// MaxDepth bounds list nesting in Decode, so that a short adversarial input such as
// 0xc1 0xc1 0xc1 ... cannot drive unbounded recursion. Ethereum's own structures nest a few
// levels deep; trie nodes with inline children nest at most 64 (one level per key nibble).
const MaxDepth = 1024

// Decoding errors. They are wrapped with the byte offset at which the problem was detected,
// so callers should compare with errors.Is.
var (
	ErrUnexpectedEnd    = errors.New("rlp: unexpected end of input")
	ErrNonCanonicalSize = errors.New("rlp: non-canonical size information")
	ErrNonCanonicalInt  = errors.New("rlp: non-canonical integer (leading zero bytes)")
	ErrTooLarge         = errors.New("rlp: declared length exceeds the remaining input")
	ErrTrailingData     = errors.New("rlp: trailing data after the top-level item")
	ErrUintOverflow     = errors.New("rlp: integer does not fit in the target type")
	ErrExpectedString   = errors.New("rlp: expected a string, found a list")
	ErrExpectedList     = errors.New("rlp: expected a list, found a string")
	ErrTooDeep          = errors.New("rlp: nesting deeper than MaxDepth")
)

// Split reads the header of the first item in b and returns its kind, its payload (content)
// and the bytes that follow it (rest). It rejects every non-canonical header: a single byte
// below 0x80 in a string header, a long-form length that would fit the short form, and a long
// length with leading zero bytes. Split does not look inside list payloads.
func Split(b []byte) (k Kind, content, rest []byte, err error) {
	if len(b) == 0 {
		return 0, nil, nil, ErrUnexpectedEnd
	}
	prefix := b[0]
	var (
		hdr  int    // header length in bytes
		size uint64 // payload length
	)
	switch {
	case prefix < shortString:
		return String, b[:1], b[1:], nil
	case prefix <= longString:
		k, hdr, size = String, 1, uint64(prefix-shortString)
	case prefix < shortList:
		k, hdr = String, 1+int(prefix-longString)
		if size, err = readLongSize(b, hdr); err != nil {
			return 0, nil, nil, err
		}
	case prefix <= longList:
		k, hdr, size = List, 1, uint64(prefix-shortList)
	default:
		k, hdr = List, 1+int(prefix-longList)
		if size, err = readLongSize(b, hdr); err != nil {
			return 0, nil, nil, err
		}
	}
	// hdr <= len(b) holds here: the short forms have hdr == 1 and readLongSize checked the
	// long forms. Comparing in uint64 avoids overflow for declared sizes near 2^64.
	if size > uint64(len(b)-hdr) {
		return 0, nil, nil, fmt.Errorf("%w: %d-byte payload, %d bytes left", ErrTooLarge, size, len(b)-hdr)
	}
	content, rest = b[hdr:hdr+int(size)], b[hdr+int(size):]
	if k == String && size == 1 && content[0] < shortString {
		return 0, nil, nil, fmt.Errorf("%w: byte 0x%02x must be encoded as itself", ErrNonCanonicalSize, content[0])
	}
	return k, content, rest, nil
}

// readLongSize decodes the big-endian length that follows a long-form header byte. hdr is the
// total header length (1 + number of length bytes, which is between 1 and 8).
func readLongSize(b []byte, hdr int) (uint64, error) {
	if len(b) < hdr {
		return 0, fmt.Errorf("%w: %d-byte header, %d bytes left", ErrUnexpectedEnd, hdr, len(b))
	}
	if b[1] == 0 {
		return 0, fmt.Errorf("%w: length has a leading zero byte", ErrNonCanonicalSize)
	}
	var size uint64
	for _, c := range b[1:hdr] {
		size = size<<8 | uint64(c)
	}
	if size <= maxShort {
		return 0, fmt.Errorf("%w: long form used for a %d-byte payload", ErrNonCanonicalSize, size)
	}
	return size, nil
}

// SplitString is Split for an item that must be a string.
func SplitString(b []byte) (content, rest []byte, err error) {
	k, content, rest, err := Split(b)
	if err != nil {
		return nil, nil, err
	}
	if k != String {
		return nil, nil, ErrExpectedString
	}
	return content, rest, nil
}

// SplitList is Split for an item that must be a list; content is the list payload.
func SplitList(b []byte) (content, rest []byte, err error) {
	k, content, rest, err := Split(b)
	if err != nil {
		return nil, nil, err
	}
	if k != List {
		return nil, nil, ErrExpectedList
	}
	return content, rest, nil
}

// SplitUint64 reads a canonical unsigned integer of at most 64 bits.
func SplitUint64(b []byte) (v uint64, rest []byte, err error) {
	content, rest, err := SplitString(b)
	if err != nil {
		return 0, nil, err
	}
	v, err = bytesToUint64(content)
	return v, rest, err
}

// CountValues returns the number of items in a list payload, validating each item header.
func CountValues(payload []byte) (int, error) {
	n := 0
	for len(payload) > 0 {
		_, _, rest, err := Split(payload)
		if err != nil {
			return 0, err
		}
		payload = rest
		n++
	}
	return n, nil
}

func bytesToUint64(b []byte) (uint64, error) {
	if len(b) > 8 {
		return 0, fmt.Errorf("%w: %d bytes for a 64-bit integer", ErrUintOverflow, len(b))
	}
	if len(b) > 0 && b[0] == 0 {
		return 0, ErrNonCanonicalInt
	}
	var v uint64
	for _, c := range b {
		v = v<<8 | uint64(c)
	}
	return v, nil
}

// Value is a decoded RLP item: a byte string or a list of items.
type Value struct {
	Kind  Kind
	Bytes []byte  // payload of a String
	Items []Value // elements of a List
}

// Str returns a String value.
func Str(b []byte) Value { return Value{Kind: String, Bytes: b} }

// Uint returns the String value encoding the unsigned integer v.
func Uint(v uint64) Value {
	enc := EncodeUint64(v)
	if len(enc) == 1 && enc[0] < shortString {
		return Str(enc)
	}
	return Str(enc[1:])
}

// ListOf returns a List value.
func ListOf(items ...Value) Value {
	if items == nil {
		items = []Value{}
	}
	return Value{Kind: List, Items: items}
}

// Decode parses b as exactly one RLP item and validates every nested header. It fails on
// non-canonical encodings, on trailing bytes and on nesting deeper than MaxDepth.
func Decode(b []byte) (Value, error) {
	v, rest, err := decode(b, 0, 0)
	if err != nil {
		return Value{}, err
	}
	if len(rest) > 0 {
		return Value{}, fmt.Errorf("%w: %d bytes at offset %d", ErrTrailingData, len(rest), len(b)-len(rest))
	}
	return v, nil
}

func decode(b []byte, depth, offset int) (Value, []byte, error) {
	k, content, rest, err := Split(b)
	if err != nil {
		return Value{}, nil, fmt.Errorf("at offset %d: %w", offset, err)
	}
	if k == String {
		return Str(content), rest, nil
	}
	if depth >= MaxDepth {
		return Value{}, nil, fmt.Errorf("at offset %d: %w", offset, ErrTooDeep)
	}
	items := []Value{}
	inner := offset + (len(b) - len(rest) - len(content)) // offset of the first payload byte
	for len(content) > 0 {
		var item Value
		before := len(content)
		item, content, err = decode(content, depth+1, inner)
		if err != nil {
			return Value{}, nil, err
		}
		inner += before - len(content)
		items = append(items, item)
	}
	return Value{Kind: List, Items: items}, rest, nil
}

// AppendTo appends the canonical encoding of v to dst.
func (v Value) AppendTo(dst []byte) []byte {
	if v.Kind == String {
		return AppendString(dst, v.Bytes)
	}
	items := make([][]byte, len(v.Items))
	for i, it := range v.Items {
		items[i] = it.AppendTo(nil)
	}
	return AppendList(dst, items...)
}

// Encode returns the canonical encoding of v.
func (v Value) Encode() []byte { return v.AppendTo(nil) }

// Uint64 interprets a String value as a canonical unsigned integer.
func (v Value) Uint64() (uint64, error) {
	if v.Kind != String {
		return 0, ErrExpectedString
	}
	return bytesToUint64(v.Bytes)
}

// Big interprets a String value as a canonical unsigned integer of any size.
func (v Value) Big() (*big.Int, error) {
	if v.Kind != String {
		return nil, ErrExpectedString
	}
	if len(v.Bytes) > 0 && v.Bytes[0] == 0 {
		return nil, ErrNonCanonicalInt
	}
	return new(big.Int).SetBytes(v.Bytes), nil
}

// Equal reports whether v and w are the same item.
func (v Value) Equal(w Value) bool {
	if v.Kind != w.Kind {
		return false
	}
	if v.Kind == String {
		return string(v.Bytes) == string(w.Bytes)
	}
	if len(v.Items) != len(w.Items) {
		return false
	}
	for i := range v.Items {
		if !v.Items[i].Equal(w.Items[i]) {
			return false
		}
	}
	return true
}
