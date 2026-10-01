// SPDX-License-Identifier: MIT

package keeper

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
)

// Metrics are the keeper's Prometheus instruments, on a private registry.
type Metrics struct {
	Registry       *prometheus.Registry
	Actions        *prometheus.CounterVec
	ReportErrors   *prometheus.CounterVec
	BatchFallbacks prometheus.Counter
	Replacements   prometheus.Counter
	Retries        prometheus.Counter
	Ticks          prometheus.Counter
	Price          prometheus.Gauge
	PnlFactor      prometheus.Gauge
	Pending        *prometheus.GaugeVec
	TickSeconds    prometheus.Histogram
}

// NewMetrics registers the keeper metrics on a fresh registry.
func NewMetrics() *Metrics {
	m := &Metrics{
		Registry: prometheus.NewRegistry(),
		Actions: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "keeper_actions_total",
			Help: "Keeper transactions by action (order, lp_request, liquidation, adl) and result.",
		}, []string{"action", "result"}),
		ReportErrors: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "keeper_report_errors_total",
			Help: "Signer reports dropped, by signer URL and reason (fetch, not_in_set, malformed, future, stale, signature).",
		}, []string{"signer", "reason"}),
		BatchFallbacks: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "keeper_batch_fallbacks_total",
			Help: "Candidate report batches the on-chain verifier rejected in simulation (the next one was tried).",
		}),
		Replacements: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "keeper_tx_replacements_total",
			Help: "Transactions re-sent with the same nonce and higher fees after not being mined in time.",
		}),
		Retries: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "keeper_tx_retries_total", Help: "Transaction attempts beyond the first.",
		}),
		Ticks: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "keeper_ticks_total", Help: "Completed keeper iterations.",
		}),
		Price: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "keeper_median_price_usd", Help: "Median price of the last usable report batch (float).",
		}),
		PnlFactor: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "keeper_pnl_to_pool_factor", Help: "Aggregate positive trader PnL over pool liquidity (float).",
		}),
		Pending: prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Name: "keeper_pending", Help: "Tracked items by kind (orders, lp_requests, positions).",
		}, []string{"kind"}),
		TickSeconds: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name: "keeper_tick_seconds", Help: "Duration of a keeper iteration.",
			Buckets: prometheus.ExponentialBuckets(0.01, 2, 12),
		}),
	}
	m.Registry.MustRegister(m.Actions, m.ReportErrors, m.BatchFallbacks, m.Replacements, m.Retries, m.Ticks, m.Price,
		m.PnlFactor, m.Pending, m.TickSeconds, collectors.NewGoCollector())
	return m
}
