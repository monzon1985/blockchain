// SPDX-License-Identifier: MIT

package fetch

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/fakechain"
)

// source wraps the fake chain with provider behaviour: result caps, range caps, timeouts on
// wide ranges, silently dropped blocks, transient failures and arbitrary tampering.
type source struct {
	*fakechain.Chain

	maxLogs       int    // a query (range or hash) returning more logs fails with "too many results"
	maxRange      uint64 // a wider range fails with a -32005-style "block range" error
	timeoutAbove  uint64 // a wider range fails with a deadline error
	dropBlocks    map[uint64]bool
	transientLeft atomic.Int64 // the next N calls fail with a truncated-body error
	tamperHeaders func([]chain.Header) []chain.Header
	tamperLogs    func(chain.LogQuery, []types.Log) []types.Log
	delay         func() time.Duration
	failLogs      func(chain.LogQuery) error // an error to answer instead of the logs, if non-nil
	receiptsErr   error                      // the answer to every eth_getBlockReceipts

	inFlight, maxInFlight atomic.Int64
	mu                    sync.Mutex
	calls                 map[string]int
}

func newSource(fc *fakechain.Chain) *source { return &source{Chain: fc, calls: map[string]int{}} }

func (s *source) count(op string) {
	s.mu.Lock()
	s.calls[op]++
	s.mu.Unlock()
}

func (s *source) callCount(op string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls[op]
}

func (s *source) transient() error {
	if s.transientLeft.Add(-1) >= 0 {
		return fmt.Errorf("decode response: %w", io.ErrUnexpectedEOF)
	}
	return nil
}

func (s *source) HeadersByRange(ctx context.Context, from, to uint64) ([]chain.Header, error) {
	n := s.inFlight.Add(1)
	defer s.inFlight.Add(-1)
	for {
		m := s.maxInFlight.Load()
		if n <= m || s.maxInFlight.CompareAndSwap(m, n) {
			break
		}
	}
	if s.delay != nil {
		time.Sleep(s.delay())
	}
	s.count("headers")
	if err := s.transient(); err != nil {
		return nil, err
	}
	hs, err := s.Chain.HeadersByRange(ctx, from, to)
	if err == nil && s.tamperHeaders != nil {
		hs = s.tamperHeaders(hs)
	}
	return hs, err
}

func (s *source) Logs(ctx context.Context, q chain.LogQuery) ([]types.Log, error) {
	if q.BlockHash != nil {
		s.count("logs_hash")
	} else {
		s.count("logs_range")
	}
	if s.failLogs != nil {
		if err := s.failLogs(q); err != nil {
			return nil, err
		}
	}
	if q.BlockHash == nil {
		span := q.To - q.From + 1
		switch {
		case s.maxRange > 0 && span > s.maxRange:
			return nil, fmt.Errorf("block range too large: %d > %d", span, s.maxRange)
		case s.timeoutAbove > 0 && span > s.timeoutAbove:
			return nil, fmt.Errorf("eth_getLogs: %w", context.DeadlineExceeded)
		}
	}
	if err := s.transient(); err != nil {
		return nil, err
	}
	logs, err := s.Chain.Logs(ctx, q)
	if err != nil {
		return nil, err
	}
	if s.maxLogs > 0 && len(logs) > s.maxLogs {
		return nil, fmt.Errorf("query returned more than %d results", s.maxLogs)
	}
	if q.BlockHash == nil && len(s.dropBlocks) > 0 {
		kept := logs[:0]
		for _, l := range logs {
			if !s.dropBlocks[l.BlockNumber] {
				kept = append(kept, l)
			}
		}
		logs = kept
	}
	if s.tamperLogs != nil {
		logs = s.tamperLogs(q, logs)
	}
	return logs, nil
}

func (s *source) BlockLogs(ctx context.Context, hash common.Hash) ([]types.Log, error) {
	s.count("receipts")
	if s.receiptsErr != nil {
		return nil, s.receiptsErr
	}
	return s.Chain.BlockLogs(ctx, hash)
}

// codedErr is a JSON-RPC error with a code, as go-ethereum's client surfaces it.
type codedErr struct {
	code int
	msg  string
}

func (e codedErr) Error() string  { return e.msg }
func (e codedErr) ErrorCode() int { return e.code }

