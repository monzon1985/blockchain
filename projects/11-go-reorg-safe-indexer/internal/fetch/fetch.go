// SPDX-License-Identifier: MIT

// Package fetch downloads contiguous, internally consistent chain segments (headers plus the logs
// of the watched contracts) and streams them to the committer in block order.
//
// Consistency is checked, not assumed. A node can answer consecutive calls from different forks
// (a reorg between two requests, or a load balancer spreading them over nodes). Every segment
// therefore satisfies, before it is emitted:
//
//  1. its headers are contiguous and linked by parent hash;
//  2. every log's blockHash is the hash of the header at the log's number;
//  3. every log's emitter is in that header's logs bloom (blooms have no false negatives);
//  4. logs are unique and ordered by (block, logIndex).
//
// Deep blocks are fetched with range eth_getLogs, split adaptively. Blocks near the head, where
// reorgs happen, are fetched per block by hash (EIP-234), which is fork-consistent by
// construction and skipped entirely when the header bloom rules the watched contracts out. A
// single block whose logs exceed the provider's result cap is read from eth_getBlockReceipts.
package fetch

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
)

// ErrInconsistent means the node's answers do not describe one fork. The caller re-reads the
// head (which usually reveals a reorg) and tries again.
var ErrInconsistent = errors.New("fetch: node answered from different forks")

// Mode selects how a segment's logs are fetched.
type Mode int

const (
	// ModeRange uses one eth_getLogs over the block range, split adaptively.
	ModeRange Mode = iota
	// ModeHash uses one eth_getLogs per block, by block hash.
	ModeHash
)

func (m Mode) String() string {
	if m == ModeHash {
		return "hash"
	}
	return "range"
}

// Config tunes a Fetcher.
type Config struct {
	// Addresses are the watched contracts (required, non-empty).
	Addresses []common.Address
	// InitialSpan and MaxSpan bound the adaptive eth_getLogs range (defaults 100 and 5000).
	InitialSpan, MaxSpan uint64
	// HashSpan is the number of blocks per ModeHash segment (default 16).
	HashSpan uint64
	// Concurrency is the number of segments fetched in parallel (default 4).
	Concurrency int
	// Attempts bounds retries of a transient failure per call (default 5).
	Attempts int
	// Backoff is the first retry delay; it doubles up to 2s (default 50ms).
	Backoff time.Duration
	// BloomCheck re-queries by hash every range-mode block whose bloom matches a watched
	// contract but that came back without logs, recovering logs a provider silently dropped.
	BloomCheck bool
}

// Hooks observe fetcher decisions (metrics). Nil hooks are skipped.
type Hooks struct {
	Split           func()
	Retry           func(op string, err error)
	BloomRefetch    func(recovered bool)
	ReceiptFallback func()
}

// Segment is a validated slice of the chain.
type Segment struct {
	From, To uint64
	Mode     Mode
	Headers  []chain.Header
	Logs     []types.Log
}

// Fetcher downloads segments from a Source.
type Fetcher struct {
	src     chain.Source
	cfg     Config
	planner *Planner
	watched map[common.Address]bool
	hooks   Hooks
}

// New returns a fetcher. It panics if cfg.Addresses is empty (a configuration bug).
func New(src chain.Source, cfg Config, hooks Hooks) *Fetcher {
	if len(cfg.Addresses) == 0 {
		panic("fetch: no watched addresses")
	}
	if cfg.MaxSpan == 0 {
		cfg.MaxSpan = 5000
	}
	if cfg.InitialSpan == 0 {
		cfg.InitialSpan = min(100, cfg.MaxSpan)
	}
	if cfg.HashSpan == 0 {
		cfg.HashSpan = 16
	}
	if cfg.Concurrency <= 0 {
		cfg.Concurrency = 4
	}
	if cfg.Attempts <= 0 {
		cfg.Attempts = 5
	}
	if cfg.Backoff <= 0 {
		cfg.Backoff = 50 * time.Millisecond
	}
	f := &Fetcher{src: src, cfg: cfg, planner: NewPlanner(cfg.InitialSpan, cfg.MaxSpan), watched: map[common.Address]bool{}, hooks: hooks}
	for _, a := range cfg.Addresses {
		f.watched[a] = true
	}
	return f
}

