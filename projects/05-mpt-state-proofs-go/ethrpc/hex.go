// SPDX-License-Identifier: MIT

package ethrpc

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
)

// ErrBadHex is returned for a JSON value that is not valid Ethereum JSON-RPC hex.
var ErrBadHex = errors.New("ethrpc: invalid hex value")

func jsonString(raw json.RawMessage) (string, error) {
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return "", fmt.Errorf("%w: %s is not a JSON string", ErrBadHex, truncate(raw))
	}
	return s, nil
}

func truncate(raw []byte) string {
	if len(raw) > 40 {
		return string(raw[:40]) + "..."
	}
	return string(raw)
}

// parseData decodes unformatted data: "0x" followed by an even number of hex digits.
func parseData(s string) ([]byte, error) {
	if !strings.HasPrefix(s, "0x") {
		return nil, fmt.Errorf("%w: %q lacks the 0x prefix", ErrBadHex, s)
	}
	b, err := hex.DecodeString(s[2:])
	if err != nil {
		return nil, fmt.Errorf("%w: %q: %w", ErrBadHex, s, err)
	}
	return b, nil
}

// parseQuantity decodes a quantity: "0x" followed by hex digits without leading zeros
// ("0x0" for zero), as the JSON-RPC specification requires.
func parseQuantity(s string) (*big.Int, error) {
	if !strings.HasPrefix(s, "0x") || len(s) == 2 {
		return nil, fmt.Errorf("%w: quantity %q", ErrBadHex, s)
	}
	digits := s[2:]
	if len(digits) > 1 && digits[0] == '0' {
		return nil, fmt.Errorf("%w: quantity %q has leading zeros", ErrBadHex, s)
	}
	if len(digits) > 64 {
		return nil, fmt.Errorf("%w: quantity %q exceeds 256 bits", ErrBadHex, s)
	}
	v, ok := new(big.Int).SetString(digits, 16)
	if !ok {
		return nil, fmt.Errorf("%w: quantity %q", ErrBadHex, s)
	}
	return v, nil
}

func parseUint64(s string) (uint64, error) {
	v, err := parseQuantity(s)
	if err != nil {
		return 0, err
	}
	if !v.IsUint64() {
		return 0, fmt.Errorf("%w: quantity %q exceeds 64 bits", ErrBadHex, s)
	}
	return v.Uint64(), nil
}

func parseFixed(s string, n int) ([]byte, error) {
	b, err := parseData(s)
	if err != nil {
		return nil, err
	}
	if len(b) != n {
		return nil, fmt.Errorf("%w: %q has %d bytes, want %d", ErrBadHex, s, len(b), n)
	}
	return b, nil
}

func parseHash(s string) (keccak.Hash, error) {
	b, err := parseFixed(s, 32)
	if err != nil {
		return keccak.Hash{}, err
	}
	return keccak.Hash(b), nil
}

func parseAddress(s string) (keccak.Address, error) {
	b, err := parseFixed(s, 20)
	if err != nil {
		return keccak.Address{}, err
	}
	return keccak.Address(b), nil
}

// parseSlot decodes a storage key as eth_getProof echoes it: hex of up to 32 bytes, which
// nodes print either as a 32-byte word or as a quantity ("0x0"). It is left-padded.
func parseSlot(s string) (keccak.Hash, error) {
	if !strings.HasPrefix(s, "0x") {
		return keccak.Hash{}, fmt.Errorf("%w: slot %q lacks the 0x prefix", ErrBadHex, s)
	}
	digits := s[2:]
	if len(digits) > 64 || len(digits) == 0 {
		return keccak.Hash{}, fmt.Errorf("%w: slot %q", ErrBadHex, s)
	}
	b, err := hex.DecodeString(strings.Repeat("0", 64-len(digits)) + digits)
	if err != nil {
		return keccak.Hash{}, fmt.Errorf("%w: slot %q: %w", ErrBadHex, s, err)
	}
	return keccak.Hash(b), nil
}

