// SPDX-License-Identifier: MIT

//go:build integration

package integration

import (
	"bytes"
	"context"
	"fmt"
	"math/big"
	"math/rand/v2"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/fetch"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/indexer"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/model"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/rpcfault"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store/sqlite"
)

var maxUint256 = new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 256), big.NewInt(1))

// workload generates random token and vault transactions from anvil's unlocked accounts.
type workload struct {
	a       *Anvil
	f       Fixtures
	rng     *rand.Rand
	holders []common.Address
}

func (w *workload) pick() common.Address { return w.holders[w.rng.IntN(len(w.holders))] }

func (w *workload) amount() *big.Int {
	v := new(big.Int).SetUint64(w.rng.Uint64N(1_000_000) + 1)
	return v.Lsh(v, uint(w.rng.IntN(60)))
}

// tx returns one random transaction. Some revert on purpose (redeeming more shares than owned):
// a reverted transaction emits no logs, which the indexer must not care about.
func (w *workload) tx() txRequest {
	holder, other := w.pick(), w.pick()
	tokens := []common.Address{w.f.TokenA, w.f.TokenB}
	token := tokens[w.rng.IntN(2)]
	req := txRequest{From: holder, To: &token, Gas: 1_000_000}
	switch w.rng.IntN(10) {
	case 0:
		req.From = w.f.Owner
		req.Data = tokenABI.PackMint(holder, w.amount())
	case 1, 2:
		req.Data = tokenABI.PackTransfer(other, w.amount())
	case 3:
		n := 2 + w.rng.IntN(20)
		to := make([]common.Address, n)
		amounts := make([]*big.Int, n)
		for i := range n {
			to[i], amounts[i] = w.pick(), w.amount()
		}
		req.Data = tokenABI.PackBatchTransfer(to, amounts)
	case 4:
		req.Data = tokenABI.PackBurn(w.amount())
	case 5:
		req.To = &w.f.Vault
		req.Data = vaultABI.PackDeposit(w.amount(), holder)
	case 6:
		req.To = &w.f.Vault
		req.Data = vaultABI.PackRedeem(w.amount(), other, holder)
	case 7:
		req.To = &w.f.TokenA
		req.Data = tokenABI.PackTransfer(w.f.Vault, w.amount())
	case 8:
		req.To = &w.f.Vault
		req.Data = vaultABI.PackTransfer(other, w.amount())
	default:
		req.Data = tokenABI.PackApprove(other, w.amount())
	}
	return req
}

func (w *workload) setup() {
	for _, h := range w.holders {
		for _, token := range []common.Address{w.f.TokenA, w.f.TokenB} {
			w.a.Send(w.f.Owner, &token, tokenABI.PackMint(h, new(big.Int).Lsh(big.NewInt(1), 100)))
		}
		w.a.Send(h, &w.f.TokenA, tokenABI.PackApprove(w.f.Vault, maxUint256))
	}
	w.a.Mine(1)
}

// liveIndexer tracks the current indexer process across crash-restarts.
type liveIndexer struct {
	mu   sync.Mutex
	ix   *Indexer
	args []string
	t    testing.TB
}

func (l *liveIndexer) url() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.ix.URL
}

// kill SIGKILLs the current process: no graceful shutdown, no final checkpoint write.
func (l *liveIndexer) kill() {
	l.mu.Lock()
	ix := l.ix
	l.mu.Unlock()
	ix.Kill()
}

// restart starts a new process on the same database (and a new port).
func (l *liveIndexer) restart() {
	next := StartIndexer(l.t, l.args...)
	l.mu.Lock()
	l.ix = next
	l.mu.Unlock()
}

func rounds() int {
	if v, err := strconv.Atoi(os.Getenv("INDEXER_IT_ROUNDS")); err == nil && v > 0 {
		return v
	}
	return 2
}

// TestDifferentialAnvil is the project's headline property, end to end against a real node:
// after a random sequence of transactions, anvil_reorg calls of random depth, crash-restarts
// (SIGKILL) and injected RPC faults, the database the indexer maintained incrementally is
// identical to a from-scratch reindex of the canonical chain (checked by `indexer verify` and by
// an in-test diff), every balance, supply and vault total equals the contracts' own view at the
// tip, and an SSE consumer that applied `transfer` and undid `retract` events holds exactly
// the stored transfers.
func TestDifferentialAnvil(t *testing.T) {
	total := map[string]int64{}
	for round := range rounds() {
		seed := uint64(round + 1)
		t.Run(fmt.Sprintf("seed=%d", seed), func(t *testing.T) { runDifferential(t, seed, total) })
	}
	// The README's anvil totals come from this line (CI keeps it in its artifacts).
	keys := make([]string, 0, len(total))
	for k := range total {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = fmt.Sprintf("%s=%d", k, total[k])
	}
	t.Logf("TOTAL TestDifferentialAnvil: %s", strings.Join(parts, " "))
}

