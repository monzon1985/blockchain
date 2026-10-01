// SPDX-License-Identifier: MIT

package chain_test

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/rpc"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/fakechain"
)

// rpcErr is a JSON-RPC error with a code, as go-ethereum's client surfaces it.
type rpcErr struct {
	code int
	msg  string
}

func (e rpcErr) Error() string  { return e.msg }
func (e rpcErr) ErrorCode() int { return e.code }

type netTimeout struct{}

func (netTimeout) Error() string   { return "i/o timeout" }
func (netTimeout) Timeout() bool   { return true }
func (netTimeout) Temporary() bool { return true }

var _ net.Error = netTimeout{}

func TestErrorClassification(t *testing.T) {
	cases := []struct {
		name      string
		err       error
		kind      string
		tooLarge  bool
		timeout   bool
		retryable bool
		unknown   bool
	}{
		{"nil", nil, "ok", false, false, false, false},
		{"cancelled", context.Canceled, "canceled", false, false, false, false},
		{"deadline", fmt.Errorf("call: %w", context.DeadlineExceeded), "timeout", false, true, true, false},
		{"net timeout", netTimeout{}, "timeout", false, true, true, false},
		{"not found", fmt.Errorf("header 9: %w", chain.ErrNotFound), "not_found", false, false, false, true},
		{"eip-1474 limit", rpcErr{-32005, "whatever"}, "range_too_large", true, false, false, false},
		{"geth 10k", rpcErr{-32000, "query returned more than 10000 results"}, "range_too_large", true, false, false, false},
		{"alchemy", errors.New("Log response size exceeded. You can make eth_getLogs requests with up to a 2K block range"), "range_too_large", true, false, false, false},
		{"block range", errors.New("block range is too wide"), "range_too_large", true, false, false, false},
		{"http 503", rpc.HTTPError{StatusCode: 503, Status: "503 Service Unavailable"}, "http", false, false, true, false},
		{"rpc internal", rpcErr{-32603, "internal error"}, "rpc", false, false, true, false},
		{"rpc unknown block", rpcErr{-32000, "unknown block"}, "rpc", false, false, false, true},
		{"method not found", rpcErr{-32601, "the method eth_call does not exist/is not available"}, "rpc", false, false, false, false},
		// JSON-RPC 2.0's standard wording: permanent, and not an orphaned block despite "not found".
		{"method not found (standard)", rpcErr{-32601, "Method not found"}, "rpc", false, false, false, false},
		{"header not found", rpcErr{-32000, "header not found"}, "rpc", false, false, false, true},
		{"block not found", rpcErr{-32000, "block not found"}, "rpc", false, false, false, true},
		{"other not found", rpcErr{-32000, "transaction not found"}, "rpc", false, false, true, false},
		// Rate limits: retried with backoff, never split (even with -32005).
		{"infura rate limit", rpcErr{-32005, "daily request count exceeded, request rate limited"}, "rate_limited", false, false, true, false},
		{"rate limit -32005", rpcErr{-32005, "project ID request rate exceeded"}, "rate_limited", false, false, true, false},
		{"alchemy capacity", rpcErr{429, "Your app has exceeded its compute units per second capacity"}, "rate_limited", false, false, true, false},
		{"http 429", rpc.HTTPError{StatusCode: 429, Status: "429 Too Many Requests"}, "rate_limited", false, false, true, false},
		{"invalid params", rpcErr{-32602, "invalid argument 0"}, "rpc", false, false, false, false},
		{"execution reverted", rpcErr{3, "execution reverted"}, "rpc", false, false, false, false},
		{"truncated json", io.ErrUnexpectedEOF, "transport", false, false, true, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := chain.Kind(tc.err); got != tc.kind {
				t.Errorf("Kind = %q, want %q", got, tc.kind)
			}
			if got := chain.IsRangeTooLarge(tc.err); got != tc.tooLarge {
				t.Errorf("IsRangeTooLarge = %v", got)
			}
			if got := chain.IsTimeout(tc.err); got != tc.timeout {
				t.Errorf("IsTimeout = %v", got)
			}
			if got := chain.IsRateLimited(tc.err); got != (tc.kind == "rate_limited") {
				t.Errorf("IsRateLimited = %v", got)
			}
			if tc.err == nil {
				return
			}
			if got := chain.Retryable(tc.err); got != tc.retryable {
				t.Errorf("Retryable = %v", got)
			}
			if got := chain.IsUnknownBlock(tc.err); got != tc.unknown {
				t.Errorf("IsUnknownBlock = %v", got)
			}
		})
	}
}