// fixture mines blocks of random traffic and returns the chain and its watched addresses.
func fixture(t *testing.T, blocks, txs int) (*fakechain.Chain, []common.Address) {
	t.Helper()
	fc := fakechain.New(1)
	w := fakechain.NewWorld(5)
	rng := rand.New(rand.NewPCG(uint64(blocks), uint64(txs)))
	for i := range blocks {
		n := txs
		if i%5 == 4 {
			n = 0 // some empty blocks, which the bloom lets hash mode skip
		}
		fc.Mine(w.Block(rng, fc.Canonical(0), n))
	}
	return fc, w.Contracts().Addresses()
}

// expected returns the watched logs of from..to straight from the chain.
func expected(t *testing.T, fc *fakechain.Chain, addrs []common.Address, from, to uint64) []types.Log {
	t.Helper()
	logs, err := fc.Logs(context.Background(), chain.LogQuery{From: from, To: to, Addresses: addrs})
	if err != nil {
		t.Fatal(err)
	}
	return logs
}

func sameLogs(t *testing.T, got, want []types.Log) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("got %d logs, want %d", len(got), len(want))
	}
	for i := range got {
		if got[i].BlockHash != want[i].BlockHash || got[i].Index != want[i].Index {
			t.Fatalf("log %d: got %d/%d, want %d/%d", i, got[i].BlockNumber, got[i].Index, want[i].BlockNumber, want[i].Index)
		}
	}
}

func cfg(addrs []common.Address) Config {
	return Config{Addresses: addrs, InitialSpan: 16, MaxSpan: 64, HashSpan: 4, Concurrency: 3, Backoff: time.Microsecond}
}

func TestPlanner(t *testing.T) {
	p := NewPlanner(0, 0) // clamped to 1..1
	if p.Span() != 1 {
		t.Fatalf("span %d", p.Span())
	}
	p = NewPlanner(500, 100)
	if p.Span() != 100 {
		t.Fatalf("initial span above max: %d", p.Span())
	}
	steps := []struct {
		op        string
		span      uint64
		wantAfter uint64
	}{
		{"too_large", 100, 50},
		{"too_large", 100, 50}, // a stale, wider failure never raises the span
		{"ok", 10, 50},         // a small success carries no information
		{"ok", 25, 50},         // half the span: 2*25 is not above 50
		{"ok", 30, 60},
		{"ok", 60, 100}, // capped at max
		{"too_large", 1, 1},
		{"too_large", 1, 1}, // never below one block
	}
	for i, s := range steps {
		if s.op == "ok" {
			p.Succeeded(s.span)
		} else {
			p.TooLarge(s.span)
		}
		if got := p.Span(); got != s.wantAfter {
			t.Fatalf("step %d (%s %d): span %d, want %d", i, s.op, s.span, got, s.wantAfter)
		}
	}
	p = NewPlanner(10, 100)
	if end := p.Next(5, 100); end != 14 {
		t.Fatalf("Next(5, 100) = %d", end)
	}
	if end := p.Next(5, 9); end != 9 {
		t.Fatalf("Next capped at the limit: %d", end)
	}
	if ModeHash.String() != "hash" || ModeRange.String() != "range" {
		t.Fatal("mode names")
	}
}

func TestFetchSplitsAdaptivelyOnProviderLimits(t *testing.T) {
	fc, addrs := fixture(t, 80, 6)
	cases := []struct {
		name  string
		setup func(*source)
	}{
		{"result cap", func(s *source) { s.maxLogs = 40 }},
		{"block range cap", func(s *source) { s.maxRange = 7 }},
		{"timeouts on wide ranges", func(s *source) { s.timeoutAbove = 5 }},
		{"all at once", func(s *source) { s.maxLogs = 25; s.maxRange = 20; s.timeoutAbove = 12 }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			src := newSource(fc)
			tc.setup(src)
			var splits atomic.Int64
			f := New(src, cfg(addrs), Hooks{Split: func() { splits.Add(1) }})
			seg, err := f.Fetch(context.Background(), 1, 64, ModeRange)
			if err != nil {
				t.Fatal(err)
			}
			sameLogs(t, seg.Logs, expected(t, fc, addrs, 1, 64))
			if len(seg.Headers) != 64 || seg.From != 1 || seg.To != 64 || seg.Mode != ModeRange {
				t.Fatalf("segment %d..%d with %d headers", seg.From, seg.To, len(seg.Headers))
			}
			if splits.Load() == 0 || f.Planner().Span() >= 64 {
				t.Fatalf("splits %d, span %d", splits.Load(), f.Planner().Span())
			}
		})
	}
}

