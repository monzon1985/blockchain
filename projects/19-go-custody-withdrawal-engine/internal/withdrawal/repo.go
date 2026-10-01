// SPDX-License-Identifier: MIT

package withdrawal

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/audit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/metrics"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

// Withdrawal is the persisted record.
type Withdrawal struct {
	ID                string
	ClientID          string
	AccountID         string
	Asset             string
	Amount            *big.Int
	Destination       common.Address
	Status            Status
	ApprovalsRequired int
	Nonce             *uint64
	TxHash            *common.Hash
	FailureReason     string
	CreatedAt         time.Time
	UpdatedAt         time.Time
}

// Approval is one approver decision.
type Approval struct {
	ApproverID string    `json:"approver_id"`
	Decision   string    `json:"decision"`
	At         time.Time `json:"at"`
}

// View is the API representation.
type View struct {
	ID                string     `json:"id"`
	AccountID         string     `json:"account_id"`
	Asset             string     `json:"asset"`
	Amount            string     `json:"amount"`
	Destination       string     `json:"destination"`
	Status            Status     `json:"status"`
	ApprovalsRequired int        `json:"approvals_required"`
	Approvals         []Approval `json:"approvals"`
	Nonce             *uint64    `json:"nonce"`
	TxHash            *string    `json:"tx_hash"`
	FailureReason     string     `json:"failure_reason,omitempty"`
	CreatedAt         time.Time  `json:"created_at"`
	UpdatedAt         time.Time  `json:"updated_at"`
}

// ToView converts w (with its approvals) to its API form.
func ToView(w Withdrawal, approvals []Approval) View {
	v := View{
		ID: w.ID, AccountID: w.AccountID, Asset: w.Asset, Amount: w.Amount.String(), Destination: w.Destination.Hex(),
		Status: w.Status, ApprovalsRequired: w.ApprovalsRequired, Approvals: approvals, Nonce: w.Nonce,
		FailureReason: w.FailureReason, CreatedAt: w.CreatedAt, UpdatedAt: w.UpdatedAt,
	}
	if v.Approvals == nil {
		v.Approvals = []Approval{}
	}
	if w.TxHash != nil {
		h := w.TxHash.Hex()
		v.TxHash = &h
	}
	return v
}

func newID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return "wd_" + hex.EncodeToString(b[:]), nil
}

const wColumns = `id, client_id, account_id, asset, amount, destination, status, approvals_required, nonce, tx_hash,
	COALESCE(failure_reason, ''), created_at, updated_at`

func scanWithdrawal(row interface{ Scan(...any) error }) (Withdrawal, error) {
	var w Withdrawal
	var amount, dest, status string
	var nonce sql.NullInt64
	var txHash sql.NullString
	var created, updated int64
	if err := row.Scan(&w.ID, &w.ClientID, &w.AccountID, &w.Asset, &amount, &dest, &status, &w.ApprovalsRequired,
		&nonce, &txHash, &w.FailureReason, &created, &updated); err != nil {
		return Withdrawal{}, err
	}
	var ok bool
	if w.Amount, ok = new(big.Int).SetString(amount, 10); !ok {
		return Withdrawal{}, fmt.Errorf("withdrawal %s: corrupt amount", w.ID)
	}
	w.Destination = common.HexToAddress(dest)
	w.Status = Status(status)
	if nonce.Valid {
		n := uint64(nonce.Int64)
		w.Nonce = &n
	}
	if txHash.Valid {
		h := common.HexToHash(txHash.String)
		w.TxHash = &h
	}
	w.CreatedAt = time.Unix(0, created).UTC()
	w.UpdatedAt = time.Unix(0, updated).UTC()
	return w, nil
}

