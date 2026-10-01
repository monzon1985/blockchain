// SPDX-License-Identifier: MIT

package indexer

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"math/big"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/decode"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/fakechain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/fetch"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/metrics"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/model"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/reorg"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store/sqlstore"
)

// --- hand-written traffic -----------------------------------------------------------------------

func word(v int64) []byte { return common.LeftPadBytes(big.NewInt(v).Bytes(), 32) }

func topic(a common.Address) common.Hash { return common.BytesToHash(a.Bytes()) }

func xfer(tx uint, token, from, to common.Address, v int64) fakechain.LogSpec {
	return fakechain.LogSpec{Tx: tx, Address: token, Topics: []common.Hash{decode.TopicTransfer, topic(from), topic(to)}, Data: word(v)}
}

// deposit is the log triple OpenZeppelin's ERC4626.deposit emits.
func deposit(tx uint, w *fakechain.World, holder common.Address, assets, shares int64) []fakechain.LogSpec {
	return []fakechain.LogSpec{
		xfer(tx, w.Asset, holder, w.Vault, assets),
		xfer(tx, w.Vault, common.Address{}, holder, shares),
		{Tx: tx, Address: w.Vault, Topics: []common.Hash{decode.TopicDeposit, topic(holder), topic(holder)}, Data: append(word(assets), word(shares)...)},
	}
}

