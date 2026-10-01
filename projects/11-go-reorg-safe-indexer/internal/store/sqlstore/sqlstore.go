// SPDX-License-Identifier: MIT

// Package sqlstore implements store.Store on database/sql with SQL that SQLite and PostgreSQL
// both accept: `$n` placeholders (modernc.org/sqlite binds them by ordinal), ON CONFLICT
// upserts and row-value-free keyset predicates. The backends differ only in driver, DSN and
// transaction options, which the thin sqlite and postgres packages supply as a Dialect.
package sqlstore

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"slices"
	"strconv"
	"strings"
)

//go:embed migrations/*.sql
var migrationFS embed.FS

// Dialect carries what differs between backends.
type Dialect struct {
	// Name is reported by Store.Backend.
	Name string
	// Read is used for View transactions (a consistent snapshot).
	Read sql.TxOptions
	// Write is used for Update transactions.
	Write sql.TxOptions
	// MigrationLock, when set, runs first in every migration transaction so that concurrent
	// processes migrating the same database serialise (PostgreSQL uses an advisory lock;
	// SQLite's BEGIN IMMEDIATE already serialises writers).
	MigrationLock string
}

// Store is the database/sql implementation of store.Store.
type Store struct {
	db      *sql.DB
	dialect Dialect
}

// Open wraps db, applies pending migrations and returns the store.
func Open(ctx context.Context, db *sql.DB, d Dialect) (*Store, error) {
	s := &Store{db: db, dialect: d}
	if err := s.migrate(ctx); err != nil {
		return nil, err
	}
	return s, nil
}

// DB exposes the underlying handle (tests use it to corrupt data on purpose).
func (s *Store) DB() *sql.DB { return s.db }

// Backend implements store.Store.
func (s *Store) Backend() string { return s.dialect.Name }

// Ping implements store.Store.
func (s *Store) Ping(ctx context.Context) error { return s.db.PingContext(ctx) }

// Close implements store.Store.
func (s *Store) Close() error { return s.db.Close() }

// Migration is one embedded schema migration.
type Migration struct {
	Version    int
	Name       string
	Statements []string
}

// Migrations returns the embedded migrations in version order.
func Migrations() ([]Migration, error) {
	entries, err := fs.ReadDir(migrationFS, "migrations")
	if err != nil {
		return nil, err
	}
	var out []Migration
	for _, e := range entries {
		name := e.Name()
		prefix, _, ok := strings.Cut(name, "_")
		if !ok || !strings.HasSuffix(name, ".sql") {
			return nil, fmt.Errorf("sqlstore: migration %q is not named NNNN_name.sql", name)
		}
		v, err := strconv.Atoi(prefix)
		if err != nil {
			return nil, fmt.Errorf("sqlstore: migration %q: %w", name, err)
		}
		body, err := migrationFS.ReadFile("migrations/" + name)
		if err != nil {
			return nil, err
		}
		out = append(out, Migration{Version: v, Name: name, Statements: SplitStatements(string(body))})
	}
	slices.SortFunc(out, func(a, b Migration) int { return a.Version - b.Version })
	for i := range out {
		if out[i].Version != i+1 {
			return nil, fmt.Errorf("sqlstore: migration versions must be 1..n without gaps, found %d at position %d", out[i].Version, i+1)
		}
	}
	return out, nil
}

// SplitStatements splits a migration into statements on semicolons that end a line, dropping
// `--` comment lines. The migrations never put a semicolon inside a string literal.
func SplitStatements(body string) []string {
	var out []string
	var cur strings.Builder
	for line := range strings.SplitSeq(strings.ReplaceAll(body, "\r\n", "\n"), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "--") {
			continue
		}
		cur.WriteString(line)
		cur.WriteByte('\n')
		if strings.HasSuffix(trimmed, ";") {
			stmt := strings.TrimSpace(cur.String())
			out = append(out, strings.TrimSuffix(stmt, ";"))
			cur.Reset()
		}
	}
	if rest := strings.TrimSpace(cur.String()); rest != "" {
		out = append(out, rest)
	}
	return out
}

func (s *Store) migrate(ctx context.Context) error {
	migrations, err := Migrations()
	if err != nil {
		return err
	}
	for _, m := range migrations {
		if err := s.apply(ctx, m); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) apply(ctx context.Context, m Migration) error {
	tx, err := s.db.BeginTx(ctx, &s.dialect.Write)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if s.dialect.MigrationLock != "" {
		if _, err := tx.ExecContext(ctx, s.dialect.MigrationLock); err != nil {
			return fmt.Errorf("sqlstore: migration lock: %w", err)
		}
	}
	if _, err := tx.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version BIGINT PRIMARY KEY,
		name    TEXT NOT NULL
	)`); err != nil {
		return fmt.Errorf("sqlstore: create schema_migrations: %w", err)
	}
	var n int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM schema_migrations WHERE version = $1`, m.Version).Scan(&n); err != nil {
		return fmt.Errorf("sqlstore: read schema_migrations: %w", err)
	}
	if n > 0 {
		return nil
	}
	for _, stmt := range m.Statements {
		if _, err := tx.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("sqlstore: migration %s: %w\n%s", m.Name, err, stmt)
		}
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO schema_migrations (version, name) VALUES ($1, $2)`, m.Version, m.Name); err != nil {
		return err
	}
	return tx.Commit()
}

// SchemaVersion returns the highest applied migration.
func (s *Store) SchemaVersion(ctx context.Context) (int, error) {
	var v sql.NullInt64
	if err := s.db.QueryRowContext(ctx, `SELECT MAX(version) FROM schema_migrations`).Scan(&v); err != nil {
		return 0, err
	}
	return int(v.Int64), nil
}

// ErrClosedTx is returned when a transaction handle is used after its callback returned.
var ErrClosedTx = errors.New("sqlstore: transaction already finished")
