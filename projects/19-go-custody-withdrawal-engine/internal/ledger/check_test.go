// SPDX-License-Identifier: MIT

package ledger_test

import (
	"context"
	"fmt"
	"math/rand/v2"
	"slices"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

// TestCheckerMatchesCheck: the incremental checker, reading a few entries per transaction and
// re-verifying a few old ones per run, always agrees with the one-shot recomputation.
func TestCheckerMatchesCheck(t *testing.T) {
	for seed := uint64(1); seed <= 8; seed++ {
		t.Run(fmt.Sprint(seed), func(t *testing.T) {
			rng := rand.New(rand.NewPCG(seed, 11))
			db := openDB(t)
			ctx := context.Background()
			c := ledger.NewChecker(1 + rng.IntN(7))
			accounts := []string{ledger.HotWallet, ledger.InFlight, ledger.Fees, ledger.Treasury, ledger.User("a"), ledger.User("b")}
			for i := range 80 {
				for range rng.IntN(4) {
					_, _ = post(t, db, randomEntry(rng, accounts, []string{"ETH", "USD"}, i*10+rng.IntN(10)))
				}
				got, snap, err := c.Run(ctx, db)
				if err != nil {
					t.Fatal(err)
				}
				want, err := ledger.Check(ctx, db)
				if err != nil {
					t.Fatal(err)
				}
				if !got.OK() || !want.OK() || fmt.Sprint(got.TrialBalance) != fmt.Sprint(want.TrialBalance) {
					t.Fatalf("step %d: checker %+v, check %+v", i, got, want)
				}
				full, _ := ledger.Balances(ctx, db)
				if fmt.Sprint(snap) != fmt.Sprint(full) {
					t.Fatalf("step %d: the snapshot returned is not the balances table", i)
				}
			}
		})
	}
}

// TestCheckerDetectsTampering: a cached balance edited behind the ledger's back is reported on
// the next run; an old posting edited or an old entry deleted (which the incremental sums never
// re-read) is reported once the background re-verification has gone over it, and stops being
// reported once the damage is undone.
func TestCheckerDetectsTampering(t *testing.T) {
	ctx := context.Background()
	setup := func(t *testing.T) (*store.DB, *ledger.Checker) {
		db := openDB(t)
		for i := range 20 {
			mustPost(t, db, ledger.Entry{Ref: fmt.Sprint("e", i), Kind: "k", Postings: []ledger.Posting{
				ledger.Debit(ledger.HotWallet, "X", b(int64(i+1))), ledger.Credit(ledger.Treasury, "X", b(int64(i+1)))}})
		}
		c := ledger.NewChecker(3)
		if res, _, err := c.Run(ctx, db); err != nil || !res.OK() {
			t.Fatalf("clean ledger: %+v %v", res, err)
		}
		return db, c
	}
	exec := func(t *testing.T, db *store.DB, q string) {
		if _, err := db.ExecContext(ctx, q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	runs := func(t *testing.T, db *store.DB, c *ledger.Checker, n int) ledger.CheckResult {
		var res ledger.CheckResult
		for range n {
			var err error
			if res, _, err = c.Run(ctx, db); err != nil {
				t.Fatal(err)
			}
		}
		return res
	}
	t.Run("cached balance", func(t *testing.T) {
		db, c := setup(t)
		exec(t, db, `UPDATE ledger_balances SET balance = '1' WHERE account = 'treasury'`)
		if res := runs(t, db, c, 1); res.OK() || fmt.Sprint(res.CacheMismatches) != "[treasury/X]" {
			t.Fatalf("got %+v", res)
		}
	})
	t.Run("old posting edited", func(t *testing.T) {
		db, c := setup(t)
		exec(t, db, `UPDATE ledger_postings SET amount = '100' WHERE account = 'hot_wallet' AND entry_id = (SELECT id FROM ledger_entries WHERE ref = 'e2')`)
		// 20 entries, 3 per run: the pass under way may already be past e2, so it takes up to
		// two passes (14 runs) to report the edit.
		res := runs(t, db, c, 14)
		if res.OK() || fmt.Sprint(res.Rewritten) != "[hot_wallet/X]" || fmt.Sprint(res.UnbalancedEntries) != "[e2]" {
			t.Fatalf("got %+v", res)
		}
		exec(t, db, `UPDATE ledger_postings SET amount = '3' WHERE account = 'hot_wallet' AND entry_id = (SELECT id FROM ledger_entries WHERE ref = 'e2')`)
		if res := runs(t, db, c, 16); !res.OK() {
			t.Fatalf("still reported after the damage was undone: %+v", res)
		}
	})
	t.Run("old entry deleted", func(t *testing.T) {
		db, c := setup(t)
		exec(t, db, `DELETE FROM ledger_postings WHERE entry_id = (SELECT id FROM ledger_entries WHERE ref = 'e5')`)
		exec(t, db, `DELETE FROM ledger_entries WHERE ref = 'e5'`)
		res := runs(t, db, c, 14)
		if res.OK() || !slices.Equal(res.Rewritten, []string{"hot_wallet/X", "treasury/X"}) {
			t.Fatalf("got %+v", res)
		}
	})
	t.Run("unbalanced entry appended", func(t *testing.T) {
		db, c := setup(t)
		exec(t, db, `INSERT INTO ledger_entries (ref, kind, created_at) VALUES ('raw', 'manual', 0)`)
		exec(t, db, `INSERT INTO ledger_postings (entry_id, account, asset, amount) VALUES ((SELECT id FROM ledger_entries WHERE ref = 'raw'), 'fees', 'X', '4')`)
		res := runs(t, db, c, 1)
		if res.OK() || fmt.Sprint(res.UnbalancedEntries) != "[raw]" || fmt.Sprint(res.CacheMismatches) != "[fees/X]" || res.TrialBalance["X"].Int64() != 4 {
			t.Fatalf("got %+v", res)
		}
	})
}

// TestCheckerUnderConcurrentPosts: entries are posted from another goroutine while the checker
// runs. Its postings and the cached balances come from one snapshot, so no run may report a
// mismatch (reading them in two separate queries did, whenever a post landed in between).
func TestCheckerUnderConcurrentPosts(t *testing.T) {
	db := openDB(t)
	ctx := context.Background()
	c := ledger.NewChecker(0)
	var posted atomic.Int64
	stop := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			err := db.WithTx(ctx, func(tx *store.Tx) error {
				_, err := ledger.Post(ctx, tx, ledger.Entry{Ref: fmt.Sprint("c", i), Kind: "k", Postings: []ledger.Posting{
					ledger.Debit(ledger.HotWallet, "X", b(1)), ledger.Credit(ledger.User("u"), "X", b(1))}}, now)
				return err
			})
			if err == nil {
				posted.Add(1)
			}
		}
	}()
	for i := range 300 {
		res, _, err := c.Run(ctx, db)
		if err != nil {
			t.Fatal(err)
		}
		if !res.OK() {
			close(stop)
			wg.Wait()
			t.Fatalf("run %d with %d concurrent posts: %+v", i, posted.Load(), res)
		}
	}
	close(stop)
	wg.Wait()
	if posted.Load() < 100 {
		t.Fatalf("only %d concurrent posts", posted.Load())
	}
}
