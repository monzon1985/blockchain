// SPDX-License-Identifier: MIT

package stateproof

import (
	"fmt"
	"math/big"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/trie"
)

// GetProofResult is an eth_getProof response (EIP-1186): the proofs plus the values the node
// claims they prove.
type GetProofResult struct {
	Address      keccak.Address
	AccountProof [][]byte
	Balance      *big.Int
	CodeHash     keccak.Hash
	Nonce        uint64
	StorageHash  keccak.Hash
	StorageProof []StorageResult
}

// StorageResult is one slot of an eth_getProof response.
type StorageResult struct {
	Key   keccak.Hash // the slot, left-padded to 32 bytes
	Value *big.Int
	Proof [][]byte
}

// Outcome is what an eth_getProof response proves.
type Outcome struct {
	// Account is the proven account, or nil if the proof shows the address has no account.
	Account      *Account
	AccountSteps []trie.Step
	Slots        []SlotOutcome
	// Mismatches lists every claim in the response that the proofs contradict. A response
	// with mismatches carries valid proofs but must not be trusted.
	Mismatches []string
}

// SlotOutcome is the proven value of one requested slot.
type SlotOutcome struct {
	Key    keccak.Hash
	Value  keccak.Hash // proven value (zero for an absent slot)
	Exists bool
	Steps  []trie.Step
}

// OK reports whether the response's claims all match its proofs.
func (o *Outcome) OK() bool { return len(o.Mismatches) == 0 }

// CheckGetProof verifies every proof in r against stateRoot and compares the response's
// claims with the proven values. An error means a proof is invalid (forged, truncated or
// malformed); a valid proof whose claims disagree is reported in Outcome.Mismatches.
//
// For an address without an account the claims must be the zero account: nonce 0, balance
// 0, and a code hash and storage hash that are either zero (go-ethereum's convention) or the
// empty code hash and empty trie root (the hashes of an empty account).
//
// The proofs are checked for the address and slots the response names (r.Address and the
// keys in r.StorageProof). The caller must check that these are the ones it asked for, as
// the inspect package does: a valid proof of another account verifies here.
func CheckGetProof(stateRoot keccak.Hash, r *GetProofResult) (*Outcome, error) {
	acct, steps, err := VerifyAccount(stateRoot, r.Address, r.AccountProof)
	if err != nil {
		return nil, fmt.Errorf("account proof for %s: %w", r.Address, err)
	}
	out := &Outcome{Account: acct, AccountSteps: steps}
	mismatch := func(format string, args ...any) {
		out.Mismatches = append(out.Mismatches, fmt.Sprintf(format, args...))
	}

	storageRoot := keccak.EmptyRoot
	balance := r.Balance
	if balance == nil {
		balance = new(big.Int)
	}
	if acct != nil {
		storageRoot = acct.StorageRoot
		if r.Nonce != acct.Nonce {
			mismatch("nonce: claimed %d, proven %d", r.Nonce, acct.Nonce)
		}
		if balance.Cmp(acct.Balance) != 0 {
			mismatch("balance: claimed %s, proven %s", balance, acct.Balance)
		}
		if r.CodeHash != acct.CodeHash {
			mismatch("codeHash: claimed %s, proven %s", r.CodeHash, acct.CodeHash)
		}
		if r.StorageHash != acct.StorageRoot {
			mismatch("storageHash: claimed %s, proven %s", r.StorageHash, acct.StorageRoot)
		}
	} else {
		if r.Nonce != 0 || balance.Sign() != 0 {
			mismatch("absent account claimed nonce %d and balance %s", r.Nonce, balance)
		}
		if !r.CodeHash.IsZero() && r.CodeHash != keccak.EmptyCode {
			mismatch("absent account claimed codeHash %s", r.CodeHash)
		}
		if !r.StorageHash.IsZero() && r.StorageHash != keccak.EmptyRoot {
			mismatch("absent account claimed storageHash %s", r.StorageHash)
		}
	}

	for _, s := range r.StorageProof {
		value, steps, err := VerifyStorage(storageRoot, s.Key, s.Proof)
		if err != nil {
			return nil, fmt.Errorf("storage proof for slot %s: %w", s.Key, err)
		}
		proven := new(big.Int).SetBytes(value[:])
		out.Slots = append(out.Slots, SlotOutcome{Key: s.Key, Value: value, Exists: proven.Sign() != 0, Steps: steps})
		claimed := s.Value
		if claimed == nil {
			claimed = new(big.Int)
		}
		if claimed.Cmp(proven) != 0 {
			mismatch("slot %s: claimed %#x, proven %#x", s.Key, claimed, proven)
		}
	}
	return out, nil
}
