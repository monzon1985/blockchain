// SPDX-License-Identifier: MIT

// Package chain is the indexer's read-only view of an EVM node: block references, the header
// subset it needs, and the Source interface that the fetcher, the reorg tracker and the tests'
// fake chain all speak.
package chain

import (
	"context"
	"errors"
	"fmt"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
)

// ErrNotFound is returned when the node has no block for a number or hash (a number above its
// head, or a hash it never saw or already forgot).
var ErrNotFound = errors.New("chain: block not found")

// BlockRef identifies one block on one fork.
type BlockRef struct {
	Number uint64      `json:"number"`
	Hash   common.Hash `json:"hash"`
}

// String renders the reference as number/short-hash for logs.
func (r BlockRef) String() string {
	return fmt.Sprintf("%d/%s", r.Number, r.Hash.TerminalString())
}

// Header is the subset of a block header the indexer uses. Hash is the value the node reports,
// never recomputed locally: L2 headers (OP Stack, Arbitrum, ...) do not hash like L1 headers,
// and trusting the reported hash keeps the indexer chain-agnostic.
type Header struct {
	Number     uint64
	Hash       common.Hash
	ParentHash common.Hash
	Time       uint64
	Bloom      types.Bloom
}

// Ref returns the header's block reference.
func (h Header) Ref() BlockRef { return BlockRef{Number: h.Number, Hash: h.Hash} }

// LogQuery is an eth_getLogs filter restricted to what the indexer needs: either an inclusive
// block range or a single block hash (EIP-234), and a set of emitting addresses.
type LogQuery struct {
	From, To  uint64
	BlockHash *common.Hash
	Addresses []common.Address
}

// Source is the node API the indexer depends on. Implementations must be safe for concurrent
// use; RPCSource is the production one, fakechain.Chain serves the same API in memory.
type Source interface {
	// ChainID returns the EIP-155 chain id.
	ChainID(ctx context.Context) (uint64, error)
	// LatestHeader returns the header of the node's current head.
	LatestHeader(ctx context.Context) (Header, error)
	// HeaderByNumber returns the canonical header at number, or ErrNotFound.
	HeaderByNumber(ctx context.Context, number uint64) (Header, error)
	// HeaderByHash returns the header with the given hash (canonical or not), or ErrNotFound.
	HeaderByHash(ctx context.Context, hash common.Hash) (Header, error)
	// HeadersByRange returns the canonical headers from..to inclusive, in order. Implementations
	// batch the requests; the result may mix forks if the chain reorganises mid-call, which the
	// caller detects through parent-hash linkage.
	HeadersByRange(ctx context.Context, from, to uint64) ([]Header, error)
	// Logs runs eth_getLogs.
	Logs(ctx context.Context, q LogQuery) ([]types.Log, error)
	// BlockLogs returns every log of one block from eth_getBlockReceipts. It is the fallback
	// for a block whose logs exceed the provider's eth_getLogs result cap, which no range split
	// can get under.
	BlockLogs(ctx context.Context, hash common.Hash) ([]types.Log, error)
}

// rpcHeader is the JSON shape of eth_getBlockByNumber / eth_getBlockByHash (full=false),
// reduced to the fields the indexer reads.
type rpcHeader struct {
	Number     *hexutil.Uint64 `json:"number"`
	Hash       *common.Hash    `json:"hash"`
	ParentHash *common.Hash    `json:"parentHash"`
	Timestamp  *hexutil.Uint64 `json:"timestamp"`
	LogsBloom  *types.Bloom    `json:"logsBloom"`
}

func (r *rpcHeader) header() (Header, error) {
	switch {
	case r.Number == nil:
		return Header{}, errors.New("chain: header without number")
	case r.Hash == nil:
		// Pending blocks have no hash; the indexer never asks for them.
		return Header{}, errors.New("chain: header without hash")
	case r.ParentHash == nil:
		return Header{}, errors.New("chain: header without parentHash")
	case r.Timestamp == nil:
		return Header{}, errors.New("chain: header without timestamp")
	}
	h := Header{
		Number:     uint64(*r.Number),
		Hash:       *r.Hash,
		ParentHash: *r.ParentHash,
		Time:       uint64(*r.Timestamp),
	}
	if r.LogsBloom != nil {
		h.Bloom = *r.LogsBloom
	}
	return h, nil
}

// MarshalHeader renders h in the eth_getBlockBy* JSON shape (used by the fake chain server).
func MarshalHeader(h Header) map[string]any {
	return map[string]any{
		"number":     hexutil.Uint64(h.Number),
		"hash":       h.Hash,
		"parentHash": h.ParentHash,
		"timestamp":  hexutil.Uint64(h.Time),
		"logsBloom":  h.Bloom,
	}
}

// BloomKnown reports whether the bloom carries information at all. Some chains leave it all
// zero, and a zero bloom must then be read as "may contain anything", never as "contains nothing".
func BloomKnown(bloom types.Bloom) bool { return bloom != (types.Bloom{}) }
