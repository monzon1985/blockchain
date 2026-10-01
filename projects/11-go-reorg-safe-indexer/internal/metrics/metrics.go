// SPDX-License-Identifier: MIT

// Package metrics defines the indexer's Prometheus metrics on a private registry (never the
// global one), so tests and multiple engines in one process do not collide.
package metrics

import (
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
)

const namespace = "indexer"

// Metrics groups every collector.
type Metrics struct {
	Registry *prometheus.Registry

	ChainHead       prometheus.Gauge
	IndexedHead     prometheus.Gauge
	SafeHead        prometheus.Gauge
	HeadLag         prometheus.Gauge
	BlocksIndexed   prometheus.Counter
	BlocksPerSecond prometheus.Gauge
	LogsIndexed     prometheus.Counter
	Undecodable     prometheus.Counter
	CommitDuration  prometheus.Histogram

	Reorgs      prometheus.Counter
	ReorgDepth  prometheus.Histogram
	DeepReorgs  prometheus.Counter
	Retractions *prometheus.CounterVec

	RPCRequests      *prometheus.CounterVec
	RPCErrors        *prometheus.CounterVec
	RPCDuration      *prometheus.HistogramVec
	RPCRetries       *prometheus.CounterVec
	RangeSplits      prometheus.Counter
	RangeSpan        prometheus.Gauge
	BloomRefetches   *prometheus.CounterVec
	ReceiptFallbacks prometheus.Counter
	SyncErrors       *prometheus.CounterVec

	BalanceAnomalies prometheus.Counter
	EventsPublished  *prometheus.CounterVec
	SSEClients       prometheus.Gauge

	rateMu      sync.Mutex
	rateSamples []rateSample
}

type rateSample struct {
	at     time.Time
	blocks int
}

// New builds and registers every collector, plus the Go runtime and process collectors.
func New() *Metrics {
	m := &Metrics{Registry: prometheus.NewRegistry()}
	gauge := func(name, help string) prometheus.Gauge {
		return prometheus.NewGauge(prometheus.GaugeOpts{Namespace: namespace, Name: name, Help: help})
	}
	counter := func(name, help string) prometheus.Counter {
		return prometheus.NewCounter(prometheus.CounterOpts{Namespace: namespace, Name: name, Help: help})
	}
	counterVec := func(name, help string, labels ...string) *prometheus.CounterVec {
		return prometheus.NewCounterVec(prometheus.CounterOpts{Namespace: namespace, Name: name, Help: help}, labels)
	}

	m.ChainHead = gauge("chain_head_block", "Latest block number reported by the node.")
	m.IndexedHead = gauge("indexed_head_block", "Last block committed to the database.")
	m.SafeHead = gauge("safe_head_block", "Highest indexed block with at least --confirmations confirmations.")
	m.HeadLag = gauge("head_lag_blocks", "Chain head minus indexed head.")
	m.BlocksIndexed = counter("blocks_indexed_total", "Blocks committed (re-indexed blocks after a reorg count again).")
	m.BlocksPerSecond = gauge("blocks_per_second", "Blocks committed per second over the last 10 seconds.")
	m.LogsIndexed = counter("logs_indexed_total", "Raw logs committed.")
	m.Undecodable = counter("undecodable_logs_total", "Logs with a tracked event signature but a non-canonical encoding (stored raw only).")
	m.CommitDuration = prometheus.NewHistogram(prometheus.HistogramOpts{Namespace: namespace, Name: "commit_duration_seconds",
		Help: "Duration of one segment or rollback transaction.", Buckets: prometheus.ExponentialBuckets(0.001, 2, 14)})

	m.Reorgs = counter("reorgs_total", "Reorgs detected and rolled back.")
	m.ReorgDepth = prometheus.NewHistogram(prometheus.HistogramOpts{Namespace: namespace, Name: "reorg_depth_blocks",
		Help: "Number of indexed blocks orphaned by each reorg.", Buckets: []float64{1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 64, 128}})
	m.DeepReorgs = counter("deep_reorgs_total", "Reorgs deeper than --confirmations (data in the safe view was retracted).")
	m.Retractions = counterVec("retractions_total", "Records removed by rollbacks, by type.", "type")

	m.RPCRequests = counterVec("rpc_requests_total", "JSON-RPC requests (a batch counts once).", "method")
	m.RPCErrors = counterVec("rpc_errors_total", "Failed JSON-RPC requests by error kind.", "method", "kind")
	m.RPCDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{Namespace: namespace, Name: "rpc_duration_seconds",
		Help: "JSON-RPC request latency.", Buckets: prometheus.ExponentialBuckets(0.001, 2, 15)}, []string{"method"})
	m.RPCRetries = counterVec("rpc_retries_total", "Transient RPC failures that were retried.", "op")
	m.RangeSplits = counter("getlogs_range_splits_total", "eth_getLogs ranges halved after a limit error or a timeout.")
	m.RangeSpan = gauge("getlogs_range_span_blocks", "Current adaptive eth_getLogs span.")
	m.BloomRefetches = counterVec("bloom_refetches_total", "Per-block re-queries triggered by the bloom check.", "result")
	m.ReceiptFallbacks = counter("receipt_fallbacks_total", "Blocks read from eth_getBlockReceipts because their logs exceed the provider's eth_getLogs cap.")
	m.SyncErrors = counterVec("sync_errors_total", "Failed sync iterations by cause.", "kind")

	m.BalanceAnomalies = counter("balance_anomalies_total", "Balances that became negative (a token moved balances without Transfer events).")
	m.EventsPublished = counterVec("stream_events_total", "Events appended to the SSE outbox, by kind.", "kind")
	m.SSEClients = gauge("sse_clients", "Connected SSE clients.")

	m.Registry.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		m.ChainHead, m.IndexedHead, m.SafeHead, m.HeadLag, m.BlocksIndexed, m.BlocksPerSecond, m.LogsIndexed,
		m.Undecodable, m.CommitDuration, m.Reorgs, m.ReorgDepth, m.DeepReorgs, m.Retractions,
		m.RPCRequests, m.RPCErrors, m.RPCDuration, m.RPCRetries, m.RangeSplits, m.RangeSpan,
		m.BloomRefetches, m.ReceiptFallbacks, m.SyncErrors, m.BalanceAnomalies, m.EventsPublished, m.SSEClients,
	)
	return m
}

// ObserveRPC is a chain.Observer.
func (m *Metrics) ObserveRPC(method string, elapsed time.Duration, err error) {
	m.RPCRequests.WithLabelValues(method).Inc()
	m.RPCDuration.WithLabelValues(method).Observe(elapsed.Seconds())
	if err != nil {
		m.RPCErrors.WithLabelValues(method, chain.Kind(err)).Inc()
	}
}

// ObserveBlocks records n committed blocks and refreshes the blocks-per-second gauge.
func (m *Metrics) ObserveBlocks(n int, now time.Time) {
	m.BlocksIndexed.Add(float64(n))
	m.rateMu.Lock()
	defer m.rateMu.Unlock()
	m.rateSamples = append(m.rateSamples, rateSample{at: now, blocks: n})
	cutoff := now.Add(-10 * time.Second)
	i := 0
	for i < len(m.rateSamples) && m.rateSamples[i].at.Before(cutoff) {
		i++
	}
	m.rateSamples = m.rateSamples[i:]
	total := 0
	for _, s := range m.rateSamples {
		total += s.blocks
	}
	window := now.Sub(m.rateSamples[0].at).Seconds()
	if window < 1 {
		window = 1
	}
	m.BlocksPerSecond.Set(float64(total) / window)
}
