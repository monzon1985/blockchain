// SPDX-License-Identifier: MIT

package store_test

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

func TestOpenIsIdempotentAndDurable(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "s.db")
	db, err := store.Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	var mode, sync string
	if err := db.QueryRowContext(ctx, `PRAGMA journal_mode`).Scan(&mode); err != nil || mode != "wal" {
		t.Fatalf("journal_mode = %q %v", mode, err)
	}
	if err := db.QueryRowContext(ctx, `PRAGMA synchronous`).Scan(&sync); err != nil || sync != "2" { // 2 = FULL
		t.Fatalf("synchronous = %q %v", sync, err)
	}
	if err := store.SetMeta(ctx, db, "k", "v1"); err != nil {
		t.Fatal(err)
	}
	db.Close()
	db, err = store.Open(ctx, path) // migrations must not re-run
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if v, ok, err := store.GetMeta(ctx, db, "k"); err != nil || !ok || v != "v1" {
		t.Fatalf("meta after reopen: %q %v %v", v, ok, err)
	}
	if _, ok, _ := store.GetMeta(ctx, db, "absent"); ok {
		t.Fatal("absent key reported present")
	}
	if _, err := store.OpenWith(ctx, path, store.Options{Synchronous: "SOMETIMES"}); err == nil {
		t.Fatal("invalid synchronous level accepted")
	}
	if db.Path() != path && filepath.Base(db.Path()) != "s.db" {
		t.Fatalf("path %s", db.Path())
	}
}

func TestWithTxRollsBackOnErrorAndPanic(t *testing.T) {
	ctx := context.Background()
	db, err := store.OpenWith(ctx, filepath.Join(t.TempDir(), "s.db"), store.Options{Synchronous: "OFF"})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	hooked := false
	boom := errors.New("boom")
	err = db.WithTx(ctx, func(tx *store.Tx) error {
		tx.OnCommit(func() { hooked = true })
		if err := store.SetMeta(ctx, tx, "a", "1"); err != nil {
			return err
		}
		return boom
	})
	if !errors.Is(err, boom) || hooked {
		t.Fatalf("err=%v hooked=%v", err, hooked)
	}
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("panic swallowed")
			}
		}()
		_ = db.WithTx(ctx, func(tx *store.Tx) error {
			_ = store.SetMeta(ctx, tx, "b", "1")
			panic("crash")
		})
	}()
	for _, k := range []string{"a", "b"} {
		if _, ok, _ := store.GetMeta(ctx, db, k); ok {
			t.Fatalf("%s survived a rolled-back transaction", k)
		}
	}
	err = db.WithTx(ctx, func(tx *store.Tx) error {
		tx.OnCommit(func() { hooked = true })
		return store.SetMeta(ctx, tx, "c", "1")
	})
	if err != nil || !hooked {
		t.Fatalf("commit hook not run: %v", err)
	}
}
