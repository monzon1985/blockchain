// SPDX-License-Identifier: MIT

// Package model holds the indexer's domain records. The same structs are rows in the store,
// JSON bodies in the REST API and payloads of the SSE stream, so a consumer can undo a
// `retract` event with exactly the object it received earlier.
package model

import (
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
)

// Amount is an arbitrary-precision integer that marshals to a JSON decimal string, since
// uint256 values do not survive JSON numbers in most clients.
type Amount big.Int

// NewAmount copies x into a new Amount.
func NewAmount(x *big.Int) *Amount { return (*Amount)(new(big.Int).Set(x)) }

// Big returns a copy of the value as a *big.Int.
func (a *Amount) Big() *big.Int {
	if a == nil {
		return new(big.Int)
	}
	return new(big.Int).Set((*big.Int)(a))
}

// String renders the value in base 10.
func (a *Amount) String() string {
	if a == nil {
		return "0"
	}
	return (*big.Int)(a).String()
}

// MarshalText implements encoding.TextMarshaler (JSON string).
func (a *Amount) MarshalText() ([]byte, error) { return []byte(a.String()), nil }

// UnmarshalText implements encoding.TextUnmarshaler.
func (a *Amount) UnmarshalText(b []byte) error {
	x, ok := new(big.Int).SetString(string(b), 10)
	if !ok {
		return fmt.Errorf("model: invalid decimal amount %q", b)
	}
	*a = Amount(*x)
	return nil
}

// Log is a raw log emitted by a watched contract, keyed by (BlockHash, LogIndex).
type Log struct {
	Block    chain.BlockRef `json:"block"`
	LogIndex uint64         `json:"logIndex"`
	TxHash   common.Hash    `json:"txHash"`
	TxIndex  uint64         `json:"txIndex"`
	Address  common.Address `json:"address"`
	Topics   []common.Hash  `json:"topics"`
	Data     []byte         `json:"data"`
}

// Transfer is a decoded ERC-20 Transfer, keyed by (Block.Hash, LogIndex).
type Transfer struct {
	Block     chain.BlockRef `json:"block"`
	BlockTime uint64         `json:"blockTime"`
	LogIndex  uint64         `json:"logIndex"`
	TxHash    common.Hash    `json:"txHash"`
	Token     common.Address `json:"token"`
	From      common.Address `json:"from"`
	To        common.Address `json:"to"`
	Value     *Amount        `json:"value"`
}

// Vault event kinds.
const (
	VaultDeposit  = "deposit"
	VaultWithdraw = "withdraw"
)

// VaultEvent is a decoded ERC-4626 Deposit or Withdraw, keyed by (Block.Hash, LogIndex).
// Receiver is the zero address for deposits (the event has no receiver field).
type VaultEvent struct {
	Block     chain.BlockRef `json:"block"`
	BlockTime uint64         `json:"blockTime"`
	LogIndex  uint64         `json:"logIndex"`
	TxHash    common.Hash    `json:"txHash"`
	Vault     common.Address `json:"vault"`
	Kind      string         `json:"kind"`
	Sender    common.Address `json:"sender"`
	Owner     common.Address `json:"owner"`
	Receiver  common.Address `json:"receiver"`
	Assets    *Amount        `json:"assets"`
	Shares    *Amount        `json:"shares"`
}

// SharePrice is a vault's state at the end of a block in which its total assets or total
// supply changed, keyed by (Block.Hash, Vault). PriceWad is floor(totalAssets * 1e18 /
// totalSupply) in raw base units, nil while the supply is zero.
type SharePrice struct {
	Block       chain.BlockRef `json:"block"`
	BlockTime   uint64         `json:"blockTime"`
	Vault       common.Address `json:"vault"`
	TotalAssets *Amount        `json:"totalAssets"`
	TotalSupply *Amount        `json:"totalSupply"`
	PriceWad    *Amount        `json:"priceWad"`
}

// Wad is 1e18, the fixed-point scale of SharePrice.PriceWad.
var Wad = new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)

// ComputePriceWad returns floor(assets * 1e18 / supply), or nil when supply is zero.
func ComputePriceWad(assets, supply *big.Int) *Amount {
	if supply.Sign() == 0 {
		return nil
	}
	p := new(big.Int).Mul(assets, Wad)
	return (*Amount)(p.Quo(p, supply))
}

// Balance is a holder's balance of a token. Rows with a zero balance do not exist.
type Balance struct {
	Token   common.Address `json:"token"`
	Holder  common.Address `json:"holder"`
	Balance *Amount        `json:"balance"`
}

// Reorg records one rollback: the stored tip it replaced, the common ancestor it rolled back
// to (nil when the fork went below the first indexed block) and how many blocks it orphaned.
type Reorg struct {
	DetectedAt int64           `json:"detectedAt"`
	OldTip     chain.BlockRef  `json:"oldTip"`
	Ancestor   *chain.BlockRef `json:"ancestor"`
	NewHead    chain.BlockRef  `json:"newHead"`
	Depth      uint64          `json:"depth"`
}

// Checkpoint is the indexer's durable progress marker, written in the same transaction as the
// data it describes.
type Checkpoint struct {
	// Tip is the last indexed block, nil when nothing is indexed.
	Tip *chain.BlockRef `json:"tip"`
	// ChainHead is the node head seen by the last sync, for lag reporting.
	ChainHead uint64 `json:"chainHead"`
	// UpdatedAt is the wall-clock time (unix ms) of the last write.
	UpdatedAt int64 `json:"updatedAt"`
}

// Event is one entry of the transactional outbox behind the SSE stream.
type Event struct {
	Seq         uint64 `json:"seq"`
	Kind        string `json:"kind"`
	BlockNumber uint64 `json:"blockNumber"`
	Payload     []byte `json:"-"`
}

// Stream event kinds.
const (
	EventTransfer   = "transfer"
	EventVault      = "vault_event"
	EventSharePrice = "share_price"
	EventRetract    = "retract"
	EventReorg      = "reorg"
)

// Retraction is the payload of a `retract` event: the kind of record that was removed by a
// reorg and the record itself, exactly as it was published.
type Retraction struct {
	Type string `json:"type"`
	Item any    `json:"item"`
}
