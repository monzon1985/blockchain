// SPDX-License-Identifier: MIT

// Package fakechain is an in-memory EVM chain for tests: blocks with logs, reorgs of any depth,
// rollbacks, and a real go-ethereum JSON-RPC server in front of it. Tests can use it directly
// as a chain.Source, or over HTTP through the production RPCSource (optionally behind the
// rpcfault transport), which exercises the whole client stack without anvil.
package fakechain

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"net/http"
	"sync"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/rpc"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
)

// GenesisTime is the timestamp of block 0; every block adds BlockTime seconds.
const (
	GenesisTime = 1_700_000_000
	BlockTime   = 2
)

// LogSpec describes one log to include in a mined block. Logs with the same Tx share a
// transaction hash; transaction indexes are the Tx values.
type LogSpec struct {
	Tx      uint
	Address common.Address
	Topics  []common.Hash
	Data    []byte
}

// Block is a mined block.
type Block struct {
	Header chain.Header
	Logs   []types.Log
}

// Chain is the fake chain. It is safe for concurrent use.
type Chain struct {
	mu      sync.RWMutex
	chainID uint64
	canon   []*Block
	byHash  map[common.Hash]*Block
	fork    uint64
	forget  bool
}

var _ chain.Source = (*Chain)(nil)

// New returns a chain containing only an empty genesis block.
func New(chainID uint64) *Chain {
	c := &Chain{chainID: chainID, byHash: map[common.Hash]*Block{}}
	c.appendBlock(nil)
	return c
}

// ForgetOrphans makes the chain drop reorged-out blocks from its hash index, as nodes eventually
// do, so by-hash lookups of orphans fail.
func (c *Chain) ForgetOrphans(on bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.forget = on
}

// appendBlock mines one canonical block on top of the current head. Callers hold mu.
func (c *Chain) appendBlock(specs []LogSpec) *Block {
	var parent chain.Header
	number := uint64(len(c.canon))
	if number > 0 {
		parent = c.canon[number-1].Header
	}
	// The hash commits to the parent, the number, the fork counter and the log contents, so
	// replacement blocks on a new fork never collide with the blocks they replace.
	seed := make([]byte, 0, 64+len(specs)*96)
	seed = append(seed, parent.Hash[:]...)
	seed = binary.BigEndian.AppendUint64(seed, number)
	seed = binary.BigEndian.AppendUint64(seed, c.fork)
	for _, s := range specs {
		seed = append(seed, s.Address[:]...)
		for _, t := range s.Topics {
			seed = append(seed, t[:]...)
		}
		seed = append(seed, s.Data...)
		seed = binary.BigEndian.AppendUint64(seed, uint64(s.Tx))
	}
	h := chain.Header{
		Number:     number,
		Hash:       crypto.Keccak256Hash(seed),
		ParentHash: parent.Hash,
		Time:       GenesisTime + number*BlockTime,
	}
	b := &Block{}
	for i, s := range specs {
		txHash := crypto.Keccak256Hash(h.Hash[:], binary.BigEndian.AppendUint64(nil, uint64(s.Tx)))
		l := types.Log{
			Address:        s.Address,
			Topics:         append([]common.Hash{}, s.Topics...),
			Data:           append([]byte{}, s.Data...),
			BlockNumber:    number,
			TxHash:         txHash,
			TxIndex:        s.Tx,
			BlockHash:      h.Hash,
			BlockTimestamp: h.Time,
			Index:          uint(i),
		}
		if l.Data == nil {
			l.Data = []byte{}
		}
		h.Bloom.Add(l.Address.Bytes())
		for _, t := range l.Topics {
			h.Bloom.Add(t.Bytes())
		}
		b.Logs = append(b.Logs, l)
	}
	b.Header = h
	c.canon = append(c.canon, b)
	c.byHash[h.Hash] = b
	return b
}