func TestFetchFallsBackToReceiptsForOversizedBlocks(t *testing.T) {
	fc, addrs := fixture(t, 12, 30)
	src := newSource(fc)
	src.maxLogs = 5 // most single blocks exceed it on their own
	var fallbacks atomic.Int64
	f := New(src, cfg(addrs), Hooks{ReceiptFallback: func() { fallbacks.Add(1) }})
	for _, mode := range []Mode{ModeRange, ModeHash} {
		seg, err := f.Fetch(context.Background(), 1, 12, mode)
		if err != nil {
			t.Fatalf("%s: %v", mode, err)
		}
		// Receipts contain every log of the block; the fetcher keeps the watched ones only.
		sameLogs(t, seg.Logs, expected(t, fc, addrs, 1, 12))
	}
	if fallbacks.Load() == 0 || src.callCount("receipts") == 0 {
		t.Fatal("no receipt fallback happened")
	}
}

// TestHashModeSkipsBlocksTheBloomRulesOut builds blocks of three kinds: with watched logs, with
// logs of an unwatched contract only (non-zero bloom without the watched addresses: skipped), and
// empty (all-zero bloom: carries no information, so it is queried).
func TestHashModeSkipsBlocksTheBloomRulesOut(t *testing.T) {
	fc := fakechain.New(1)
	w := fakechain.NewWorld(2)
	addrs := w.Contracts().Addresses()
	transfer := func(token common.Address) []fakechain.LogSpec {
		return []fakechain.LogSpec{{Address: token, Topics: []common.Hash{{1}, {}, {}}, Data: make([]byte, 32)}}
	}
	kinds := []string{"watched", "unwatched", "empty", "unwatched", "watched", "unwatched", "empty", "unwatched"}
	for _, k := range kinds {
		switch k {
		case "watched":
			fc.Mine(transfer(w.Tokens[0]))
		case "unwatched":
			fc.Mine(transfer(w.Unwatched))
		default:
			fc.Mine(nil)
		}
	}
	src := newSource(fc)
	seg, err := New(src, cfg(addrs), Hooks{}).Fetch(context.Background(), 1, uint64(len(kinds)), ModeHash)
	if err != nil {
		t.Fatal(err)
	}
	sameLogs(t, seg.Logs, expected(t, fc, addrs, 1, uint64(len(kinds))))
	if got := src.callCount("logs_hash"); got != 4 {
		t.Fatalf("%d by-hash queries, want 4 (2 watched + 2 empty blocks; 4 unwatched-only blocks skipped)", got)
	}
}

func TestBloomCheckRecoversSilentlyDroppedLogs(t *testing.T) {
	fc, addrs := fixture(t, 30, 4)
	want := expected(t, fc, addrs, 1, 30)
	drop := map[uint64]bool{}
	for _, l := range want {
		if l.BlockNumber%3 == 0 {
			drop[l.BlockNumber] = true
		}
	}
	// Without the check, a provider that drops blocks loses data silently.
	src := newSource(fc)
	src.dropBlocks = drop
	seg, err := New(src, cfg(addrs), Hooks{}).Fetch(context.Background(), 1, 30, ModeRange)
	if err != nil {
		t.Fatal(err)
	}
	if len(seg.Logs) >= len(want) {
		t.Fatal("the dropping provider did not drop anything")
	}
	// With it, every block whose bloom admits a watched contract but came back empty is
	// re-read by hash.
	c := cfg(addrs)
	c.BloomCheck = true
	var recovered atomic.Int64
	seg, err = New(src, c, Hooks{BloomRefetch: func(ok bool) {
		if ok {
			recovered.Add(1)
		}
	}}).Fetch(context.Background(), 1, 30, ModeRange)
	if err != nil {
		t.Fatal(err)
	}
	sameLogs(t, seg.Logs, want)
	if recovered.Load() != int64(len(drop)) {
		t.Fatalf("recovered %d blocks, dropped %d", recovered.Load(), len(drop))
	}
}

