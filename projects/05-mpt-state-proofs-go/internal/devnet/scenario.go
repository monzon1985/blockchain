// SPDX-License-Identifier: MIT

package devnet

import (
	"context"
	"fmt"
	"maps"
	"math/big"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
)

// Scenario parameters: the SlotWriter batch the integration tests and the CLI fixtures use.
const (
	ScenarioSeed    = 1
	ScenarioWrites  = 200 // slots written in block 2
	ScenarioCleared = 50  // slots 0..49 zeroed in block 3
	// GenesisTimestamp and BlockInterval make the recorded chain reproducible.
	GenesisTimestamp = 1_767_225_600 // 2026-01-01T00:00:00Z
	BlockInterval    = 12
)

// ScenarioResult describes the chain built by RunScenario.
type ScenarioResult struct {
	SlotWriter keccak.Address
	Sender     keccak.Address
	Recipient  keccak.Address
	// Storage is the expected non-zero storage of SlotWriter after each block, computed
	// off-chain from the seeds: Storage[n] is the state after block n.
	Storage map[uint64]map[keccak.Hash]keccak.Hash
	// TxTypes lists the envelope types sent in each block.
	TxTypes map[uint64][]uint8
	// Reverted is the hash of the transaction that fails on purpose (status 0).
	Reverted keccak.Hash
	Head     uint64
}

// RunScenario builds the standard chain on a fresh node:
//
//	block 1: deploy SlotWriter (type 2 when supported), a legacy transfer, an EIP-2930 transfer
//	block 2: write(1, 200): 200 slots and 200 logs in one receipt
//	block 3: clear(1, 0, 50), and write(1, 1000), which reverts (receipt status 0)
//
// dynamicFee must be false on pre-London chains, which reject type-2 transactions.
func RunScenario(ctx context.Context, n *Node, creationCode []byte, dynamicFee bool) (*ScenarioResult, error) {
	if len(n.Accounts) < 2 {
		return nil, fmt.Errorf("devnet: need 2 accounts, have %d", len(n.Accounts))
	}
	res := &ScenarioResult{
		Sender:    n.Accounts[0],
		Recipient: n.Accounts[1],
		Storage:   map[uint64]map[keccak.Hash]keccak.Hash{},
		TxTypes:   map[uint64][]uint8{},
	}
	var genesisTime string
	var head struct {
		Timestamp string `json:"timestamp"`
	}
	if err := n.Call(ctx, &head, "eth_getBlockByNumber", "0x0", false); err != nil {
		return nil, err
	}
	genesisTime = head.Timestamp
	ts, ok := new(big.Int).SetString(genesisTime[2:], 16)
	if !ok {
		return nil, fmt.Errorf("devnet: genesis timestamp %q", genesisTime)
	}
	nextTime := ts.Uint64()
	mine := func(block uint64) error {
		nextTime += BlockInterval
		got, err := n.Mine(ctx, nextTime)
		if err != nil {
			return err
		}
		if got != block {
			return fmt.Errorf("devnet: mined block %d, expected %d", got, block)
		}
		return nil
	}
	deployType := uint8(2)
	if !dynamicFee {
		deployType = 0
	}

	// Block 1.
	deploy, err := n.Send(ctx, Tx{From: res.Sender, Data: creationCode, Gas: 1_000_000, Type: deployType})
	if err != nil {
		return nil, err
	}
	if _, err := n.Send(ctx, Tx{From: res.Sender, To: &res.Recipient, Value: big.NewInt(1e18), Gas: 21_000, Type: 0}); err != nil {
		return nil, err
	}
	al := []AccessTuple{{Address: res.Recipient, StorageKeys: []keccak.Hash{{31: 1}}}}
	if _, err := n.Send(ctx, Tx{From: res.Recipient, To: &res.Sender, Value: big.NewInt(12345), Gas: 30_000, Type: 1, AccessList: al}); err != nil {
		return nil, err
	}
	if err := mine(1); err != nil {
		return nil, err
	}
	res.TxTypes[1] = []uint8{deployType, 0, 1}
	r, err := n.Receipt(ctx, deploy)
	if err != nil {
		return nil, err
	}
	if r.Status != "0x1" || r.ContractAddress == nil {
		return nil, fmt.Errorf("devnet: SlotWriter deployment failed: %+v", r)
	}
	res.SlotWriter = *r.ContractAddress
	res.Storage[1] = map[keccak.Hash]keccak.Hash{}

	// Block 2.
	callType := deployType
	write, err := n.Send(ctx, Tx{From: res.Sender, To: &res.SlotWriter, Data: WriteCall(ScenarioSeed, ScenarioWrites), Gas: 12_000_000, Type: callType})
	if err != nil {
		return nil, err
	}
	if err := mine(2); err != nil {
		return nil, err
	}
	if r, err := n.Receipt(ctx, write); err != nil || r.Status != "0x1" {
		return nil, fmt.Errorf("devnet: write failed: %v %+v", err, r)
	}
	res.TxTypes[2] = []uint8{callType}
	res.Storage[2] = Batch(ScenarioSeed, ScenarioWrites)

	// Block 3.
	clear, err := n.Send(ctx, Tx{From: res.Sender, To: &res.SlotWriter, Data: ClearCall(ScenarioSeed, 0, ScenarioCleared), Gas: 3_000_000, Type: callType})
	if err != nil {
		return nil, err
	}
	res.Reverted, err = n.Send(ctx, Tx{From: res.Recipient, To: &res.SlotWriter, Data: WriteCall(ScenarioSeed, 1000), Gas: 100_000, Type: 0})
	if err != nil {
		return nil, err
	}
	if err := mine(3); err != nil {
		return nil, err
	}
	if r, err := n.Receipt(ctx, clear); err != nil || r.Status != "0x1" {
		return nil, fmt.Errorf("devnet: clear failed: %v %+v", err, r)
	}
	if r, err := n.Receipt(ctx, res.Reverted); err != nil || r.Status != "0x0" {
		return nil, fmt.Errorf("devnet: the oversized write should revert: %v %+v", err, r)
	}
	res.TxTypes[3] = []uint8{callType, 0}
	after := maps.Clone(res.Storage[2])
	for i := range uint64(ScenarioCleared) {
		delete(after, Slot(ScenarioSeed, i))
	}
	res.Storage[3] = after
	res.Head = 3
	return res, nil
}
