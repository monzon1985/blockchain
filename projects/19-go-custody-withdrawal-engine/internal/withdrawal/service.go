// SPDX-License-Identifier: MIT

package withdrawal

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/audit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/clock"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/failpoint"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/metrics"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/policy"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/signer"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/txmgr"
)

// Outbox intent kinds.
const (
	IntentEvaluate = "withdrawal.evaluate"
	IntentSign     = "withdrawal.sign"
)

// Config is the service configuration.
type Config struct {
	Rules  policy.Rules
	Tokens map[string]common.Address // asset symbol -> ERC-20 contract
	// Forbidden destinations: the hot wallet, the forwarder factory, token contracts.
	Forbidden []common.Address
}

// Service implements the withdrawal operations behind the HTTP API.
type Service struct {
	db      *store.DB
	clock   clock.Clock
	fp      *failpoint.Set
	metrics *metrics.Metrics
	log     *slog.Logger
	cfg     Config
	txm     *txmgr.Manager
}

// NewService returns a Service.
func NewService(db *store.DB, clk clock.Clock, fp *failpoint.Set, m *metrics.Metrics, log *slog.Logger, cfg Config, txm *txmgr.Manager) (*Service, error) {
	if err := cfg.Rules.Validate(); err != nil {
		return nil, err
	}
	for sym := range cfg.Rules.Assets {
		if _, ok := cfg.Tokens[sym]; !ok {
			return nil, fmt.Errorf("withdrawal: asset %s has policy rules but no token address", sym)
		}
	}
	return &Service{db: db, clock: clk, fp: fp, metrics: m, log: log, cfg: cfg, txm: txm}, nil
}

// Rules exposes the policy (the API authenticates approvers with it).
func (s *Service) Rules() policy.Rules { return s.cfg.Rules }

// CreateRequest is the body of POST /v1/withdrawals.
type CreateRequest struct {
	AccountID   string `json:"account_id"`
	Asset       string `json:"asset"`
	Amount      string `json:"amount"`      // base units, decimal string
	Destination string `json:"destination"` // 0x-prefixed address
}

// Response is an HTTP response produced (or replayed) by the service.
type Response struct {
	Code     int
	Body     []byte
	Replayed bool
}

// ErrorBody is the JSON error shape.
type ErrorBody struct {
	Error ErrorDetail `json:"error"`
}

// ErrorDetail carries a machine-readable code and a human message.
type ErrorDetail struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// ErrorJSON renders an error body.
func ErrorJSON(code, msg string) []byte {
	b, _ := json.Marshal(ErrorBody{Error: ErrorDetail{Code: code, Message: msg}})
	return b
}

var (
	accountRe = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,64}$`)
	keyRe     = regexp.MustCompile(`^[\x21-\x7e]{1,255}$`)
	amountRe  = regexp.MustCompile(`^[1-9][0-9]{0,77}$`)
)

// ValidAccountID reports whether id is an acceptable account identifier.
func ValidAccountID(id string) bool { return accountRe.MatchString(id) }

// ValidIdempotencyKey reports whether key is an acceptable Idempotency-Key header value.
func ValidIdempotencyKey(key string) bool { return keyRe.MatchString(key) }

// ParseAmount parses a strictly formatted positive base-unit amount (no sign, no leading zeros,
// no exponent, at most 78 digits which covers uint256).
func ParseAmount(s string) (*big.Int, bool) {
	if !amountRe.MatchString(s) {
		return nil, false
	}
	v, ok := new(big.Int).SetString(s, 10)
	if !ok || v.BitLen() > 256 {
		return nil, false
	}
	return v, true
}

// ParseAddress parses a 0x-prefixed 20-byte hex address. Mixed-case input must carry a valid
// EIP-55 checksum, which catches most typos in pasted addresses.
func ParseAddress(s string) (common.Address, bool) {
	if !common.IsHexAddress(s) || !strings.HasPrefix(s, "0x") {
		return common.Address{}, false
	}
	a := common.HexToAddress(s)
	body := s[2:]
	if body != strings.ToLower(body) && body != strings.ToUpper(body) && a.Hex() != s {
		return common.Address{}, false
	}
	return a, true
}

// fingerprint is the request hash stored with an idempotency key: the normalised request, so
// whitespace and field order do not matter but any value change does.
func fingerprint(r CreateRequest) string {
	b, _ := json.Marshal(r)
	sum := sha256.Sum256(append([]byte("POST /v1/withdrawals\n"), b...))
	return hex.EncodeToString(sum[:])
}

// Create handles POST /v1/withdrawals. The withdrawal, its fund reservation, its outbox intent,
// its audit event and the idempotency record all commit in one transaction, so a retry with the
// same key after any failure either replays the stored response or runs the request for the
// first time; it can never create a second withdrawal.
func (s *Service) Create(ctx context.Context, clientID, key string, body []byte) (Response, error) {
	if !ValidIdempotencyKey(key) {
		return Response{Code: http.StatusBadRequest, Body: ErrorJSON("idempotency_key_required",
			"an Idempotency-Key header of 1-255 printable ASCII characters is required")}, nil
	}
	var req CreateRequest
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		return Response{Code: http.StatusBadRequest, Body: ErrorJSON("malformed_body", err.Error())}, nil
	}
	if dec.More() {
		return Response{Code: http.StatusBadRequest, Body: ErrorJSON("malformed_body", "trailing data after the JSON object")}, nil
	}
	fp := fingerprint(req)

	var resp Response
	err := s.db.WithTx(ctx, func(tx *store.Tx) error {
		var storedHash string
		var storedCode int
		var storedBody []byte
		err := tx.QueryRowContext(ctx, `SELECT request_hash, status_code, response_body FROM idempotency_keys WHERE client_id = ? AND key = ?`,
			clientID, key).Scan(&storedHash, &storedCode, &storedBody)
		switch {
		case err == nil:
			if storedHash != fp {
				resp = Response{Code: http.StatusUnprocessableEntity, Body: ErrorJSON("idempotency_key_reused",
					"this Idempotency-Key was already used with a different request body")}
				return nil
			}
			resp = Response{Code: storedCode, Body: storedBody, Replayed: true}
			return nil
		case !errors.Is(err, sql.ErrNoRows):
			return err
		}
		resp, err = s.createLocked(ctx, tx, clientID, req)
		if err != nil {
			return err
		}
		_, err = tx.ExecContext(ctx, `INSERT INTO idempotency_keys (client_id, key, request_hash, status_code, response_body, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
			clientID, key, fp, resp.Code, resp.Body, s.clock.Now().UnixNano())
		return err
	})
	if err != nil {
		return Response{}, err
	}
	if !resp.Replayed && resp.Code == http.StatusCreated {
		s.fp.Hit(failpoint.AfterRequestCommit)
	}
	return resp, nil
}

