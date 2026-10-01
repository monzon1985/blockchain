// SPDX-License-Identifier: MIT

package indexer

import (
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/decode"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/fakechain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/fetch"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/model"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/reorg"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store/sqlite"
)

func openStore(t testing.TB) store.Store {
	t.Helper()
	st, err := sqlite.Open(context.Background(), filepath.Join(t.TempDir(), "index.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

func testConfig(w *fakechain.World) Config {
	return Config{
		Start:          1,
		Confirmations:  3,
		PollInterval:   time.Millisecond,
		ReorgWindow:    48,
		EventRetention: 1 << 40,
		Contracts:      w.Contracts(),
		Fetch: fetch.Config{
			InitialSpan: 4,
			MaxSpan:     64,
			HashSpan:    4,
			Concurrency: 3,
			Backoff:     time.Millisecond,
			Attempts:    8,
		},
	}
}

func newEngine(t testing.TB, cfg Config, src chain.Source, st store.Store) *Engine {
	t.Helper()
	e, err := New(context.Background(), cfg, src, st, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	return e
}

// syncToHead runs SyncOnce until the engine has caught up with the node: its tip is the head,
// or the head is a block the engine already holds. The second case is a node that is behind the
// indexer, or one that rolled back to an ancestor of the indexed tip without producing a
// conflicting block yet; the engine deliberately waits instead of rolling back (see
// TestHeadBelowTipIsTreatedAsLagging).
func syncToHead(t testing.TB, e *Engine, fc *fakechain.Chain) {
	t.Helper()
	ctx := context.Background()
	for i := 0; i < 500; i++ {
		head := fc.Head()
		tip, ok := e.tracker.Tip()
		switch {
		case ok && tip.Hash == head.Hash:
			return
		case head.Number < e.cfg.Start:
			return
		case ok && head.Number < tip.Number && e.tracker.Check(head) == reorg.Known:
			return
		}
		if _, err := e.SyncOnce(ctx); err != nil {
			t.Fatalf("sync: %v", err)
		}
	}
	t.Fatalf("engine did not reach head %s", fc.Head().Ref())
}

// syncToTip is syncToHead with the stricter requirement that the engine's tip is the head.
func syncToTip(t testing.TB, e *Engine, fc *fakechain.Chain) {
	t.Helper()
	syncToHead(t, e, fc)
	if tip, ok := e.tracker.Tip(); fc.Head().Number >= e.cfg.Start && (!ok || tip.Hash != fc.Head().Hash) {
		t.Fatalf("engine tip %v is not the head %s", tip.Ref(), fc.Head().Ref())
	}
}

func snapshot(t testing.TB, st store.Store) *store.Snapshot {
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

func requireSame(t testing.TB, what string, a, b *store.Snapshot) {
	t.Helper()
	diffs := store.Diff(a, b)
	if len(diffs) == 0 {
		return
	}
	var sb strings.Builder
	for i, d := range diffs {
		if i == 20 {
			fmt.Fprintf(&sb, "... and %d more\n", len(diffs)-20)
			break
		}
		sb.WriteString(d.String() + "\n")
	}
	t.Fatalf("%s: %d differences\n%s", what, len(diffs), sb.String())
}

// oracleSnapshot derives the expected indexed state straight from the canonical chain with the
// simplest possible logic (sums over all canonical transfers), independently of the engine's
// incremental apply/revert code, and renders it through a fresh store so snapshots compare.
func oracleSnapshot(t testing.TB, fc *fakechain.Chain, c decode.Contracts, start uint64) *store.Snapshot {
	t.Helper()
	st := openStore(t)
	watched := map[common.Address]bool{}
	for _, a := range c.Addresses() {
		watched[a] = true
	}
	type key struct{ token, holder common.Address }
	bal := map[key]*big.Int{}
	sup := map[common.Address]*big.Int{}
	add := func(m map[key]*big.Int, k key, v *big.Int) {
		if m[k] == nil {
			m[k] = new(big.Int)
		}
		m[k].Add(m[k], v)
	}
	blocks := fc.Canonical(start)
	err := st.Update(context.Background(), func(tx store.Tx) error {
		if len(blocks) > 0 {
			tip := blocks[len(blocks)-1].Header.Ref()
			if err := tx.MoveTip(nil, &tip, 0, 0); err != nil {
				return err
			}
		}
		zero := common.Address{}
		for _, b := range blocks {
			touched := map[common.Address]bool{}
			for i := range b.Logs {
				l := &b.Logs[i]
				if !watched[l.Address] {
					continue
				}
				if _, err := tx.InsertLog(model.Log{Block: chain.BlockRef{Number: l.BlockNumber, Hash: l.BlockHash}, LogIndex: uint64(l.Index),
					TxHash: l.TxHash, TxIndex: uint64(l.TxIndex), Address: l.Address, Topics: l.Topics, Data: l.Data}); err != nil {
					return err
				}
				if tr, err := decode.DecodeTransfer(l); err == nil {
					tr.BlockTime = b.Header.Time
					if _, err := tx.InsertTransfer(*tr); err != nil {
						return err
					}
					v := tr.Value.Big()
					if tr.From != zero {
						add(bal, key{tr.Token, tr.From}, new(big.Int).Neg(v))
					} else {
						if sup[tr.Token] == nil {
							sup[tr.Token] = new(big.Int)
						}
						sup[tr.Token].Add(sup[tr.Token], v)
					}
					if tr.To != zero {
						add(bal, key{tr.Token, tr.To}, v)
					} else {
						if sup[tr.Token] == nil {
							sup[tr.Token] = new(big.Int)
						}
						sup[tr.Token].Sub(sup[tr.Token], v)
					}
					for vault, asset := range c.Vaults {
						if tr.Token == asset && (tr.From == vault || tr.To == vault) {
							touched[vault] = true
						}
						if tr.Token == vault && (tr.From == zero || tr.To == zero) {
							touched[vault] = true
						}
					}
				}
				if _, isVault := c.Vaults[l.Address]; isVault {
					if ve, err := decode.DecodeVaultEvent(l); err == nil {
						ve.BlockTime = b.Header.Time
						if _, err := tx.InsertVaultEvent(*ve); err != nil {
							return err
						}
					}
				}
			}
			for vault := range touched {
				assets := new(big.Int)
				if v := bal[key{c.Vaults[vault], vault}]; v != nil {
					assets.Set(v)
				}
				supply := new(big.Int)
				if v := sup[vault]; v != nil {
					supply.Set(v)
				}
				if err := tx.InsertSharePrice(model.SharePrice{Block: b.Header.Ref(), BlockTime: b.Header.Time, Vault: vault,
					TotalAssets: model.NewAmount(assets), TotalSupply: model.NewAmount(supply), PriceWad: model.ComputePriceWad(assets, supply)}); err != nil {
					return err
				}
			}
		}
		for k, v := range bal {
			if err := tx.SetBalance(k.token, k.holder, v); err != nil {
				return err
			}
		}
		for token, v := range sup {
			if err := tx.SetSupply(token, v); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return snapshot(t, st)
}

// consumer is an SSE-style client: it applies `transfer` events and undoes them on `retract`,
// exactly as an API consumer would.
type consumer struct {
	last      uint64
	transfers map[string]model.Transfer
	retracted int // transfer retractions applied
}

func newConsumer() *consumer { return &consumer{transfers: map[string]model.Transfer{}} }

func transferKey(t model.Transfer) string {
	return fmt.Sprintf("%s/%d", t.Block.Hash.Hex(), t.LogIndex)
}

func (c *consumer) apply(t testing.TB, events []model.Event) {
	t.Helper()
	for _, ev := range events {
		if ev.Seq != c.last+1 {
			t.Fatalf("outbox gap: got seq %d after %d", ev.Seq, c.last)
		}
		c.last = ev.Seq
		switch ev.Kind {
		case model.EventTransfer:
			var tr model.Transfer
			if err := json.Unmarshal(ev.Payload, &tr); err != nil {
				t.Fatal(err)
			}
			k := transferKey(tr)
			if _, dup := c.transfers[k]; dup {
				t.Fatalf("transfer %s published twice", k)
			}
			c.transfers[k] = tr
		case model.EventRetract:
			var r struct {
				Type string          `json:"type"`
				Item json.RawMessage `json:"item"`
			}
			if err := json.Unmarshal(ev.Payload, &r); err != nil {
				t.Fatal(err)
			}
			if r.Type != model.EventTransfer {
				continue
			}
			var tr model.Transfer
			if err := json.Unmarshal(r.Item, &tr); err != nil {
				t.Fatal(err)
			}
			k := transferKey(tr)
			if _, ok := c.transfers[k]; !ok {
				t.Fatalf("retraction of unknown transfer %s", k)
			}
			delete(c.transfers, k)
			c.retracted++
		}
	}
}

func (c *consumer) drain(t testing.TB, st store.Store) {
	t.Helper()
	for {
		var evs []model.Event
		if err := st.View(context.Background(), func(r store.Reader) error {
			var err error
			evs, err = r.EventsAfter(c.last, 1000)
			return err
		}); err != nil {
			t.Fatal(err)
		}
		if len(evs) == 0 {
			return
		}
		c.apply(t, evs)
	}
}

// requireConsumerMatches checks that the consumer's view equals the stored transfers.
func (c *consumer) requireMatches(t testing.TB, st store.Store) {
	t.Helper()
	var all []model.Transfer
	if err := st.View(context.Background(), func(r store.Reader) error {
		var err error
		all, err = r.TransfersFrom(0)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if len(all) != len(c.transfers) {
		t.Fatalf("consumer holds %d transfers, store holds %d", len(c.transfers), len(all))
	}
	for _, tr := range all {
		got, ok := c.transfers[transferKey(tr)]
		if !ok {
			t.Fatalf("consumer is missing transfer %s", transferKey(tr))
		}
		a, _ := json.Marshal(got)
		b, _ := json.Marshal(tr)
		if string(a) != string(b) {
			t.Fatalf("consumer transfer differs:\n%s\n%s", a, b)
		}
	}
}

// tally sums per-seed counters across parallel subtests and logs one "TOTAL" line when they
// have all finished (t.Cleanup of the parent runs after its parallel subtests). CI keeps these
// lines in its artifacts; they are where the README's totals come from.
type tally struct {
	mu   sync.Mutex
	sums map[string]int64
}

func newTally(t *testing.T, name string) *tally {
	tl := &tally{sums: map[string]int64{}}
	t.Cleanup(func() { t.Logf("TOTAL %s: %s", name, tl) })
	return tl
}

func (tl *tally) add(key string, v int64) {
	tl.mu.Lock()
	defer tl.mu.Unlock()
	tl.sums[key] += v
}

func (tl *tally) addAll(prefix string, m map[string]int64) {
	for k, v := range m {
		tl.add(prefix+k, v)
	}
}

func (tl *tally) String() string {
	tl.mu.Lock()
	defer tl.mu.Unlock()
	keys := make([]string, 0, len(tl.sums))
	for k := range tl.sums {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = fmt.Sprintf("%s=%d", k, tl.sums[k])
	}
	return strings.Join(parts, " ")
}

func readCheckpoint(st store.Store) (*chain.BlockRef, error) {
	var tip *chain.BlockRef
	err := st.View(context.Background(), func(r store.Reader) error {
		cp, err := r.Checkpoint()
		tip = cp.Tip
		return err
	})
	return tip, err
}