// Planner exposes the adaptive span (for metrics and tests).
func (f *Fetcher) Planner() *Planner { return f.planner }

// Do runs fn with the fetcher's retry policy for transient failures (the engine uses it for
// head and ancestor reads).
func (f *Fetcher) Do(ctx context.Context, op string, fn func() error) error {
	return f.retry(ctx, op, nil, fn)
}

func (f *Fetcher) retry(ctx context.Context, op string, stop func(error) bool, fn func() error) error {
	return chain.Retry(ctx, chain.RetryPolicy{
		Attempts: f.cfg.Attempts,
		Backoff:  f.cfg.Backoff,
		Stop:     stop,
		OnRetry: func(err error) {
			if f.hooks.Retry != nil {
				f.hooks.Retry(op, err)
			}
		},
	}, fn)
}

// Fetch downloads and validates the segment from..to.
func (f *Fetcher) Fetch(ctx context.Context, from, to uint64, mode Mode) (Segment, error) {
	if to < from {
		return Segment{}, fmt.Errorf("fetch: empty segment %d..%d", from, to)
	}
	var headers []chain.Header
	err := f.retry(ctx, "headers", nil, func() error {
		var err error
		headers, err = f.src.HeadersByRange(ctx, from, to)
		return err
	})
	if err != nil {
		if errors.Is(err, chain.ErrNotFound) {
			// The chain got shorter under us: a rollback or a lagging node.
			return Segment{}, fmt.Errorf("%w: %v", ErrInconsistent, err)
		}
		return Segment{}, err
	}
	if len(headers) != int(to-from+1) {
		return Segment{}, fmt.Errorf("%w: asked for %d headers, got %d", ErrInconsistent, to-from+1, len(headers))
	}
	for i := 1; i < len(headers); i++ {
		if headers[i].ParentHash != headers[i-1].Hash {
			return Segment{}, fmt.Errorf("%w: header %d does not link to header %d", ErrInconsistent, headers[i].Number, headers[i-1].Number)
		}
	}

	var logs []types.Log
	if mode == ModeHash {
		for _, h := range headers {
			if !f.bloomMatches(h) {
				continue
			}
			got, err := f.hashLogs(ctx, h)
			if err != nil {
				return Segment{}, err
			}
			logs = append(logs, got...)
		}
	} else if logs, err = f.rangeLogs(ctx, headers, from, to); err != nil {
		return Segment{}, err
	}
	if logs, err = f.validate(from, headers, logs); err != nil {
		return Segment{}, err
	}
	if f.cfg.BloomCheck && mode == ModeRange {
		if logs, err = f.bloomComplete(ctx, from, headers, logs); err != nil {
			return Segment{}, err
		}
	}
	return Segment{From: from, To: to, Mode: mode, Headers: headers, Logs: logs}, nil
}

// bloomMatches reports whether the header's bloom admits a log from any watched contract.
func (f *Fetcher) bloomMatches(h chain.Header) bool {
	if !chain.BloomKnown(h.Bloom) {
		return true
	}
	for a := range f.watched {
		if h.Bloom.Test(a.Bytes()) {
			return true
		}
	}
	return false
}

// hashLogs fetches one block's logs by hash, falling back to receipts when the block alone
// exceeds the provider's cap.
func (f *Fetcher) hashLogs(ctx context.Context, h chain.Header) ([]types.Log, error) {
	var logs []types.Log
	hash := h.Hash
	err := f.retry(ctx, "eth_getLogs[hash]", chain.IsRangeTooLarge, func() error {
		var err error
		logs, err = f.src.Logs(ctx, chain.LogQuery{BlockHash: &hash, Addresses: f.cfg.Addresses})
		return err
	})
	switch {
	case err == nil:
		return logs, nil
	case chain.IsRangeTooLarge(err):
		return f.receiptLogs(ctx, h)
	case chain.IsUnknownBlock(err):
		// The block was orphaned between the header and the log query.
		return nil, fmt.Errorf("%w: logs of block %d: %v", ErrInconsistent, h.Number, err)
	default:
		return nil, err
	}
}

