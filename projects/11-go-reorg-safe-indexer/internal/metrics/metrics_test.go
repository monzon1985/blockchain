// SPDX-License-Identifier: MIT

package metrics

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestObserveRPC(t *testing.T) {
	m := New()
	m.ObserveRPC("eth_getLogs", 3*time.Millisecond, nil)
	m.ObserveRPC("eth_getLogs", time.Millisecond, context.DeadlineExceeded)
	m.ObserveRPC("eth_chainId", time.Millisecond, errors.New("query returned more than 10000 results"))
	if got := testutil.ToFloat64(m.RPCRequests.WithLabelValues("eth_getLogs")); got != 2 {
		t.Fatalf("requests %v", got)
	}
	if got := testutil.ToFloat64(m.RPCErrors.WithLabelValues("eth_getLogs", "timeout")); got != 1 {
		t.Fatalf("timeout errors %v", got)
	}
	if got := testutil.ToFloat64(m.RPCErrors.WithLabelValues("eth_chainId", "range_too_large")); got != 1 {
		t.Fatalf("limit errors %v", got)
	}
}

func TestBlocksPerSecondUsesATenSecondWindow(t *testing.T) {
	m := New()
	t0 := time.Unix(1_000_000, 0)
	m.ObserveBlocks(10, t0)
	if got := testutil.ToFloat64(m.BlocksPerSecond); got != 10 {
		t.Fatalf("first sample: %v blocks/s (the window floors at 1s)", got)
	}
	m.ObserveBlocks(30, t0.Add(4*time.Second))
	if got := testutil.ToFloat64(m.BlocksPerSecond); got != 10 {
		t.Fatalf("40 blocks over 4s: %v", got)
	}
	// 20s later the old samples have left the window.
	m.ObserveBlocks(5, t0.Add(24*time.Second))
	if got := testutil.ToFloat64(m.BlocksPerSecond); got != 5 {
		t.Fatalf("after the window: %v", got)
	}
	if got := testutil.ToFloat64(m.BlocksIndexed); got != 45 {
		t.Fatalf("blocks indexed %v", got)
	}
}

func TestRegistryExposesEveryMetric(t *testing.T) {
	m := New()
	m.Retractions.WithLabelValues("transfer").Inc()
	m.RPCRequests.WithLabelValues("eth_getLogs").Inc()
	m.RPCErrors.WithLabelValues("eth_getLogs", "http").Inc()
	m.RPCRetries.WithLabelValues("headers").Inc()
	m.BloomRefetches.WithLabelValues("recovered").Inc()
	m.SyncErrors.WithLabelValues("other").Inc()
	m.EventsPublished.WithLabelValues("transfer").Inc()
	m.RPCDuration.WithLabelValues("eth_getLogs").Observe(0.01)
	m.ReorgDepth.Observe(3)
	m.CommitDuration.Observe(0.01)
	families, err := m.Registry.Gather()
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, f := range families {
		names[f.GetName()] = true
	}
	for _, want := range []string{
		"indexer_chain_head_block", "indexer_indexed_head_block", "indexer_safe_head_block", "indexer_head_lag_blocks",
		"indexer_blocks_indexed_total", "indexer_blocks_per_second", "indexer_reorgs_total", "indexer_reorg_depth_blocks",
		"indexer_deep_reorgs_total", "indexer_retractions_total", "indexer_rpc_requests_total", "indexer_rpc_errors_total",
		"indexer_rpc_duration_seconds", "indexer_getlogs_range_splits_total", "indexer_getlogs_range_span_blocks",
		"indexer_receipt_fallbacks_total", "indexer_sse_clients", "go_goroutines",
	} {
		if !names[want] {
			t.Errorf("metric %s is not registered", want)
		}
	}
	for n := range names {
		if !strings.HasPrefix(n, "indexer_") && !strings.HasPrefix(n, "go_") && !strings.HasPrefix(n, "process_") {
			t.Errorf("unexpected metric %s", n)
		}
	}
}
