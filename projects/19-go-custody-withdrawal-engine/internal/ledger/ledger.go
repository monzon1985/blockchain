// SPDX-License-Identifier: MIT

// Package ledger implements the double-entry ledger.
//
// Every business event is one Entry: a set of postings whose signed amounts sum to zero per
// asset (debits equal credits). Amounts are debit-positive: an asset account holding funds has
// a positive balance, a liability (what the exchange owes a user) has a negative one.
//
// Chart of accounts (per asset):
//
//	user:<id>            liability  customer balance (negative = owed to the customer)
//	withdrawals_pending  liability  customer funds reserved for withdrawals not yet on chain
//	hot_wallet           asset      funds in the hot wallet, as of the last FINAL transaction
//	in_flight            asset      net on-chain effect of our transactions that are mined but
//	                                not yet final (negative = outflow already visible on chain)
//	forwarders           asset      credited deposits still sitting in deposit forwarders
//	fees                 expense    gas paid by the hot wallet
//	treasury             equity     operator capital (opening balance, top-ups)
//
// With those definitions the reconciliation identity is exact at any block the tracker has
// processed: on-chain hot-wallet balance == balance(hot_wallet) + balance(in_flight), i.e. the
// ledger hot_wallet minus what is in flight out of it.
package ledger

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

// Well-known account names.
const (
	HotWallet          = "hot_wallet"
	InFlight           = "in_flight"
	Fees               = "fees"
	WithdrawalsPending = "withdrawals_pending"
	Forwarders         = "forwarders"
	Treasury           = "treasury"
	userPrefix         = "user:"
)

// User returns the ledger account of a customer.
func User(id string) string { return userPrefix + id }

// IsUser reports whether account is a customer account.
func IsUser(account string) bool { return strings.HasPrefix(account, userPrefix) }

// Errors returned by Post.
var (
	ErrEmpty      = errors.New("ledger: entry has no postings")
	ErrUnbalanced = errors.New("ledger: debits do not equal credits")
	ErrZeroAmount = errors.New("ledger: posting amount is zero")
	ErrOverdraft  = errors.New("ledger: customer account would be overdrawn")
	ErrBadPosting = errors.New("ledger: malformed posting")
)

// Posting is one line of an entry.
type Posting struct {
	Account string
	Asset   string
	Amount  *big.Int // positive = debit, negative = credit
}

// Entry is a balanced set of postings identified by a unique reference. Posting the same
// reference twice is a no-op, which makes every ledger write idempotent under retries and
// crash recovery.
type Entry struct {
	Ref      string
	Kind     string
	Postings []Posting
}

// Debit and Credit are small helpers to build postings that read like accounting.
func Debit(account, asset string, amount *big.Int) Posting {
	return Posting{Account: account, Asset: asset, Amount: new(big.Int).Set(amount)}
}

// Credit is the negative-amount counterpart of Debit.
func Credit(account, asset string, amount *big.Int) Posting {
	return Posting{Account: account, Asset: asset, Amount: new(big.Int).Neg(amount)}
}

// Validate checks the structural rules of an entry without touching the database.
func (e Entry) Validate() error {
	if e.Ref == "" || e.Kind == "" {
		return fmt.Errorf("%w: missing ref or kind", ErrBadPosting)
	}
	if len(e.Postings) == 0 {
		return ErrEmpty
	}
	sums := map[string]*big.Int{}
	for _, p := range e.Postings {
		if p.Account == "" || p.Asset == "" || p.Amount == nil {
			return fmt.Errorf("%w: %+v", ErrBadPosting, p)
		}
		if p.Amount.Sign() == 0 {
			return fmt.Errorf("%w: %s %s", ErrZeroAmount, p.Account, p.Asset)
		}
		s, ok := sums[p.Asset]
		if !ok {
			s = new(big.Int)
			sums[p.Asset] = s
		}
		s.Add(s, p.Amount)
	}
	for asset, s := range sums {
		if s.Sign() != 0 {
			return fmt.Errorf("%w: asset %s is off by %s", ErrUnbalanced, asset, s)
		}
	}
	return nil
}