func TestRetry(t *testing.T) {
	ctx := context.Background()
	transient := errors.New("connection reset")
	t.Run("succeeds after transient failures", func(t *testing.T) {
		calls, retries := 0, 0
		err := chain.Retry(ctx, chain.RetryPolicy{Attempts: 4, Backoff: time.Microsecond, OnRetry: func(error) { retries++ }}, func() error {
			if calls++; calls < 3 {
				return transient
			}
			return nil
		})
		if err != nil || calls != 3 || retries != 2 {
			t.Fatalf("err=%v calls=%d retries=%d", err, calls, retries)
		}
	})
	t.Run("gives up after the attempts", func(t *testing.T) {
		calls := 0
		err := chain.Retry(ctx, chain.RetryPolicy{Attempts: 3, Backoff: time.Microsecond, MaxBackoff: time.Microsecond}, func() error { calls++; return transient })
		if !errors.Is(err, transient) || calls != 3 {
			t.Fatalf("err=%v calls=%d", err, calls)
		}
	})
	t.Run("defaults to five attempts", func(t *testing.T) {
		calls := 0
		_ = chain.Retry(ctx, chain.RetryPolicy{Backoff: time.Microsecond}, func() error { calls++; return transient })
		if calls != 5 {
			t.Fatalf("calls=%d", calls)
		}
	})
	t.Run("does not retry permanent errors", func(t *testing.T) {
		calls := 0
		err := chain.Retry(ctx, chain.RetryPolicy{}, func() error { calls++; return chain.ErrNotFound })
		if !errors.Is(err, chain.ErrNotFound) || calls != 1 {
			t.Fatalf("err=%v calls=%d", err, calls)
		}
	})
	t.Run("stop predicate", func(t *testing.T) {
		calls := 0
		err := chain.Retry(ctx, chain.RetryPolicy{Stop: chain.IsRangeTooLarge}, func() error {
			calls++
			return rpcErr{-32000, "query returned more than 10000 results"}
		})
		if !chain.IsRangeTooLarge(err) || calls != 1 {
			t.Fatalf("err=%v calls=%d", err, calls)
		}
	})
	t.Run("cancellation wins", func(t *testing.T) {
		cctx, cancel := context.WithCancel(ctx)
		calls := 0
		err := chain.Retry(cctx, chain.RetryPolicy{Attempts: 100, Backoff: time.Hour}, func() error {
			calls++
			if calls == 1 {
				time.AfterFunc(10*time.Millisecond, cancel)
			}
			return transient
		})
		if !errors.Is(err, context.Canceled) || calls != 1 {
			t.Fatalf("err=%v calls=%d", err, calls)
		}
		err = chain.Retry(cctx, chain.RetryPolicy{}, func() error { return transient })
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("already-cancelled context: %v", err)
		}
	})
}

func TestBlockRefAndBloom(t *testing.T) {
	r := chain.BlockRef{Number: 42, Hash: common.HexToHash("0xabcdef")}
	if !strings.HasPrefix(r.String(), "42/") {
		t.Fatalf("String() = %q", r.String())
	}
	h := chain.Header{Number: 42, Hash: r.Hash}
	if h.Ref() != r {
		t.Fatal("Ref")
	}
	if chain.BloomKnown(types.Bloom{}) {
		t.Fatal("zero bloom carries no information")
	}
	var b types.Bloom
	b.Add(common.Address{1}.Bytes())
	if !chain.BloomKnown(b) {
		t.Fatal("non-zero bloom")
	}
}

// node serves a fake chain over HTTP and dials it with the production RPC client.
func node(t *testing.T, opts chain.RPCOptions) (*fakechain.Chain, *chain.RPCSource, *fakechain.World) {
	t.Helper()
	fc := fakechain.New(31337)
	w := fakechain.NewWorld(3)
	srv := httptest.NewServer(fc.Handler())
	t.Cleanup(srv.Close)
	src, err := chain.Dial(context.Background(), srv.URL, opts)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(src.Close)
	return fc, src, w
}

