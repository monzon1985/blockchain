// SPDX-License-Identifier: MIT

package devnet

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
)

// LoadSlotWriter reads the SlotWriter creation code from the Foundry artifact under
// fixturesDir (run `forge build` in fixtures/ first).
func LoadSlotWriter(fixturesDir string) ([]byte, error) {
	path := filepath.Join(fixturesDir, "out", "SlotWriter.sol", "SlotWriter.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("devnet: %w (run `forge build` in fixtures/)", err)
	}
	var art struct {
		Bytecode struct {
			Object string `json:"object"`
		} `json:"bytecode"`
	}
	if err := json.Unmarshal(raw, &art); err != nil {
		return nil, fmt.Errorf("devnet: %s: %w", path, err)
	}
	code, err := hex.DecodeString(strings.TrimPrefix(art.Bytecode.Object, "0x"))
	if err != nil || len(code) == 0 {
		return nil, fmt.Errorf("devnet: %s: no creation bytecode", path)
	}
	return code, nil
}

func selector(signature string) []byte {
	h := keccak.Sum256([]byte(signature))
	return h[:4]
}

func word(v uint64) []byte {
	var w keccak.Hash
	new(big.Int).SetUint64(v).FillBytes(w[:])
	return w[:]
}

// WriteCall is the calldata of SlotWriter.write(seed, count).
func WriteCall(seed, count uint64) []byte {
	return append(append(selector("write(uint256,uint256)"), word(seed)...), word(count)...)
}

// ClearCall is the calldata of SlotWriter.clear(seed, from, to).
func ClearCall(seed, from, to uint64) []byte {
	out := append(selector("clear(uint256,uint256,uint256)"), word(seed)...)
	return append(append(out, word(from)...), word(to)...)
}

// Slot is SlotWriter.slotOf(seed, i), computed off-chain: keccak256(abi.encode(seed, i)).
func Slot(seed, i uint64) keccak.Hash {
	return keccak.Sum256(word(seed), word(i))
}

// Value is SlotWriter.valueOf(slot, i), computed off-chain:
// keccak256(abi.encode(slot)) >> (8 * (i % 32)), or 1 if that is zero.
func Value(slot keccak.Hash, i uint64) keccak.Hash {
	h := keccak.Sum256(slot[:])
	shift := int(i % 32)
	var v keccak.Hash
	copy(v[shift:], h[:32-shift])
	if v.IsZero() {
		v[31] = 1
	}
	return v
}

// Batch returns the slots and values that write(seed, count) stores.
func Batch(seed, count uint64) map[keccak.Hash]keccak.Hash {
	out := make(map[keccak.Hash]keccak.Hash, count)
	for i := range count {
		s := Slot(seed, i)
		out[s] = Value(s, i)
	}
	return out
}