func (s *Service) reject(reason, msg string) Response {
	s.metrics.WithdrawalsRejected.WithLabelValues(reason).Inc()
	return Response{Code: http.StatusUnprocessableEntity, Body: ErrorJSON(reason, msg)}
}

func (s *Service) createLocked(ctx context.Context, tx *store.Tx, clientID string, req CreateRequest) (Response, error) {
	now := s.clock.Now()
	if !ValidAccountID(req.AccountID) {
		return s.reject("account_invalid", "account_id must match "+accountRe.String()), nil
	}
	amount, ok := ParseAmount(req.Amount)
	if !ok {
		return s.reject(policy.ReasonAmountInvalid, "amount must be a positive integer in base units"), nil
	}
	dest, ok := ParseAddress(req.Destination)
	if !ok {
		return s.reject(policy.ReasonBadDestination, "destination must be a 0x-prefixed address with a valid checksum"), nil
	}
	preq := policy.Request{AccountID: req.AccountID, Asset: req.Asset, Amount: amount, Destination: dest}
	st := policy.State{Now: now, Forbidden: s.cfg.Forbidden}
	var err error
	if st.Available, err = ledger.Available(ctx, tx, req.AccountID, req.Asset); err != nil {
		return Response{}, err
	}
	if st.UsedIn24h, err = usedInWindow(ctx, tx, req.AccountID, req.Asset, now); err != nil {
		return Response{}, err
	}
	if st.Allowlist, err = policy.Lookup(ctx, tx, req.AccountID, dest); err != nil {
		return Response{}, err
	}
	d := s.cfg.Rules.Evaluate(preq, st)
	if !d.Allowed {
		if err := audit.Record(ctx, tx, now, audit.Event{Type: "withdrawal.rejected", Actor: clientID, Subject: req.AccountID,
			Data: map[string]any{"reason": d.Reason, "asset": req.Asset, "amount": req.Amount, "destination": dest.Hex()}}); err != nil {
			return Response{}, err
		}
		return s.reject(d.Reason, "withdrawal refused by policy: "+d.Reason), nil
	}

	id, err := newID()
	if err != nil {
		return Response{}, err
	}
	w := Withdrawal{
		ID: id, ClientID: clientID, AccountID: req.AccountID, Asset: req.Asset, Amount: amount, Destination: dest,
		Status: Requested, ApprovalsRequired: d.ApprovalsRequired, CreatedAt: now, UpdatedAt: now,
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO withdrawals (id, client_id, account_id, asset, amount, destination, status, approvals_required, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		w.ID, clientID, w.AccountID, w.Asset, w.Amount.String(), w.Destination.Hex(), string(Requested), w.ApprovalsRequired,
		now.UnixNano(), now.UnixNano()); err != nil {
		return Response{}, err
	}
	if err := logTransition(ctx, tx, now, w.ID, Created, Requested, d.Reason); err != nil {
		return Response{}, err
	}
	if _, err := ledger.Post(ctx, tx, ledger.Entry{
		Ref:  "wd:" + w.ID + ":reserve",
		Kind: "withdrawal_reserve",
		Postings: []ledger.Posting{
			ledger.Debit(ledger.User(w.AccountID), w.Asset, w.Amount),
			ledger.Credit(ledger.WithdrawalsPending, w.Asset, w.Amount),
		},
	}, now); err != nil {
		return Response{}, err
	}
	if err := enqueue(ctx, tx, now, IntentEvaluate, w.ID); err != nil {
		return Response{}, err
	}
	if err := audit.Record(ctx, tx, now, audit.Event{Type: "withdrawal.requested", Actor: clientID, Subject: w.ID,
		Data: map[string]any{"account": w.AccountID, "asset": w.Asset, "amount": w.Amount.String(), "destination": w.Destination.Hex(),
			"approvals_required": w.ApprovalsRequired}}); err != nil {
		return Response{}, err
	}
	tx.OnCommit(func() { s.metrics.WithdrawalsCreated.Inc() })
	body, err := json.Marshal(ToView(w, nil))
	if err != nil {
		return Response{}, err
	}
	return Response{Code: http.StatusCreated, Body: body}, nil
}

// usedInWindow sums an account's withdrawals of asset created in the last 24 h that did not
// fail or get replaced (those returned their funds, so they no longer count).
func usedInWindow(ctx context.Context, q store.Querier, accountID, asset string, now time.Time) (*big.Int, error) {
	rows, err := q.QueryContext(ctx, `SELECT amount FROM withdrawals WHERE account_id = ? AND asset = ? AND created_at > ? AND status NOT IN ('failed', 'replaced')`,
		accountID, asset, now.Add(-policy.Window).UnixNano())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	sum := new(big.Int)
	for rows.Next() {
		var a string
		if err := rows.Scan(&a); err != nil {
			return nil, err
		}
		v, ok := new(big.Int).SetString(a, 10)
		if !ok {
			return nil, fmt.Errorf("withdrawal: corrupt amount %q", a)
		}
		sum.Add(sum, v)
	}
	return sum, rows.Err()
}

// Get returns a withdrawal with its approvals.
func (s *Service) Get(ctx context.Context, id string) (View, error) {
	w, err := Load(ctx, s.db, id)
	if err != nil {
		return View{}, err
	}
	a, err := Approvals(ctx, s.db, id)
	if err != nil {
		return View{}, err
	}
	return ToView(w, a), nil
}

// List returns an account's withdrawals.
func (s *Service) List(ctx context.Context, accountID string, limit int) ([]View, error) {
	ws, err := ListByAccount(ctx, s.db, accountID, limit)
	if err != nil {
		return nil, err
	}
	out := make([]View, 0, len(ws))
	for _, w := range ws {
		a, err := Approvals(ctx, s.db, w.ID)
		if err != nil {
			return nil, err
		}
		out = append(out, ToView(w, a))
	}
	return out, nil
}

// Errors returned by Approve and Cancel.
var (
	ErrNotPending      = errors.New("withdrawal: not awaiting approval")
	ErrAlreadyDecided  = errors.New("withdrawal: approver already decided")
	ErrNotCancellable  = errors.New("withdrawal: already final")
	ErrInvalidDecision = errors.New("withdrawal: decision must be approve or reject")
)

// Approve records an approver's decision. A rejection fails the withdrawal immediately and
// returns the funds; an approval queues a re-evaluation, which moves the withdrawal to
// approved once M distinct approvers agree.
func (s *Service) Approve(ctx context.Context, id, approverID, decision string) (View, error) {
	if decision != "approve" && decision != "reject" {
		return View{}, ErrInvalidDecision
	}
	err := s.db.WithTx(ctx, func(tx *store.Tx) error {
		now := s.clock.Now()
		w, err := Load(ctx, tx, id)
		if err != nil {
			return err
		}
		if w.Status != Requested {
			return ErrNotPending
		}
		res, err := tx.ExecContext(ctx, `INSERT INTO approvals (withdrawal_id, approver_id, decision, created_at) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING`,
			id, approverID, decision, now.UnixNano())
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return ErrAlreadyDecided
		}
		if err := audit.Record(ctx, tx, now, audit.Event{Type: "withdrawal.approval", Actor: approverID, Subject: id,
			Data: map[string]any{"decision": decision}}); err != nil {
			return err
		}
		if decision == "reject" {
			if err := transition(ctx, tx, s.metrics, now, &w, Failed, approverID, policy.ReasonRejectedByApprover); err != nil {
				return err
			}
			if err := s.setFailure(ctx, tx, w.ID, policy.ReasonRejectedByApprover); err != nil {
				return err
			}
			return refund(ctx, tx, now, w)
		}
		return enqueue(ctx, tx, now, IntentEvaluate, id)
	})
	if err != nil {
		return View{}, err
	}
	return s.Get(ctx, id)
}

