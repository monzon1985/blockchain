// SPDX-License-Identifier: MIT

// Package api exposes the engine over HTTP with chi.
//
// Authentication is by bearer token. Two principal kinds exist: clients (the exchange's
// internal services that submit withdrawals on behalf of customers) and approvers (operators
// who approve large withdrawals and cancel stuck ones). Tokens are configured as SHA-256
// hashes and compared in constant time.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/app"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/deposit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/failpoint"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/policy"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/withdrawal"
)

// maxBody caps request bodies.
const maxBody = 64 << 10

type ctxKey int

const principalKey ctxKey = 0

type principal struct {
	kind string // "client" or "approver"
	id   string
}

// Server holds the handlers' dependencies.
type Server struct {
	a         *app.App
	clients   []policy.Principal
	approvers []policy.Principal
	log       *slog.Logger
}

// NewRouter builds the HTTP handler.
func NewRouter(a *app.App) http.Handler {
	s := &Server{a: a, log: a.Log, approvers: a.Withdrawals.Rules().ApproverPrincipals()}
	for _, c := range a.Cfg.Clients {
		s.clients = append(s.clients, policy.Principal{ID: c.ID, TokenSHA256: c.TokenSHA256})
	}
	r := chi.NewRouter()
	r.Use(s.recoverer, middleware.RequestID, s.instrument)
	r.Get("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	r.Get("/readyz", s.ready)
	r.Handle("/metrics", a.Metrics.Handler())

	r.Route("/v1", func(r chi.Router) {
		r.Group(func(r chi.Router) {
			r.Use(s.auth("client"))
			r.Post("/withdrawals", s.createWithdrawal)
			r.Get("/accounts/{account}/withdrawals", s.listWithdrawals)
			r.Get("/accounts/{account}/balances", s.balances)
			r.Get("/accounts/{account}/allowlist", s.listAllowlist)
			r.Post("/accounts/{account}/allowlist", s.addAllowlist)
			r.Delete("/accounts/{account}/allowlist/{address}", s.removeAllowlist)
			r.Post("/accounts/{account}/deposit-address", s.depositAddress)
			r.Get("/accounts/{account}/deposit-address", s.depositAddress)
			r.Get("/accounts/{account}/deposits", s.listDeposits)
		})
		r.Group(func(r chi.Router) {
			r.Use(s.auth("approver"))
			r.Post("/withdrawals/{id}/approvals", s.approve)
			r.Post("/withdrawals/{id}/cancel", s.cancel)
		})
		r.Group(func(r chi.Router) {
			r.Use(s.auth("client", "approver"))
			r.Get("/withdrawals/{id}", s.getWithdrawal)
			r.Get("/reconciliation", s.reconciliation)
		})
	})
	return r
}

// recoverer turns handler panics into 500s, except failpoint crashes, which must take the whole
// process down (net/http would otherwise swallow them).
func (s *Server) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				if c, ok := failpoint.AsCrash(v); ok {
					failpoint.Die(c)
				}
				if v == http.ErrAbortHandler {
					panic(v)
				}
				s.log.Error("handler panic", "panic", v, "path", r.URL.Path)
				writeError(w, http.StatusInternalServerError, "internal", "internal error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.code = code
	s.ResponseWriter.WriteHeader(code)
}

func (s *Server) instrument(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
		next.ServeHTTP(rec, r)
		route := chi.RouteContext(r.Context()).RoutePattern()
		if route == "" {
			route = "unmatched"
		}
		s.a.Metrics.HTTPRequests.WithLabelValues(route, strconv.Itoa(rec.code)).Inc()
		s.a.Metrics.HTTPDuration.WithLabelValues(route).Observe(time.Since(start).Seconds())
		s.log.Info("http", "method", r.Method, "route", route, "code", rec.code, "ms", time.Since(start).Milliseconds(),
			"request_id", middleware.GetReqID(r.Context()))
	})
}

func (s *Server) auth(kinds ...string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			if !ok || token == "" {
				writeError(w, http.StatusUnauthorized, "unauthenticated", "a bearer token is required")
				return
			}
			for _, k := range kinds {
				set := s.clients
				if k == "approver" {
					set = s.approvers
				}
				if id, ok := policy.Authenticate(token, set); ok {
					ctx := context.WithValue(r.Context(), principalKey, principal{kind: k, id: id})
					next.ServeHTTP(w, r.WithContext(ctx))
					return
				}
			}
			writeError(w, http.StatusForbidden, "forbidden", "this token may not call this endpoint")
		})
	}
}

