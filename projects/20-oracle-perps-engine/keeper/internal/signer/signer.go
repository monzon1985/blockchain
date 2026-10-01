// SPDX-License-Identifier: MIT

// Package signer implements one member of the oracle signer set: an HTTP service that signs the current price of a
// deterministic price path as an EIP-712 PriceReport.
package signer

import (
	"crypto/ecdsa"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"math/big"
	"net/http"
	"strconv"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/pricepath"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/report"
)

// DefaultMaxBackdate is how far before its own clock a signer dates a report on request by default.
const DefaultMaxBackdate = 60 * time.Second

// Config configures a signer.
type Config struct {
	Key      *ecdsa.PrivateKey
	Domain   report.Domain
	MarketID [32]byte
	Path     *pricepath.Path
	// Start is the wall-clock time of the path's first step.
	Start time.Time
	// NoiseBps shifts every quote by a fixed number of basis points, so the signer set disagrees slightly (as real
	// independent sources do) and the on-chain median is exercised.
	NoiseBps int64
	// Account is the signer-set member the reports are signed for. Zero means the key's own address (an EOA
	// signer); set it to an ERC-1271 contract wallet that accepts Key's signatures to run a contract signer.
	Account common.Address
	// MaxBackdate bounds `GET /report?notAfter=T`: the keeper asks for a report dated no later than T (the latest
	// block's timestamp, because nodes simulate transactions against that block and the verifier rejects reports
	// from its future). The signer never dates a report after its own clock, and refuses a T more than MaxBackdate
	// in the past (default DefaultMaxBackdate), so it cannot be used as an oracle of arbitrary historical prices.
	MaxBackdate time.Duration
	// Now overrides the clock (tests); defaults to time.Now.
	Now    func() time.Time
	Logger *slog.Logger
}

// Server serves /report, /healthz and /metrics.
type Server struct {
	cfg       Config
	address   common.Address
	registry  *prometheus.Registry
	served    prometheus.Counter
	failures  prometheus.Counter
	backdated prometheus.Counter
	lastPrice prometheus.Gauge
	mux       *http.ServeMux
}

// errTooOld is returned when the requested notAfter is further in the past than MaxBackdate.
var errTooOld = errors.New("signer: notAfter is further in the past than the maximum backdate")

// New validates the configuration and builds the HTTP handler.
func New(cfg Config) (*Server, error) {
	if cfg.Key == nil || cfg.Path == nil || cfg.Domain.ChainID == nil {
		return nil, errors.New("signer: key, path and domain are required")
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	if cfg.MaxBackdate <= 0 {
		cfg.MaxBackdate = DefaultMaxBackdate
	}
	address := cfg.Account
	if address == (common.Address{}) {
		address = crypto.PubkeyToAddress(cfg.Key.PublicKey)
	}
	s := &Server{
		cfg:      cfg,
		address:  address,
		registry: prometheus.NewRegistry(),
		served: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "signer_reports_served_total", Help: "Signed reports served.",
		}),
		failures: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "signer_report_failures_total", Help: "Report requests that failed to sign.",
		}),
		backdated: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "signer_reports_backdated_total", Help: "Reports dated at a keeper's notAfter rather than now.",
		}),
		lastPrice: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "signer_last_price_usd", Help: "Last signed price in USD (float, for dashboards only).",
		}),
		mux: http.NewServeMux(),
	}
	s.registry.MustRegister(s.served, s.failures, s.backdated, s.lastPrice, collectors.NewGoCollector())
	s.mux.HandleFunc("GET /report", s.handleReport)
	s.mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok\n"))
	})
	s.mux.Handle("GET /metrics", promhttp.HandlerFor(s.registry, promhttp.HandlerOpts{}))
	return s, nil
}

// Address is the signer-set member the reports are signed for (the key's address, or the configured Account).
func (s *Server) Address() common.Address { return s.address }

// Handler returns the HTTP handler.
func (s *Server) Handler() http.Handler { return s.mux }

// Report signs the price active now.
func (s *Server) Report() (report.Report, error) {
	return s.ReportAt(s.cfg.Now())
}

// ReportAt signs the price active at t, dated t.
func (s *Server) ReportAt(t time.Time) (report.Report, error) {
	price := pricepath.ApplyBps(s.cfg.Path.PriceAt(s.cfg.Start, t), s.cfg.NoiseBps)
	r, err := report.Sign(s.cfg.Key, s.cfg.Domain, s.cfg.MarketID, price, uint64(t.Unix()))
	if err != nil {
		return report.Report{}, err
	}
	r.Signer = s.address
	return r, nil
}

// reportTime is the time a request asks for: now, or the keeper's notAfter when that is earlier.
func (s *Server) reportTime(notAfter string) (time.Time, bool, error) {
	now := s.cfg.Now()
	if notAfter == "" {
		return now, false, nil
	}
	v, err := strconv.ParseUint(notAfter, 10, 64)
	if err != nil || v > math.MaxInt64 {
		return time.Time{}, false, fmt.Errorf("signer: notAfter %q is not a unix timestamp", notAfter)
	}
	limit := time.Unix(int64(v), 0)
	if !limit.Before(now.Truncate(time.Second)) {
		return now, false, nil
	}
	if now.Sub(limit) > s.cfg.MaxBackdate {
		return time.Time{}, false, errTooOld
	}
	return limit, true, nil
}

func (s *Server) handleReport(w http.ResponseWriter, req *http.Request) {
	at, backdated, err := s.reportTime(req.URL.Query().Get("notAfter"))
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errTooOld) {
			status = http.StatusUnprocessableEntity
		}
		http.Error(w, err.Error(), status)
		return
	}
	r, err := s.ReportAt(at)
	if err != nil {
		s.failures.Inc()
		s.cfg.Logger.Error("sign report", "err", err)
		http.Error(w, "cannot sign report", http.StatusInternalServerError)
		return
	}
	s.served.Inc()
	if backdated {
		s.backdated.Inc()
	}
	usd, _ := new(big.Float).Quo(new(big.Float).SetInt(r.Price), big.NewFloat(1e18)).Float64()
	s.lastPrice.Set(usd)
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(r); err != nil {
		s.cfg.Logger.Warn("write report", "err", err)
	}
}
