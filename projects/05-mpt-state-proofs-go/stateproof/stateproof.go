// SPDX-License-Identifier: MIT

// Package stateproof verifies Ethereum state proofs: an account proof against a block's
// stateRoot, storage proofs against the proven account's storageRoot, and whole eth_getProof
// responses, whose plain-text claims (balance, nonce, codeHash, storageHash, slot values) are
// compared with what the proofs establish. It also rebuilds a storage root from slot values.
//
// The chain of trust is: block hash -> header -> stateRoot -> account (keyed by
// keccak(address)) -> storageRoot -> slot value (keyed by keccak(slot)).
package stateproof

import (
	"errors"
	"fmt"
	"math/big"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/rlp"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/trie"
)

// ErrInvalidAccount is returned for an account leaf that is not a canonical account encoding.
var ErrInvalidAccount = errors.New("stateproof: invalid account encoding")

// ErrInvalidStorageValue is returned for a storage leaf that is not a canonical slot value.
var ErrInvalidStorageValue = errors.New("stateproof: invalid storage value encoding")

// Account is the state of an account: the value stored under keccak(address) in the state trie.
type Account struct {
	Nonce       uint64
	Balance     *big.Int
	StorageRoot keccak.Hash
	CodeHash    keccak.Hash
}

// Encode returns RLP([nonce, balance, storageRoot, codeHash]).
func (a Account) Encode() ([]byte, error) {
	balance, err := rlp.EncodeBig(a.Balance)
	if err != nil {
		return nil, fmt.Errorf("%w: balance: %w", ErrInvalidAccount, err)
	}
	return rlp.EncodeList(rlp.EncodeUint64(a.Nonce), balance, rlp.EncodeString(a.StorageRoot[:]), rlp.EncodeString(a.CodeHash[:])), nil
}

// DecodeAccount parses an account leaf strictly: exactly four items, canonical integers and
// 32-byte hashes, nothing trailing.
func DecodeAccount(enc []byte) (Account, error) {
	v, err := rlp.Decode(enc)
	if err != nil {
		return Account{}, fmt.Errorf("%w: %w", ErrInvalidAccount, err)
	}
	if v.Kind != rlp.List || len(v.Items) != 4 {
		return Account{}, fmt.Errorf("%w: want a list of 4 items", ErrInvalidAccount)
	}
	var a Account
	if a.Nonce, err = v.Items[0].Uint64(); err != nil {
		return Account{}, fmt.Errorf("%w: nonce: %w", ErrInvalidAccount, err)
	}
	if a.Balance, err = v.Items[1].Big(); err != nil {
		return Account{}, fmt.Errorf("%w: balance: %w", ErrInvalidAccount, err)
	}
	for i, dst := range []*keccak.Hash{&a.StorageRoot, &a.CodeHash} {
		it := v.Items[2+i]
		if it.Kind != rlp.String || len(it.Bytes) != 32 {
			return Account{}, fmt.Errorf("%w: item %d must be a 32-byte hash", ErrInvalidAccount, 2+i)
		}
		copy(dst[:], it.Bytes)
	}
	return a, nil
}

// VerifyAccount verifies an account proof against a state root. It returns nil (and no
// error) when the proof shows that no account exists at addr.
func VerifyAccount(stateRoot keccak.Hash, addr keccak.Address, proof [][]byte) (*Account, []trie.Step, error) {
	res, err := trie.VerifyProofTrace(stateRoot, hashed(addr[:]), proof)
	if err != nil {
		return nil, nil, err
	}
	if !res.Exists() {
		return nil, res.Steps, nil
	}
	a, err := DecodeAccount(res.Value)
	if err != nil {
		return nil, nil, err
	}
	return &a, res.Steps, nil
}

// VerifyStorage verifies a storage proof against a storage root and returns the slot's value
// as a 32-byte word (all zeros for a slot proven absent, which is how zero is stored).
func VerifyStorage(storageRoot keccak.Hash, slot keccak.Hash, proof [][]byte) (keccak.Hash, []trie.Step, error) {
	res, err := trie.VerifyProofTrace(storageRoot, hashed(slot[:]), proof)
	if err != nil {
		return keccak.Hash{}, nil, err
	}
	if !res.Exists() {
		return keccak.Hash{}, res.Steps, nil
	}
	v, err := DecodeStorageValue(res.Value)
	if err != nil {
		return keccak.Hash{}, nil, err
	}
	return v, res.Steps, nil
}

func hashed(b []byte) []byte {
	h := keccak.Sum256(b)
	return h[:]
}

// EncodeStorageValue returns the storage-trie leaf for a slot value: the RLP string of the
// value without leading zero bytes. A zero value has no leaf (nil): zero slots are deleted.
func EncodeStorageValue(v keccak.Hash) []byte {
	i := 0
	for i < len(v) && v[i] == 0 {
		i++
	}
	if i == len(v) {
		return nil
	}
	return rlp.EncodeString(v[i:])
}

// DecodeStorageValue parses a storage leaf strictly: an RLP string of 1 to 32 bytes without
// a leading zero byte.
func DecodeStorageValue(enc []byte) (keccak.Hash, error) {
	content, rest, err := rlp.SplitString(enc)
	if err != nil {
		return keccak.Hash{}, fmt.Errorf("%w: %w", ErrInvalidStorageValue, err)
	}
	switch {
	case len(rest) > 0:
		return keccak.Hash{}, fmt.Errorf("%w: trailing bytes", ErrInvalidStorageValue)
	case len(content) == 0 || len(content) > 32:
		return keccak.Hash{}, fmt.Errorf("%w: %d-byte value", ErrInvalidStorageValue, len(content))
	case content[0] == 0:
		return keccak.Hash{}, fmt.Errorf("%w: leading zero byte", ErrInvalidStorageValue)
	}
	var v keccak.Hash
	copy(v[32-len(content):], content)
	return v, nil
}

// StorageTrie builds a contract's storage trie from slot values; zero values are skipped.
func StorageTrie(slots map[keccak.Hash]keccak.Hash) *trie.SecureTrie {
	t := trie.NewSecure()
	for slot, value := range slots {
		if enc := EncodeStorageValue(value); enc != nil {
			t.Put(slot[:], enc)
		}
	}
	return t
}

// StorageRoot returns the storage root of a contract whose non-zero slots are exactly slots.
func StorageRoot(slots map[keccak.Hash]keccak.Hash) keccak.Hash { return StorageTrie(slots).Hash() }
