// SPDX-License-Identifier: MIT

// Package store owns the SQLite database: opening it with durable settings, applying the
// embedded schema migrations and running write transactions with post-commit hooks.
//
// The engine uses a single connection. SQLite serialises writers anyway, and a single
// connection turns every "check then write" sequence (velocity limits, nonce allocation,
// idempotency keys) into a critical section without application-level locking. No RPC call
// is ever made while a transaction is open, so the connection is never held across the network.
package store

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"modernc.org/sqlite" // pure-Go SQLite driver (CGO_ENABLED=0)
)

//go:embed schema/*.sql
var schemaFS embed.FS

// ErrNotFound is returned by lookups that match no row.
var ErrNotFound = errors.New("not found")

// DB wraps the database handle.
type DB struct {
	*sql.DB
	path string
}

// Options tunes how the database is opened.
type Options struct {
	// Synchronous is the SQLite synchronous level. The engine always runs with FULL; only the
	// in-process simulator, which "crashes" by reopening the file inside the same OS process,
	// relaxes it because fsync durability is not what it exercises.
	Synchronous string
	// WrapConn, when set, wraps every physical SQLite connection. The storage fault-injection
	// tests use it to fail one chosen statement, BEGIN or COMMIT; production leaves it nil.
	WrapConn func(driver.Conn) driver.Conn
}

// wrapConnector interposes Options.WrapConn on the connections database/sql opens.
type wrapConnector struct {
	driver.Connector
	wrap func(driver.Conn) driver.Conn
}

// Connect implements driver.Connector.
func (c wrapConnector) Connect(ctx context.Context) (driver.Conn, error) {
	conn, err := c.Connector.Connect(ctx)
	if err != nil {
		return nil, err
	}
	return c.wrap(conn), nil
}

// Open opens (creating if needed) the database at path and applies pending migrations.
// Durability settings: WAL journal, synchronous=FULL (every commit is fsynced, which is what
// makes "committed before broadcast" meaningful across power loss), foreign keys on, and
// BEGIN IMMEDIATE for every transaction so writers never deadlock on lock upgrades.
func Open(ctx context.Context, path string) (*DB, error) {
	return OpenWith(ctx, path, Options{Synchronous: "FULL"})
}

// OpenWith is Open with explicit options.
func OpenWith(ctx context.Context, path string, o Options) (*DB, error) {
	switch o.Synchronous {
	case "":
		o.Synchronous = "FULL"
	case "FULL", "NORMAL", "OFF":
	default:
		return nil, fmt.Errorf("store: invalid synchronous level %q", o.Synchronous)
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, fmt.Errorf("store: resolve path: %w", err)
	}
	q := url.Values{}
	q.Add("_pragma", "journal_mode(WAL)")
	q.Add("_pragma", "synchronous("+o.Synchronous+")")
	q.Add("_pragma", "foreign_keys(1)")
	q.Add("_pragma", "busy_timeout(10000)")
	q.Set("_txlock", "immediate")
	dsn := "file:" + filepath.ToSlash(abs) + "?" + q.Encode()
	// sqlite.NewConnector is equivalent to sql.Open("sqlite", dsn) and lets tests interpose on
	// the physical connection without registering a process-global driver name.
	base, err := sqlite.NewConnector(dsn)
	if err != nil {
		return nil, fmt.Errorf("store: open: %w", err)
	}
	if o.WrapConn != nil {
		base = wrapConnector{Connector: base, wrap: o.WrapConn}
	}
	sqlDB := sql.OpenDB(base)
	sqlDB.SetMaxOpenConns(1)
	sqlDB.SetMaxIdleConns(1)
	sqlDB.SetConnMaxLifetime(0)
	db := &DB{DB: sqlDB, path: abs}
	if err := db.migrate(ctx); err != nil {
		_ = sqlDB.Close()
		return nil, err
	}
	return db, nil
}

// OpenReadOnly opens an existing database for inspection (audit-verify): read-only, no
// migrations, and it never creates a file. It works while custodyd runs (WAL readers do not
// block the writer).
func OpenReadOnly(ctx context.Context, path string) (*DB, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, fmt.Errorf("store: resolve path: %w", err)
	}
	q := url.Values{}
	q.Set("mode", "ro")
	q.Add("_pragma", "busy_timeout(10000)")
	sqlDB, err := sql.Open("sqlite", "file:"+filepath.ToSlash(abs)+"?"+q.Encode())
	if err != nil {
		return nil, fmt.Errorf("store: open: %w", err)
	}
	sqlDB.SetMaxOpenConns(1)
	if err := sqlDB.PingContext(ctx); err != nil {
		_ = sqlDB.Close()
		return nil, fmt.Errorf("store: open %s read-only: %w", abs, err)
	}
	var tables int
	if err := sqlDB.QueryRowContext(ctx, `SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'schema_migrations'`).Scan(&tables); err != nil || tables == 0 {
		_ = sqlDB.Close()
		return nil, fmt.Errorf("store: %s is not a custodyd database (%v)", abs, err)
	}
	return &DB{DB: sqlDB, path: abs}, nil
}

