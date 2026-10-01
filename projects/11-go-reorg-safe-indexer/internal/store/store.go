// SPDX-License-Identifier: MIT

// Package store defines the indexer's storage contract. Backends (internal/store/sqlite and
// internal/store/postgres) implement a small set of transactional primitives; all domain logic
// (balance deltas, share prices, rollback reversal, the SSE outbox) lives above them in
// internal/indexer and is therefore identical on every backend.
package store

import (
	"context"
	"errors"
	"math/big"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/model"
)

// ErrTipConflict means a write transaction expected a different stored tip than the one in the
// database: another writer moved it. The transaction is rolled back.
var ErrTipConflict = errors.New("store: checkpoint tip changed concurrently")

// Store is a transactional database of indexed data.
type Store interface {
	// Update runs fn in a read-write transaction and commits it if fn returns nil.
	Update(ctx context.Context, fn func(Tx) error) error
	// View runs fn in a read-only transaction that sees one consistent snapshot.
	View(ctx context.Context, fn func(Reader) error) error
	// Ping checks that the database answers.
	Ping(ctx context.Context) error
	// Backend names the implementation ("sqlite" or "postgres").
	Backend() string
	// Close releases the database.
	Close() error
}

// Position is a keyset-pagination position: (block number, log index).
type Position struct {
	Block    uint64
	LogIndex uint64
}

// TransferFilter selects transfers. Nil pointers mean "no constraint".
type TransferFilter struct {
	Token     *common.Address
	Address   *common.Address // matches From or To
	From      *common.Address
	To        *common.Address
	FromBlock *uint64
	ToBlock   *uint64
	After     *Position
	Limit     int
}

// VaultEventFilter selects the events of one vault.
type VaultEventFilter struct {
	Vault     common.Address
	FromBlock *uint64
	ToBlock   *uint64
	After     *Position
	Limit     int
}

// SharePriceFilter selects the share-price history of one vault. After is a block number.
type SharePriceFilter struct {
	Vault     common.Address
	FromBlock *uint64
	ToBlock   *uint64
	After     *uint64
	Limit     int
}

// BalanceFilter lists the holders of one token in address order, or (with Holders set) the
// given holders only.
type BalanceFilter struct {
	Token   common.Address
	After   *common.Address
	Holders []common.Address
	Limit   int
}

// Deleted counts the rows removed by Tx.DeleteFrom.
type Deleted struct {
	Blocks, Logs, Transfers, VaultEvents, SharePrices int64
}

// Reader is the read side of a transaction. Methods use the transaction's context.
type Reader interface {
	// Meta returns a metadata value.
	Meta(key string) (string, bool, error)
	// Checkpoint returns the progress marker (Tip nil when nothing is indexed).
	Checkpoint() (model.Checkpoint, error)
	// RecentBlocks returns up to limit of the highest stored headers, ascending.
	RecentBlocks(limit int) ([]chain.Header, error)
	// BlockCount returns the number of stored headers.
	BlockCount() (int64, error)
	// Balance returns a balance (zero when the row does not exist).
	Balance(token, holder common.Address) (*big.Int, error)
	// Supply returns a token's supply as derived from mints and burns.
	Supply(token common.Address) (*big.Int, error)
	// TransfersFrom returns every transfer at block >= from, in (block, logIndex) order.
	TransfersFrom(from uint64) ([]model.Transfer, error)
	// VaultEventsFrom returns every vault event at block >= from, in (block, logIndex) order.
	VaultEventsFrom(from uint64) ([]model.VaultEvent, error)
	// SharePricesFrom returns every share-price point at block >= from, in (block, vault) order.
	SharePricesFrom(from uint64) ([]model.SharePrice, error)
	// Transfers lists transfers matching f in (block, logIndex) order, at most f.Limit rows.
	Transfers(f TransferFilter) ([]model.Transfer, error)
	// VaultEvents lists vault events matching f in (block, logIndex) order.
	VaultEvents(f VaultEventFilter) ([]model.VaultEvent, error)
	// SharePrices lists share-price points matching f in block order.
	SharePrices(f SharePriceFilter) ([]model.SharePrice, error)
	// Balances lists non-zero balances matching f in holder order.
	Balances(f BalanceFilter) ([]model.Balance, error)
	// HolderBalances lists every non-zero balance of one holder, in token order.
	HolderBalances(holder common.Address) ([]model.Balance, error)
	// EventsAfter returns up to limit outbox events with seq > after, ascending.
	EventsAfter(after uint64, limit int) ([]model.Event, error)
	// EventBounds returns the lowest retained and the highest assigned outbox sequence numbers
	// (0, 0 when the outbox has never been written).
	EventBounds() (oldest, newest uint64, err error)
	// LastReorg returns the most recent recorded reorg, if any.
	LastReorg() (*model.Reorg, bool, error)
	// ReorgCount returns the number of recorded reorgs.
	ReorgCount() (int64, error)
	// Snapshot dumps the canonical-chain data in a backend-independent form.
	Snapshot() (*Snapshot, error)
}

// Tx is a read-write transaction.
type Tx interface {
	Reader
	// PutMeta sets a metadata value.
	PutMeta(key, value string) error
	// MoveTip compare-and-swaps the checkpoint tip: it fails with ErrTipConflict unless the
	// stored tip equals expected (nil meaning "nothing indexed").
	MoveTip(expected, next *chain.BlockRef, chainHead uint64, now int64) error
	// Heartbeat records the node head without moving the tip.
	Heartbeat(chainHead uint64, now int64) error
	// InsertBlock stores a header.
	InsertBlock(h chain.Header) error
	// InsertLog stores a raw log; false means the (blockHash, logIndex) key already existed.
	InsertLog(l model.Log) (bool, error)
	// InsertTransfer stores a transfer; false means the key already existed.
	InsertTransfer(t model.Transfer) (bool, error)
	// InsertVaultEvent stores a vault event; false means the key already existed.
	InsertVaultEvent(v model.VaultEvent) (bool, error)
	// InsertSharePrice upserts a share-price point keyed by (blockHash, vault).
	InsertSharePrice(p model.SharePrice) error
	// SetBalance writes a balance; a zero value deletes the row.
	SetBalance(token, holder common.Address, v *big.Int) error
	// SetSupply writes a supply; a zero value deletes the row.
	SetSupply(token common.Address, v *big.Int) error
	// AppendEvent appends to the outbox and returns the assigned sequence number.
	AppendEvent(kind string, block uint64, payload []byte) (uint64, error)
	// DeleteFrom removes blocks, logs and derived rows at block >= from.
	DeleteFrom(from uint64) (Deleted, error)
	// PruneBlocksBelow drops stored headers with number < n (their data stays).
	PruneBlocksBelow(n uint64) error
	// PruneEventsBelow drops outbox events with seq < n.
	PruneEventsBelow(n uint64) error
	// InsertReorg records a reorg.
	InsertReorg(r model.Reorg) error
}
