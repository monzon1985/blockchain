// SPDX-License-Identifier: MIT

// Package api serves the indexed data: cursor-paginated REST endpoints with a "latest" and a
// "safe" view, a Server-Sent Events stream backed by the transactional outbox (with explicit
// `retract` events for data removed by reorgs and Last-Event-ID resumption), Prometheus
// metrics, liveness and a lag-aware readiness probe.
//
// Every page is read in one snapshot transaction together with the metadata (tip, safe head)
// it reports, and nothing is silently truncated: a limit above the maximum is a 400, and
// `hasMore` plus `nextCursor` are always explicit.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/decode"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/metrics"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store"
)

// Pagination limits.
const (
	DefaultLimit = 100
	MaxLimit     = 1000
)

// Health is what the readiness probe judges.
type Health struct {
	// Tip is the last indexed block (nil before the first commit).
	Tip *chain.BlockRef
	// ChainHead is the latest node head the indexer saw.
	ChainHead uint64
	// UpdatedAt is when the indexer last completed a sync (or wrote a heartbeat).
	UpdatedAt time.Time
	// LastError is the last sync error, empty after a successful sync.
	LastError string
}

// HealthFunc reports indexer health: from the in-process engine, or from the database's
// checkpoint when the API runs without an indexer.
type HealthFunc func(ctx context.Context) (Health, error)

// Config configures a Server.
type Config struct {
	ChainID       uint64
	Confirmations uint64
	Contracts     decode.Contracts
	// MaxLag is the largest head lag, in blocks, at which /readyz still reports ready.
	MaxLag uint64
	// StaleAfter is how old the last successful sync may be before /readyz fails.
	StaleAfter time.Duration
	// PollInterval is how often SSE streams look for new events when no in-process
	// notification arrives (the API may run in another process than the indexer).
	PollInterval time.Duration
	// Heartbeat is the SSE keep-alive comment interval.
	Heartbeat time.Duration
	// OpsOnly serves only /healthz, /readyz and /metrics (the `index` command).
	OpsOnly bool
}

// Server is the HTTP API.
type Server struct {
	cfg     Config
	st      store.Store
	health  HealthFunc
	m       *metrics.Metrics
	log     *slog.Logger
	hub     *Hub
	tokens  map[common.Address]bool
	vaults  map[common.Address]bool
	handler http.Handler
	now     func() time.Time

	streams     context.Context
	stopStreams context.CancelFunc
}

// New builds the server. hub may be nil (streams then rely on polling only).
func New(cfg Config, st store.Store, health HealthFunc, m *metrics.Metrics, hub *Hub, log *slog.Logger) *Server {
	if cfg.StaleAfter <= 0 {
		cfg.StaleAfter = time.Minute
	}
	if cfg.PollInterval <= 0 {
		cfg.PollInterval = time.Second
	}
	if cfg.Heartbeat <= 0 {
		cfg.Heartbeat = 15 * time.Second
	}
	if hub == nil {
		hub = NewHub()
	}
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	s := &Server{cfg: cfg, st: st, health: health, m: m, log: log.With("component", "api"), hub: hub,
		tokens: map[common.Address]bool{}, vaults: map[common.Address]bool{}, now: time.Now}
	s.streams, s.stopStreams = context.WithCancel(context.Background())
	for _, a := range cfg.Contracts.Addresses() {
		s.tokens[a] = true
	}
	for v := range cfg.Contracts.Vaults {
		s.vaults[v] = true
	}
	s.handler = s.routes()
	return s
}

// Handler returns the root handler.
func (s *Server) Handler() http.Handler { return s.handler }

// Hub returns the notification hub (the engine's OnCommit calls Hub().Notify).
func (s *Server) Hub() *Hub { return s.hub }

// CloseStreams ends every open SSE stream. http.Server.Shutdown does not cancel request
// contexts, so the serve command registers this with RegisterOnShutdown; clients reconnect
// elsewhere and resume with Last-Event-ID.
func (s *Server) CloseStreams() { s.stopStreams() }

