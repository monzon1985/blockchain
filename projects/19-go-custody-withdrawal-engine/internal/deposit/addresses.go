// SPDX-License-Identifier: MIT

// Package deposit derives per-user CREATE2 deposit addresses, detects ERC-20 deposits to them
// with reorg-aware log scanning, credits them at the confirmation depth and sweeps forwarder
// balances to the hot wallet in batches through ForwarderFactory.flushMany.
package deposit

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/audit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

// cloneInitCode prefix and suffix of the ERC-1167 minimal proxy creation code, exactly as
// OpenZeppelin's Clones.cloneDeterministic assembles it around the implementation address.
var (
	clonePrefix = common.FromHex("3d602d80600a3d3981f3363d3d373d3d3d363d73")
	cloneSuffix = common.FromHex("5af43d82803e903d91602b57fd5bf3")
)

// Salt is the CREATE2 salt of an account: keccak256(bytes(accountID)).
func Salt(accountID string) common.Hash { return crypto.Keccak256Hash([]byte(accountID)) }

// CloneInitCodeHash returns keccak256 of the ERC-1167 creation code for implementation.
func CloneInitCodeHash(implementation common.Address) []byte {
	code := make([]byte, 0, len(clonePrefix)+20+len(cloneSuffix))
	code = append(code, clonePrefix...)
	code = append(code, implementation.Bytes()...)
	code = append(code, cloneSuffix...)
	return crypto.Keccak256(code)
}

// ForwarderAddress is the counterfactual deposit address for salt:
// keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))[12:].
func ForwarderAddress(factory, implementation common.Address, salt common.Hash) common.Address {
	return crypto.CreateAddress2(factory, salt, CloneInitCodeHash(implementation))
}

// Deriver computes deposit addresses for one factory deployment.
type Deriver struct {
	Factory        common.Address
	Implementation common.Address
	initCodeHash   []byte
}

// NewDeriver returns a Deriver.
func NewDeriver(factory, implementation common.Address) *Deriver {
	return &Deriver{Factory: factory, Implementation: implementation, initCodeHash: CloneInitCodeHash(implementation)}
}

// Address returns the deposit address and salt of accountID.
func (d *Deriver) Address(accountID string) (common.Address, common.Hash) {
	salt := Salt(accountID)
	return crypto.CreateAddress2(d.Factory, salt, d.initCodeHash), salt
}

// Address is a registered deposit address.
type Address struct {
	AccountID string         `json:"account_id"`
	Salt      common.Hash    `json:"salt"`
	Address   common.Address `json:"address"`
	CreatedAt time.Time      `json:"created_at"`
}

// Register records (idempotently) the deposit address of accountID so the scanner watches it.
func Register(ctx context.Context, tx *store.Tx, d *Deriver, accountID string, now time.Time) (Address, error) {
	addr, salt := d.Address(accountID)
	res, err := tx.ExecContext(ctx, `INSERT INTO deposit_addresses (account_id, salt, address, created_at) VALUES (?, ?, ?, ?) ON CONFLICT (account_id) DO NOTHING`,
		accountID, salt.Hex(), addr.Hex(), now.UnixNano())
	if err != nil {
		return Address{}, fmt.Errorf("deposit: register: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 1 {
		if err := audit.Record(ctx, tx, now, audit.Event{Type: "deposit.address_registered", Actor: "engine", Subject: accountID,
			Data: map[string]any{"address": addr.Hex(), "salt": salt.Hex()}}); err != nil {
			return Address{}, err
		}
	}
	return LookupAddress(ctx, tx, accountID)
}

// LookupAddress returns the registered address of accountID.
func LookupAddress(ctx context.Context, q store.Querier, accountID string) (Address, error) {
	var a Address
	var salt, addr string
	var created int64
	err := q.QueryRowContext(ctx, `SELECT account_id, salt, address, created_at FROM deposit_addresses WHERE account_id = ?`, accountID).
		Scan(&a.AccountID, &salt, &addr, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return Address{}, store.ErrNotFound
	}
	if err != nil {
		return Address{}, err
	}
	a.Salt, a.Address, a.CreatedAt = common.HexToHash(salt), common.HexToAddress(addr), time.Unix(0, created).UTC()
	return a, nil
}

// Addresses returns every registered deposit address keyed by address.
func Addresses(ctx context.Context, q store.Querier) (map[common.Address]Address, error) {
	rows, err := q.QueryContext(ctx, `SELECT account_id, salt, address, created_at FROM deposit_addresses`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[common.Address]Address{}
	for rows.Next() {
		var a Address
		var salt, addr string
		var created int64
		if err := rows.Scan(&a.AccountID, &salt, &addr, &created); err != nil {
			return nil, err
		}
		a.Salt, a.Address, a.CreatedAt = common.HexToHash(salt), common.HexToAddress(addr), time.Unix(0, created).UTC()
		out[a.Address] = a
	}
	return out, rows.Err()
}
