// SPDX-License-Identifier: MIT

package ledger

import (
	"context"
	"fmt"
	"maps"
	"math"
	"math/big"
	"slices"
	"sync"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

// CheckResult reports the ledger's global invariants.
type CheckResult struct {
	// UnbalancedEntries lists entries whose postings do not sum to zero per asset.
	UnbalancedEntries []string
	// TrialBalance is the sum of every balance per asset; it must be zero.
	TrialBalance map[string]*big.Int
	// CacheMismatches lists account/asset pairs whose cached balance differs from the sum of
	// their postings.
	CacheMismatches []string
	// Overdrawn lists customer accounts with a debit balance.
	Overdrawn []string
	// Rewritten lists account/asset pairs whose postings changed after a Checker had verified
	// them (an old posting edited, deleted or added behind the ledger's back). Only a Checker
	// reports it; a one-shot Check has nothing earlier to compare with.
	Rewritten []string
}

// OK reports whether every invariant holds.
func (c CheckResult) OK() bool {
	if len(c.UnbalancedEntries)+len(c.CacheMismatches)+len(c.Overdrawn)+len(c.Rewritten) > 0 {
		return false
	}
	for _, v := range c.TrialBalance {
		if v.Sign() != 0 {
			return false
		}
	}
	return true
}

// Check recomputes everything from the raw postings in one pass: per-entry balance, the trial
// balance and the cached balances table. It reads the whole ledger, so it is meant for tests
// and offline tools; give it a transaction (see store.DB.ReadTx) when other goroutines may be
// writing, so that the postings and the cached balances come from the same snapshot.
// Reconciliation uses a Checker instead.
func Check(ctx context.Context, q store.Querier) (CheckResult, error) {
	f, err := readEntries(ctx, q, 0, math.MaxInt64, -1)
	if err != nil {
		return CheckResult{TrialBalance: map[string]*big.Int{}}, err
	}
	snap, err := Balances(ctx, q)
	if err != nil {
		return CheckResult{TrialBalance: map[string]*big.Int{}}, err
	}
	c := &Checker{cursor: f.last, sums: f.sums, bad: f.bad}
	return c.result(snap), nil
}

// DefaultChunk is the number of ledger entries a Checker reads per read transaction, and the
// number of already-verified entries it re-verifies per Run.
const DefaultChunk = 5000

// Checker verifies the ledger incrementally, so that a reconciliation never rescans the whole
// ledger while it holds the database's only connection.
//
// It keeps, in memory, the sum of every account's postings over the entries it has read (entry
// ids grow with commit order: there is a single writer). Each Run folds in the entries posted
// since the previous one and compares the sums with the cached balances, both inside one read
// transaction, so a write committed concurrently by the API or another loop is either seen by
// both reads or by neither and can never show up as a false mismatch. A Run that finds more than
// Chunk new entries (the first Run after a start) reads them in several short transactions and
// compares only in the last one, releasing the connection in between.
//
// Entries are never modified after they are posted, so the sums of verified entries are not
// re-read on every Run. To still catch postings edited, deleted or inserted behind the ledger's
// back, each Run also re-verifies up to Chunk old entries from scratch; when such a pass has
// covered every entry it had to, it compares what it recomputed with the sums recorded when it
// started (Rewritten) and refreshes the list of unbalanced entries.
type Checker struct {
	// Chunk overrides DefaultChunk when positive.
	Chunk int

	mu        sync.Mutex
	cursor    int64                  // highest entry id folded into sums
	sums      map[acctAsset]*big.Int // per account and asset, over entries <= cursor
	bad       map[int64]string       // unbalanced entries seen so far: id -> ref
	pass      *reverification        // the re-verification in progress, if any
	rewritten []string               // what the last completed re-verification found
}

// NewChecker returns a Checker that reads chunk entries per transaction (0: DefaultChunk).
func NewChecker(chunk int) *Checker { return &Checker{Chunk: chunk} }

type acctAsset struct{ account, asset string }

// reverification recomputes the sums of entries (after, boundary] from scratch.
type reverification struct {
	boundary, after int64
	want, got       map[acctAsset]*big.Int
	bad             map[int64]string
}

func (c *Checker) chunk() int {
	if c.Chunk > 0 {
		return c.Chunk
	}
	return DefaultChunk
}

// Run verifies the ledger in db and returns the result together with the balances snapshot the
// comparison used (reconciliation reads the hot-wallet balances from it).
func (c *Checker) Run(ctx context.Context, db *store.DB) (CheckResult, Snapshot, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.sums == nil {
		c.sums, c.bad = map[acctAsset]*big.Int{}, map[int64]string{}
	}
	var snap Snapshot
	for done := false; !done; {
		err := db.ReadTx(ctx, func(q store.Querier) error {
			f, err := readEntries(ctx, q, c.cursor, math.MaxInt64, c.chunk())
			if err != nil {
				return err
			}
			c.fold(f)
			if f.entries < c.chunk() { // caught up within this snapshot: compare in it
				done = true
				snap, err = Balances(ctx, q)
			}
			return err
		})
		if err != nil {
			return CheckResult{TrialBalance: map[string]*big.Int{}}, nil, err
		}
	}
	if err := db.ReadTx(ctx, func(q store.Querier) error { return c.reverify(ctx, q) }); err != nil {
		return CheckResult{TrialBalance: map[string]*big.Int{}}, nil, err
	}
	return c.result(snap), snap, nil
}

// fold adds a successfully read range of entries to the verified sums.
func (c *Checker) fold(f entryRange) {
	for k, v := range f.sums {
		addTo(c.sums, k, v)
	}
	maps.Copy(c.bad, f.bad)
	c.cursor = max(c.cursor, f.last)
}

// reverify advances the re-verification by one chunk, starting a new pass when none is running.
func (c *Checker) reverify(ctx context.Context, q store.Querier) error {
	if c.pass == nil {
		if c.cursor == 0 {
			return nil
		}
		want := make(map[acctAsset]*big.Int, len(c.sums))
		for k, v := range c.sums {
			want[k] = new(big.Int).Set(v)
		}
		c.pass = &reverification{boundary: c.cursor, want: want, got: map[acctAsset]*big.Int{}, bad: map[int64]string{}}
	}
	p := c.pass
	f, err := readEntries(ctx, q, p.after, p.boundary, c.chunk())
	if err != nil {
		return err
	}
	for k, v := range f.sums {
		addTo(p.got, k, v)
	}
	maps.Copy(p.bad, f.bad)
	p.after = max(p.after, f.last)
	if f.entries == c.chunk() {
		return nil // more to read next Run
	}
	var changed []string
	for k := range p.want {
		if p.got[k] == nil || p.got[k].Cmp(p.want[k]) != 0 {
			changed = append(changed, k.account+"/"+k.asset)
		}
	}
	for k, v := range p.got {
		if p.want[k] == nil && v.Sign() != 0 {
			changed = append(changed, k.account+"/"+k.asset)
		}
	}
	slices.Sort(changed)
	c.rewritten = changed
	for id := range c.bad {
		if _, still := p.bad[id]; id <= p.boundary && !still {
			delete(c.bad, id)
		}
	}
	maps.Copy(c.bad, p.bad)
	c.pass = nil
	return nil
}

// result compares the verified sums with a balances snapshot.
func (c *Checker) result(snap Snapshot) CheckResult {
	res := CheckResult{TrialBalance: map[string]*big.Int{}}
	for k, v := range c.sums {
		if res.TrialBalance[k.asset] == nil {
			res.TrialBalance[k.asset] = new(big.Int)
		}
		res.TrialBalance[k.asset].Add(res.TrialBalance[k.asset], v)
		if snap.Get(k.account, k.asset).Cmp(v) != 0 {
			res.CacheMismatches = append(res.CacheMismatches, k.account+"/"+k.asset)
		}
		if IsUser(k.account) && v.Sign() > 0 {
			res.Overdrawn = append(res.Overdrawn, k.account+"/"+k.asset)
		}
	}
	for acct, assets := range snap {
		for asset, v := range assets {
			if _, ok := c.sums[acctAsset{acct, asset}]; !ok && v.Sign() != 0 {
				res.CacheMismatches = append(res.CacheMismatches, acct+"/"+asset)
			}
		}
	}
	for _, ref := range c.bad {
		res.UnbalancedEntries = append(res.UnbalancedEntries, ref)
	}
	res.Rewritten = slices.Clone(c.rewritten)
	slices.Sort(res.UnbalancedEntries)
	slices.Sort(res.CacheMismatches)
	slices.Sort(res.Overdrawn)
	return res
}

// entryRange is what readEntries found in a range of entries.
type entryRange struct {
	entries int                    // entries read, including any without postings
	last    int64                  // highest entry id read (0 when none)
	sums    map[acctAsset]*big.Int // per account and asset
	bad     map[int64]string       // unbalanced entries: id -> ref
}

// readEntries reads at most limit entries (limit < 0: all) with after < id <= upTo, in id order,
// and sums their postings. It either returns everything it read or an error, never a part.
func readEntries(ctx context.Context, q store.Querier, after, upTo int64, limit int) (entryRange, error) {
	out := entryRange{sums: map[acctAsset]*big.Int{}, bad: map[int64]string{}}
	rows, err := q.QueryContext(ctx, `
		SELECT e.id, e.ref, COALESCE(p.account, ''), COALESCE(p.asset, ''), COALESCE(p.amount, '0')
		FROM (SELECT id, ref FROM ledger_entries WHERE id > ? AND id <= ? ORDER BY id LIMIT ?) e
		LEFT JOIN ledger_postings p ON p.entry_id = e.id
		ORDER BY e.id`, after, upTo, limit)
	if err != nil {
		return entryRange{}, fmt.Errorf("ledger: check: %w", err)
	}
	defer rows.Close()
	var curID int64
	var curRef string
	cur := map[string]*big.Int{}
	closeEntry := func() {
		for _, s := range cur {
			if s.Sign() != 0 {
				out.bad[curID] = curRef
				break
			}
		}
		clear(cur)
	}
	for rows.Next() {
		var id int64
		var ref, acct, asset, amt string
		if err := rows.Scan(&id, &ref, &acct, &asset, &amt); err != nil {
			return entryRange{}, err
		}
		if id != curID {
			if out.entries > 0 {
				closeEntry()
			}
			curID, curRef = id, ref
			out.entries++
			out.last = id
		}
		if acct == "" {
			continue // an entry without postings
		}
		v, err := parse(amt)
		if err != nil {
			return entryRange{}, err
		}
		if cur[asset] == nil {
			cur[asset] = new(big.Int)
		}
		cur[asset].Add(cur[asset], v)
		addTo(out.sums, acctAsset{acct, asset}, v)
	}
	if err := rows.Err(); err != nil {
		return entryRange{}, err
	}
	if out.entries > 0 {
		closeEntry()
	}
	return out, nil
}

func addTo(m map[acctAsset]*big.Int, k acctAsset, v *big.Int) {
	if m[k] == nil {
		m[k] = new(big.Int)
	}
	m[k].Add(m[k], v)
}
