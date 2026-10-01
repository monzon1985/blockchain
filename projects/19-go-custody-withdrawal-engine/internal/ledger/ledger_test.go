// SPDX-License-Identifier: MIT

package ledger_test

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"math/rand/v2"
	"path/filepath"
	"testing"
	"time"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

var now = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

func openDB(t testing.TB) *store.DB {
	t.Helper()
	db, err := store.OpenWith(context.Background(), filepath.Join(t.TempDir(), "l.db"), store.Options{Synchronous: "OFF"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func post(t testing.TB, db *store.DB, e ledger.Entry) (bool, error) {
	t.Helper()
	var posted bool
	err := db.WithTx(context.Background(), func(tx *store.Tx) error {
		var err error
		posted, err = ledger.Post(context.Background(), tx, e, now)
		return err
	})
	return posted, err
}

func b(v int64) *big.Int { return big.NewInt(v) }

func TestValidate(t *testing.T) {
	cases := []struct {
		name string
		e    ledger.Entry
		want error
	}{
		{"empty", ledger.Entry{Ref: "r", Kind: "k"}, ledger.ErrEmpty},
		{"missing ref", ledger.Entry{Kind: "k", Postings: []ledger.Posting{ledger.Debit("a", "X", b(1))}}, ledger.ErrBadPosting},
		{"zero amount", ledger.Entry{Ref: "r", Kind: "k", Postings: []ledger.Posting{
			{Account: "a", Asset: "X", Amount: b(0)}, {Account: "b", Asset: "X", Amount: b(0)}}}, ledger.ErrZeroAmount},
		{"nil amount", ledger.Entry{Ref: "r", Kind: "k", Postings: []ledger.Posting{{Account: "a", Asset: "X"}}}, ledger.ErrBadPosting},
		{"unbalanced", ledger.Entry{Ref: "r", Kind: "k", Postings: []ledger.Posting{
			ledger.Debit("a", "X", b(2)), ledger.Credit("b", "X", b(1))}}, ledger.ErrUnbalanced},
		{"balanced in total but not per asset", ledger.Entry{Ref: "r", Kind: "k", Postings: []ledger.Posting{
			ledger.Debit("a", "X", b(1)), ledger.Credit("b", "Y", b(1))}}, ledger.ErrUnbalanced},
		{"balanced", ledger.Entry{Ref: "r", Kind: "k", Postings: []ledger.Posting{
			ledger.Debit("a", "X", b(5)), ledger.Credit("b", "X", b(3)), ledger.Credit("c", "X", b(2))}}, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.e.Validate()
			if !errors.Is(err, tc.want) {
				t.Fatalf("got %v, want %v", err, tc.want)
			}
		})
	}
}

func TestPostIsIdempotentByRef(t *testing.T) {
	db := openDB(t)
	e := ledger.Entry{Ref: "dep:1", Kind: "deposit", Postings: []ledger.Posting{
		ledger.Debit(ledger.Forwarders, "X", b(10)), ledger.Credit(ledger.User("alice"), "X", b(10))}}
	if posted, err := post(t, db, e); err != nil || !posted {
		t.Fatalf("first post: %v %v", posted, err)
	}
	if posted, err := post(t, db, e); err != nil || posted {
		t.Fatalf("second post must be a no-op: %v %v", posted, err)
	}
	got, _ := ledger.Available(context.Background(), db, "alice", "X")
	if got.Cmp(b(10)) != 0 {
		t.Fatalf("available = %s", got)
	}
}

func TestPostRejectsCustomerOverdraft(t *testing.T) {
	db := openDB(t)
	_, err := post(t, db, ledger.Entry{Ref: "w", Kind: "withdraw", Postings: []ledger.Posting{
		ledger.Debit(ledger.User("bob"), "X", b(1)), ledger.Credit(ledger.WithdrawalsPending, "X", b(1))}})
	if !errors.Is(err, ledger.ErrOverdraft) {
		t.Fatalf("expected overdraft, got %v", err)
	}
	// The failed entry left nothing behind.
	res, err := ledger.Check(context.Background(), db)
	if err != nil || !res.OK() {
		t.Fatalf("check after rollback: %+v %v", res, err)
	}
	if bal, _ := ledger.Balance(context.Background(), db, ledger.User("bob"), "X"); bal.Sign() != 0 {
		t.Fatalf("balance leaked: %s", bal)
	}
}

func TestReverseNegatesExactly(t *testing.T) {
	db := openDB(t)
	ctx := context.Background()
	mustPost(t, db, ledger.Entry{Ref: "open", Kind: "k", Postings: []ledger.Posting{
		ledger.Debit(ledger.HotWallet, "ETH", b(100)), ledger.Credit(ledger.Treasury, "ETH", b(100))}})
	mustPost(t, db, ledger.Entry{Ref: "incl", Kind: "k", Postings: []ledger.Posting{
		ledger.Debit(ledger.Fees, "ETH", b(7)), ledger.Credit(ledger.InFlight, "ETH", b(7))}})
	err := db.WithTx(ctx, func(tx *store.Tx) error {
		_, err := ledger.Reverse(ctx, tx, "incl", "rev:incl", now)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, acct := range []string{ledger.Fees, ledger.InFlight} {
		if v, _ := ledger.Balance(ctx, db, acct, "ETH"); v.Sign() != 0 {
			t.Fatalf("%s = %s after reversal", acct, v)
		}
	}
	err = db.WithTx(ctx, func(tx *store.Tx) error {
		_, err := ledger.Reverse(ctx, tx, "missing", "rev:missing", now)
		return err
	})
	if !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("reversing an unknown entry: %v", err)
	}
}

func mustPost(t testing.TB, db *store.DB, e ledger.Entry) {
	t.Helper()
	if _, err := post(t, db, e); err != nil {
		t.Fatal(err)
	}
}

// TestCheckDetectsTampering edits the database behind the ledger's back, one way per case, and
// checks that the recomputation in Check flags exactly the damage done (reconciliation reports
// these as ledger issues).
func TestCheckDetectsTampering(t *testing.T) {
	user := ledger.User("bob")
	cases := []struct {
		name       string
		sql        []string
		unbalanced []string
		cache      []string
		overdrawn  []string
		wantErr    bool
	}{
		{name: "posting amount altered",
			sql:        []string{`UPDATE ledger_postings SET amount = '6' WHERE account = 'hot_wallet'`},
			unbalanced: []string{"a"}, cache: []string{"hot_wallet/X"}},
		{name: "cached balance altered",
			sql:   []string{`UPDATE ledger_balances SET balance = '7' WHERE account = 'hot_wallet'`},
			cache: []string{"hot_wallet/X"}},
		{name: "phantom cached balance",
			sql:   []string{`INSERT INTO ledger_balances (account, asset, balance) VALUES ('fees', 'X', '3')`},
			cache: []string{"fees/X"}},
		{name: "customer overdrawn by a raw entry",
			sql: []string{
				`INSERT INTO ledger_entries (id, ref, kind, created_at) VALUES (99, 'raw', 'manual', 0)`,
				`INSERT INTO ledger_postings (entry_id, account, asset, amount) VALUES (99, '` + user + `', 'X', '9'), (99, 'treasury', 'X', '-9')`,
				`INSERT INTO ledger_balances (account, asset, balance) VALUES ('` + user + `', 'X', '9')`,
				`UPDATE ledger_balances SET balance = '-14' WHERE account = 'treasury'`,
			},
			overdrawn: []string{user + "/X"}},
		{name: "corrupt amount", sql: []string{`UPDATE ledger_postings SET amount = '12x' WHERE account = 'hot_wallet'`}, wantErr: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			db := openDB(t)
			ctx := context.Background()
			mustPost(t, db, ledger.Entry{Ref: "a", Kind: "k", Postings: []ledger.Posting{
				ledger.Debit(ledger.HotWallet, "X", b(5)), ledger.Credit(ledger.Treasury, "X", b(5))}})
			if res, err := ledger.Check(ctx, db); err != nil || !res.OK() {
				t.Fatalf("clean ledger: %+v %v", res, err)
			}
			for _, q := range tc.sql {
				if _, err := db.ExecContext(ctx, q); err != nil {
					t.Fatalf("%s: %v", q, err)
				}
			}
			res, err := ledger.Check(ctx, db)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("corrupt data accepted: %+v", res)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if res.OK() || fmt.Sprint(res.UnbalancedEntries) != fmt.Sprint(tc.unbalanced) ||
				fmt.Sprint(res.CacheMismatches) != fmt.Sprint(tc.cache) || fmt.Sprint(res.Overdrawn) != fmt.Sprint(tc.overdrawn) {
				t.Fatalf("got %+v, want unbalanced=%v cache=%v overdrawn=%v", res, tc.unbalanced, tc.cache, tc.overdrawn)
			}
		})
	}
}

// TestPropertyDebitsEqualCredits posts random entries (balanced, unbalanced, duplicate refs,
// overdrafts) and checks after every step that the trial balance is zero per asset, that the
// cached balances equal the sum of postings, and that no customer is overdrawn.
func TestPropertyDebitsEqualCredits(t *testing.T) {
	for seed := uint64(1); seed <= 25; seed++ {
		t.Run(fmt.Sprint(seed), func(t *testing.T) {
			rng := rand.New(rand.NewPCG(seed, 7))
			db := openDB(t)
			accounts := []string{ledger.HotWallet, ledger.InFlight, ledger.Fees, ledger.Treasury, ledger.Forwarders,
				ledger.WithdrawalsPending, ledger.User("a"), ledger.User("b"), ledger.User("c")}
			assets := []string{"ETH", "USD"}
			var refs []string
			for i := range 120 {
				e := randomEntry(rng, accounts, assets, i)
				if rng.IntN(10) == 0 && len(refs) > 0 {
					e.Ref = refs[rng.IntN(len(refs))] // replay an existing reference
				}
				posted, err := post(t, db, e)
				if err == nil && posted {
					refs = append(refs, e.Ref)
				}
				if vErr := e.Validate(); vErr != nil && err == nil {
					t.Fatalf("invalid entry accepted: %v", vErr)
				}
				res, err := ledger.Check(context.Background(), db)
				if err != nil {
					t.Fatal(err)
				}
				if !res.OK() {
					t.Fatalf("step %d: invariants broken: %+v", i, res)
				}
			}
		})
	}
}

func randomEntry(rng *rand.Rand, accounts, assets []string, i int) ledger.Entry {
	e := ledger.Entry{Ref: fmt.Sprintf("e%d", i), Kind: "random"}
	for range 1 + rng.IntN(3) {
		asset := assets[rng.IntN(len(assets))]
		amt := b(int64(1 + rng.IntN(1000)))
		from, to := accounts[rng.IntN(len(accounts))], accounts[rng.IntN(len(accounts))]
		e.Postings = append(e.Postings, ledger.Debit(to, asset, amt), ledger.Credit(from, asset, amt))
	}
	if rng.IntN(8) == 0 { // corrupt it
		e.Postings[0].Amount = new(big.Int).Add(e.Postings[0].Amount, b(1))
	}
	return e
}

// FuzzValidate checks that Validate accepts exactly the entries whose postings sum to zero per
// asset with no zero amounts, whatever the amounts' sizes (including beyond 256 bits).
func FuzzValidate(f *testing.F) {
	f.Add(int64(5), int64(-5), int64(0), false)
	f.Add(int64(1), int64(-2), int64(1), true)
	f.Add(int64(0), int64(0), int64(0), false)
	f.Fuzz(func(t *testing.T, a, b2, c int64, twoAssets bool) {
		big1 := new(big.Int).Lsh(big.NewInt(a), 200) // exercise > uint256 magnitudes
		big2 := new(big.Int).Lsh(big.NewInt(b2), 200)
		big3 := new(big.Int).Lsh(big.NewInt(c), 200)
		asset3 := "X"
		if twoAssets {
			asset3 = "Y"
		}
		e := ledger.Entry{Ref: "f", Kind: "fuzz", Postings: []ledger.Posting{
			{Account: "p", Asset: "X", Amount: big1}, {Account: "q", Asset: "X", Amount: big2}, {Account: "r", Asset: asset3, Amount: big3}}}
		err := e.Validate()
		sumX := new(big.Int).Add(big1, big2)
		sumY := new(big.Int)
		if twoAssets {
			sumY.Set(big3)
		} else {
			sumX.Add(sumX, big3)
		}
		wantOK := a != 0 && b2 != 0 && c != 0 && sumX.Sign() == 0 && sumY.Sign() == 0
		if (err == nil) != wantOK {
			t.Fatalf("Validate(%d,%d,%d,%v) = %v, want ok=%v", a, b2, c, twoAssets, err, wantOK)
		}
	})
}
