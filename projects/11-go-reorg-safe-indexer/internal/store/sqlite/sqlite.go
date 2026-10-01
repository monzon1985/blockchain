// SPDX-License-Identifier: MIT

// Package sqlite opens the indexer store on SQLite through modernc.org/sqlite, a pure-Go
// translation of SQLite: no cgo, so `CGO_ENABLED=0` builds and cross-compiles work.
package sqlite

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	// Registers the "sqlite" database/sql driver.
	msqlite "modernc.org/sqlite"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store/sqlstore"
)

// Dialect is the SQLite flavour of the shared SQL store. Read transactions are plain deferred
// BEGINs, which in WAL mode see one snapshot from their first read; write transactions use
// BEGIN IMMEDIATE (the `_txlock` DSN parameter), so two writers queue on busy_timeout instead
// of deadlocking on a lock upgrade.
var Dialect = sqlstore.Dialect{
	Name:  "sqlite",
	Read:  sql.TxOptions{ReadOnly: true},
	Write: sql.TxOptions{},
}

// DSN builds the modernc DSN for a database file.
//
//   - journal_mode=WAL: readers (the API) never block the writer (the indexer) and vice versa.
//   - synchronous=FULL: every commit is on disk before it is acknowledged. NORMAL would be
//     enough for the indexed data (a commit lost to a power cut is simply re-fetched, since the
//     checkpoint moves with the data), but not for the SSE stream: a client may already have
//     received the events of the lost commit, and after the restart the same sequence numbers
//     would be reassigned to other events. The indexer commits one segment per transaction, so
//     the extra fsync per commit is cheap.
//   - busy_timeout: wait for the write lock instead of failing with SQLITE_BUSY.
func DSN(path string) string {
	q := url.Values{}
	q.Add("_pragma", "busy_timeout(10000)")
	q.Add("_pragma", "journal_mode(WAL)")
	q.Add("_pragma", "synchronous(FULL)")
	q.Set("_txlock", "immediate")
	return path + "?" + q.Encode()
}

// ErrInMemory rejects in-memory databases: every connection of the pool would open its own empty
// database, so the API's reads and the indexer's writes would not see the same tables.
var ErrInMemory = errors.New("sqlite: in-memory databases are not supported (each pooled connection would get its own empty database); pass a file path")

// isInMemory reports whether path names an in-memory SQLite database (":memory:", an empty
// path, or a file: URI with mode=memory).
func isInMemory(path string) bool {
	p := strings.TrimSpace(path)
	if p == "" || p == ":memory:" || strings.HasPrefix(p, "file::memory:") {
		return true
	}
	if strings.HasPrefix(p, "file:") {
		if i := strings.IndexByte(p, '?'); i >= 0 {
			if q, err := url.ParseQuery(p[i+1:]); err == nil && q.Get("mode") == "memory" {
				return true
			}
		}
	}
	return false
}

// openBusyTimeout bounds how long Open keeps retrying a database another process is
// initialising.
const openBusyTimeout = 30 * time.Second

// sqliteBusy is SQLITE_BUSY, the primary result code of every "database is locked" error.
const sqliteBusy = 5

func isBusy(err error) bool {
	var se *msqlite.Error
	return errors.As(err, &se) && se.Code()&0xff == sqliteBusy
}

// Open opens (creating if needed) the SQLite database at path and applies migrations.
//
// Two processes opening a fresh file at once (`indexer index` and `indexer serve --readonly`)
// race to switch it to WAL, and SQLite answers the loser with SQLITE_BUSY without consulting
// busy_timeout. Open therefore retries SQLITE_BUSY, with backoff, for up to 30 seconds.
func Open(ctx context.Context, path string) (*sqlstore.Store, error) {
	if isInMemory(path) {
		return nil, fmt.Errorf("%w: %q", ErrInMemory, path)
	}
	backoff := 10 * time.Millisecond
	deadline := time.Now().Add(openBusyTimeout)
	for {
		s, err := open(ctx, path)
		if err == nil || !isBusy(err) || time.Now().After(deadline) {
			return s, err
		}
		t := time.NewTimer(backoff)
		select {
		case <-t.C:
		case <-ctx.Done():
			t.Stop()
			return nil, err
		}
		backoff = min(2*backoff, 500*time.Millisecond)
	}
}

func open(ctx context.Context, path string) (*sqlstore.Store, error) {
	db, err := sql.Open("sqlite", DSN(path))
	if err != nil {
		return nil, fmt.Errorf("sqlite: open %s: %w", path, err)
	}
	db.SetMaxOpenConns(8)
	s, err := sqlstore.Open(ctx, db, Dialect)
	if err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("sqlite: %s: %w", path, err)
	}
	return s, nil
}
