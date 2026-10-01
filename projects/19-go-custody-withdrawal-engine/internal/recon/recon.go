// SPDX-License-Identifier: MIT

// Package recon reconciles the ledger against chain state.
//
// At a block B the tracker has fully processed, for every asset:
//
//	on-chain balance of the hot wallet at B == ledger(hot_wallet) + ledger(in_flight)
//
// ledger(in_flight) is the (usually negative) net effect of transactions mined at or below B
// that have not reached the confirmation depth, so the identity reads "the ledger's hot wallet
// minus what is in flight out of it". It also checks the ledger's own invariants (every entry
// balanced, trial balance zero, cached balances equal to the postings, no customer overdrawn,
// no verified posting changed afterwards) with an incremental ledger.Checker.
package recon

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math/big"
	"slices"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/audit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/chain"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/clock"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/metrics"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

// AssetLine is the reconciliation of one asset.
type AssetLine struct {
	Asset     string `json:"asset"`
	OnChain   string `json:"on_chain"`
	HotWallet string `json:"ledger_hot_wallet"`
	InFlight  string `json:"ledger_in_flight"`
	Expected  string `json:"expected"`
	Delta     string `json:"delta"` // on_chain - expected; positive = unexplained inflow
	OK        bool   `json:"ok"`
}

// Report is the result of a run.
type Report struct {
	Block        uint64      `json:"block"`
	BlockHash    common.Hash `json:"block_hash"`
	OK           bool        `json:"ok"`
	Inconclusive bool        `json:"inconclusive,omitempty"`
	Assets       []AssetLine `json:"assets"`
	LedgerIssues []string    `json:"ledger_issues,omitempty"`
	At           time.Time   `json:"at"`
}

// Reconciler runs reconciliations.
type Reconciler struct {
	db       *store.DB
	chain    chain.Client
	clock    clock.Clock
	metrics  *metrics.Metrics
	log      *slog.Logger
	hot      common.Address
	native   string
	tokens   map[string]common.Address
	checker  *ledger.Checker
	mu       sync.Mutex
	last     *Report
	lastOK   bool
	haveLast bool
}

// New returns a Reconciler.
func New(db *store.DB, c chain.Client, clk clock.Clock, m *metrics.Metrics, log *slog.Logger, hot common.Address, native string, tokens map[string]common.Address) *Reconciler {
	return &Reconciler{db: db, chain: c, clock: clk, metrics: m, log: log, hot: hot, native: native, tokens: tokens,
		checker: ledger.NewChecker(0)}
}

// Opening records the hot wallet's balances as treasury capital on first start, so the ledger
// starts in agreement with the chain. It must run before the engine sends anything.
func (r *Reconciler) Opening(ctx context.Context) error {
	head, err := r.chain.Head(ctx)
	if err != nil {
		return err
	}
	balances, err := r.onChain(ctx, head.Hash)
	if err != nil {
		return err
	}
	return r.db.WithTx(ctx, func(tx *store.Tx) error {
		if _, ok, err := store.GetMeta(ctx, tx, "opening_block"); err != nil || ok {
			return err
		}
		var postings []ledger.Posting
		for _, asset := range r.assets() {
			if v := balances[asset]; v.Sign() > 0 {
				postings = append(postings, ledger.Debit(ledger.HotWallet, asset, v), ledger.Credit(ledger.Treasury, asset, v))
			}
		}
		if len(postings) > 0 {
			if _, err := ledger.Post(ctx, tx, ledger.Entry{Ref: "opening", Kind: "opening_balance", Postings: postings}, r.clock.Now()); err != nil {
				return err
			}
		}
		if err := audit.Record(ctx, tx, r.clock.Now(), audit.Event{Type: "ledger.opening", Actor: "engine", Subject: r.hot.Hex(),
			Data: map[string]any{"block": head.Number}}); err != nil {
			return err
		}
		return store.SetMeta(ctx, tx, "opening_block", fmt.Sprint(head.Number))
	})
}

func (r *Reconciler) assets() []string {
	out := []string{r.native}
	for a := range r.tokens {
		out = append(out, a)
	}
	slices.Sort(out[1:])
	return out
}

func (r *Reconciler) onChain(ctx context.Context, block common.Hash) (map[string]*big.Int, error) {
	out := map[string]*big.Int{}
	v, err := r.chain.BalanceAtHash(ctx, r.hot, block)
	if err != nil {
		return nil, fmt.Errorf("recon: native balance: %w", err)
	}
	out[r.native] = v
	for asset, token := range r.tokens {
		v, err := chain.TokenBalanceAtHash(ctx, r.chain, token, r.hot, block)
		if err != nil {
			return nil, err
		}
		out[asset] = v
	}
	return out, nil
}

