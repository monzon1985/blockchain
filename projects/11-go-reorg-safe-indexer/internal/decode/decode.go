// SPDX-License-Identifier: MIT

// Package decode turns raw logs from watched contracts into typed records with the abigen v2
// bindings in internal/bindings.
//
// The bindings' Unpack*Event methods are lenient: they skip empty data, ignore the high bytes of
// address topics and accept trailing data. The indexer is stricter. It only accepts the exact
// canonical ABI encoding of each event (the only encoding a Solidity `emit` produces), which is
// the property FuzzDecodeLog checks: whatever decodes re-encodes to the identical log.
// Everything else stays in the raw log table and is counted as undecodable.
package decode

import (
	"errors"
	"fmt"
	"slices"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/bindings"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/model"
)

var (
	// ErrUnknownEvent means the log is not an event the indexer derives anything from
	// (Approval, OwnershipTransferred, ...). It is not an error condition.
	ErrUnknownEvent = errors.New("decode: not a tracked event")
	// ErrMalformed means the log carries a tracked event signature but not its canonical
	// encoding (for example an ERC-721 Transfer, whose tokenId is a fourth topic).
	ErrMalformed = errors.New("decode: malformed event encoding")
)

var (
	tokenABI = bindings.NewFixtureToken()
	vaultABI = bindings.NewFixtureVault()

	// TopicTransfer is keccak256("Transfer(address,address,uint256)").
	TopicTransfer = tokenABI.GetABI().Events["Transfer"].ID
	// TopicDeposit is keccak256("Deposit(address,address,uint256,uint256)").
	TopicDeposit = vaultABI.GetABI().Events["Deposit"].ID
	// TopicWithdraw is keccak256("Withdraw(address,address,address,uint256,uint256)").
	TopicWithdraw = vaultABI.GetABI().Events["Withdraw"].ID
)

// Contracts is the watched set: ERC-20 tokens, and ERC-4626 vaults with their asset. Vault
// shares and vault assets are ERC-20 tokens too and are indexed as such.
type Contracts struct {
	Tokens []common.Address
	Vaults map[common.Address]common.Address // vault -> asset
}

// Addresses returns every watched address (tokens, vaults and assets), deduplicated and sorted.
func (c Contracts) Addresses() []common.Address {
	seen := map[common.Address]bool{}
	var out []common.Address
	add := func(a common.Address) {
		if !seen[a] {
			seen[a] = true
			out = append(out, a)
		}
	}
	for _, t := range c.Tokens {
		add(t)
	}
	for v, a := range c.Vaults {
		add(v)
		add(a)
	}
	slices.SortFunc(out, func(a, b common.Address) int { return a.Cmp(b) })
	return out
}

// Decoder decodes logs of the watched contracts.
type Decoder struct {
	tokens map[common.Address]bool
	vaults map[common.Address]bool
}

// New builds a decoder for the watched set.
func New(c Contracts) *Decoder {
	d := &Decoder{tokens: map[common.Address]bool{}, vaults: map[common.Address]bool{}}
	for _, a := range c.Addresses() {
		d.tokens[a] = true
	}
	for v := range c.Vaults {
		d.vaults[v] = true
	}
	return d
}

// Decoded is the result of decoding one log: exactly one of Transfer and Vault is set.
type Decoded struct {
	Transfer *model.Transfer
	Vault    *model.VaultEvent
}

// Decode decodes one log. The block time is not part of a log and is filled by the caller.
func (d *Decoder) Decode(l *types.Log) (Decoded, error) {
	if len(l.Topics) == 0 {
		return Decoded{}, ErrUnknownEvent
	}
	switch l.Topics[0] {
	case TopicTransfer:
		if !d.tokens[l.Address] {
			return Decoded{}, ErrUnknownEvent
		}
		t, err := DecodeTransfer(l)
		if err != nil {
			return Decoded{}, err
		}
		return Decoded{Transfer: t}, nil
	case TopicDeposit, TopicWithdraw:
		if !d.vaults[l.Address] {
			return Decoded{}, ErrUnknownEvent
		}
		v, err := DecodeVaultEvent(l)
		if err != nil {
			return Decoded{}, err
		}
		return Decoded{Vault: v}, nil
	default:
		return Decoded{}, ErrUnknownEvent
	}
}

// DecodeTransfer decodes an ERC-20 Transfer(address indexed, address indexed, uint256).
func DecodeTransfer(l *types.Log) (*model.Transfer, error) {
	if err := canonical(l, TopicTransfer, 3, 1); err != nil {
		return nil, err
	}
	ev, err := tokenABI.UnpackTransferEvent(l)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrMalformed, err)
	}
	return &model.Transfer{
		Block:    blockRef(l),
		LogIndex: uint64(l.Index),
		TxHash:   l.TxHash,
		Token:    l.Address,
		From:     ev.From,
		To:       ev.To,
		Value:    model.NewAmount(ev.Value),
	}, nil
}

// DecodeVaultEvent decodes an ERC-4626 Deposit or Withdraw.
func DecodeVaultEvent(l *types.Log) (*model.VaultEvent, error) {
	if len(l.Topics) == 0 {
		return nil, ErrUnknownEvent
	}
	base := model.VaultEvent{
		Block:    blockRef(l),
		LogIndex: uint64(l.Index),
		TxHash:   l.TxHash,
		Vault:    l.Address,
	}
	switch l.Topics[0] {
	case TopicDeposit:
		if err := canonical(l, TopicDeposit, 3, 2); err != nil {
			return nil, err
		}
		ev, err := vaultABI.UnpackDepositEvent(l)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", ErrMalformed, err)
		}
		base.Kind = model.VaultDeposit
		base.Sender, base.Owner = ev.Sender, ev.Owner
		base.Assets, base.Shares = model.NewAmount(ev.Assets), model.NewAmount(ev.Shares)
	case TopicWithdraw:
		if err := canonical(l, TopicWithdraw, 4, 2); err != nil {
			return nil, err
		}
		ev, err := vaultABI.UnpackWithdrawEvent(l)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", ErrMalformed, err)
		}
		base.Kind = model.VaultWithdraw
		base.Sender, base.Receiver, base.Owner = ev.Sender, ev.Receiver, ev.Owner
		base.Assets, base.Shares = model.NewAmount(ev.Assets), model.NewAmount(ev.Shares)
	default:
		return nil, ErrUnknownEvent
	}
	return &base, nil
}

// canonical checks the exact shape Solidity emits: the signature topic, the number of topics,
// address topics left-padded with zeros, and exactly words*32 bytes of static data.
func canonical(l *types.Log, sig common.Hash, topics, words int) error {
	if len(l.Topics) == 0 || l.Topics[0] != sig {
		return ErrUnknownEvent
	}
	if len(l.Topics) != topics {
		return fmt.Errorf("%w: %d topics, want %d", ErrMalformed, len(l.Topics), topics)
	}
	for i, t := range l.Topics[1:] {
		if !isAddressWord(t) {
			return fmt.Errorf("%w: topic %d is not a left-padded address", ErrMalformed, i+1)
		}
	}
	if len(l.Data) != words*32 {
		return fmt.Errorf("%w: %d data bytes, want %d", ErrMalformed, len(l.Data), words*32)
	}
	return nil
}

func isAddressWord(w common.Hash) bool {
	for _, b := range w[:12] {
		if b != 0 {
			return false
		}
	}
	return true
}

func blockRef(l *types.Log) chain.BlockRef {
	return chain.BlockRef{Number: l.BlockNumber, Hash: l.BlockHash}
}