func (s *Service) setFailure(ctx context.Context, tx *store.Tx, id, reason string) error {
	_, err := tx.ExecContext(ctx, `UPDATE withdrawals SET failure_reason = ? WHERE id = ?`, reason, id)
	return err
}

// Cancel stops a withdrawal. Before signing it fails immediately (funds returned, reserved nonce
// released). After signing the engine can only race the chain: it flags the nonce and the
// tracker sends a zero-value self-send at the same nonce with a bumped fee. Whichever
// transaction is mined decides between confirmed and replaced.
func (s *Service) Cancel(ctx context.Context, id, actor string) (View, error) {
	err := s.db.WithTx(ctx, func(tx *store.Tx) error {
		now := s.clock.Now()
		w, err := Load(ctx, tx, id)
		if err != nil {
			return err
		}
		switch w.Status {
		case Requested, Approved:
			if _, err := txmgr.Release(ctx, tx, signer.PurposeWithdrawal, w.ID); err != nil {
				return err
			}
			if err := transition(ctx, tx, s.metrics, now, &w, Failed, actor, "cancelled"); err != nil {
				return err
			}
			if err := s.setFailure(ctx, tx, w.ID, "cancelled"); err != nil {
				return err
			}
			return refund(ctx, tx, now, w)
		case Signed, Broadcast, Mined:
			if w.Nonce == nil {
				return fmt.Errorf("withdrawal %s is %s without a nonce", w.ID, w.Status)
			}
			if err := txmgr.RequestCancel(ctx, tx, *w.Nonce, now); err != nil {
				return err
			}
			return audit.Record(ctx, tx, now, audit.Event{Type: "withdrawal.cancel_requested", Actor: actor, Subject: w.ID,
				Data: map[string]any{"nonce": *w.Nonce}})
		default:
			return ErrNotCancellable
		}
	})
	if err != nil {
		return View{}, err
	}
	s.txm.Wake()
	return s.Get(ctx, id)
}