// Run reconciles at head, which must be the head of a complete tracker round. It returns an
// inconclusive report if head stopped being canonical in the meantime.
func (r *Reconciler) Run(ctx context.Context, head chain.BlockRef) (Report, error) {
	rep := Report{Block: head.Number, BlockHash: head.Hash, At: r.clock.Now()}
	canon, err := r.chain.BlockByNumber(ctx, head.Number)
	if err != nil {
		return rep, err
	}
	if canon.Hash != head.Hash {
		rep.Inconclusive = true
		r.metrics.ReconciliationRuns.WithLabelValues("inconclusive").Inc()
		return rep, nil
	}
	balances, err := r.onChain(ctx, head.Hash)
	if err != nil {
		return rep, err
	}
	// The ledger's own invariants and the balances used below come from one read snapshot, so a
	// write committed meanwhile by the API or another loop can never surface as a mismatch.
	// hot_wallet and in_flight only change in tracker rounds, and this runs on the tracker's
	// goroutine right after a complete round at head, so they are exactly the ledger at head.
	check, snap, err := r.checker.Run(ctx, r.db)
	if err != nil {
		return rep, err
	}
	rep.OK = true
	for _, asset := range r.assets() {
		hw := snap.Get(ledger.HotWallet, asset)
		inf := snap.Get(ledger.InFlight, asset)
		expected := new(big.Int).Add(hw, inf)
		delta := new(big.Int).Sub(balances[asset], expected)
		line := AssetLine{Asset: asset, OnChain: balances[asset].String(), HotWallet: hw.String(), InFlight: inf.String(),
			Expected: expected.String(), Delta: delta.String(), OK: delta.Sign() == 0}
		rep.OK = rep.OK && line.OK
		rep.Assets = append(rep.Assets, line)
		f, _ := new(big.Float).SetInt(delta).Float64()
		r.metrics.ReconciliationDelta.WithLabelValues(asset).Set(f)
	}
	if !check.OK() {
		rep.OK = false
		rep.LedgerIssues = append(rep.LedgerIssues, check.UnbalancedEntries...)
		rep.LedgerIssues = append(rep.LedgerIssues, check.CacheMismatches...)
		rep.LedgerIssues = append(rep.LedgerIssues, check.Overdrawn...)
		for _, k := range check.Rewritten {
			rep.LedgerIssues = append(rep.LedgerIssues, "postings changed after verification: "+k)
		}
		for asset, v := range check.TrialBalance {
			if v.Sign() != 0 {
				rep.LedgerIssues = append(rep.LedgerIssues, "trial balance "+asset+" = "+v.String())
			}
		}
	}
	result := "ok"
	if !rep.OK {
		result = "mismatch"
	}
	r.metrics.ReconciliationRuns.WithLabelValues(result).Inc()
	body, err := json.Marshal(rep)
	if err != nil {
		return rep, err
	}
	r.mu.Lock()
	changed := !r.haveLast || r.lastOK != rep.OK
	r.last, r.lastOK, r.haveLast = &rep, rep.OK, true
	r.mu.Unlock()
	err = r.db.WithTx(ctx, func(tx *store.Tx) error {
		ok := 0
		if rep.OK {
			ok = 1
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO reconciliations (block_number, block_hash, ok, report, created_at) VALUES (?, ?, ?, ?, ?)`,
			head.Number, head.Hash.Hex(), ok, string(body), rep.At.UnixNano()); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM reconciliations WHERE id NOT IN (SELECT id FROM reconciliations ORDER BY id DESC LIMIT 1000)`); err != nil {
			return err
		}
		if changed {
			typ := "reconciliation.ok"
			if !rep.OK {
				typ = "reconciliation.mismatch"
			}
			var data map[string]any
			if err := json.Unmarshal(body, &data); err != nil {
				return err
			}
			return audit.Record(ctx, tx, rep.At, audit.Event{Type: typ, Actor: "engine", Subject: r.hot.Hex(), Data: data})
		}
		return nil
	})
	if !rep.OK && changed {
		r.log.Error("reconciliation mismatch", "block", head.Number, "report", string(body))
	}
	return rep, err
}

// Last returns the most recent report, if any.
func (r *Reconciler) Last() (Report, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.last == nil {
		return Report{}, false
	}
	return *r.last, true
}
