// SPDX-License-Identifier: MIT

// Package postgres opens the indexer store on PostgreSQL through pgx's database/sql driver. It
// shares the embedded migrations and every query with the SQLite backend; only the transaction
// options differ.
package postgres

import (
	"context"
	"database/sql"
	"fmt"

	// Registers the "pgx" database/sql driver.
	_ "github.com/jackc/pgx/v5/stdlib"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store/sqlstore"
)

// migrationLockKey is an arbitrary constant identifying this application's advisory lock.
const migrationLockKey = 0x11_1D_E8

// Dialect is the PostgreSQL flavour of the shared SQL store. API reads run REPEATABLE READ so a
// page and its metadata (tip, safe head) come from one snapshot. Writes run at the default
// READ COMMITTED: the first statement of every indexer transaction is a compare-and-swap
// UPDATE of the single checkpoint row, which row-locks it and serialises writers.
var Dialect = sqlstore.Dialect{
	Name:          "postgres",
	Read:          sql.TxOptions{Isolation: sql.LevelRepeatableRead, ReadOnly: true},
	Write:         sql.TxOptions{},
	MigrationLock: fmt.Sprintf("SELECT pg_advisory_xact_lock(%d)", migrationLockKey),
}

// Open connects to dsn (a postgres:// URL or key=value string) and applies migrations.
func Open(ctx context.Context, dsn string) (*sqlstore.Store, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, fmt.Errorf("postgres: open: %w", err)
	}
	db.SetMaxOpenConns(16)
	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("postgres: ping: %w", err)
	}
	s, err := sqlstore.Open(ctx, db, Dialect)
	if err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("postgres: %w", err)
	}
	return s, nil
}
