// SPDX-License-Identifier: MIT

// Package metrics defines the engine's Prometheus instruments on a private registry, so tests
// can create independent instances and the process exposes exactly what it registers.
package metrics

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Metrics holds every instrument.
type Metrics struct {
	Registry *prometheus.Registry

	WithdrawalsCreated    prometheus.Counter
	WithdrawalsRejected   *prometheus.CounterVec // reason
	WithdrawalTransitions *prometheus.CounterVec // from, to
	TxSigned              *prometheus.CounterVec // purpose, kind
	TxSendResults         *prometheus.CounterVec // outcome
	FeeBumps              prometheus.Counter
	FeeCapReached         prometheus.Counter
	Rebroadcasts          prometheus.Counter
	InclusionReorgs       prometheus.Counter
	NonceGapsFilled       prometheus.Counter
	NonceDrift            prometheus.Counter
	ReservationsReleased  prometheus.Counter
	DepositsSeen          prometheus.Counter
	DepositsCredited      prometheus.Counter
	DepositsOrphaned      prometheus.Counter
	DepositsStale         prometheus.Counter
	DeepReorgs            prometheus.Counter
	Sweeps                *prometheus.CounterVec // outcome
	ReconciliationRuns    *prometheus.CounterVec // result
	ReconciliationDelta   *prometheus.GaugeVec   // asset
	AllowlistChanges      *prometheus.CounterVec // action
	AuditShipFailures     prometheus.Counter
	OutboxPending         prometheus.Gauge
	TrackerHead           prometheus.Gauge
	HTTPRequests          *prometheus.CounterVec   // route, code
	HTTPDuration          *prometheus.HistogramVec // route
}

// New creates and registers every instrument.
func New() *Metrics {
	r := prometheus.NewRegistry()
	f := func(c prometheus.Collector) { r.MustRegister(c) }
	m := &Metrics{Registry: r}

	m.WithdrawalsCreated = prometheus.NewCounter(prometheus.CounterOpts{Name: "custody_withdrawals_created_total", Help: "Withdrawals accepted by the API."})
	m.WithdrawalsRejected = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "custody_withdrawals_rejected_total", Help: "Withdrawal requests refused by policy, by reason."}, []string{"reason"})
	m.WithdrawalTransitions = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "custody_withdrawal_transitions_total", Help: "Withdrawal state transitions."}, []string{"from", "to"})
	m.TxSigned = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "custody_tx_signed_total", Help: "Transactions signed, by purpose and attempt kind."}, []string{"purpose", "kind"})
	m.TxSendResults = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "custody_tx_send_results_total", Help: "eth_sendRawTransaction results, by classified outcome."}, []string{"outcome"})
	m.FeeBumps = prometheus.NewCounter(prometheus.CounterOpts{Name: "custody_fee_bumps_total", Help: "Replace-by-fee replacements created (including cancellations)."})
	m.FeeCapReached = prometheus.NewCounter(prometheus.CounterOpts{Name: "custody_fee_cap_reached_total", Help: "Bumps skipped because the fee cap was reached."})
	m.Rebroadcasts = prometheus.NewCounter(prometheus.CounterOpts{Name: "custody_rebroadcasts_total", Help: "Transactions re-sent after the node forgot them."})
	m.InclusionReorgs = prometheus.NewCounter(prometheus.CounterOpts{Name: "custody_inclusion_reorgs_total", Help: "Inclusions reverted because the receipt moved or disappeared."})
	m.NonceGapsFilled = prometheus.NewCounter(prometheus.CounterOpts{Name: "custody_nonce_gaps_filled_total", Help: "Nonce gaps filled with zero-value self-sends."})
	m.NonceDrift = prometheus.NewCounter(prometheus.CounterOpts{Name: "custody_nonce_drift_total", Help: "Times the on-chain nonce was ahead of the engine's records."})
	m.ReservationsReleased = prometheus.NewCounter(prometheus.CounterOpts{Name: "custody_nonce_reservations_released_total", Help: "Nonce reservations released without ever being signed (failed retry estimate, abandoned filler, or stale)."})
	m.DepositsSeen = prometheus.NewCounter(prometheus.CounterOpts{Name: "custody_deposits_seen_total", Help: "Deposit Transfer logs observed."})
	m.DepositsCredited = prometheus.NewCounter(prometheus.CounterOpts{Name: "custody_deposits_credited_total", Help: "Deposits credited after reaching the confirmation depth."})
	m.DepositsOrphaned = prometheus.NewCounter(prometheus.CounterOpts{Name: "custody_deposits_orphaned_total", Help: "Uncredited deposits discarded by a reorg."})
	m.DepositsStale = prometheus.NewCounter(prometheus.CounterOpts{Name: "custody_deposits_stale_pending_total", Help: "Pending deposits found at the confirmation depth in a block that is no longer canonical; the scanner rewinds below them (should stay at zero)."})
	m.DeepReorgs = prometheus.NewCounter(prometheus.CounterOpts{Name: "custody_deep_reorgs_total", Help: "Reorgs deeper than the confirmation depth (manual intervention required)."})
	m.Sweeps = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "custody_sweeps_total", Help: "Batch sweeps, by final outcome."}, []string{"outcome"})
	m.ReconciliationRuns = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "custody_reconciliation_runs_total", Help: "Reconciliation runs, by result."}, []string{"result"})
	m.ReconciliationDelta = prometheus.NewGaugeVec(prometheus.GaugeOpts{Name: "custody_reconciliation_delta", Help: "On-chain minus expected hot-wallet balance at the last reconciliation, in base units (lossy float)."}, []string{"asset"})
	m.AllowlistChanges = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "custody_allowlist_changes_total", Help: "Withdrawal allowlist changes, by action (added, removed); alert on bursts."}, []string{"action"})
	m.AuditShipFailures = prometheus.NewCounter(prometheus.CounterOpts{Name: "custody_audit_ship_failures_total", Help: "Audit shipping rounds that failed, including a shipper refusing to append to a corrupt or divergent log."})
	m.OutboxPending = prometheus.NewGauge(prometheus.GaugeOpts{Name: "custody_outbox_pending", Help: "Outbox intents not yet executed."})
	m.TrackerHead = prometheus.NewGauge(prometheus.GaugeOpts{Name: "custody_tracker_head", Help: "Last block processed by the transaction tracker."})
	m.HTTPRequests = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "custody_http_requests_total", Help: "HTTP requests by route and status code."}, []string{"route", "code"})
	m.HTTPDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{Name: "custody_http_request_duration_seconds", Help: "HTTP request latency by route.", Buckets: prometheus.DefBuckets}, []string{"route"})

	for _, c := range []prometheus.Collector{
		m.WithdrawalsCreated, m.WithdrawalsRejected, m.WithdrawalTransitions, m.TxSigned, m.TxSendResults,
		m.FeeBumps, m.FeeCapReached, m.Rebroadcasts, m.InclusionReorgs, m.NonceGapsFilled, m.NonceDrift, m.ReservationsReleased,
		m.DepositsSeen, m.DepositsCredited, m.DepositsOrphaned, m.DepositsStale, m.DeepReorgs, m.Sweeps,
		m.ReconciliationRuns, m.ReconciliationDelta, m.AllowlistChanges, m.AuditShipFailures, m.OutboxPending, m.TrackerHead,
		m.HTTPRequests, m.HTTPDuration,
		collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	} {
		f(c)
	}
	return m
}

// Handler serves the registry in the Prometheus exposition format.
func (m *Metrics) Handler() http.Handler {
	return promhttp.HandlerFor(m.Registry, promhttp.HandlerOpts{Registry: m.Registry})
}