// ParseSlot parses a user-supplied storage slot: decimal, or 0x-prefixed hex of up to 32
// bytes, left-padded to a 32-byte word.
func ParseSlot(s string) (keccak.Hash, error) {
	if strings.HasPrefix(s, "0x") || strings.HasPrefix(s, "0X") {
		return parseSlot("0x" + s[2:])
	}
	v, ok := new(big.Int).SetString(s, 10)
	if !ok || v.Sign() < 0 || v.BitLen() > 256 {
		return keccak.Hash{}, fmt.Errorf("ethrpc: slot %q is neither a decimal nor a 0x-prefixed number below 2^256", s)
	}
	var h keccak.Hash
	v.FillBytes(h[:])
	return h, nil
}

// fields is a JSON object decoded one member at a time, collecting the first error.
type fields struct {
	m   map[string]json.RawMessage
	err error
}

func newFields(raw json.RawMessage) (*fields, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("ethrpc: expected a JSON object: %w", err)
	}
	if m == nil {
		return nil, errors.New("ethrpc: expected a JSON object, got null")
	}
	return &fields{m: m}, nil
}

// has reports whether name is present and not null.
func (f *fields) has(name string) bool {
	raw, ok := f.m[name]
	return ok && string(raw) != "null"
}

func (f *fields) str(name string) string {
	if f.err != nil {
		return ""
	}
	raw, ok := f.m[name]
	if !ok || string(raw) == "null" {
		f.err = fmt.Errorf("ethrpc: missing field %q", name)
		return ""
	}
	s, err := jsonString(raw)
	if err != nil {
		f.err = fmt.Errorf("field %q: %w", name, err)
	}
	return s
}

func (f *fields) wrap(name string, err error) {
	if err != nil && f.err == nil {
		f.err = fmt.Errorf("field %q: %w", name, err)
	}
}

func (f *fields) hash(name string) keccak.Hash {
	s := f.str(name)
	if f.err != nil {
		return keccak.Hash{}
	}
	h, err := parseHash(s)
	f.wrap(name, err)
	return h
}

func (f *fields) address(name string) keccak.Address {
	s := f.str(name)
	if f.err != nil {
		return keccak.Address{}
	}
	a, err := parseAddress(s)
	f.wrap(name, err)
	return a
}

func (f *fields) uint64(name string) uint64 {
	s := f.str(name)
	if f.err != nil {
		return 0
	}
	v, err := parseUint64(s)
	f.wrap(name, err)
	return v
}

func (f *fields) big(name string) *big.Int {
	s := f.str(name)
	if f.err != nil {
		return nil
	}
	v, err := parseQuantity(s)
	f.wrap(name, err)
	return v
}

func (f *fields) data(name string) []byte {
	s := f.str(name)
	if f.err != nil {
		return nil
	}
	b, err := parseData(s)
	f.wrap(name, err)
	return b
}

func (f *fields) fixed(name string, n int) []byte {
	s := f.str(name)
	if f.err != nil {
		return nil
	}
	b, err := parseFixed(s, n)
	f.wrap(name, err)
	return b
}

func (f *fields) optHash(name string) *keccak.Hash {
	if !f.has(name) {
		return nil
	}
	h := f.hash(name)
	return &h
}

func (f *fields) optUint64(name string) *uint64 {
	if !f.has(name) {
		return nil
	}
	v := f.uint64(name)
	return &v
}

func (f *fields) array(name string) []json.RawMessage {
	if f.err != nil {
		return nil
	}
	raw, ok := f.m[name]
	if !ok || string(raw) == "null" {
		f.err = fmt.Errorf("ethrpc: missing field %q", name)
		return nil
	}
	var out []json.RawMessage
	if err := json.Unmarshal(raw, &out); err != nil {
		f.err = fmt.Errorf("field %q: expected an array: %w", name, err)
	}
	return out
}

func (f *fields) stringArray(name string) []string {
	items := f.array(name)
	out := make([]string, len(items))
	for i, it := range items {
		s, err := jsonString(it)
		if err != nil {
			f.wrap(fmt.Sprintf("%s[%d]", name, i), err)
			return nil
		}
		out[i] = s
	}
	return out
}