// TestRateLimitsAreRetriedNotSplit: a provider that throttles with -32005 (Infura's wording) is
// backed off from, never answered with smaller ranges and receipt reads, which would multiply the
// requests against a provider that is already refusing them.
func TestRateLimitsAreRetriedNotSplit(t *testing.T) {
	fc, addrs := fixture(t, 80, 6)
	limited := codedErr{-32005, "daily request count exceeded, request rate limited"}

	src := newSource(fc)
	src.failLogs = func(chain.LogQuery) error { return limited }
	var splits atomic.Int64
	c := cfg(addrs)
	f := New(src, c, Hooks{Split: func() { splits.Add(1) }})
	_, err := f.Fetch(context.Background(), 1, 64, ModeRange)
	if !chain.IsRateLimited(err) || chain.Kind(err) != "rate_limited" {
		t.Fatalf("err %v (kind %s), want the rate limit", err, chain.Kind(err))
	}
	if got := src.callCount("logs_range"); got != 5 {
		t.Fatalf("%d eth_getLogs calls, want 5 (one per attempt, no split)", got)
	}
	if src.callCount("receipts") != 0 || splits.Load() != 0 || f.Planner().Span() != c.InitialSpan {
		t.Fatalf("receipts %d, splits %d, span %d: a rate limit was treated as a range limit",
			src.callCount("receipts"), splits.Load(), f.Planner().Span())
	}

	// A throttle that lifts is absorbed by the retries, with the range intact.
	src = newSource(fc)
	var left atomic.Int64
	left.Store(2)
	src.failLogs = func(chain.LogQuery) error {
		if left.Add(-1) >= 0 {
			return limited
		}
		return nil
	}
	f = New(src, c, Hooks{Split: func() { splits.Add(1) }})
	seg, err := f.Fetch(context.Background(), 1, 64, ModeRange)
	if err != nil {
		t.Fatal(err)
	}
	sameLogs(t, seg.Logs, expected(t, fc, addrs, 1, 64))
	if got := src.callCount("logs_range"); got != 3 || splits.Load() != 0 {
		t.Fatalf("%d eth_getLogs calls and %d splits, want 3 and 0", got, splits.Load())
	}
}

// TestMissingReceiptsMethodIsNotAnOrphanedBlock: a block whose watched logs exceed the
// provider's result cap is read from eth_getBlockReceipts. A provider without that method
// answers -32601 "Method not found"; that is a permanent error to report, not "block orphaned"
// (ErrInconsistent), which the engine would retry forever.
func TestMissingReceiptsMethodIsNotAnOrphanedBlock(t *testing.T) {
	fc, addrs := fixture(t, 12, 30)
	for _, mode := range []Mode{ModeRange, ModeHash} {
		t.Run(mode.String(), func(t *testing.T) {
			src := newSource(fc)
			src.maxLogs = 2
			src.receiptsErr = codedErr{-32601, "Method not found"}
			_, err := New(src, cfg(addrs), Hooks{}).Fetch(context.Background(), 1, 12, mode)
			if err == nil || errors.Is(err, ErrInconsistent) || chain.Kind(err) != "rpc" {
				t.Fatalf("err %v (kind %s), want a permanent rpc error", err, chain.Kind(err))
			}
			if got := src.callCount("receipts"); got != 1 {
				t.Fatalf("%d receipt calls: a permanent error must not be retried", got)
			}
		})
	}
}

func TestFetchRetriesTransientFailures(t *testing.T) {
	fc, addrs := fixture(t, 10, 3)
	src := newSource(fc)
	src.transientLeft.Store(3)
	var retries atomic.Int64
	f := New(src, cfg(addrs), Hooks{Retry: func(string, error) { retries.Add(1) }})
	seg, err := f.Fetch(context.Background(), 1, 10, ModeRange)
	if err != nil {
		t.Fatal(err)
	}
	sameLogs(t, seg.Logs, expected(t, fc, addrs, 1, 10))
	if retries.Load() != 3 {
		t.Fatalf("retries %d", retries.Load())
	}
	// Do applies the same policy to arbitrary calls.
	calls := 0
	if err := f.Do(context.Background(), "x", func() error {
		if calls++; calls < 2 {
			return io.ErrUnexpectedEOF
		}
		return nil
	}); err != nil || calls != 2 {
		t.Fatalf("Do: %v after %d calls", err, calls)
	}
	// A failure that persists past the attempts is returned.
	src.transientLeft.Store(1 << 30)
	if _, err := f.Fetch(context.Background(), 1, 10, ModeRange); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("persistent failure: %v", err)
	}
}