func (s *Server) routes() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RequestID, middleware.Recoverer, s.accessLog)
	r.NotFound(func(w http.ResponseWriter, _ *http.Request) {
		writeError(w, http.StatusNotFound, "not_found", "no such endpoint")
	})
	r.MethodNotAllowed(func(w http.ResponseWriter, _ *http.Request) {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "only GET is supported")
	})
	r.Get("/healthz", s.healthz)
	r.Get("/readyz", s.readyz)
	if s.m != nil {
		r.Handle("/metrics", promhttp.HandlerFor(s.m.Registry, promhttp.HandlerOpts{}))
	}
	if s.cfg.OpsOnly {
		return r
	}
	r.Route("/v1", func(r chi.Router) {
		r.Get("/status", s.status)
		r.Get("/transfers", s.transfers)
		r.Get("/tokens/{token}/balances", s.tokenBalances)
		r.Get("/accounts/{address}/balances", s.accountBalances)
		r.Get("/vaults/{vault}/events", s.vaultEvents)
		r.Get("/vaults/{vault}/share-prices", s.sharePrices)
		r.Get("/stream", s.stream)
	})
	return r
}

func (s *Server) accessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
		next.ServeHTTP(ww, r)
		s.log.Debug("request", "method", r.Method, "path", r.URL.Path, "status", ww.Status(),
			"bytes", ww.BytesWritten(), "duration_ms", time.Since(start).Milliseconds(),
			"request_id", middleware.GetReqID(r.Context()))
	})
}

// --- errors and JSON --------------------------------------------------------------------------

type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]apiError{"error": {Code: code, Message: msg}})
}

// requestError is a client error carrying its HTTP status and code.
type requestError struct {
	status int
	code   string
	msg    string
}

func (e *requestError) Error() string { return e.msg }

func badRequest(code, msg string) error {
	return &requestError{status: http.StatusBadRequest, code: code, msg: msg}
}

func notFound(code, msg string) error {
	return &requestError{status: http.StatusNotFound, code: code, msg: msg}
}

func (s *Server) fail(w http.ResponseWriter, r *http.Request, err error) {
	var re *requestError
	if errors.As(err, &re) {
		writeError(w, re.status, re.code, re.msg)
		return
	}
	if errors.Is(err, context.Canceled) {
		return
	}
	s.log.Error("request failed", "path", r.URL.Path, "err", err, "request_id", middleware.GetReqID(r.Context()))
	writeError(w, http.StatusInternalServerError, "internal", "internal error")
}

// --- health -----------------------------------------------------------------------------------

func (s *Server) healthz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.st.Ping(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "unhealthy", "reason": "database: " + err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

type readiness struct {
	Ready     bool            `json:"ready"`
	Reason    string          `json:"reason,omitempty"`
	Tip       *chain.BlockRef `json:"tip"`
	ChainHead uint64          `json:"chainHead"`
	Lag       uint64          `json:"lag"`
	MaxLag    uint64          `json:"maxLag"`
	UpdatedAt *time.Time      `json:"updatedAt"`
	LastError string          `json:"lastError,omitempty"`
}

func (s *Server) readiness(ctx context.Context) (readiness, error) {
	h, err := s.health(ctx)
	if err != nil {
		return readiness{}, err
	}
	out := readiness{Tip: h.Tip, ChainHead: h.ChainHead, MaxLag: s.cfg.MaxLag, LastError: h.LastError}
	if !h.UpdatedAt.IsZero() {
		t := h.UpdatedAt.UTC()
		out.UpdatedAt = &t
	}
	if h.Tip != nil && h.ChainHead > h.Tip.Number {
		out.Lag = h.ChainHead - h.Tip.Number
	}
	switch {
	case h.Tip == nil:
		out.Reason = "nothing indexed yet"
	case h.UpdatedAt.IsZero() || s.now().Sub(h.UpdatedAt) > s.cfg.StaleAfter:
		out.Reason = "no successful sync within " + s.cfg.StaleAfter.String()
	case out.Lag > s.cfg.MaxLag:
		out.Reason = "indexer is behind the chain head"
	default:
		out.Ready = true
	}
	return out, nil
}

func (s *Server) readyz(w http.ResponseWriter, r *http.Request) {
	rd, err := s.readiness(r.Context())
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, readiness{Reason: "health unavailable: " + err.Error()})
		return
	}
	status := http.StatusOK
	if !rd.Ready {
		status = http.StatusServiceUnavailable
	}
	writeJSON(w, status, rd)
}

// --- hub --------------------------------------------------------------------------------------

// Hub wakes SSE streams when the in-process indexer commits. Notify never blocks.
type Hub struct {
	mu sync.Mutex
	ch chan struct{}
}

// NewHub returns a hub.
func NewHub() *Hub { return &Hub{ch: make(chan struct{})} }

// Notify wakes every current waiter.
func (h *Hub) Notify() {
	h.mu.Lock()
	defer h.mu.Unlock()
	close(h.ch)
	h.ch = make(chan struct{})
}

// Wait returns a channel closed by the next Notify.
func (h *Hub) Wait() <-chan struct{} {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.ch
}