// receiptLogs reads a block's logs from its receipts and keeps the watched contracts' ones.
func (f *Fetcher) receiptLogs(ctx context.Context, h chain.Header) ([]types.Log, error) {
	if f.hooks.ReceiptFallback != nil {
		f.hooks.ReceiptFallback()
	}
	var all []types.Log
	err := f.retry(ctx, "eth_getBlockReceipts", nil, func() error {
		var err error
		all, err = f.src.BlockLogs(ctx, h.Hash)
		return err
	})
	if err != nil {
		if chain.IsUnknownBlock(err) {
			return nil, fmt.Errorf("%w: receipts of block %d: %v", ErrInconsistent, h.Number, err)
		}
		return nil, err
	}
	out := all[:0]
	for _, l := range all {
		if f.watched[l.Address] {
			out = append(out, l)
		}
	}
	return out, nil
}

// splittable reports whether a range query error means "ask for less".
func splittable(ctx context.Context, err error) bool {
	return chain.IsRangeTooLarge(err) || (chain.IsTimeout(err) && ctx.Err() == nil)
}

// rangeLogs runs eth_getLogs over from..to, halving the range on "too many results" or a
// timeout until the provider accepts it; a single block that is still too large is read from
// its receipts.
func (f *Fetcher) rangeLogs(ctx context.Context, headers []chain.Header, from, to uint64) ([]types.Log, error) {
	span := to - from + 1
	var logs []types.Log
	err := f.retry(ctx, "eth_getLogs", func(err error) bool { return splittable(ctx, err) }, func() error {
		var err error
		logs, err = f.src.Logs(ctx, chain.LogQuery{From: from, To: to, Addresses: f.cfg.Addresses})
		return err
	})
	if err == nil {
		f.planner.Succeeded(span)
		return logs, nil
	}
	if !splittable(ctx, err) {
		return nil, err
	}
	f.planner.TooLarge(span)
	if from == to {
		if !chain.IsRangeTooLarge(err) {
			return nil, err // a single-block timeout: retried by the caller's next sync
		}
		return f.receiptLogs(ctx, headers[from-headers[0].Number])
	}
	if f.hooks.Split != nil {
		f.hooks.Split()
	}
	mid := from + (to-from)/2
	left, err := f.rangeLogs(ctx, headers, from, mid)
	if err != nil {
		return nil, err
	}
	right, err := f.rangeLogs(ctx, headers, mid+1, to)
	if err != nil {
		return nil, err
	}
	return append(left, right...), nil
}

// validate enforces properties 2-4 of the package documentation.
func (f *Fetcher) validate(from uint64, headers []chain.Header, logs []types.Log) ([]types.Log, error) {
	to := from + uint64(len(headers)) - 1
	for i := range logs {
		l := &logs[i]
		switch {
		case l.Removed:
			return nil, fmt.Errorf("%w: node returned a removed log", ErrInconsistent)
		case l.BlockNumber < from || l.BlockNumber > to:
			return nil, fmt.Errorf("%w: log of block %d outside %d..%d", ErrInconsistent, l.BlockNumber, from, to)
		}
		h := headers[l.BlockNumber-from]
		switch {
		case l.BlockHash != h.Hash:
			return nil, fmt.Errorf("%w: log of block %d has hash %s, header has %s", ErrInconsistent,
				l.BlockNumber, l.BlockHash.TerminalString(), h.Hash.TerminalString())
		case !f.watched[l.Address]:
			return nil, fmt.Errorf("%w: node returned a log of unwatched contract %s", ErrInconsistent, l.Address)
		case chain.BloomKnown(h.Bloom) && !h.Bloom.Test(l.Address.Bytes()):
			return nil, fmt.Errorf("%w: log of %s is not in the bloom of block %d", ErrInconsistent, l.Address, l.BlockNumber)
		}
	}
	slices.SortStableFunc(logs, func(a, b types.Log) int {
		if a.BlockNumber != b.BlockNumber {
			return cmpU(a.BlockNumber, b.BlockNumber)
		}
		return cmpU(uint64(a.Index), uint64(b.Index))
	})
	for i := 1; i < len(logs); i++ {
		if logs[i].BlockNumber == logs[i-1].BlockNumber && logs[i].Index == logs[i-1].Index {
			return nil, fmt.Errorf("%w: duplicate log %d/%d", ErrInconsistent, logs[i].BlockNumber, logs[i].Index)
		}
	}
	return logs, nil
}