// Mine appends one block per argument (nil for an empty block) and returns the new head.
func (c *Chain) Mine(blocks ...[]LogSpec) chain.Header {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(blocks) == 0 {
		blocks = [][]LogSpec{nil}
	}
	for _, specs := range blocks {
		c.appendBlock(specs)
	}
	return c.canon[len(c.canon)-1].Header
}

// Reorg replaces the last depth blocks with len(blocks) new ones (which may be fewer, equal or
// more). Genesis cannot be replaced.
func (c *Chain) Reorg(depth int, blocks [][]LogSpec) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if depth < 0 || depth >= len(c.canon) {
		return fmt.Errorf("fakechain: reorg depth %d with head %d", depth, len(c.canon)-1)
	}
	for _, b := range c.canon[len(c.canon)-depth:] {
		if c.forget {
			delete(c.byHash, b.Header.Hash)
		}
	}
	c.canon = c.canon[:len(c.canon)-depth]
	c.fork++
	for _, specs := range blocks {
		c.appendBlock(specs)
	}
	return nil
}

// Head returns the current head header.
func (c *Chain) Head() chain.Header {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.canon[len(c.canon)-1].Header
}

// Canonical returns the canonical blocks from number from to the head.
func (c *Chain) Canonical(from uint64) []*Block {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if from >= uint64(len(c.canon)) {
		return nil
	}
	return append([]*Block(nil), c.canon[from:]...)
}

// ChainID implements chain.Source.
func (c *Chain) ChainID(context.Context) (uint64, error) { return c.chainID, nil }

// LatestHeader implements chain.Source.
func (c *Chain) LatestHeader(context.Context) (chain.Header, error) { return c.Head(), nil }

// HeaderByNumber implements chain.Source.
func (c *Chain) HeaderByNumber(_ context.Context, n uint64) (chain.Header, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if n >= uint64(len(c.canon)) {
		return chain.Header{}, chain.ErrNotFound
	}
	return c.canon[n].Header, nil
}

// HeaderByHash implements chain.Source.
func (c *Chain) HeaderByHash(_ context.Context, h common.Hash) (chain.Header, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	b, ok := c.byHash[h]
	if !ok {
		return chain.Header{}, chain.ErrNotFound
	}
	return b.Header, nil
}

// HeadersByRange implements chain.Source.
func (c *Chain) HeadersByRange(_ context.Context, from, to uint64) ([]chain.Header, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if to < from {
		return nil, fmt.Errorf("fakechain: empty range %d..%d", from, to)
	}
	if to >= uint64(len(c.canon)) {
		return nil, chain.ErrNotFound
	}
	out := make([]chain.Header, 0, to-from+1)
	for n := from; n <= to; n++ {
		out = append(out, c.canon[n].Header)
	}
	return out, nil
}

// errUnknownBlock mimics geth's answer for a block-hash filter on an unknown block.
var errUnknownBlock = errors.New("unknown block")

// Logs implements chain.Source.
func (c *Chain) Logs(_ context.Context, q chain.LogQuery) ([]types.Log, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	want := map[common.Address]bool{}
	for _, a := range q.Addresses {
		want[a] = true
	}
	match := func(b *Block, out []types.Log) []types.Log {
		for _, l := range b.Logs {
			if len(want) == 0 || want[l.Address] {
				cp := l
				cp.Topics = append([]common.Hash(nil), l.Topics...)
				cp.Data = append([]byte{}, l.Data...)
				out = append(out, cp)
			}
		}
		return out
	}
	if q.BlockHash != nil {
		b, ok := c.byHash[*q.BlockHash]
		if !ok {
			return nil, errUnknownBlock
		}
		return match(b, []types.Log{}), nil
	}
	if q.To < q.From {
		return nil, fmt.Errorf("invalid block range params %d..%d", q.From, q.To)
	}
	out := []types.Log{}
	for n := q.From; n <= q.To && n < uint64(len(c.canon)); n++ {
		out = match(c.canon[n], out)
	}
	return out, nil
}