// TestFetchRejectsInconsistentAnswers checks every consistency property the package documents:
// answers mixing forks, or lying about logs, never reach the committer.
func TestFetchRejectsInconsistentAnswers(t *testing.T) {
	fc, addrs := fixture(t, 12, 4)
	someLog := func(logs []types.Log) int {
		if len(logs) == 0 {
			t.Fatal("fixture block range has no logs")
		}
		return len(logs) / 2
	}
	cases := []struct {
		name  string
		mode  Mode
		from  uint64
		to    uint64
		setup func(*source)
	}{
		{"headers not linked", ModeRange, 1, 12, func(s *source) {
			s.tamperHeaders = func(hs []chain.Header) []chain.Header { hs[3].ParentHash = common.Hash{1}; return hs }
		}},
		{"too few headers", ModeRange, 1, 12, func(s *source) {
			s.tamperHeaders = func(hs []chain.Header) []chain.Header { return hs[:len(hs)-1] }
		}},
		{"chain shorter than the segment", ModeRange, 10, 40, func(*source) {}},
		{"log from another fork", ModeRange, 1, 12, func(s *source) {
			s.tamperLogs = func(_ chain.LogQuery, ls []types.Log) []types.Log {
				ls[someLog(ls)].BlockHash = common.Hash{2}
				return ls
			}
		}},
		{"log outside the range", ModeRange, 1, 12, func(s *source) {
			s.tamperLogs = func(_ chain.LogQuery, ls []types.Log) []types.Log { ls[someLog(ls)].BlockNumber = 99; return ls }
		}},
		{"removed log", ModeRange, 1, 12, func(s *source) {
			s.tamperLogs = func(_ chain.LogQuery, ls []types.Log) []types.Log { ls[someLog(ls)].Removed = true; return ls }
		}},
		{"unwatched emitter", ModeRange, 1, 12, func(s *source) {
			s.tamperLogs = func(_ chain.LogQuery, ls []types.Log) []types.Log {
				ls[someLog(ls)].Address = common.Address{0xee}
				return ls
			}
		}},
		{"duplicate log", ModeRange, 1, 12, func(s *source) {
			s.tamperLogs = func(_ chain.LogQuery, ls []types.Log) []types.Log { return append(ls, ls[someLog(ls)]) }
		}},
		{"log not in the bloom", ModeRange, 1, 12, func(s *source) {
			s.tamperHeaders = func(hs []chain.Header) []chain.Header {
				for i := range hs {
					hs[i].Bloom = types.Bloom{}
					hs[i].Bloom.Add([]byte("something else"))
				}
				return hs
			}
		}},
		{"block orphaned before its logs were read", ModeHash, 1, 12, func(s *source) {
			s.tamperHeaders = func(hs []chain.Header) []chain.Header {
				// A header the node no longer knows: by-hash log queries fail with "unknown block".
				hs[len(hs)-1].Hash = common.Hash{3}
				return hs
			}
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			src := newSource(fc)
			tc.setup(src)
			_, err := New(src, cfg(addrs), Hooks{}).Fetch(context.Background(), tc.from, tc.to, tc.mode)
			if !errors.Is(err, ErrInconsistent) {
				t.Fatalf("err = %v, want ErrInconsistent", err)
			}
		})
	}
	if _, err := New(newSource(fc), cfg(addrs), Hooks{}).Fetch(context.Background(), 5, 4, ModeRange); err == nil {
		t.Fatal("an empty segment must be rejected")
	}
}

func TestNewRequiresAddresses(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("New without addresses must panic")
		}
	}()
	New(newSource(fakechain.New(1)), Config{}, Hooks{})
}