// Path returns the absolute database path.
func (db *DB) Path() string { return db.path }

func (db *DB) migrate(ctx context.Context) error {
	if _, err := db.ExecContext(ctx,
		`CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL) STRICT`); err != nil {
		return fmt.Errorf("store: create migrations table: %w", err)
	}
	entries, err := fs.ReadDir(schemaFS, "schema")
	if err != nil {
		return fmt.Errorf("store: read schema: %w", err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	slices.Sort(names)
	for _, name := range names {
		version, err := strconv.Atoi(strings.SplitN(name, "_", 2)[0])
		if err != nil {
			return fmt.Errorf("store: bad migration name %q", name)
		}
		var exists int
		if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM schema_migrations WHERE version = ?`, version).Scan(&exists); err != nil {
			return fmt.Errorf("store: check migration %d: %w", version, err)
		}
		if exists > 0 {
			continue
		}
		body, err := schemaFS.ReadFile("schema/" + name)
		if err != nil {
			return fmt.Errorf("store: read migration %s: %w", name, err)
		}
		err = db.WithTx(ctx, func(tx *Tx) error {
			if _, err := tx.ExecContext(ctx, string(body)); err != nil {
				return fmt.Errorf("apply %s: %w", name, err)
			}
			_, err := tx.ExecContext(ctx, `INSERT INTO schema_migrations (version, applied_at) VALUES (?, datetime('now'))`, version)
			return err
		})
		if err != nil {
			return fmt.Errorf("store: migration %s: %w", name, err)
		}
	}
	return nil
}

// Tx is a write transaction with hooks that run only after a successful commit (metrics,
// wake-ups): a rolled-back transaction must not leave observable side effects.
type Tx struct {
	*sql.Tx
	onCommit []func()
}

// OnCommit registers f to run after the transaction commits.
func (tx *Tx) OnCommit(f func()) { tx.onCommit = append(tx.onCommit, f) }

// WithTx runs fn in a transaction, committing if fn returns nil and rolling back otherwise.
// A panic inside fn (a failpoint) rolls back through the deferred Rollback, like a crash would.
func (db *DB) WithTx(ctx context.Context, fn func(tx *Tx) error) (err error) {
	sqlTx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("store: begin: %w", err)
	}
	tx := &Tx{Tx: sqlTx}
	defer func() {
		if err != nil {
			_ = sqlTx.Rollback()
		}
	}()
	defer func() {
		if p := recover(); p != nil {
			_ = sqlTx.Rollback()
			panic(p)
		}
	}()
	if err = fn(tx); err != nil {
		return err
	}
	if err = sqlTx.Commit(); err != nil {
		return fmt.Errorf("store: commit: %w", err)
	}
	for _, f := range tx.onCommit {
		f()
	}
	return nil
}

// ReadTx runs fn in a read-only transaction and always rolls it back. Every read inside it sees
// one snapshot of the database: a write that commits meanwhile is either entirely visible or not
// at all. With the engine's single connection the transaction also holds that connection until
// fn returns, so fn must stay short and must not call the node.
func (db *DB) ReadTx(ctx context.Context, fn func(q Querier) error) error {
	sqlTx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return fmt.Errorf("store: begin read: %w", err)
	}
	defer func() { _ = sqlTx.Rollback() }()
	return fn(sqlTx)
}

// Querier is satisfied by *sql.DB, *sql.Tx and *Tx.
type Querier interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// GetMeta reads a meta value; ok is false when the key is absent.
func GetMeta(ctx context.Context, q Querier, key string) (value string, ok bool, err error) {
	err = q.QueryRowContext(ctx, `SELECT value FROM meta WHERE key = ?`, key).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("store: get meta %s: %w", key, err)
	}
	return value, true, nil
}

// SetMeta upserts a meta value.
func SetMeta(ctx context.Context, q Querier, key, value string) error {
	_, err := q.ExecContext(ctx,
		`INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value`, key, value)
	if err != nil {
		return fmt.Errorf("store: set meta %s: %w", key, err)
	}
	return nil
}