// bloomComplete re-queries, by hash, every block whose bloom admits a watched contract but that
// has no logs in a range answer.
func (f *Fetcher) bloomComplete(ctx context.Context, from uint64, headers []chain.Header, logs []types.Log) ([]types.Log, error) {
	has := make(map[uint64]bool, len(logs))
	for _, l := range logs {
		has[l.BlockNumber] = true
	}
	added := false
	for _, h := range headers {
		if has[h.Number] || !chain.BloomKnown(h.Bloom) || !f.bloomMatches(h) {
			continue
		}
		extra, err := f.hashLogs(ctx, h)
		if err != nil {
			return nil, err
		}
		if f.hooks.BloomRefetch != nil {
			f.hooks.BloomRefetch(len(extra) > 0)
		}
		if len(extra) > 0 {
			logs = append(logs, extra...)
			added = true
		}
	}
	if !added {
		return logs, nil
	}
	return f.validate(from, headers, logs)
}

func cmpU(a, b uint64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	default:
		return 0
	}
}

// Stream fetches from..to with up to Concurrency segments in flight and calls emit for each
// segment strictly in block order, from the caller's goroutine. Blocks >= hashFrom use ModeHash.
// The first error (from a fetch or from emit) cancels outstanding fetches and is returned once
// every worker has stopped.
func (f *Fetcher) Stream(ctx context.Context, from, to, hashFrom uint64, emit func(Segment) error) error {
	if to < from {
		return nil
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	type result struct {
		seg Segment
		err error
	}
	queue := make(chan chan result, f.cfg.Concurrency)
	slots := make(chan struct{}, f.cfg.Concurrency)
	var workers sync.WaitGroup

	go func() {
		defer close(queue)
		for start := from; ; {
			select {
			case slots <- struct{}{}:
			case <-ctx.Done():
				return
			}
			mode, end := ModeRange, uint64(0)
			if start >= hashFrom {
				mode = ModeHash
				end = to
				if to-start >= f.cfg.HashSpan {
					end = start + f.cfg.HashSpan - 1
				}
			} else {
				end = f.planner.Next(start, min(to, hashFrom-1))
			}
			fut := make(chan result, 1)
			workers.Add(1)
			go func(s, e uint64, m Mode) {
				defer workers.Done()
				seg, err := f.Fetch(ctx, s, e, m)
				fut <- result{seg, err}
			}(start, end, mode)
			select {
			case queue <- fut:
			case <-ctx.Done():
				<-fut
				return
			}
			if end >= to {
				return
			}
			start = end + 1
		}
	}()

	var firstErr error
	for fut := range queue {
		r := <-fut
		<-slots
		if firstErr != nil {
			continue
		}
		if r.err != nil {
			firstErr = r.err
			cancel()
			continue
		}
		if err := emit(r.seg); err != nil {
			firstErr = err
			cancel()
		}
	}
	workers.Wait()
	if firstErr == nil && ctx.Err() != nil {
		// Only the parent context can have been cancelled here.
		firstErr = ctx.Err()
	}
	return firstErr
}