func runDifferential(t *testing.T, seed uint64, total map[string]int64) {
	rng := rand.New(rand.NewPCG(seed, seed^0xa11ce))
	a := StartAnvil(t)
	f := a.Deploy()
	w := &workload{a: a, f: f, rng: rng, holders: a.Accounts[1:8]}
	w.setup()
	setupHead, _ := a.HeadRef()

	faults := rpcfault.New(nil, rpcfault.Config{
		Seed:          seed,
		HTTPErrorRate: 0.02,
		RPCErrorRate:  0.02,
		TruncateRate:  0.02,
		TimeoutRate:   0.003,
		MaxLatency:    3 * time.Millisecond,
		MaxLogs:       12,
		DropBlockRate: 0.3,
	})
	target, _ := url.Parse(a.URL)
	proxy := httptest.NewServer(rpcfault.NewProxy(target, faults))
	t.Cleanup(proxy.Close)

	db := filepath.Join(t.TempDir(), "idx.db")
	live := &liveIndexer{t: t, args: []string{"serve", "--rpc-url", proxy.URL, "--db", db,
		"--token", f.TokenA.Hex(), "--token", f.TokenB.Hex(), "--vault", f.Vault.Hex(),
		"--confirmations", "3", "--poll-interval", "25ms", "--initial-range", "4", "--max-range", "64",
		"--concurrency", "3", "--rpc-timeout", "1s", "--header-batch", "16", "--bloom-check",
		"--reorg-window", "64"}}
	live.ix = StartIndexer(t, live.args...)
	consumer := StartConsumer(live.url)
	defer consumer.Stop()

	reorgs, crashes, txs, down := 0, 0, 0, 0
	for range 160 {
		if down > 0 {
			if down--; down == 0 {
				live.restart()
			}
		}
		switch op := rng.IntN(20); {
		case op < 12: // a block with a few transactions
			n := rng.IntN(6)
			for range n {
				req := w.tx()
				a.Send(req.From, req.To, req.Data)
			}
			txs += n
			a.Mine(1)
		case op < 16: // reorg of random depth, with fresh transactions in the new blocks
			head, _ := a.HeadRef()
			maxDepth := int(head - setupHead)
			if maxDepth < 1 {
				a.Mine(1)
				continue
			}
			depth := 1 + rng.IntN(min(8, maxDepth))
			var repl []ReorgTx
			for range rng.IntN(4) {
				repl = append(repl, ReorgTx{Req: w.tx(), Offset: rng.IntN(depth)})
			}
			a.Reorg(depth, repl)
			reorgs++
		case op < 17: // crash: SIGKILL mid-flight; the chain moves on (blocks, reorgs) while the
			// indexer is down, and the restart resumes from the checkpoint with a range backfill.
			if down == 0 {
				live.kill()
				down = 1 + rng.IntN(6)
				crashes++
			}
		default:
			a.Mine(1 + rng.IntN(5))
		}
		// Give the indexer time to index most blocks before they are reorganised away, so reorgs
		// hit indexed data (sometimes mid-commit, sometimes between polls).
		time.Sleep(time.Duration(20+rng.IntN(120)) * time.Millisecond)
	}
	if down > 0 {
		live.restart()
	}
	a.Mine(1)
	headNum, headHash := a.HeadRef()
	WaitForTip(t, live.url, headNum, headHash, 3*time.Minute, func() string {
		live.mu.Lock()
		defer live.mu.Unlock()
		return live.ix.Logs()
	})

	var st struct {
		Reorgs int64 `json:"reorgs"`
		Events struct {
			Newest uint64 `json:"newest"`
		} `json:"events"`
	}
	if _, err := GetJSON(live.url()+"/v1/status", &st); err != nil {
		t.Fatal(err)
	}
	consumer.WaitFor(t, st.Events.Newest, time.Minute)
	live.mu.Lock()
	live.ix.Kill()
	live.mu.Unlock()
	stats := faults.Stats.Snapshot()
	t.Logf("seed=%d head=%d txs=%d reorgs=%d (indexer saw %d) crashes=%d faults=%v", seed, headNum, txs, reorgs, st.Reorgs, crashes, stats)
	for _, kind := range []string{"http_errors", "rpc_errors", "truncated", "limit_errors"} {
		if stats[kind] == 0 {
			t.Errorf("fault %q was never injected; the run did not exercise it", kind)
		}
	}
	if st.Reorgs < 5 {
		t.Errorf("the indexer observed only %d reorgs; the run did not exercise rollbacks", st.Reorgs)
	}

	// 1. The shipped verification command agrees.
	var out bytes.Buffer
	verify := exec.Command(indexerBin, "verify", "--rpc-url", a.URL, "--db", db, "--log-level", "warn")
	verify.Stdout, verify.Stderr = &out, &out
	if err := verify.Run(); err != nil {
		t.Fatalf("indexer verify failed: %v\n%s", err, out.String())
	}
	if !strings.Contains(out.String(), "OK: identical") {
		t.Fatalf("unexpected verify output:\n%s", out.String())
	}

	// 2. The same diff in-process, for a readable failure.
	ctx := context.Background()
	st1, err := sqlite.Open(ctx, db)
	if err != nil {
		t.Fatal(err)
	}
	defer st1.Close()
	incremental := snapshotOf(t, st1)
	reindexed := reindex(t, a.URL, st1, incremental.Tip.Number)
	if diffs := store.Diff(incremental, reindexed); len(diffs) > 0 {
		t.Fatalf("incremental != reindex: %d differences, first: %s", len(diffs), diffs[0])
	}
	if incremental.Tip.Hash != headHash {
		t.Fatalf("tip %s is not the head %s", incremental.Tip.Hash, headHash)
	}

	// 3. Derived state equals the contracts' own view at the tip.
	checkOnChain(t, a, st1, f, append([]common.Address{f.Owner, f.Vault}, w.holders...), headHash)

	// 4. The SSE consumer ends with exactly the stored transfers.
	var stored []model.Transfer
	if err := st1.View(ctx, func(r store.Reader) error {
		var err error
		stored, err = r.TransfersFrom(0)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	seen := consumer.Transfers()
	if len(seen) != len(stored) {
		t.Fatalf("SSE consumer holds %d transfers, database %d", len(seen), len(stored))
	}
	for _, tr := range stored {
		if got, ok := seen[transferKey(tr)]; !ok || got.Value.String() != tr.Value.String() || got.To != tr.To || got.From != tr.From {
			t.Fatalf("SSE consumer disagrees on transfer %s", transferKey(tr))
		}
	}
	consumer.Stop()
	t.Logf("rows=%v consumer: transfers=%d retracted=%d reorg events=%d reconnects=%d",
		incremental.Counts(), len(seen), consumer.retracted, consumer.reorgs, consumer.reconnects)
	total["rounds"]++
	total["blocks"] += int64(headNum)
	total["txs"] += int64(txs)
	total["anvil_reorgs"] += int64(reorgs)
	total["reorgs_seen_by_indexer"] += st.Reorgs
	total["crashes"] += int64(crashes)
	total["rows_compared"] += int64(incremental.Rows())
	total["sse_retractions"] += int64(consumer.retracted)
	total["sse_reconnects"] += int64(consumer.reconnects)
	for k, v := range stats {
		total["proxy_"+k] += v
	}
}

func snapshotOf(t testing.TB, st store.Store) *store.Snapshot {
	t.Helper()
	var s *store.Snapshot
	if err := st.View(context.Background(), func(r store.Reader) error {
		var err error
		s, err = r.Snapshot()
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return s
}

// reindex rebuilds the database from scratch into a fresh store, up to tip, without faults.
func reindex(t testing.TB, rpcURL string, original store.Store, tip uint64) *store.Snapshot {
	t.Helper()
	ctx := context.Background()
	fp, _, err := indexer.ReadFingerprint(ctx, original)
	if err != nil {
		t.Fatal(err)
	}
	src, err := chain.Dial(ctx, rpcURL, chain.RPCOptions{})
	if err != nil {
		t.Fatal(err)
	}
	defer src.Close()
	fresh, err := sqlite.Open(ctx, filepath.Join(t.TempDir(), "reindex.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer fresh.Close()
	eng, err := indexer.New(ctx, indexer.Config{Start: fp.Start, Confirmations: 3, PollInterval: 10 * time.Millisecond,
		ReorgWindow: 1 << 20, StopAt: &tip, Contracts: fp.Contracts(), Fetch: fetch.Config{MaxSpan: 10_000}}, src, fresh, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := eng.SyncUntil(ctx, tip); err != nil {
		t.Fatal(err)
	}
	return snapshotOf(t, fresh)
}

// checkOnChain compares every derived balance, supply and vault total with eth_call at block.
func checkOnChain(t testing.TB, a *Anvil, st store.Store, f Fixtures, accounts []common.Address, block common.Hash) {
	t.Helper()
	ctx := context.Background()
	err := st.View(ctx, func(r store.Reader) error {
		for _, token := range []common.Address{f.TokenA, f.TokenB, f.Vault} {
			for _, acct := range accounts {
				got, err := r.Balance(token, acct)
				if err != nil {
					return err
				}
				want := a.CallUint(token, tokenABI.PackBalanceOf(acct), block)
				if got.Cmp(want) != 0 {
					return fmt.Errorf("balance of %s in %s: indexed %s, on chain %s", acct, token, got, want)
				}
			}
			supply, err := r.Supply(token)
			if err != nil {
				return err
			}
			if want := a.CallUint(token, tokenABI.PackTotalSupply(), block); supply.Cmp(want) != 0 {
				return fmt.Errorf("supply of %s: indexed %s, on chain %s", token, supply, want)
			}
		}
		assets, err := r.Balance(f.TokenA, f.Vault)
		if err != nil {
			return err
		}
		if want := a.CallUint(f.Vault, vaultABI.PackTotalAssets(), block); assets.Cmp(want) != 0 {
			return fmt.Errorf("vault total assets: indexed %s, on chain %s", assets, want)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
