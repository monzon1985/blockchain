// SPDX-License-Identifier: MIT

package sqlite_test

import (
	"context"
	"errors"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store/sqlite"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store/sqlstore"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store/storetest"
)

func open(t *testing.T) *sqlstore.Store {
	t.Helper()
	s, err := sqlite.Open(context.Background(), filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

// TestConformance runs the backend-independent store suite (the PostgreSQL adapter runs the
// same suite in CI).
func TestConformance(t *testing.T) {
	storetest.Run(t, func(t *testing.T) store.Store { return open(t) })
}

func TestDSNEnablesWALAndImmediateWrites(t *testing.T) {
	dsn := sqlite.DSN("x.db")
	for _, want := range []string{"journal_mode%28WAL%29", "busy_timeout%2810000%29", "synchronous%28FULL%29", "_txlock=immediate"} {
		if !strings.Contains(dsn, want) {
			t.Errorf("DSN %q lacks %q", dsn, want)
		}
	}
	s := open(t)
	var mode string
	if err := s.DB().QueryRow(`PRAGMA journal_mode`).Scan(&mode); err != nil {
		t.Fatal(err)
	}
	if mode != "wal" {
		t.Fatalf("journal_mode = %q, want wal", mode)
	}
	// FULL (2): a commit, and the SSE events it publishes, survives a power cut once
	// acknowledged.
	var sync int
	if err := s.DB().QueryRow(`PRAGMA synchronous`).Scan(&sync); err != nil {
		t.Fatal(err)
	}
	if sync != 2 {
		t.Fatalf("synchronous = %d, want 2 (FULL)", sync)
	}
	if s.Backend() != "sqlite" {
		t.Fatalf("backend %q", s.Backend())
	}
}

// TestInMemoryDatabasesAreRejected: each pooled connection to ":memory:" is its own empty
// database, so migrations would land on one connection and a concurrent read on another would
// find no tables. Such paths are refused up front with a clear error.
func TestInMemoryDatabasesAreRejected(t *testing.T) {
	for _, path := range []string{":memory:", "", " ", "file::memory:", "file::memory:?cache=shared", "file:idx.db?mode=memory&cache=shared"} {
		s, err := sqlite.Open(context.Background(), path)
		if !errors.Is(err, sqlite.ErrInMemory) {
			if s != nil {
				_ = s.Close()
			}
			t.Errorf("Open(%q) = %v, want ErrInMemory", path, err)
		}
	}
}

func TestMigrationsAreIdempotent(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "m.db")
	for i := range 3 {
		s, err := sqlite.Open(ctx, path)
		if err != nil {
			t.Fatalf("open #%d: %v", i, err)
		}
		v, err := s.SchemaVersion(ctx)
		if err != nil {
			t.Fatal(err)
		}
		ms, err := sqlstore.Migrations()
		if err != nil {
			t.Fatal(err)
		}
		if v != len(ms) || v == 0 {
			t.Fatalf("schema version %d, want %d", v, len(ms))
		}
		if i == 0 {
			tip := chain.BlockRef{Number: 1}
			if err := s.Update(ctx, func(tx store.Tx) error { return tx.MoveTip(nil, &tip, 1, 1) }); err != nil {
				t.Fatal(err)
			}
		}
		// Re-running the migrations must not reset the checkpoint row.
		err = s.View(ctx, func(r store.Reader) error {
			cp, err := r.Checkpoint()
			if err == nil && (cp.Tip == nil || cp.Tip.Number != 1) {
				err = errors.New("checkpoint lost on reopen")
			}
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		_ = s.Close()
	}
}

// TestConcurrentOpen opens the same fresh database from several goroutines: migrations
// serialise on SQLite's write lock and every handle sees the same schema.
func TestConcurrentOpen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "c.db")
	var wg sync.WaitGroup
	errs := make(chan error, 6)
	for range 6 {
		wg.Go(func() {
			s, err := sqlite.Open(context.Background(), path)
			if err == nil {
				err = s.Close()
			}
			errs <- err
		})
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
}

func TestSplitStatements(t *testing.T) {
	body := "-- header comment\r\nCREATE TABLE a (\r\n  x INT\r\n);\n\n-- between\nINSERT INTO a VALUES (1);\nSELECT 1"
	got := sqlstore.SplitStatements(body)
	want := []string{"CREATE TABLE a (\n  x INT\n)", "INSERT INTO a VALUES (1)", "SELECT 1"}
	if !slices.Equal(got, want) {
		t.Fatalf("SplitStatements = %q, want %q", got, want)
	}
	ms, err := sqlstore.Migrations()
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range ms {
		if len(m.Statements) == 0 || !strings.HasSuffix(m.Name, ".sql") {
			t.Fatalf("migration %+v", m)
		}
	}
}

func TestOpenFailures(t *testing.T) {
	// A directory is not a database file.
	if _, err := sqlite.Open(context.Background(), t.TempDir()); err == nil {
		t.Fatal("opening a directory must fail")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := sqlite.Open(ctx, filepath.Join(t.TempDir(), "x.db")); err == nil {
		t.Fatal("opening with a cancelled context must fail")
	}
}

func TestTransactionHandleIsInvalidAfterCallback(t *testing.T) {
	s := open(t)
	ctx := context.Background()
	var leaked store.Tx
	if err := s.Update(ctx, func(tx store.Tx) error { leaked = tx; return nil }); err != nil {
		t.Fatal(err)
	}
	if err := leaked.PutMeta("k", "v"); !errors.Is(err, sqlstore.ErrClosedTx) {
		t.Fatalf("write through a finished transaction: %v", err)
	}
	if _, err := leaked.TransfersFrom(0); !errors.Is(err, sqlstore.ErrClosedTx) {
		t.Fatalf("read through a finished transaction: %v", err)
	}
	if err := s.Ping(ctx); err != nil {
		t.Fatal(err)
	}
}

func TestUpdateAndViewFailures(t *testing.T) {
	s := open(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := s.Update(ctx, func(store.Tx) error { return nil }); err == nil {
		t.Fatal("Update with a cancelled context must fail")
	}
	if err := s.View(ctx, func(store.Reader) error { return nil }); err == nil {
		t.Fatal("View with a cancelled context must fail")
	}
	// Values that do not fit the schema's signed 64-bit columns are rejected, not wrapped.
	huge := chain.BlockRef{Number: 1 << 63}
	err := s.Update(context.Background(), func(tx store.Tx) error { return tx.MoveTip(nil, &huge, 0, 0) })
	if err == nil || !strings.Contains(err.Error(), "exceeds int64") {
		t.Fatalf("oversized block number: %v", err)
	}
	_ = s.Close()
	if err := s.Update(context.Background(), func(store.Tx) error { return nil }); err == nil {
		t.Fatal("Update on a closed store must fail")
	}
}

// TestCorruptRowsAreReported checks that rows a query cannot parse surface as errors instead of
// zero values.
func TestCorruptRowsAreReported(t *testing.T) {
	ctx := context.Background()
	cases := []struct {
		name, corrupt string
		read          func(r store.Reader) error
	}{
		{"checkpoint hash", `UPDATE checkpoint SET tip_number = 1, tip_hash = 'zz'`, func(r store.Reader) error { _, err := r.Checkpoint(); return err }},
		{"block hash", `INSERT INTO blocks VALUES (1, '0x01', '0x02', 0)`, func(r store.Reader) error { _, err := r.RecentBlocks(5); return err }},
		{"transfer value", `INSERT INTO transfers VALUES ('0x` + strings.Repeat("00", 32) + `', 0, 1, 0, '0x` + strings.Repeat("00", 32) + `', '0x` + strings.Repeat("00", 20) + `', '0x` + strings.Repeat("00", 20) + `', '0x` + strings.Repeat("00", 20) + `', 'NaN')`,
			func(r store.Reader) error { _, err := r.TransfersFrom(0); return err }},
		{"balance", `INSERT INTO balances VALUES ('0x` + strings.Repeat("00", 20) + `', '0x` + strings.Repeat("11", 20) + `', 'x')`,
			func(r store.Reader) error {
				_, err := r.HolderBalances([20]byte{0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11})
				return err
			}},
		{"supply", `INSERT INTO supplies VALUES ('0x` + strings.Repeat("00", 20) + `', '1.5')`, func(r store.Reader) error { _, err := r.Supply([20]byte{}); return err }},
		{"reorg hash", `INSERT INTO reorgs VALUES (1, 0, 1, 'bad', -1, '', 2, '0x00', 1)`, func(r store.Reader) error { _, _, err := r.LastReorg(); return err }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := open(t)
			if _, err := s.DB().ExecContext(ctx, tc.corrupt); err != nil {
				t.Fatal(err)
			}
			if err := s.View(ctx, tc.read); err == nil {
				t.Fatal("corrupt row read without error")
			}
		})
	}
}