// ErrForbiddenDestination is returned when an engine-owned address is added to an allowlist.
var ErrForbiddenDestination = errors.New("withdrawal: destination is an engine-owned address")

// AddAllowlist registers a destination for an account. It becomes usable after the configured
// cool-down, which is what protects customers whose session is hijacked: an attacker cannot
// add an address and withdraw to it immediately. Every change is audited and counted
// (custody_allowlist_changes_total), so a burst, the signature of a stolen gateway token
// adding its own address everywhere, can be alerted on within the cool-down.
func (s *Service) AddAllowlist(ctx context.Context, actor, accountID string, addr common.Address, label string) (policy.AllowlistEntry, error) {
	if addr == (common.Address{}) {
		return policy.AllowlistEntry{}, ErrForbiddenDestination
	}
	for _, f := range s.cfg.Forbidden {
		if addr == f {
			return policy.AllowlistEntry{}, ErrForbiddenDestination
		}
	}
	var e policy.AllowlistEntry
	err := s.db.WithTx(ctx, func(tx *store.Tx) error {
		now := s.clock.Now()
		var err error
		if e, err = policy.Add(ctx, tx, accountID, addr, label, now, s.cfg.Rules.ActiveAt(now)); err != nil {
			return err
		}
		tx.OnCommit(func() { s.metrics.AllowlistChanges.WithLabelValues("added").Inc() })
		return audit.Record(ctx, tx, now, audit.Event{Type: "allowlist.added", Actor: actor, Subject: accountID,
			Data: map[string]any{"address": addr.Hex(), "label": label, "active_at": e.ActiveAt}})
	})
	return e, err
}

// RemoveAllowlist deletes a destination. Withdrawals already signed to it are not affected;
// the signing firewall refuses any new or bumped transaction to it.
func (s *Service) RemoveAllowlist(ctx context.Context, actor, accountID string, addr common.Address) (bool, error) {
	var removed bool
	err := s.db.WithTx(ctx, func(tx *store.Tx) error {
		var err error
		if removed, err = policy.Remove(ctx, tx, accountID, addr); err != nil || !removed {
			return err
		}
		tx.OnCommit(func() { s.metrics.AllowlistChanges.WithLabelValues("removed").Inc() })
		return audit.Record(ctx, tx, s.clock.Now(), audit.Event{Type: "allowlist.removed", Actor: actor, Subject: accountID,
			Data: map[string]any{"address": addr.Hex()}})
	})
	return removed, err
}
