// SPDX-License-Identifier: MIT

package policy

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

// Allowlist persists per-account destination allowlists.
type Allowlist struct {
	db *store.DB
}

// NewAllowlist returns an Allowlist backed by db.
func NewAllowlist(db *store.DB) *Allowlist { return &Allowlist{db: db} }

// Add registers addr for accountID. Re-adding an existing entry does not reset its cool-down;
// removing and re-adding does (that is the point of the cool-down).
func Add(ctx context.Context, q store.Querier, accountID string, addr common.Address, label string, addedAt, activeAt time.Time) (AllowlistEntry, error) {
	_, err := q.ExecContext(ctx,
		`INSERT INTO allowlist (account_id, address, label, added_at, active_at) VALUES (?, ?, ?, ?, ?)
		 ON CONFLICT (account_id, address) DO NOTHING`,
		accountID, addr.Hex(), label, addedAt.UnixNano(), activeAt.UnixNano())
	if err != nil {
		return AllowlistEntry{}, fmt.Errorf("policy: add allowlist entry: %w", err)
	}
	e, err := Lookup(ctx, q, accountID, addr)
	if err != nil {
		return AllowlistEntry{}, err
	}
	if e == nil {
		return AllowlistEntry{}, errors.New("policy: allowlist entry vanished")
	}
	return *e, nil
}

// Remove deletes an entry; it reports whether one existed.
func Remove(ctx context.Context, q store.Querier, accountID string, addr common.Address) (bool, error) {
	res, err := q.ExecContext(ctx, `DELETE FROM allowlist WHERE account_id = ? AND address = ?`, accountID, addr.Hex())
	if err != nil {
		return false, fmt.Errorf("policy: remove allowlist entry: %w", err)
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// Lookup returns the entry for (accountID, addr), or nil.
func Lookup(ctx context.Context, q store.Querier, accountID string, addr common.Address) (*AllowlistEntry, error) {
	var added, active int64
	err := q.QueryRowContext(ctx, `SELECT added_at, active_at FROM allowlist WHERE account_id = ? AND address = ?`,
		accountID, addr.Hex()).Scan(&added, &active)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("policy: lookup allowlist: %w", err)
	}
	return &AllowlistEntry{Address: addr, AddedAt: time.Unix(0, added).UTC(), ActiveAt: time.Unix(0, active).UTC()}, nil
}

// ListEntry is an allowlist entry with its label.
type ListEntry struct {
	AllowlistEntry
	Label string
}

// List returns every entry of an account.
func List(ctx context.Context, q store.Querier, accountID string) ([]ListEntry, error) {
	rows, err := q.QueryContext(ctx, `SELECT address, label, added_at, active_at FROM allowlist WHERE account_id = ? ORDER BY added_at, address`, accountID)
	if err != nil {
		return nil, fmt.Errorf("policy: list allowlist: %w", err)
	}
	defer rows.Close()
	var out []ListEntry
	for rows.Next() {
		var addr, label string
		var added, active int64
		if err := rows.Scan(&addr, &label, &added, &active); err != nil {
			return nil, err
		}
		out = append(out, ListEntry{
			AllowlistEntry: AllowlistEntry{Address: common.HexToAddress(addr), AddedAt: time.Unix(0, added).UTC(), ActiveAt: time.Unix(0, active).UTC()},
			Label:          label,
		})
	}
	return out, rows.Err()
}

// IsActive implements signer.AllowlistChecker: the entry exists and its cool-down has passed.
func (a *Allowlist) IsActive(ctx context.Context, accountID string, addr common.Address, at time.Time) (bool, error) {
	e, err := Lookup(ctx, a.db, accountID, addr)
	if err != nil || e == nil {
		return false, err
	}
	return !at.Before(e.ActiveAt), nil
}
