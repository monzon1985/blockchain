// SPDX-License-Identifier: MIT

//go:build postgres

// These tests need a PostgreSQL server: set INDEXER_TEST_POSTGRES_DSN to a postgres:// URL (CI
// runs a postgres service container). Every test gets its own schema, so runs never interfere.
//
//	INDEXER_TEST_POSTGRES_DSN='postgres://postgres:postgres@localhost:5432/indexer?sslmode=disable' \
//	  go test -tags postgres ./internal/store/postgres/...
package postgres_test

import (
	"context"
	"database/sql"
	"fmt"
	"math/rand/v2"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/fakechain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/fetch"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/indexer"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store/postgres"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store/sqlite"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store/storetest"
)

var schemaSeq atomic.Int64

// freshDSN creates an empty schema and returns a DSN whose search_path points at it.
func freshDSN(t *testing.T) string {
	t.Helper()
	base := os.Getenv("INDEXER_TEST_POSTGRES_DSN")
	if base == "" {
		t.Fatal("INDEXER_TEST_POSTGRES_DSN is not set (the postgres build tag needs a server)")
	}
	admin, err := sql.Open("pgx", base)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = admin.Close() })
	schema := fmt.Sprintf("it_%d_%d", time.Now().UnixNano(), schemaSeq.Add(1))
	if _, err := admin.Exec(`CREATE SCHEMA ` + schema); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = admin.Exec(`DROP SCHEMA ` + schema + ` CASCADE`) })
	u, err := url.Parse(base)
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	q.Set("search_path", schema)
	u.RawQuery = q.Encode()
	return u.String()
}

func open(t *testing.T, dsn string) store.Store {
	t.Helper()
	s, err := postgres.Open(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

// TestConformance runs the same suite as the SQLite backend.
func TestConformance(t *testing.T) {
	storetest.Run(t, func(t *testing.T) store.Store { return open(t, freshDSN(t)) })
}

// TestConcurrentMigrations opens one fresh schema from several connections at once: the
// advisory lock serialises the migrations and every handle ends at the same version.
func TestConcurrentMigrations(t *testing.T) {
	dsn := freshDSN(t)
	var wg sync.WaitGroup
	errs := make(chan error, 8)
	for range 8 {
		wg.Go(func() {
			s, err := postgres.Open(context.Background(), dsn)
			if err == nil {
				if s.Backend() != "postgres" {
					err = fmt.Errorf("backend %q", s.Backend())
				}
				_ = s.Close()
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

func TestOpenRejectsUnreachableServer(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := postgres.Open(ctx, "postgres://nobody@127.0.0.1:1/none?sslmode=disable&connect_timeout=2"); err == nil {
		t.Fatal("open must fail when the server is unreachable")
	}
}

// TestEngineMatchesSQLiteReindex is the cross-backend differential test: the engine indexes a
// fake chain with random traffic, reorgs and restarts into PostgreSQL, and the result must be
// identical, row for row, to a from-scratch reindex of the final canonical chain into SQLite.
func TestEngineMatchesSQLiteReindex(t *testing.T) {
	for seed := range uint64(3) {
		t.Run(fmt.Sprintf("seed=%d", seed), func(t *testing.T) {
			ctx := context.Background()
			rng := rand.New(rand.NewPCG(seed, seed+7))
			fc := fakechain.New(31337)
			world := fakechain.NewWorld(6)
			cfg := indexer.Config{
				Start: 1, Confirmations: 3, PollInterval: time.Millisecond, ReorgWindow: 48, EventRetention: 1 << 40,
				Contracts: world.Contracts(),
				Fetch:     fetch.Config{InitialSpan: 4, MaxSpan: 64, HashSpan: 4, Concurrency: 3, Backoff: time.Millisecond},
			}
			pg := open(t, freshDSN(t))
			newEngine := func(st store.Store) *indexer.Engine {
				e, err := indexer.New(ctx, cfg, fc, st, nil, nil)
				if err != nil {
					t.Fatal(err)
				}
				return e
			}
			eng := newEngine(pg)
			maxHead := uint64(0)
			mine := func() {
				for range 1 + rng.IntN(3) {
					fc.Mine(world.Block(rng, fc.Canonical(0), rng.IntN(6)))
				}
				maxHead = max(maxHead, fc.Head().Number)
			}
			syncAll := func(e *indexer.Engine) {
				head := fc.Head()
				if err := e.SyncUntil(ctx, head.Number); err != nil {
					t.Fatal(err)
				}
			}
			for range 50 {
				switch op := rng.IntN(10); {
				case op < 6:
					mine()
				case op < 9:
					head := int(fc.Head().Number)
					if head < 3 {
						continue
					}
					depth := 1 + rng.IntN(min(10, head-2))
					canon := fc.Canonical(0)
					base := canon[:len(canon)-depth]
					var blocks [][]fakechain.LogSpec
					for range depth + rng.IntN(2) {
						blocks = append(blocks, world.BlockAfter(rng, base, blocks, rng.IntN(6)))
					}
					if err := fc.Reorg(depth, blocks); err != nil {
						t.Fatal(err)
					}
					maxHead = max(maxHead, fc.Head().Number)
				default:
					eng = newEngine(pg) // restart from the database
				}
				syncAll(eng)
			}
			for target := maxHead; fc.Head().Number <= target; {
				mine()
			}
			syncAll(eng)

			lite, err := sqlite.Open(ctx, filepath.Join(t.TempDir(), "reindex.db"))
			if err != nil {
				t.Fatal(err)
			}
			defer lite.Close()
			syncAll(newEngine(lite))

			a, b := snapshot(t, pg), snapshot(t, lite)
			if a.Tip == nil || a.Tip.Hash != fc.Head().Hash {
				t.Fatalf("postgres tip %v is not the head %s", a.Tip, fc.Head().Ref())
			}
			if diffs := store.Diff(a, b); len(diffs) > 0 {
				var sb strings.Builder
				for i, d := range diffs {
					if i == 10 {
						break
					}
					sb.WriteString(d.String() + "\n")
				}
				t.Fatalf("postgres (incremental) != sqlite (reindex): %d differences\n%s", len(diffs), sb.String())
			}
			if a.Rows() == 0 {
				t.Fatal("nothing was indexed")
			}
			t.Logf("rows=%v", a.Counts())
		})
	}
}

func snapshot(t *testing.T, s store.Store) *store.Snapshot {
	t.Helper()
	var snap *store.Snapshot
	if err := s.View(context.Background(), func(r store.Reader) error {
		var err error
		snap, err = r.Snapshot()
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return snap
}