func TestStreamEmitsContiguousSegmentsInOrder(t *testing.T) {
	fc, addrs := fixture(t, 300, 2)
	src := newSource(fc)
	rng := rand.New(rand.NewPCG(9, 9))
	var rngMu sync.Mutex
	src.delay = func() time.Duration {
		rngMu.Lock()
		defer rngMu.Unlock()
		return time.Duration(rng.IntN(3000)) * time.Microsecond
	}
	src.maxLogs = 30
	c := cfg(addrs)
	c.Concurrency = 4
	f := New(src, c, Hooks{})
	var segs []Segment
	err := f.Stream(context.Background(), 3, 290, 270, func(s Segment) error {
		segs = append(segs, s)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	next := uint64(3)
	var logs []types.Log
	for _, s := range segs {
		if s.From != next || s.To < s.From {
			t.Fatalf("segment %d..%d after block %d", s.From, s.To, next-1)
		}
		wantMode := ModeRange
		if s.From >= 270 {
			wantMode = ModeHash
			if s.To-s.From+1 > c.HashSpan {
				t.Fatalf("hash segment %d..%d longer than %d", s.From, s.To, c.HashSpan)
			}
		} else if s.To >= 270 {
			t.Fatalf("range segment %d..%d crosses the hash boundary", s.From, s.To)
		}
		if s.Mode != wantMode {
			t.Fatalf("segment %d..%d mode %s", s.From, s.To, s.Mode)
		}
		next = s.To + 1
		logs = append(logs, s.Logs...)
	}
	if next != 291 {
		t.Fatalf("stream ended at %d", next-1)
	}
	sameLogs(t, logs, expected(t, fc, addrs, 3, 290))
	if m := src.maxInFlight.Load(); m < 2 || m > int64(c.Concurrency) {
		t.Fatalf("max concurrent fetches %d, concurrency %d", m, c.Concurrency)
	}
}

func TestStreamStopsAtTheFirstError(t *testing.T) {
	fc, addrs := fixture(t, 100, 1)
	ctx := context.Background()
	t.Run("emit error", func(t *testing.T) {
		f := New(newSource(fc), cfg(addrs), Hooks{})
		stop := errors.New("stop here")
		var seen []uint64
		err := f.Stream(ctx, 1, 100, 101, func(s Segment) error {
			seen = append(seen, s.From)
			if len(seen) == 2 {
				return stop
			}
			return nil
		})
		if !errors.Is(err, stop) || len(seen) != 2 {
			t.Fatalf("err %v after %d segments", err, len(seen))
		}
	})
	t.Run("fetch error", func(t *testing.T) {
		src := newSource(fc)
		var firstBad atomic.Uint64
		firstBad.Store(1 << 62)
		src.tamperHeaders = func(hs []chain.Header) []chain.Header {
			if from := hs[0].Number; from > 40 {
				for cur := firstBad.Load(); from < cur && !firstBad.CompareAndSwap(cur, from); cur = firstBad.Load() {
				}
				return hs[:len(hs)-1] // one header short: inconsistent
			}
			return hs
		}
		var last uint64
		err := New(src, cfg(addrs), Hooks{}).Stream(ctx, 1, 100, 101, func(s Segment) error { last = s.To; return nil })
		// Segments are emitted strictly in order up to the first failed one, and nothing after.
		if !errors.Is(err, ErrInconsistent) || last+1 != firstBad.Load() {
			t.Fatalf("err %v, last emitted block %d, first failed segment at %d", err, last, firstBad.Load())
		}
	})
	t.Run("cancelled", func(t *testing.T) {
		cctx, cancel := context.WithCancel(ctx)
		err := New(newSource(fc), cfg(addrs), Hooks{}).Stream(cctx, 1, 100, 101, func(Segment) error { cancel(); return nil })
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("err %v", err)
		}
	})
	t.Run("empty", func(t *testing.T) {
		if err := New(newSource(fc), cfg(addrs), Hooks{}).Stream(ctx, 5, 4, 0, nil); err != nil {
			t.Fatal(err)
		}
	})
}

func TestValidateOrdersLogs(t *testing.T) {
	fc, addrs := fixture(t, 8, 4)
	src := newSource(fc)
	src.tamperLogs = func(_ chain.LogQuery, ls []types.Log) []types.Log {
		slices.Reverse(ls)
		return ls
	}
	seg, err := New(src, cfg(addrs), Hooks{}).Fetch(context.Background(), 1, 8, ModeRange)
	if err != nil {
		t.Fatal(err)
	}
	sameLogs(t, seg.Logs, expected(t, fc, addrs, 1, 8))
}