func TestRPCSourceAgainstFakeNode(t *testing.T) {
	ctx := context.Background()
	var mu sync.Mutex
	observed := map[string]int{}
	fc, src, w := node(t, chain.RPCOptions{HeaderBatch: 3, Observe: func(method string, _ time.Duration, _ error) {
		mu.Lock()
		observed[method]++
		mu.Unlock()
	}})
	for range 10 {
		fc.Mine(w.Block(randSource(), fc.Canonical(0), 4))
	}
	if id, err := src.ChainID(ctx); err != nil || id != 31337 {
		t.Fatalf("chain id %d %v", id, err)
	}
	head, err := src.LatestHeader(ctx)
	if err != nil || head != fc.Head() {
		t.Fatalf("latest %+v %v, want %+v", head, err, fc.Head())
	}
	h5, err := src.HeaderByNumber(ctx, 5)
	if err != nil || h5 != fc.Canonical(5)[0].Header {
		t.Fatalf("header 5: %+v %v", h5, err)
	}
	if byHash, err := src.HeaderByHash(ctx, h5.Hash); err != nil || byHash != h5 {
		t.Fatalf("by hash: %+v %v", byHash, err)
	}
	if _, err := src.HeaderByNumber(ctx, 99); !errors.Is(err, chain.ErrNotFound) {
		t.Fatalf("header above head: %v", err)
	}
	if _, err := src.HeaderByHash(ctx, common.Hash{9}); !errors.Is(err, chain.ErrNotFound) {
		t.Fatalf("unknown hash: %v", err)
	}
	// 10 headers in batches of 3: four JSON-RPC batches, linked and in order.
	hs, err := src.HeadersByRange(ctx, 1, 10)
	if err != nil || len(hs) != 10 {
		t.Fatalf("range: %d %v", len(hs), err)
	}
	for i, h := range hs {
		if h != fc.Canonical(uint64(i + 1))[0].Header {
			t.Fatalf("header %d differs", i+1)
		}
	}
	if observed["eth_getBlockByNumber[batch]"] != 4 {
		t.Fatalf("batches observed: %v", observed)
	}
	if _, err := src.HeadersByRange(ctx, 8, 11); !errors.Is(err, chain.ErrNotFound) {
		t.Fatalf("range past head: %v", err)
	}
	if _, err := src.HeadersByRange(ctx, 5, 4); err == nil {
		t.Fatal("empty range must fail")
	}

	addrs := w.Contracts().Addresses()
	var want []types.Log
	for _, b := range fc.Canonical(1) {
		for _, l := range b.Logs {
			for _, a := range addrs {
				if l.Address == a {
					want = append(want, l)
				}
			}
		}
	}
	got, err := src.Logs(ctx, chain.LogQuery{From: 1, To: 10, Addresses: addrs})
	if err != nil || len(got) != len(want) || len(want) == 0 {
		t.Fatalf("range logs: %d (want %d) %v", len(got), len(want), err)
	}
	for i := range got {
		if got[i].BlockHash != want[i].BlockHash || got[i].Index != want[i].Index || got[i].Address != want[i].Address {
			t.Fatalf("log %d differs", i)
		}
	}
	b7 := fc.Canonical(7)[0]
	byHash, err := src.Logs(ctx, chain.LogQuery{BlockHash: &b7.Header.Hash, Addresses: addrs})
	if err != nil {
		t.Fatal(err)
	}
	all, err := src.BlockLogs(ctx, b7.Header.Hash)
	if err != nil || len(all) != len(b7.Logs) || len(byHash) > len(all) {
		t.Fatalf("receipts: %d logs (block has %d), by hash %d, %v", len(all), len(b7.Logs), len(byHash), err)
	}
	if _, err := src.BlockLogs(ctx, common.Hash{7}); !errors.Is(err, chain.ErrNotFound) {
		t.Fatalf("receipts of an unknown block: %v", err)
	}
	if src.Eth() == nil {
		t.Fatal("Eth() is nil")
	}
}