func who(r *http.Request) principal {
	p, _ := r.Context().Value(principalKey).(principal)
	return p
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeRaw(w http.ResponseWriter, code int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_, _ = w.Write(body)
}

func writeError(w http.ResponseWriter, code int, errCode, msg string) {
	writeRaw(w, code, withdrawal.ErrorJSON(errCode, msg))
}

// internalError logs err with the request id and answers a generic 500. Storage and node error
// strings (SQL text, file paths, RPC URLs that may embed a provider key) are for the operator's
// log, never for API clients.
func (s *Server) internalError(w http.ResponseWriter, r *http.Request, what string, err error) {
	s.log.Error(what, "err", err, "request_id", middleware.GetReqID(r.Context()))
	writeError(w, http.StatusInternalServerError, "internal", "internal error; see the server log for request "+middleware.GetReqID(r.Context()))
}

func readBody(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "body_too_large", "request body exceeds 64 KiB")
		return nil, false
	}
	return body, true
}

func (s *Server) ready(w http.ResponseWriter, r *http.Request) {
	// /readyz is unauthenticated: the details go to the log, the response only names the
	// dependency that is down.
	if _, err := s.a.Chain.Head(r.Context()); err != nil {
		s.log.Warn("readiness: node unreachable", "err", err)
		writeError(w, http.StatusServiceUnavailable, "node_unreachable", "the Ethereum node is not answering")
		return
	}
	if err := s.a.DB.PingContext(r.Context()); err != nil {
		s.log.Warn("readiness: database unavailable", "err", err)
		writeError(w, http.StatusServiceUnavailable, "database_unavailable", "the database is not answering")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (s *Server) createWithdrawal(w http.ResponseWriter, r *http.Request) {
	body, ok := readBody(w, r)
	if !ok {
		return
	}
	resp, err := s.a.Withdrawals.Create(r.Context(), who(r).id, r.Header.Get("Idempotency-Key"), body)
	if err != nil {
		s.internalError(w, r, "create withdrawal", err)
		return
	}
	if resp.Replayed {
		w.Header().Set("Idempotent-Replayed", "true")
	}
	if resp.Code == http.StatusCreated && !resp.Replayed {
		s.a.WakeDispatcher()
	}
	writeRaw(w, resp.Code, resp.Body)
}

func (s *Server) getWithdrawal(w http.ResponseWriter, r *http.Request) {
	v, err := s.a.Withdrawals.Get(r.Context(), chi.URLParam(r, "id"))
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found", "no such withdrawal")
		return
	}
	if err != nil {
		s.internalError(w, r, "get withdrawal", err)
		return
	}
	writeJSON(w, http.StatusOK, v)
}

func accountParam(w http.ResponseWriter, r *http.Request) (string, bool) {
	id := chi.URLParam(r, "account")
	if !withdrawal.ValidAccountID(id) {
		writeError(w, http.StatusBadRequest, "account_invalid", "invalid account id")
		return "", false
	}
	return id, true
}

func (s *Server) listWithdrawals(w http.ResponseWriter, r *http.Request) {
	acct, ok := accountParam(w, r)
	if !ok {
		return
	}
	limit := 100
	if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v > 0 && v <= 1000 {
		limit = v
	}
	vs, err := s.a.Withdrawals.List(r.Context(), acct, limit)
	if err != nil {
		s.internalError(w, r, "list withdrawals", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"withdrawals": vs})
}

func (s *Server) balances(w http.ResponseWriter, r *http.Request) {
	acct, ok := accountParam(w, r)
	if !ok {
		return
	}
	out := map[string]string{}
	for sym := range s.a.Tokens {
		v, err := ledger.Available(r.Context(), s.a.DB, acct, sym)
		if err != nil {
			s.internalError(w, r, "balances", err)
			return
		}
		out[sym] = v.String()
	}
	writeJSON(w, http.StatusOK, map[string]any{"account_id": acct, "available": out})
}

type allowlistView struct {
	Address  string    `json:"address"`
	Label    string    `json:"label"`
	AddedAt  time.Time `json:"added_at"`
	ActiveAt time.Time `json:"active_at"`
}

func (s *Server) listAllowlist(w http.ResponseWriter, r *http.Request) {
	acct, ok := accountParam(w, r)
	if !ok {
		return
	}
	es, err := policy.List(r.Context(), s.a.DB, acct)
	if err != nil {
		s.internalError(w, r, "list allowlist", err)
		return
	}
	out := make([]allowlistView, 0, len(es))
	for _, e := range es {
		out = append(out, allowlistView{Address: e.Address.Hex(), Label: e.Label, AddedAt: e.AddedAt, ActiveAt: e.ActiveAt})
	}
	writeJSON(w, http.StatusOK, map[string]any{"allowlist": out})
}

func (s *Server) addAllowlist(w http.ResponseWriter, r *http.Request) {
	acct, ok := accountParam(w, r)
	if !ok {
		return
	}
	body, ok := readBody(w, r)
	if !ok {
		return
	}
	var req struct {
		Address string `json:"address"`
		Label   string `json:"label"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "malformed_body", err.Error())
		return
	}
	addr, ok := withdrawal.ParseAddress(req.Address)
	if !ok || len(req.Label) > 128 {
		writeError(w, http.StatusUnprocessableEntity, "destination_invalid", "address must be a 0x-prefixed address with a valid checksum; label at most 128 bytes")
		return
	}
	e, err := s.a.Withdrawals.AddAllowlist(r.Context(), who(r).id, acct, addr, req.Label)
	if errors.Is(err, withdrawal.ErrForbiddenDestination) {
		writeError(w, http.StatusUnprocessableEntity, "destination_invalid", err.Error())
		return
	}
	if err != nil {
		s.internalError(w, r, "add allowlist entry", err)
		return
	}
	writeJSON(w, http.StatusCreated, allowlistView{Address: addr.Hex(), Label: req.Label, AddedAt: e.AddedAt, ActiveAt: e.ActiveAt})
}

func (s *Server) removeAllowlist(w http.ResponseWriter, r *http.Request) {
	acct, ok := accountParam(w, r)
	if !ok {
		return
	}
	addr, ok := withdrawal.ParseAddress(chi.URLParam(r, "address"))
	if !ok {
		writeError(w, http.StatusBadRequest, "destination_invalid", "invalid address")
		return
	}
	removed, err := s.a.Withdrawals.RemoveAllowlist(r.Context(), who(r).id, acct, addr)
	if err != nil {
		s.internalError(w, r, "remove allowlist entry", err)
		return
	}
	if !removed {
		writeError(w, http.StatusNotFound, "not_found", "address is not on the allowlist")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) depositAddress(w http.ResponseWriter, r *http.Request) {
	acct, ok := accountParam(w, r)
	if !ok {
		return
	}
	var out deposit.Address
	err := s.a.DB.WithTx(r.Context(), func(tx *store.Tx) error {
		var err error
		out, err = deposit.Register(r.Context(), tx, s.a.Deriver, acct, s.a.Clock.Now())
		return err
	})
	if err != nil {
		s.internalError(w, r, "deposit address", err)
		return
	}
	// EIP-55 checksummed, so wallets can detect a mistyped deposit address.
	writeJSON(w, http.StatusOK, map[string]any{
		"account_id": out.AccountID, "address": out.Address.Hex(), "salt": out.Salt.Hex(), "created_at": out.CreatedAt,
	})
}

func (s *Server) listDeposits(w http.ResponseWriter, r *http.Request) {
	acct, ok := accountParam(w, r)
	if !ok {
		return
	}
	ds, err := deposit.List(r.Context(), s.a.DB, acct)
	if err != nil {
		s.internalError(w, r, "list deposits", err)
		return
	}
	if ds == nil {
		ds = []deposit.Deposit{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"deposits": ds})
}

func (s *Server) approve(w http.ResponseWriter, r *http.Request) {
	body, ok := readBody(w, r)
	if !ok {
		return
	}
	var req struct {
		Decision string `json:"decision"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "malformed_body", err.Error())
		return
	}
	v, err := s.a.Withdrawals.Approve(r.Context(), chi.URLParam(r, "id"), who(r).id, req.Decision)
	switch {
	case err == nil:
		s.a.WakeDispatcher()
		writeJSON(w, http.StatusOK, v)
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "no such withdrawal")
	case errors.Is(err, withdrawal.ErrInvalidDecision):
		writeError(w, http.StatusBadRequest, "decision_invalid", err.Error())
	case errors.Is(err, withdrawal.ErrNotPending), errors.Is(err, withdrawal.ErrAlreadyDecided):
		writeError(w, http.StatusConflict, "conflict", err.Error())
	default:
		s.internalError(w, r, "approve withdrawal", err)
	}
}

func (s *Server) cancel(w http.ResponseWriter, r *http.Request) {
	v, err := s.a.Withdrawals.Cancel(r.Context(), chi.URLParam(r, "id"), who(r).id)
	switch {
	case err == nil:
		writeJSON(w, http.StatusAccepted, v)
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "no such withdrawal")
	case errors.Is(err, withdrawal.ErrNotCancellable):
		writeError(w, http.StatusConflict, "conflict", err.Error())
	default:
		s.internalError(w, r, "cancel withdrawal", err)
	}
}

func (s *Server) reconciliation(w http.ResponseWriter, _ *http.Request) {
	rep, ok := s.a.Recon.Last()
	if !ok {
		writeError(w, http.StatusNotFound, "not_found", "no reconciliation has run yet")
		return
	}
	writeJSON(w, http.StatusOK, rep)
}
