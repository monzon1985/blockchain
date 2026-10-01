// SPDX-License-Identifier: MIT

package rpcfault_test

import (
	"context"
	"errors"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/rpc"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/fakechain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/rpcfault"
)

// Per-call timeouts of the RPC client in these tests. Only a hung request is expected to time
// out, so it alone gets a short timeout; every other call gets a deadline that no amount of CPU
// contention from parallel test packages can reach, which keeps the suite deterministic.
const (
	generousTimeout = 10 * time.Second
	hangTimeout     = 200 * time.Millisecond
)

// faultyNode serves a fake chain with traffic and returns an RPC client behind the injector.
func faultyNode(t *testing.T, cfg rpcfault.Config) (*fakechain.Chain, *fakechain.World, *rpcfault.Transport, *chain.RPCSource) {
	t.Helper()
	return faultyNodeWithTimeout(t, cfg, generousTimeout)
}

func faultyNodeWithTimeout(t *testing.T, cfg rpcfault.Config, callTimeout time.Duration) (*fakechain.Chain, *fakechain.World, *rpcfault.Transport, *chain.RPCSource) {
	t.Helper()
	fc := fakechain.New(31337)
	w := fakechain.NewWorld(4)
	rng := rand.New(rand.NewPCG(3, 4))
	for range 12 {
		fc.Mine(w.Block(rng, fc.Canonical(0), 6))
	}
	srv := httptest.NewServer(fc.Handler())
	t.Cleanup(srv.Close)
	tr := rpcfault.New(nil, cfg)
	src, err := chain.Dial(context.Background(), srv.URL, chain.RPCOptions{
		HTTPClient: &http.Client{Transport: tr}, CallTimeout: callTimeout,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(src.Close)
	return fc, w, tr, src
}

func TestFaults(t *testing.T) {
	ctx := context.Background()
	cases := []struct {
		name  string
		cfg   rpcfault.Config
		check func(t *testing.T, err error, st map[string]int64)
	}{
		{"http 503", rpcfault.Config{HTTPErrorRate: 1}, func(t *testing.T, err error, st map[string]int64) {
			var he rpc.HTTPError
			if !errors.As(err, &he) || he.StatusCode != http.StatusServiceUnavailable || st["http_errors"] != 1 {
				t.Fatalf("err %v stats %v", err, st)
			}
		}},
		{"json-rpc error", rpcfault.Config{RPCErrorRate: 1}, func(t *testing.T, err error, st map[string]int64) {
			var re rpc.Error
			if !errors.As(err, &re) || re.ErrorCode() != -32603 || st["rpc_errors"] != 1 || chain.Kind(err) != "rpc" {
				t.Fatalf("err %v stats %v", err, st)
			}
		}},
		{"truncated body", rpcfault.Config{TruncateRate: 1}, func(t *testing.T, err error, st map[string]int64) {
			if err == nil || st["truncated"] != 1 || chain.Kind(err) != "transport" || !chain.Retryable(err) {
				t.Fatalf("err %v (kind %s) stats %v", err, chain.Kind(err), st)
			}
		}},
		{"hung request", rpcfault.Config{TimeoutRate: 1}, func(t *testing.T, err error, st map[string]int64) {
			if !chain.IsTimeout(err) || st["timeouts"] != 1 {
				t.Fatalf("err %v stats %v", err, st)
			}
		}},
		{"latency", rpcfault.Config{MinLatency: 30 * time.Millisecond, MaxLatency: 40 * time.Millisecond}, func(t *testing.T, err error, st map[string]int64) {
			if err != nil || st["requests"] != 1 {
				t.Fatalf("err %v stats %v", err, st)
			}
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			timeout := generousTimeout
			if tc.cfg.TimeoutRate > 0 {
				timeout = hangTimeout // the timeout is the expected outcome
			}
			_, _, tr, src := faultyNodeWithTimeout(t, tc.cfg, timeout)
			start := time.Now()
			_, err := src.LatestHeader(ctx)
			if tc.cfg.MinLatency > 0 && time.Since(start) < tc.cfg.MinLatency {
				t.Fatalf("answered after %s, minimum latency %s", time.Since(start), tc.cfg.MinLatency)
			}
			tc.check(t, err, tr.Stats.Snapshot())
		})
	}
}

func TestLogLimitsAndDrops(t *testing.T) {
	ctx := context.Background()
	fc, w, tr, src := faultyNode(t, rpcfault.Config{MaxLogs: 10, MaxBlockRange: 4})
	addrs := w.Contracts().Addresses()

	_, err := src.Logs(ctx, chain.LogQuery{From: 1, To: 5, Addresses: addrs})
	if !chain.IsRangeTooLarge(err) || !strings.Contains(err.Error(), "block range too large") {
		t.Fatalf("wide range: %v", err)
	}
	_, err = src.Logs(ctx, chain.LogQuery{From: 1, To: 4, Addresses: addrs})
	if !chain.IsRangeTooLarge(err) || !strings.Contains(err.Error(), "more than 10 results") {
		t.Fatalf("too many logs: %v", err)
	}
	if st := tr.Stats.Snapshot(); st["limit_errors"] != 2 {
		t.Fatalf("stats %v", st)
	}
	// A narrow range under the cap passes unchanged.
	var block uint64
	for n := uint64(1); n <= 12; n++ {
		logs, _ := fc.Logs(ctx, chain.LogQuery{From: n, To: n, Addresses: addrs})
		if len(logs) > 0 && len(logs) <= 10 {
			block = n
			break
		}
	}
	if block == 0 {
		t.Fatal("no block with 1..10 watched logs")
	}
	got, err := src.Logs(ctx, chain.LogQuery{From: block, To: block, Addresses: addrs})
	if err != nil || len(got) == 0 {
		t.Fatalf("narrow range: %d logs, %v", len(got), err)
	}

	// Silent drops affect range queries only; by-hash queries stay intact.
	tr.SetConfig(rpcfault.Config{DropBlockRate: 1})
	want, _ := fc.Logs(ctx, chain.LogQuery{From: 1, To: 12, Addresses: addrs})
	got, err = src.Logs(ctx, chain.LogQuery{From: 1, To: 12, Addresses: addrs})
	if err != nil || len(got) >= len(want) || tr.Stats.DroppedBlocks.Load() != 1 {
		t.Fatalf("drop: %d of %d logs returned, %v", len(got), len(want), err)
	}
	h := fc.Canonical(block)[0].Header.Hash
	full, _ := fc.Logs(ctx, chain.LogQuery{BlockHash: &h, Addresses: addrs})
	byHash, err := src.Logs(ctx, chain.LogQuery{BlockHash: &h, Addresses: addrs})
	if err != nil || len(byHash) != len(full) {
		t.Fatalf("by-hash query altered: %d of %d, %v", len(byHash), len(full), err)
	}

	// A partial omission removes one log of a block that has several: every block that had logs
	// still has some, so a check that only re-reads empty blocks cannot see the loss.
	tr.SetConfig(rpcfault.Config{DropLogRate: 1})
	got, err = src.Logs(ctx, chain.LogQuery{From: 1, To: 12, Addresses: addrs})
	if err != nil || len(got) != len(want)-1 || tr.Stats.DroppedLogs.Load() != 1 {
		t.Fatalf("partial drop: %d of %d logs returned, %v, stats %v", len(got), len(want), err, tr.Stats.Snapshot())
	}
	blocksWith := func(ls []types.Log) map[uint64]bool {
		out := map[uint64]bool{}
		for _, l := range ls {
			out[l.BlockNumber] = true
		}
		return out
	}
	if a, b := blocksWith(want), blocksWith(got); len(a) != len(b) {
		t.Fatalf("partial drop emptied a block: %d blocks with logs, want %d", len(b), len(a))
	}

	// Disabled, the transport is a plain pass-through and counts nothing.
	tr.SetConfig(rpcfault.Config{HTTPErrorRate: 1})
	tr.SetEnabled(false)
	before := tr.Stats.Requests.Load()
	if _, err := src.Logs(ctx, chain.LogQuery{From: 1, To: 12, Addresses: addrs}); err != nil {
		t.Fatal(err)
	}
	if tr.Stats.Requests.Load() != before {
		t.Fatal("disabled transport counted a request")
	}
}

// TestBatchesAreNotAnsweredWithSingleErrors: a JSON-RPC error object only makes sense for a
// single call, so batches are forwarded (they can still hit HTTP errors, hangs and truncation).
func TestBatchesAreNotAnsweredWithSingleErrors(t *testing.T) {
	_, _, tr, src := faultyNode(t, rpcfault.Config{RPCErrorRate: 1})
	hs, err := src.HeadersByRange(context.Background(), 1, 5)
	if err != nil || len(hs) != 5 || tr.Stats.RPCErrors.Load() != 0 {
		t.Fatalf("batch: %d headers, %v, stats %v", len(hs), err, tr.Stats.Snapshot())
	}
}

// TestSeedDeterminism: two injectors with the same seed make the same decisions for the same
// request sequence.
func TestSeedDeterminism(t *testing.T) {
	run := func(seed uint64) map[string]int64 {
		_, _, tr, src := faultyNode(t, rpcfault.Config{Seed: seed, HTTPErrorRate: 0.3, RPCErrorRate: 0.3, TruncateRate: 0.3})
		for n := range uint64(40) {
			_, _ = src.HeaderByNumber(context.Background(), n%12)
		}
		return tr.Stats.Snapshot()
	}
	a, b := run(7), run(7)
	for k, v := range a {
		if b[k] != v {
			t.Fatalf("seed 7 diverged on %s: %v vs %v", k, a, b)
		}
	}
	if a["http_errors"]+a["rpc_errors"]+a["truncated"] == 0 {
		t.Fatalf("no faults injected: %v", a)
	}
}

func TestProxy(t *testing.T) {
	fc := fakechain.New(5)
	fc.Mine(nil)
	upstream := httptest.NewServer(fc.Handler())
	target, _ := url.Parse(upstream.URL)
	tr := rpcfault.New(nil, rpcfault.Config{})
	proxy := httptest.NewServer(rpcfault.NewProxy(target, tr))
	defer proxy.Close()
	src, err := chain.Dial(context.Background(), proxy.URL, chain.RPCOptions{CallTimeout: generousTimeout})
	if err != nil {
		t.Fatal(err)
	}
	defer src.Close()
	if id, err := src.ChainID(context.Background()); err != nil || id != 5 {
		t.Fatalf("through the proxy: %d %v", id, err)
	}
	if tr.Stats.Requests.Load() != 1 {
		t.Fatalf("proxy bypassed the injector: %v", tr.Stats.Snapshot())
	}
	upstream.Close()
	var he rpc.HTTPError
	if _, err := src.ChainID(context.Background()); !errors.As(err, &he) || he.StatusCode != http.StatusBadGateway {
		t.Fatalf("dead upstream: %v", err)
	}
}