// BlockLogs implements chain.Source (every log of the block, unfiltered, like receipts).
func (c *Chain) BlockLogs(ctx context.Context, hash common.Hash) ([]types.Log, error) {
	return c.Logs(ctx, chain.LogQuery{BlockHash: &hash})
}

// --- JSON-RPC ---------------------------------------------------------------------------------

type ethService struct{ c *Chain }

// ChainId serves eth_chainId.
func (s *ethService) ChainId() hexutil.Uint64 { return hexutil.Uint64(s.c.chainID) }

// BlockNumber serves eth_blockNumber.
func (s *ethService) BlockNumber() hexutil.Uint64 { return hexutil.Uint64(s.c.Head().Number) }

// GetBlockByNumber serves eth_getBlockByNumber (headers only).
func (s *ethService) GetBlockByNumber(ctx context.Context, n rpc.BlockNumber, _ bool) (map[string]any, error) {
	var num uint64
	switch {
	case n == rpc.EarliestBlockNumber:
		num = 0
	case n < 0:
		num = s.c.Head().Number
	default:
		num = uint64(n)
	}
	h, err := s.c.HeaderByNumber(ctx, num)
	if errors.Is(err, chain.ErrNotFound) {
		return nil, nil
	}
	return chain.MarshalHeader(h), err
}

// GetBlockByHash serves eth_getBlockByHash (headers only).
func (s *ethService) GetBlockByHash(ctx context.Context, hash common.Hash, _ bool) (map[string]any, error) {
	h, err := s.c.HeaderByHash(ctx, hash)
	if errors.Is(err, chain.ErrNotFound) {
		return nil, nil
	}
	return chain.MarshalHeader(h), err
}

type filterArg struct {
	FromBlock *hexutil.Uint64  `json:"fromBlock"`
	ToBlock   *hexutil.Uint64  `json:"toBlock"`
	BlockHash *common.Hash     `json:"blockHash"`
	Address   []common.Address `json:"address"`
}

// GetLogs serves eth_getLogs.
func (s *ethService) GetLogs(ctx context.Context, f filterArg) ([]types.Log, error) {
	q := chain.LogQuery{BlockHash: f.BlockHash, Addresses: f.Address}
	if f.BlockHash == nil {
		if f.FromBlock == nil || f.ToBlock == nil {
			return nil, errors.New("fakechain: fromBlock and toBlock are required")
		}
		q.From, q.To = uint64(*f.FromBlock), uint64(*f.ToBlock)
	}
	return s.c.Logs(ctx, q)
}

type receipt struct {
	TransactionHash  common.Hash    `json:"transactionHash"`
	TransactionIndex hexutil.Uint64 `json:"transactionIndex"`
	BlockHash        common.Hash    `json:"blockHash"`
	Logs             []types.Log    `json:"logs"`
}

// GetBlockReceipts serves eth_getBlockReceipts (block hash only), grouping logs by transaction.
func (s *ethService) GetBlockReceipts(ctx context.Context, hash common.Hash) ([]receipt, error) {
	logs, err := s.c.BlockLogs(ctx, hash)
	if errors.Is(err, errUnknownBlock) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	out := []receipt{}
	for _, l := range logs {
		if n := len(out); n == 0 || out[n-1].TransactionHash != l.TxHash {
			out = append(out, receipt{TransactionHash: l.TxHash, TransactionIndex: hexutil.Uint64(l.TxIndex), BlockHash: hash, Logs: []types.Log{}})
		}
		out[len(out)-1].Logs = append(out[len(out)-1].Logs, l)
	}
	return out, nil
}

// Handler returns an HTTP JSON-RPC handler serving the chain (eth_chainId, eth_blockNumber,
// eth_getBlockByNumber, eth_getBlockByHash, eth_getLogs, eth_getBlockReceipts, batches
// included).
func (c *Chain) Handler() http.Handler {
	srv := rpc.NewServer()
	if err := srv.RegisterName("eth", &ethService{c: c}); err != nil {
		panic(err)
	}
	return srv
}