// Load reads a withdrawal.
func Load(ctx context.Context, q store.Querier, id string) (Withdrawal, error) {
	w, err := scanWithdrawal(q.QueryRowContext(ctx, `SELECT `+wColumns+` FROM withdrawals WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return Withdrawal{}, store.ErrNotFound
	}
	return w, err
}

// ListByAccount returns an account's withdrawals, newest first.
func ListByAccount(ctx context.Context, q store.Querier, accountID string, limit int) ([]Withdrawal, error) {
	rows, err := q.QueryContext(ctx, `SELECT `+wColumns+` FROM withdrawals WHERE account_id = ? ORDER BY created_at DESC, id LIMIT ?`, accountID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Withdrawal
	for rows.Next() {
		w, err := scanWithdrawal(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, w)
	}
	return out, rows.Err()
}

// All returns every withdrawal (tests and tooling).
func All(ctx context.Context, q store.Querier) ([]Withdrawal, error) {
	rows, err := q.QueryContext(ctx, `SELECT `+wColumns+` FROM withdrawals ORDER BY created_at, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Withdrawal
	for rows.Next() {
		w, err := scanWithdrawal(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, w)
	}
	return out, rows.Err()
}

// Approvals returns the decisions recorded for a withdrawal.
func Approvals(ctx context.Context, q store.Querier, id string) ([]Approval, error) {
	rows, err := q.QueryContext(ctx, `SELECT approver_id, decision, created_at FROM approvals WHERE withdrawal_id = ? ORDER BY created_at, approver_id`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Approval
	for rows.Next() {
		var a Approval
		var at int64
		if err := rows.Scan(&a.ApproverID, &a.Decision, &at); err != nil {
			return nil, err
		}
		a.At = time.Unix(0, at).UTC()
		out = append(out, a)
	}
	return out, rows.Err()
}

// Transition is one recorded state change.
type Transition struct {
	WithdrawalID string
	Seq          int
	From, To     Status
	Reason       string
}

// Transitions returns the full transition log (used by the model-based tests).
func Transitions(ctx context.Context, q store.Querier) ([]Transition, error) {
	rows, err := q.QueryContext(ctx, `SELECT withdrawal_id, seq, from_status, to_status, reason FROM withdrawal_transitions ORDER BY withdrawal_id, seq`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Transition
	for rows.Next() {
		var t Transition
		var from, to string
		if err := rows.Scan(&t.WithdrawalID, &t.Seq, &from, &to, &t.Reason); err != nil {
			return nil, err
		}
		t.From, t.To = Status(from), Status(to)
		out = append(out, t)
	}
	return out, rows.Err()
}

// ErrIllegalTransition is returned when a transition is not an edge of the state machine.
var ErrIllegalTransition = errors.New("withdrawal: illegal state transition")

// ErrStale is returned when the row changed under the caller.
var ErrStale = errors.New("withdrawal: state changed concurrently")

// transition moves w to `to`, logging the change, the audit event and metrics atomically.
func transition(ctx context.Context, tx *store.Tx, m *metrics.Metrics, now time.Time, w *Withdrawal, to Status, actor, reason string) error {
	if !CanTransition(w.Status, to) {
		return fmt.Errorf("%w: %s -> %s (%s)", ErrIllegalTransition, w.Status, to, w.ID)
	}
	from := w.Status
	res, err := tx.ExecContext(ctx, `UPDATE withdrawals SET status = ?, updated_at = ? WHERE id = ? AND status = ?`,
		string(to), now.UnixNano(), w.ID, string(from))
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return fmt.Errorf("%w: %s is no longer %s", ErrStale, w.ID, from)
	}
	if err := logTransition(ctx, tx, now, w.ID, from, to, reason); err != nil {
		return err
	}
	w.Status, w.UpdatedAt = to, now
	tx.OnCommit(func() { m.WithdrawalTransitions.WithLabelValues(string(from), string(to)).Inc() })
	return audit.Record(ctx, tx, now, audit.Event{
		Type: "withdrawal.transition", Actor: actor, Subject: w.ID,
		Data: map[string]any{"from": string(from), "to": string(to), "reason": reason},
	})
}

func logTransition(ctx context.Context, tx *store.Tx, now time.Time, id string, from, to Status, reason string) error {
	_, err := tx.ExecContext(ctx, `
		INSERT INTO withdrawal_transitions (withdrawal_id, seq, from_status, to_status, reason, at)
		VALUES (?, (SELECT COUNT(*) FROM withdrawal_transitions WHERE withdrawal_id = ?), ?, ?, ?, ?)`,
		id, id, string(from), string(to), reason, now.UnixNano())
	return err
}

// refund returns the reserved amount of w to the customer.
func refund(ctx context.Context, tx *store.Tx, now time.Time, w Withdrawal) error {
	_, err := ledger.Post(ctx, tx, ledger.Entry{
		Ref:  "wd:" + w.ID + ":refund",
		Kind: "withdrawal_refund",
		Postings: []ledger.Posting{
			ledger.Debit(ledger.WithdrawalsPending, w.Asset, w.Amount),
			ledger.Credit(ledger.User(w.AccountID), w.Asset, w.Amount),
		},
	}, now)
	return err
}

// enqueue adds an outbox intent.
func enqueue(ctx context.Context, tx *store.Tx, now time.Time, kind, ref string) error {
	_, err := tx.ExecContext(ctx, `INSERT INTO outbox (kind, ref_id, created_at, not_before) VALUES (?, ?, ?, ?)`,
		kind, ref, now.UnixNano(), now.UnixNano())
	return err
}