// Post writes e inside tx. It returns posted=false (and no error) if an entry with the same
// reference already exists. Customer accounts may never end up with a debit balance.
func Post(ctx context.Context, tx store.Querier, e Entry, now time.Time) (posted bool, err error) {
	if err := e.Validate(); err != nil {
		return false, err
	}
	res, err := tx.ExecContext(ctx,
		`INSERT INTO ledger_entries (ref, kind, created_at) VALUES (?, ?, ?) ON CONFLICT (ref) DO NOTHING`,
		e.Ref, e.Kind, now.UnixNano())
	if err != nil {
		return false, fmt.Errorf("ledger: insert entry: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return false, nil
	}
	entryID, err := res.LastInsertId()
	if err != nil {
		return false, fmt.Errorf("ledger: entry id: %w", err)
	}
	for _, p := range e.Postings {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO ledger_postings (entry_id, account, asset, amount) VALUES (?, ?, ?, ?)`,
			entryID, p.Account, p.Asset, p.Amount.String()); err != nil {
			return false, fmt.Errorf("ledger: insert posting: %w", err)
		}
		bal, err := Balance(ctx, tx, p.Account, p.Asset)
		if err != nil {
			return false, err
		}
		bal.Add(bal, p.Amount)
		if IsUser(p.Account) && bal.Sign() > 0 {
			return false, fmt.Errorf("%w: %s %s would be %s", ErrOverdraft, p.Account, p.Asset, bal)
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO ledger_balances (account, asset, balance) VALUES (?, ?, ?)
			 ON CONFLICT (account, asset) DO UPDATE SET balance = excluded.balance`,
			p.Account, p.Asset, bal.String()); err != nil {
			return false, fmt.Errorf("ledger: update balance: %w", err)
		}
	}
	return true, nil
}

// Balance returns the debit-positive balance of account in asset (zero if never posted).
func Balance(ctx context.Context, q store.Querier, account, asset string) (*big.Int, error) {
	var s string
	err := q.QueryRowContext(ctx, `SELECT balance FROM ledger_balances WHERE account = ? AND asset = ?`, account, asset).Scan(&s)
	if errors.Is(err, sql.ErrNoRows) {
		return new(big.Int), nil
	}
	if err != nil {
		return nil, fmt.Errorf("ledger: balance: %w", err)
	}
	return parse(s)
}

// Available returns what a customer can withdraw: the credit balance of user:<id>.
func Available(ctx context.Context, q store.Querier, accountID, asset string) (*big.Int, error) {
	b, err := Balance(ctx, q, User(accountID), asset)
	if err != nil {
		return nil, err
	}
	return b.Neg(b), nil
}

// EntryPostings returns the postings of the entry with reference ref.
func EntryPostings(ctx context.Context, q store.Querier, ref string) ([]Posting, error) {
	rows, err := q.QueryContext(ctx,
		`SELECT p.account, p.asset, p.amount FROM ledger_postings p JOIN ledger_entries e ON e.id = p.entry_id WHERE e.ref = ? ORDER BY p.rowid`, ref)
	if err != nil {
		return nil, fmt.Errorf("ledger: entry postings: %w", err)
	}
	defer rows.Close()
	var out []Posting
	for rows.Next() {
		var p Posting
		var amt string
		if err := rows.Scan(&p.Account, &p.Asset, &amt); err != nil {
			return nil, err
		}
		if p.Amount, err = parse(amt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, store.ErrNotFound
	}
	return out, nil
}

// Reverse posts the exact negation of the entry referenced by ref under reversalRef.
func Reverse(ctx context.Context, tx store.Querier, ref, reversalRef string, now time.Time) (bool, error) {
	ps, err := EntryPostings(ctx, tx, ref)
	if err != nil {
		return false, fmt.Errorf("ledger: reverse %s: %w", ref, err)
	}
	neg := make([]Posting, len(ps))
	for i, p := range ps {
		neg[i] = Posting{Account: p.Account, Asset: p.Asset, Amount: new(big.Int).Neg(p.Amount)}
	}
	return Post(ctx, tx, Entry{Ref: reversalRef, Kind: "reversal", Postings: neg}, now)
}

// Snapshot is the full set of balances.
type Snapshot map[string]map[string]*big.Int // account -> asset -> balance

// Balances reads every balance.
func Balances(ctx context.Context, q store.Querier) (Snapshot, error) {
	rows, err := q.QueryContext(ctx, `SELECT account, asset, balance FROM ledger_balances`)
	if err != nil {
		return nil, fmt.Errorf("ledger: balances: %w", err)
	}
	defer rows.Close()
	out := Snapshot{}
	for rows.Next() {
		var acct, asset, s string
		if err := rows.Scan(&acct, &asset, &s); err != nil {
			return nil, err
		}
		v, err := parse(s)
		if err != nil {
			return nil, err
		}
		if out[acct] == nil {
			out[acct] = map[string]*big.Int{}
		}
		out[acct][asset] = v
	}
	return out, rows.Err()
}

// Get returns a balance from the snapshot (zero when absent).
func (s Snapshot) Get(account, asset string) *big.Int {
	if v, ok := s[account][asset]; ok {
		return new(big.Int).Set(v)
	}
	return new(big.Int)
}

func parse(s string) (*big.Int, error) {
	v, ok := new(big.Int).SetString(s, 10)
	if !ok {
		return nil, fmt.Errorf("ledger: corrupt amount %q", s)
	}
	return v, nil
}