// TestRPCSourceRejectsMalformedNodes serves broken JSON-RPC answers.
func TestRPCSourceRejectsMalformedNodes(t *testing.T) {
	ctx := context.Background()
	cases := []struct {
		name   string
		result string
		call   func(*chain.RPCSource) error
	}{
		{"header without hash", `{"number":"0x1","parentHash":"0x` + strings.Repeat("00", 32) + `","timestamp":"0x1"}`,
			func(s *chain.RPCSource) error { _, err := s.HeaderByNumber(ctx, 1); return err }},
		{"header without number", `{"hash":"0x` + strings.Repeat("11", 32) + `"}`,
			func(s *chain.RPCSource) error { _, err := s.LatestHeader(ctx); return err }},
		{"header without parent", `{"number":"0x1","hash":"0x` + strings.Repeat("11", 32) + `","timestamp":"0x1"}`,
			func(s *chain.RPCSource) error { _, err := s.LatestHeader(ctx); return err }},
		{"header without timestamp", `{"number":"0x1","hash":"0x` + strings.Repeat("11", 32) + `","parentHash":"0x` + strings.Repeat("00", 32) + `"}`,
			func(s *chain.RPCSource) error { _, err := s.LatestHeader(ctx); return err }},
		{"chain id too large", `"0x1ffffffffffffffffff"`, func(s *chain.RPCSource) error { _, err := s.ChainID(ctx); return err }},
		{"wrong header in batch", `{"number":"0x9","hash":"0x` + strings.Repeat("11", 32) + `","parentHash":"0x` + strings.Repeat("00", 32) + `","timestamp":"0x1"}`,
			func(s *chain.RPCSource) error { _, err := s.HeadersByRange(ctx, 1, 1); return err }},
		{"null in batch", `null`, func(s *chain.RPCSource) error { _, err := s.HeadersByRange(ctx, 1, 2); return err }},
		{"rpc error in logs", `ERROR`, func(s *chain.RPCSource) error { _, err := s.Logs(ctx, chain.LogQuery{From: 1, To: 2}); return err }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				body, _ := io.ReadAll(r.Body)
				w.Header().Set("Content-Type", "application/json")
				answer := func(id string) string {
					if tc.result == "ERROR" {
						return `{"jsonrpc":"2.0","id":` + id + `,"error":{"code":-32603,"message":"boom"}}`
					}
					return `{"jsonrpc":"2.0","id":` + id + `,"result":` + tc.result + `}`
				}
				if strings.HasPrefix(strings.TrimSpace(string(body)), "[") {
					// Answer every batch element with the same result (ids 1..n as sent by geth).
					n := strings.Count(string(body), `"method"`)
					parts := make([]string, n)
					for i := range parts {
						parts[i] = answer(fmt.Sprint(i + 1))
					}
					fmt.Fprint(w, "["+strings.Join(parts, ",")+"]")
					return
				}
				id := "1"
				if i := strings.Index(string(body), `"id":`); i >= 0 {
					rest := string(body)[i+5:]
					id = rest[:strings.IndexAny(rest, ",}")]
				}
				fmt.Fprint(w, answer(id))
			}))
			defer srv.Close()
			src, err := chain.Dial(ctx, srv.URL, chain.RPCOptions{})
			if err != nil {
				t.Fatal(err)
			}
			defer src.Close()
			if err := tc.call(src); err == nil {
				t.Fatal("malformed answer accepted")
			}
		})
	}
}

func TestRPCSourceTimeoutAndDialErrors(t *testing.T) {
	ctx := context.Background()
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	defer srv.Close()
	defer close(release)
	src, err := chain.Dial(ctx, srv.URL, chain.RPCOptions{CallTimeout: 50 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	defer src.Close()
	start := time.Now()
	_, err = src.LatestHeader(ctx)
	if !chain.IsTimeout(err) || time.Since(start) > 5*time.Second {
		t.Fatalf("hung node: %v after %s", err, time.Since(start))
	}
	if _, err := src.HeadersByRange(ctx, 1, 3); !chain.IsTimeout(err) {
		t.Fatalf("hung batch: %v", err)
	}
	if _, err := chain.Dial(ctx, "ftp://nowhere", chain.RPCOptions{}); err == nil {
		t.Fatal("unsupported scheme must fail")
	}
}

// randSource returns a deterministic generator for fake-chain traffic.
func randSource() *rand.Rand { return rand.New(rand.NewPCG(1, 2)) }