func outbox(t *testing.T, st store.Store) []model.Event {
	t.Helper()
	var evs []model.Event
	if err := st.View(context.Background(), func(r store.Reader) error {
		var err error
		evs, err = r.EventsAfter(0, 1<<30)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return evs
}

func reorgCount(t *testing.T, st store.Store) int64 {
	t.Helper()
	var n int64
	if err := st.View(context.Background(), func(r store.Reader) error {
		var err error
		n, err = r.ReorgCount()
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return n
}

// --- sources with failures -----------------------------------------------------------------------

// flaky wraps a source: LatestHeader fails while headFailures > 0, and range header reads are
// recorded.
type flaky struct {
	chain.Source
	headFailures atomic.Int64
	mu           sync.Mutex
	ranges       [][2]uint64
}

func (f *flaky) LatestHeader(ctx context.Context) (chain.Header, error) {
	if f.headFailures.Add(-1) >= 0 {
		return chain.Header{}, io.ErrUnexpectedEOF
	}
	return f.Source.LatestHeader(ctx)
}

func (f *flaky) HeadersByRange(ctx context.Context, from, to uint64) ([]chain.Header, error) {
	f.mu.Lock()
	f.ranges = append(f.ranges, [2]uint64{from, to})
	f.mu.Unlock()
	return f.Source.HeadersByRange(ctx, from, to)
}

func (f *flaky) lowestRead() uint64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	low := uint64(math.MaxUint64)
	for _, r := range f.ranges {
		low = min(low, r[0])
	}
	return low
}

// --- tests ---------------------------------------------------------------------------------------

// TestHeadBelowTipIsTreatedAsLagging pins down a deliberate choice: a node whose head is an
// ancestor of the indexed tip (a lagging replica behind a load balancer, or a node that rolled
// back without producing a new block yet) is waited for, not obeyed. Rolling back on it would
// retract canonical data whenever a provider routes one request to a stale replica. The first
// block that contradicts the indexed chain triggers the rollback.
func TestHeadBelowTipIsTreatedAsLagging(t *testing.T) {
	w := fakechain.NewWorld(3)
	fc := fakechain.New(1)
	alice := w.Holders[0]
	for i := range 10 {
		fc.Mine([]fakechain.LogSpec{xfer(0, w.Tokens[0], common.Address{}, alice, int64(i+1))})
	}
	st := openStore(t)
	e := newEngine(t, testConfig(w), fc, st)
	syncToTip(t, e, fc)

	if err := fc.Reorg(2, nil); err != nil { // head 8: an ancestor of the tip
		t.Fatal(err)
	}
	for range 3 {
		out, err := e.SyncOnce(context.Background())
		if err != nil || out != Idle {
			t.Fatalf("head below the tip: outcome %v, err %v", out, err)
		}
	}
	if tip, _ := e.tracker.Tip(); tip.Number != 10 || reorgCount(t, st) != 0 {
		t.Fatalf("engine moved: tip %d, reorgs %d", tip.Number, reorgCount(t, st))
	}

	fc.Mine([]fakechain.LogSpec{xfer(0, w.Tokens[0], alice, w.Holders[1], 1)}) // 9': contradicts 9
	out, err := e.SyncOnce(context.Background())
	if err != nil || out != RolledBack {
		t.Fatalf("contradicting block: outcome %v, err %v", out, err)
	}
	syncToTip(t, e, fc)
	var last *model.Reorg
	if err := st.View(context.Background(), func(r store.Reader) error {
		var err error
		last, _, err = r.LastReorg()
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if last == nil || last.Depth != 2 || last.OldTip.Number != 10 || last.Ancestor == nil || last.Ancestor.Number != 8 {
		t.Fatalf("recorded reorg %+v", last)
	}
	fresh := openStore(t)
	syncToTip(t, newEngine(t, testConfig(w), fc, fresh), fc)
	requireSame(t, "incremental vs reindex", snapshot(t, st), snapshot(t, fresh))
}

// TestRetractionOrderAndPayloads checks the SSE contract of a rollback: one `retract` per
// removed record, newest first (share prices before the logs of their block), each carrying the
// exact object published before, then one `reorg` event.
func TestRetractionOrderAndPayloads(t *testing.T) {
	w := fakechain.NewWorld(3)
	fc := fakechain.New(1)
	alice, bob := w.Holders[0], w.Holders[1]
	fc.Mine([]fakechain.LogSpec{xfer(0, w.Asset, common.Address{}, alice, 10_000)})                                 // 1
	fc.Mine(deposit(0, w, alice, 1000, 1_000_000))                                                                  // 2
	fc.Mine(append(deposit(0, w, alice, 500, 500_000), xfer(1, w.Asset, alice, bob, 7)))                            // 3
	fc.Mine([]fakechain.LogSpec{xfer(0, w.Asset, bob, w.Vault, 7), xfer(1, w.Tokens[1], common.Address{}, bob, 3)}) // 4: donation
	st := openStore(t)
	cfg := testConfig(w)
	cfg.Confirmations = 1
	e := newEngine(t, cfg, fc, st)
	syncToTip(t, e, fc)
	before := outbox(t, st)
	published := map[string]string{} // kind/key -> payload
	for _, ev := range before {
		var key struct {
			Block    chain.BlockRef `json:"block"`
			LogIndex uint64         `json:"logIndex"`
			Vault    common.Address `json:"vault"`
		}
		_ = json.Unmarshal(ev.Payload, &key)
		published[fmt.Sprintf("%s/%s/%d/%s", ev.Kind, key.Block.Hash.Hex(), key.LogIndex, key.Vault.Hex())] = string(ev.Payload)
	}

	if err := fc.Reorg(3, [][]fakechain.LogSpec{nil, nil, nil}); err != nil { // orphan blocks 2..4
		t.Fatal(err)
	}
	syncToTip(t, e, fc)
	after := outbox(t, st)[len(before):]
	type pos struct {
		block, order uint64
	}
	var prev *pos
	retracted := 0
	for _, ev := range after {
		if ev.Kind == model.EventReorg {
			if retracted == 0 {
				t.Fatal("reorg event before the retractions")
			}
			break
		}
		if ev.Kind != model.EventRetract {
			t.Fatalf("unexpected %s event during the rollback", ev.Kind)
		}
		var r struct {
			Type string          `json:"type"`
			Item json.RawMessage `json:"item"`
		}
		if err := json.Unmarshal(ev.Payload, &r); err != nil {
			t.Fatal(err)
		}
		var key struct {
			Block    chain.BlockRef `json:"block"`
			LogIndex uint64         `json:"logIndex"`
			Vault    common.Address `json:"vault"`
		}
		_ = json.Unmarshal(r.Item, &key)
		orig, ok := published[fmt.Sprintf("%s/%s/%d/%s", r.Type, key.Block.Hash.Hex(), key.LogIndex, key.Vault.Hex())]
		if !ok || orig != string(r.Item) {
			t.Fatalf("retracted %s differs from what was published:\n%s\n%s", r.Type, r.Item, orig)
		}
		p := pos{key.Block.Number, key.LogIndex}
		if r.Type == model.EventSharePrice {
			p.order = math.MaxUint64
		}
		if prev != nil && cmp.Or(cmp.Compare(p.block, prev.block), cmp.Compare(p.order, prev.order)) >= 0 {
			t.Fatalf("retraction %+v does not come before %+v", p, *prev)
		}
		prev = &p
		retracted++
	}
	// Blocks 2..4 published 2+3+2 transfers, 1+1 vault events and 3 share prices.
	if retracted != 12 {
		t.Fatalf("%d retractions, want 12", retracted)
	}
	if got := testutil.ToFloat64(e.m.Reorgs); got != 1 {
		t.Fatalf("reorg metric %v", got)
	}
	if got := testutil.ToFloat64(e.m.DeepReorgs); got != 1 {
		t.Fatalf("a depth-3 reorg with 1 confirmation is deep: %v", got)
	}
	if got := testutil.ToFloat64(e.m.Retractions.WithLabelValues(model.EventTransfer)); got != 7 {
		t.Fatalf("transfer retractions %v", got)
	}
}

func TestFingerprintGuardsTheDatabase(t *testing.T) {
	w := fakechain.NewWorld(2)
	fc := fakechain.New(7)
	fc.Mine(nil)
	st := openStore(t)
	cfg := testConfig(w)
	newEngine(t, cfg, fc, st)
	fp, ok, err := ReadFingerprint(context.Background(), st)
	if err != nil || !ok || fp.ChainID != 7 || fp.Start != cfg.Start || len(fp.Contracts().Addresses()) != len(cfg.Contracts.Addresses()) {
		t.Fatalf("fingerprint %+v %v %v", fp, ok, err)
	}
	other := cfg
	other.Start = 2
	otherContracts := cfg
	otherContracts.Contracts = decode.Contracts{Tokens: w.Tokens[:1]}
	for name, tc := range map[string]struct {
		cfg Config
		src chain.Source
	}{
		"start block": {other, fc},
		"contracts":   {otherContracts, fc},
		"chain id":    {cfg, fakechain.New(8)},
	} {
		if _, err := New(context.Background(), tc.cfg, tc.src, st, nil, nil); !errors.Is(err, ErrConfigMismatch) {
			t.Errorf("%s: %v, want ErrConfigMismatch", name, err)
		}
	}
	if _, ok, err := ReadFingerprint(context.Background(), openStore(t)); ok || err != nil {
		t.Fatalf("fresh database has a fingerprint: %v %v", ok, err)
	}
}

func TestNewValidatesConfiguration(t *testing.T) {
	fc := fakechain.New(1)
	w := fakechain.NewWorld(2)
	cfg := testConfig(w)
	cfg.Contracts = decode.Contracts{}
	if _, err := New(context.Background(), cfg, fc, openStore(t), nil, nil); err == nil {
		t.Fatal("no contracts accepted")
	}
	cfg = testConfig(w)
	cfg.ReorgWindow = 1
	if _, err := New(context.Background(), cfg, fc, openStore(t), nil, nil); err == nil {
		t.Fatal("window of one header accepted")
	}
	cfg = Config{Contracts: w.Contracts()}
	e, err := New(context.Background(), cfg, fc, openStore(t), metrics.New(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if c := e.Config(); c.PollInterval != 2*time.Second || c.ReorgWindow != 1024 || c.EventRetention != 100_000 || len(c.Fetch.Addresses) == 0 {
		t.Fatalf("defaults %+v", c)
	}
	if e.ChainID() != 1 {
		t.Fatal("chain id")
	}
	// A node that never answers eth_chainId is reported, not waited on forever.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, err := New(ctx, testConfig(w), deadSource{}, openStore(t), nil, nil); err == nil {
		t.Fatal("dead node accepted")
	}
}

type deadSource struct{ chain.Source }

func (deadSource) ChainID(context.Context) (uint64, error) { return 0, io.ErrUnexpectedEOF }

func TestRestoreRejectsInconsistentDatabases(t *testing.T) {
	w := fakechain.NewWorld(2)
	fc := fakechain.New(1)
	for range 5 {
		fc.Mine(nil)
	}
	corrupt := map[string]string{
		"headers without checkpoint": `UPDATE checkpoint SET tip_number = -1, tip_hash = ''`,
		"checkpoint off the headers": `UPDATE checkpoint SET tip_number = 3`,
		"unlinked headers":           `UPDATE blocks SET parent_hash = '0x` + fmt.Sprintf("%064x", 1) + `' WHERE number = 4`,
	}
	for name, stmt := range corrupt {
		t.Run(name, func(t *testing.T) {
			st := openStore(t)
			syncToTip(t, newEngine(t, testConfig(w), fc, st), fc)
			if _, err := st.(*sqlstore.Store).DB().Exec(stmt); err != nil {
				t.Fatal(err)
			}
			if _, err := New(context.Background(), testConfig(w), fc, st, nil, nil); err == nil {
				t.Fatal("corrupt database accepted")
			}
		})
	}
}

func TestReorgBeyondWindowHaltsRun(t *testing.T) {
	w := fakechain.NewWorld(2)
	fc := fakechain.New(1)
	for range 20 {
		fc.Mine(nil)
	}
	cfg := testConfig(w)
	cfg.ReorgWindow = 4
	st := openStore(t)
	e := newEngine(t, cfg, fc, st)
	syncToTip(t, e, fc)
	var blocks int64
	_ = st.View(context.Background(), func(r store.Reader) error { blocks, _ = r.BlockCount(); return nil })
	if blocks != 4 {
		t.Fatalf("%d headers retained, window 4", blocks)
	}
	if err := fc.Reorg(10, make([][]fakechain.LogSpec, 11)); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := e.Run(ctx); !errors.Is(err, reorg.ErrBeyondWindow) {
		t.Fatalf("Run returned %v, want ErrBeyondWindow", err)
	}
	if err := e.SyncUntil(ctx, 100); !errors.Is(err, reorg.ErrBeyondWindow) {
		t.Fatalf("SyncUntil returned %v", err)
	}
}

func TestSecondWriterHaltsOnCheckpointConflict(t *testing.T) {
	w := fakechain.NewWorld(2)
	fc := fakechain.New(1)
	for range 5 {
		fc.Mine(nil)
	}
	st := openStore(t)
	a := newEngine(t, testConfig(w), fc, st)
	b := newEngine(t, testConfig(w), fc, st) // restored from the same, still empty, database
	syncToTip(t, a, fc)
	fc.Mine(nil)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := b.Run(ctx); !errors.Is(err, store.ErrTipConflict) {
		t.Fatalf("second writer: %v, want ErrTipConflict", err)
	}
	if err := b.SyncUntil(ctx, 6); !errors.Is(err, store.ErrTipConflict) {
		t.Fatalf("SyncUntil: %v", err)
	}
	if got := errKind(fmt.Errorf("x: %w", store.ErrTipConflict)); got != "tip_conflict" {
		t.Fatal(got)
	}
}

func TestRunStopsGracefullyAndResumesFromTheCheckpoint(t *testing.T) {
	w := fakechain.NewWorld(3)
	fc := fakechain.New(1)
	rng := newScenario(5).rng
	for range 30 {
		fc.Mine(w.Block(rng, fc.Canonical(0), 4))
	}
	st := openStore(t)
	src := &flaky{Source: fc}
	src.headFailures.Store(20) // more than the per-call retry budget: whole sync iterations fail
	m := metrics.New()
	e, err := New(context.Background(), testConfig(w), src, st, m, nil)
	if err != nil {
		t.Fatal(err)
	}
	var commits atomic.Int64
	e.OnCommit = func() { commits.Add(1) }
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- e.Run(ctx) }()
	deadline := time.Now().Add(30 * time.Second)
	for {
		if tip, _ := readCheckpoint(st); tip != nil && tip.Hash == fc.Head().Hash {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("engine did not reach the head")
		}
		time.Sleep(5 * time.Millisecond)
	}
	// Idle polls clear the last error once the node answers again.
	for e.Status().LastError != "" || e.Status().LastSync.IsZero() {
		if time.Now().After(deadline) {
			t.Fatalf("status %+v", e.Status())
		}
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("graceful stop returned %v", err)
	}
	// Transport failures are counted as "other": the label cannot tell them from database errors.
	if commits.Load() == 0 || testutil.ToFloat64(m.SyncErrors.WithLabelValues("other")) == 0 {
		t.Fatalf("commits %d, sync errors %v", commits.Load(), testutil.ToFloat64(m.SyncErrors.WithLabelValues("other")))
	}
	s := e.Status()
	if s.Tip == nil || s.Tip.Hash != fc.Head().Hash || !s.Synced || s.Lag != 0 || s.SafeHead == nil || *s.SafeHead != 30-3 {
		t.Fatalf("status %+v", s)
	}

	// Resume: the new engine starts at the checkpoint, never re-reading indexed blocks.
	for range 5 {
		fc.Mine(w.Block(rng, fc.Canonical(0), 4))
	}
	src2 := &flaky{Source: fc}
	e2, err := New(context.Background(), testConfig(w), src2, st, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if s := e2.Status(); s.Tip == nil || s.Tip.Number != 30 {
		t.Fatalf("restored status %+v", s)
	}
	if err := e2.SyncUntil(context.Background(), fc.Head().Number); err != nil {
		t.Fatal(err)
	}
	if low := src2.lowestRead(); low != 31 {
		t.Fatalf("resumed engine re-read from block %d, want 31", low)
	}
	fresh := openStore(t)
	syncToTip(t, newEngine(t, testConfig(w), fc, fresh), fc)
	requireSame(t, "resumed vs reindex", snapshot(t, st), snapshot(t, fresh))
}

func TestStopAtCapsIndexing(t *testing.T) {
	w := fakechain.NewWorld(2)
	fc := fakechain.New(1)
	for range 10 {
		fc.Mine(nil)
	}
	cfg := testConfig(w)
	stop := uint64(6)
	cfg.StopAt = &stop
	st := openStore(t)
	e := newEngine(t, cfg, fc, st)
	if err := e.SyncUntil(context.Background(), stop); err != nil {
		t.Fatal(err)
	}
	for range 3 { // further iterations stay at the stop block
		if out, err := e.SyncOnce(context.Background()); err != nil || out != Idle {
			t.Fatalf("at the stop block: %v %v", out, err)
		}
	}
	if s := e.Status(); s.Tip == nil || s.Tip.Number != 6 || !s.Synced || s.ChainHead != 10 || s.Lag != 4 {
		t.Fatalf("status %+v", s)
	}
}

func TestRetentionPrunesOutboxAndHeaders(t *testing.T) {
	w := fakechain.NewWorld(3)
	fc := fakechain.New(1)
	rng := newScenario(11).rng
	for range 40 {
		fc.Mine(w.Block(rng, fc.Canonical(0), 5))
	}
	cfg := testConfig(w)
	cfg.EventRetention = 10
	cfg.ReorgWindow = 6
	st := openStore(t)
	syncToTip(t, newEngine(t, cfg, fc, st), fc)
	err := st.View(context.Background(), func(r store.Reader) error {
		oldest, newest, err := r.EventBounds()
		if err != nil {
			return err
		}
		if newest < 20 || newest-oldest+1 != 10 {
			return fmt.Errorf("outbox keeps %d..%d", oldest, newest)
		}
		n, err := r.BlockCount()
		if err == nil && n != 6 {
			err = fmt.Errorf("%d headers kept, window 6", n)
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	// Restart with pruned headers: the tracker is restored as pruned and keeps working.
	e := newEngine(t, cfg, fc, st)
	if !e.tracker.Pruned() {
		t.Fatal("tracker not marked pruned")
	}
	if err := fc.Reorg(3, make([][]fakechain.LogSpec, 3)); err != nil {
		t.Fatal(err)
	}
	syncToTip(t, e, fc)
}

// TestUndecodableLogsAndAnomalies: logs with a tracked signature but a non-canonical encoding
// are stored raw only, and a token that moves balances without Transfer events (simulated by a
// transfer out of an empty account) produces a counted, stored negative balance rather than a
// silent clamp.
func TestUndecodableLogsAndAnomalies(t *testing.T) {
	w := fakechain.NewWorld(2)
	fc := fakechain.New(1)
	alice, bob := w.Holders[0], w.Holders[1]
	nft := fakechain.LogSpec{Address: w.Tokens[0], Topics: []common.Hash{decode.TopicTransfer, topic(alice), topic(bob), {31: 9}}}
	fc.Mine([]fakechain.LogSpec{nft, xfer(1, w.Tokens[0], alice, bob, 5)})
	st := openStore(t)
	m := metrics.New()
	e, err := New(context.Background(), testConfig(w), fc, st, m, nil)
	if err != nil {
		t.Fatal(err)
	}
	syncToTip(t, e, fc)
	snap := snapshot(t, st)
	if c := snap.Counts(); c["logs"] != 2 || c["transfers"] != 1 {
		t.Fatalf("counts %v", c)
	}
	if testutil.ToFloat64(m.Undecodable) != 1 || testutil.ToFloat64(m.BalanceAnomalies) != 1 {
		t.Fatalf("undecodable %v anomalies %v", testutil.ToFloat64(m.Undecodable), testutil.ToFloat64(m.BalanceAnomalies))
	}
	_ = st.View(context.Background(), func(r store.Reader) error {
		if b, _ := r.Balance(w.Tokens[0], alice); b.Int64() != -5 {
			t.Errorf("alice balance %v", b)
		}
		return nil
	})
}

func TestSafeHeadAndLag(t *testing.T) {
	ref := func(n uint64) *chain.BlockRef { return &chain.BlockRef{Number: n} }
	cases := []struct {
		tip        *chain.BlockRef
		head, conf uint64
		want       int64 // -1: nil
	}{
		{nil, 100, 12, -1},
		{ref(50), 10, 12, -1},
		{ref(50), 100, 12, 50},
		{ref(95), 100, 12, 88},
		{ref(100), 100, 0, 100},
		{ref(90), 100, 0, 90},
	}
	for _, tc := range cases {
		got := SafeHead(tc.tip, tc.head, tc.conf)
		if (got == nil) != (tc.want < 0) || (got != nil && int64(*got) != tc.want) {
			t.Errorf("SafeHead(%v, %d, %d) = %v, want %d", tc.tip, tc.head, tc.conf, got, tc.want)
		}
	}
	// Before the first commit, the lag counts the blocks from the start block.
	w := fakechain.NewWorld(2)
	fc := fakechain.New(1)
	for range 9 {
		fc.Mine(nil)
	}
	src := &flaky{Source: fc}
	src.headFailures.Store(0)
	e := newEngine(t, testConfig(w), src, openStore(t))
	e.updateStatus(func(s *Status) { s.ChainHead = 9 })
	if s := e.Status(); s.Lag != 9 || s.Tip != nil {
		t.Fatalf("status before the first commit %+v", s)
	}
}

func TestErrKind(t *testing.T) {
	cases := map[error]string{
		fmt.Errorf("x: %w", fetch.ErrInconsistent): "inconsistent",
		context.DeadlineExceeded:                   "timeout",
		errors.New("strange"):                      "other",
		fmt.Errorf("y: %w", chain.ErrNotFound):     "not_found",
	}
	for err, want := range cases {
		if got := errKind(err); got != want {
			t.Errorf("errKind(%v) = %q, want %q", err, got, want)
		}
	}
	fe := &forkError{header: chain.Header{Number: 3}}
	if !strings.Contains(fe.Error(), "block 3") {
		t.Fatalf("fork error %q does not name the block", fe.Error())
	}
}

// --- persistent faults, window-deep reorgs, ambiguous commits ----------------------------------

// codedErr is a JSON-RPC error with a code, as go-ethereum's client surfaces it.
type codedErr struct {
	code int
	msg  string
}

func (e codedErr) Error() string  { return e.msg }
func (e codedErr) ErrorCode() int { return e.code }

// misbehaving wraps a source: unwatched makes every non-empty eth_getLogs answer carry a log of
// an unwatched contract (a provider that ignores the address filter), and maxLogs caps the
// logs per answer while eth_getBlockReceipts answers receiptsErr.
type misbehaving struct {
	chain.Source
	unwatched   bool
	maxLogs     int
	receiptsErr error
}

func (m *misbehaving) Logs(ctx context.Context, q chain.LogQuery) ([]types.Log, error) {
	logs, err := m.Source.Logs(ctx, q)
	if err != nil {
		return nil, err
	}
	if m.maxLogs > 0 && len(logs) > m.maxLogs {
		return nil, fmt.Errorf("query returned more than %d results", m.maxLogs)
	}
	if m.unwatched && len(logs) > 0 {
		logs = slices.Clone(logs)
		logs[0].Address = common.Address{0xee}
	}
	return logs, nil
}

func (m *misbehaving) BlockLogs(ctx context.Context, hash common.Hash) ([]types.Log, error) {
	if m.receiptsErr != nil {
		return nil, m.receiptsErr
	}
	return m.Source.BlockLogs(ctx, hash)
}

// TestPersistentFaultsSurfaceAsSyncErrors: a fault that retrying the same range cannot fix must
// show up as a sync error (metric, LastError) with backoff, and end SyncUntil, instead of a
// silent re-fetch loop. Two such faults: a provider that ignores the address filter (every
// answer is inconsistent, so SyncOnce returns Retry each time), and a provider without
// eth_getBlockReceipts (-32601 "Method not found", which used to read as "block orphaned").
func TestPersistentFaultsSurfaceAsSyncErrors(t *testing.T) {
	w := fakechain.NewWorld(2)
	fc := fakechain.New(1)
	for i := range 8 {
		fc.Mine([]fakechain.LogSpec{
			xfer(0, w.Tokens[0], common.Address{}, w.Holders[0], int64(i+1)),
			xfer(1, w.Tokens[0], common.Address{}, w.Holders[1], int64(i+1)),
			xfer(2, w.Tokens[1], common.Address{}, w.Holders[0], int64(i+1)),
		})
	}
	cases := []struct {
		name     string
		src      *misbehaving
		kind     string
		lastErr  string
		sentinel error
	}{
		{"provider ignores the address filter", &misbehaving{Source: fc, unwatched: true}, "inconsistent",
			"stayed inconsistent", fetch.ErrInconsistent},
		{"provider without eth_getBlockReceipts", &misbehaving{Source: fc, maxLogs: 2, receiptsErr: codedErr{-32601, "Method not found"}}, "rpc",
			"Method not found", nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := metrics.New()
			e, err := New(context.Background(), testConfig(w), tc.src, openStore(t), m, nil)
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			done := make(chan error, 1)
			go func() { done <- e.Run(ctx) }()
			deadline := time.Now().Add(30 * time.Second)
			for testutil.ToFloat64(m.SyncErrors.WithLabelValues(tc.kind)) < 2 || !strings.Contains(e.Status().LastError, tc.lastErr) {
				if time.Now().After(deadline) {
					t.Fatalf("no %q sync errors reported: count %v, last error %q", tc.kind,
						testutil.ToFloat64(m.SyncErrors.WithLabelValues(tc.kind)), e.Status().LastError)
				}
				time.Sleep(5 * time.Millisecond)
			}
			cancel()
			if err := <-done; err != nil {
				t.Fatalf("Run returned %v; a persistent fault is retried, not fatal", err)
			}
			if tip := e.Status().Tip; tip != nil {
				t.Fatalf("committed up to %v despite the fault", tip)
			}
			// SyncUntil gives up instead of looping forever.
			err = e.SyncUntil(context.Background(), fc.Head().Number)
			if err == nil || !strings.Contains(err.Error(), tc.lastErr) || (tc.sentinel != nil && !errors.Is(err, tc.sentinel)) {
				t.Fatalf("SyncUntil returned %v", err)
			}
		})
	}
}

// TestReorgExactlyAsDeepAsTheWindow: with --reorg-window W, a reorg W blocks deep replaces
// every retained header; its common ancestor is the parent of the oldest one. It is rolled back
// like any other, the ancestor's header is stored again so a restart restores cleanly, and the
// result equals a reindex.
func TestReorgExactlyAsDeepAsTheWindow(t *testing.T) {
	w := fakechain.NewWorld(3)
	fc := fakechain.New(1)
	rng := newScenario(21).rng
	for range 20 {
		fc.Mine(w.Block(rng, fc.Canonical(0), 3))
	}
	cfg := testConfig(w)
	cfg.ReorgWindow = 4
	st := openStore(t)
	e := newEngine(t, cfg, fc, st)
	syncToTip(t, e, fc)
	cons := newConsumer()
	cons.drain(t, st)

	canon := fc.Canonical(0)
	var blocks [][]fakechain.LogSpec
	for range 5 {
		blocks = append(blocks, w.BlockAfter(rng, canon[:len(canon)-4], blocks, 3))
	}
	if err := fc.Reorg(4, blocks); err != nil { // replaces 17..20, the whole window
		t.Fatal(err)
	}
	if out, err := e.SyncOnce(context.Background()); err != nil || out != RolledBack {
		t.Fatalf("a reorg as deep as the window: outcome %v, err %v", out, err)
	}
	var last *model.Reorg
	if err := st.View(context.Background(), func(r store.Reader) error {
		var err error
		last, _, err = r.LastReorg()
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if last == nil || last.Depth != 4 || last.Ancestor == nil || last.Ancestor.Number != 16 || last.Ancestor.Hash != canon[16].Header.Hash {
		t.Fatalf("recorded reorg %+v, want depth 4 to ancestor 16", last)
	}
	// A restart right after the rollback restores from the re-stored ancestor header.
	e = newEngine(t, cfg, fc, st)
	if tip := e.Status().Tip; tip == nil || tip.Number != 16 {
		t.Fatalf("restored tip %v, want 16", tip)
	}
	syncToTip(t, e, fc)
	fresh := openStore(t)
	syncToTip(t, newEngine(t, cfg, fc, fresh), fc)
	requireSame(t, "after a window-deep reorg vs reindex", snapshot(t, st), snapshot(t, fresh))
	cons.drain(t, st)
	cons.requireMatches(t, st)
	if cons.retracted == 0 {
		t.Fatal("the window-deep reorg retracted nothing")
	}
}

// ambiguousStore reports an error for the next `fail` write transactions that move the
// checkpoint, after committing them: a COMMIT whose acknowledgement was lost.
type ambiguousStore struct {
	store.Store
	fail atomic.Int64
}

type tipSpy struct {
	store.Tx
	moved bool
}

func (t *tipSpy) MoveTip(expected, next *chain.BlockRef, chainHead uint64, now int64) error {
	t.moved = true
	return t.Tx.MoveTip(expected, next, chainHead, now)
}

func (a *ambiguousStore) Update(ctx context.Context, fn func(store.Tx) error) error {
	moved := false
	err := a.Store.Update(ctx, func(tx store.Tx) error {
		spy := &tipSpy{Tx: tx}
		err := fn(spy)
		moved = spy.moved
		return err
	})
	if err == nil && moved && a.fail.Add(-1) >= 0 {
		return errors.New("store: connection lost during COMMIT")
	}
	return err
}

// TestAmbiguousCommitIsNotMistakenForASecondWriter: a commit or a rollback that committed but
// reported an error leaves the engine's tracker behind the database. The next write then
// conflicts on the checkpoint; the engine must recognise its own write, reload from the
// database and continue, not halt with "another writer". The data and the stream stay exact.
func TestAmbiguousCommitIsNotMistakenForASecondWriter(t *testing.T) {
	w := fakechain.NewWorld(3)
	fc := fakechain.New(1)
	rng := newScenario(7).rng
	for range 12 {
		fc.Mine(w.Block(rng, fc.Canonical(0), 4))
	}
	st := &ambiguousStore{Store: openStore(t)}
	m := metrics.New()
	e, err := New(context.Background(), testConfig(w), fc, st, m, nil)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	waitFor := func(what string, cond func() bool) {
		t.Helper()
		deadline := time.Now().Add(30 * time.Second)
		for !cond() {
			select {
			case err := <-done:
				t.Fatalf("Run returned %v while waiting for %s", err, what)
			default:
			}
			if time.Now().After(deadline) {
				t.Fatalf("timed out waiting for %s (status %+v)", what, e.Status())
			}
			time.Sleep(5 * time.Millisecond)
		}
	}
	atHead := func() bool {
		tip, _ := readCheckpoint(st)
		return tip != nil && tip.Hash == fc.Head().Hash && e.Status().Tip != nil && e.Status().Tip.Hash == fc.Head().Hash
	}

	st.fail.Store(1) // the first commit
	go func() { done <- e.Run(ctx) }()
	waitFor("the head after an ambiguous commit", atHead)

	// The same for a rollback: the reorg's retractions must be published exactly once.
	canon := fc.Canonical(0)
	var blocks [][]fakechain.LogSpec
	for range 4 {
		blocks = append(blocks, w.BlockAfter(rng, canon[:len(canon)-3], blocks, 4))
	}
	st.fail.Store(1)
	if err := fc.Reorg(3, blocks); err != nil {
		t.Fatal(err)
	}
	waitFor("the head after an ambiguous rollback", atHead)
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run returned %v", err)
	}
	if st.fail.Load() >= 0 {
		t.Fatal("the ambiguous rollback was never injected")
	}
	if got := testutil.ToFloat64(m.SyncErrors.WithLabelValues("other")); got != 2 {
		t.Fatalf("%v sync errors, want the 2 injected ones", got)
	}
	if n := reorgCount(t, st); n != 1 {
		t.Fatalf("%d reorgs recorded, want 1 (the rollback must not run twice)", n)
	}
	fresh := openStore(t)
	syncToTip(t, newEngine(t, testConfig(w), fc, fresh), fc)
	requireSame(t, "after ambiguous commits vs reindex", snapshot(t, st), snapshot(t, fresh))
	cons := newConsumer()
	cons.drain(t, st)
	cons.requireMatches(t, st)

	// A failed write that did not commit, followed by another writer: the stored tip is not the
	// one this engine tried to write, so it still halts.
	other := newEngine(t, testConfig(w), fc, st)
	e.unconfirmed = &pendingWrite{tip: &chain.BlockRef{Number: 99, Hash: common.Hash{9}}}
	fc.Mine(w.Block(rng, fc.Canonical(0), 4))
	syncToTip(t, other, fc)
	fc.Mine(w.Block(rng, fc.Canonical(0), 4))
	rctx, rcancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer rcancel()
	if err := e.Run(rctx); !errors.Is(err, store.ErrTipConflict) {
		t.Fatalf("Run with a real second writer returned %v, want ErrTipConflict", err)
	}
}

// BenchmarkBackfill measures a cold backfill from the in-memory chain into SQLite: fetch,
// validate, decode, derive and commit, with the reorg tracker and the outbox, on one core of
// work per segment. Reported per block and per log.
func BenchmarkBackfill(b *testing.B) {
	const blocks = 2000
	w := fakechain.NewWorld(20)
	fc := fakechain.New(1)
	rng := newScenario(99).rng
	for range blocks {
		fc.Mine(w.Block(rng, fc.Canonical(0), 6))
	}
	logs := 0
	for _, blk := range fc.Canonical(1) {
		logs += len(blk.Logs)
	}
	cfg := testConfig(w)
	cfg.Confirmations = 12
	cfg.ReorgWindow = 256
	cfg.Fetch = fetch.Config{InitialSpan: 100, MaxSpan: 500, Concurrency: 4}
	b.ResetTimer()
	for range b.N {
		b.StopTimer()
		st := openStore(b)
		e := newEngine(b, cfg, fc, st)
		b.StartTimer()
		if err := e.SyncUntil(context.Background(), blocks); err != nil {
			b.Fatal(err)
		}
	}
	elapsed := b.Elapsed().Seconds()
	b.ReportMetric(float64(blocks*b.N)/elapsed, "blocks/s")
	b.ReportMetric(float64(logs*b.N)/elapsed, "logs/s")
}
