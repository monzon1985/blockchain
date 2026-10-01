// SPDX-License-Identifier: MIT

// Package storetest is the conformance suite every store backend must pass. The SQLite tests
// run it locally; the PostgreSQL tests (build tag `postgres`) run the same suite in CI against
// a service container, which is what makes the backends interchangeable.
package storetest

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"slices"
	"testing"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/model"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store"
)

// Opener returns a fresh, empty store for one subtest; the backend's test registers cleanup.
type Opener func(t *testing.T) store.Store

// Run executes the suite.
func Run(t *testing.T, open Opener) {
	tests := []struct {
		name string
		fn   func(t *testing.T, s store.Store)
	}{
		{"Meta", testMeta},
		{"CheckpointCAS", testCheckpointCAS},
		{"Blocks", testBlocks},
		{"IdempotentInserts", testIdempotentInserts},
		{"TransferQueries", testTransferQueries},
		{"VaultQueries", testVaultQueries},
		{"Balances", testBalances},
		{"Outbox", testOutbox},
		{"DeleteFrom", testDeleteFrom},
		{"Reorgs", testReorgs},
		{"Atomicity", testAtomicity},
		{"Snapshot", testSnapshot},
		{"LargeValues", testLargeValues},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) { tc.fn(t, open(t)) })
	}
}

var ctx = context.Background()

func update(t *testing.T, s store.Store, fn func(tx store.Tx) error) {
	t.Helper()
	if err := s.Update(ctx, fn); err != nil {
		t.Fatal(err)
	}
}

func view(t *testing.T, s store.Store, fn func(r store.Reader) error) {
	t.Helper()
	if err := s.View(ctx, fn); err != nil {
		t.Fatal(err)
	}
}

func addr(b byte) common.Address { return common.Address{19: b} }

func hash(n uint64, fork byte) common.Hash {
	var h common.Hash
	h[0] = fork
	h[31] = byte(n)
	h[30] = byte(n >> 8)
	return h
}

func header(n uint64, fork byte) chain.Header {
	parent := common.Hash{}
	if n > 0 {
		parent = hash(n-1, fork)
	}
	return chain.Header{Number: n, Hash: hash(n, fork), ParentHash: parent, Time: 1000 + n}
}

func transfer(n uint64, idx uint64, token, from, to common.Address, v int64) model.Transfer {
	return model.Transfer{Block: chain.BlockRef{Number: n, Hash: hash(n, 0)}, BlockTime: 1000 + n, LogIndex: idx,
		TxHash: common.Hash{0xaa, byte(n), byte(idx)}, Token: token, From: from, To: to, Value: model.NewAmount(big.NewInt(v))}
}

func testMeta(t *testing.T, s store.Store) {
	view(t, s, func(r store.Reader) error {
		if _, ok, err := r.Meta("config"); err != nil || ok {
			return fmt.Errorf("fresh store has meta: ok=%v err=%v", ok, err)
		}
		return nil
	})
	update(t, s, func(tx store.Tx) error { return tx.PutMeta("config", "a") })
	update(t, s, func(tx store.Tx) error { return tx.PutMeta("config", "b") })
	view(t, s, func(r store.Reader) error {
		if v, ok, err := r.Meta("config"); err != nil || !ok || v != "b" {
			return fmt.Errorf("meta = %q %v %v", v, ok, err)
		}
		return nil
	})
	if s.Backend() == "" {
		t.Fatal("empty backend name")
	}
	if err := s.Ping(ctx); err != nil {
		t.Fatal(err)
	}
}

func testCheckpointCAS(t *testing.T, s store.Store) {
	view(t, s, func(r store.Reader) error {
		cp, err := r.Checkpoint()
		if err != nil || cp.Tip != nil || cp.ChainHead != 0 {
			return fmt.Errorf("fresh checkpoint %+v %v", cp, err)
		}
		return nil
	})
	a := chain.BlockRef{Number: 5, Hash: hash(5, 0)}
	b := chain.BlockRef{Number: 6, Hash: hash(6, 0)}
	update(t, s, func(tx store.Tx) error { return tx.MoveTip(nil, &a, 10, 111) })
	// A writer that believes the tip is still empty must fail and roll back everything.
	err := s.Update(ctx, func(tx store.Tx) error {
		if err := tx.PutMeta("x", "must not persist"); err != nil {
			return err
		}
		return tx.MoveTip(nil, &b, 10, 112)
	})
	if !errors.Is(err, store.ErrTipConflict) {
		t.Fatalf("stale CAS: %v", err)
	}
	err = s.Update(ctx, func(tx store.Tx) error { return tx.MoveTip(&b, &a, 10, 112) })
	if !errors.Is(err, store.ErrTipConflict) {
		t.Fatalf("wrong expected tip: %v", err)
	}
	update(t, s, func(tx store.Tx) error { return tx.MoveTip(&a, &b, 12, 113) })
	update(t, s, func(tx store.Tx) error { return tx.Heartbeat(20, 999) })
	view(t, s, func(r store.Reader) error {
		cp, err := r.Checkpoint()
		if err != nil {
			return err
		}
		if cp.Tip == nil || *cp.Tip != b || cp.ChainHead != 20 || cp.UpdatedAt != 999 {
			return fmt.Errorf("checkpoint %+v", cp)
		}
		if _, ok, _ := r.Meta("x"); ok {
			return errors.New("rolled-back write persisted")
		}
		return nil
	})
	// Moving back to "nothing indexed" (a rollback past the start block).
	update(t, s, func(tx store.Tx) error { return tx.MoveTip(&b, nil, 20, 1000) })
	view(t, s, func(r store.Reader) error {
		if cp, _ := r.Checkpoint(); cp.Tip != nil {
			return fmt.Errorf("tip not cleared: %+v", cp.Tip)
		}
		return nil
	})
}

func testBlocks(t *testing.T, s store.Store) {
	update(t, s, func(tx store.Tx) error {
		for n := range uint64(10) {
			if err := tx.InsertBlock(header(n, 0)); err != nil {
				return err
			}
		}
		return nil
	})
	// Duplicate numbers are a programming error and must fail.
	if err := s.Update(ctx, func(tx store.Tx) error { return tx.InsertBlock(header(3, 1)) }); err == nil {
		t.Fatal("duplicate block number accepted")
	}
	update(t, s, func(tx store.Tx) error { return tx.PruneBlocksBelow(4) })
	view(t, s, func(r store.Reader) error {
		recent, err := r.RecentBlocks(3)
		if err != nil {
			return err
		}
		if len(recent) != 3 || recent[0].Number != 7 || recent[2].Number != 9 || recent[2] != (chain.Header{Number: 9, Hash: hash(9, 0), ParentHash: hash(8, 0), Time: 1009}) {
			return fmt.Errorf("recent = %+v", recent)
		}
		n, err := r.BlockCount()
		if err != nil || n != 6 {
			return fmt.Errorf("count %d %v", n, err)
		}
		return nil
	})
}

func testIdempotentInserts(t *testing.T, s store.Store) {
	l := model.Log{Block: chain.BlockRef{Number: 1, Hash: hash(1, 0)}, LogIndex: 0, TxHash: common.Hash{1}, Address: addr(1),
		Topics: []common.Hash{{1}, {2}}, Data: []byte{1, 2, 3}}
	tr := transfer(1, 0, addr(1), addr(2), addr(3), 5)
	ve := model.VaultEvent{Block: tr.Block, LogIndex: 1, Vault: addr(9), Kind: model.VaultDeposit, Sender: addr(2), Owner: addr(2),
		Assets: model.NewAmount(big.NewInt(1)), Shares: model.NewAmount(big.NewInt(2))}
	for i, want := range []bool{true, false} {
		update(t, s, func(tx store.Tx) error {
			for name, fn := range map[string]func() (bool, error){
				"log":         func() (bool, error) { return tx.InsertLog(l) },
				"transfer":    func() (bool, error) { return tx.InsertTransfer(tr) },
				"vault event": func() (bool, error) { return tx.InsertVaultEvent(ve) },
			} {
				got, err := fn()
				if err != nil {
					return err
				}
				if got != want {
					return fmt.Errorf("insert %s #%d reported created=%v", name, i, got)
				}
			}
			return nil
		})
	}
	// The same log index in another block (another fork) is a different row.
	other := tr
	other.Block.Hash = hash(1, 7)
	update(t, s, func(tx store.Tx) error {
		created, err := tx.InsertTransfer(other)
		if err != nil || !created {
			return fmt.Errorf("fork twin not inserted: %v %v", created, err)
		}
		return nil
	})
}

func testTransferQueries(t *testing.T, s store.Store) {
	tokA, tokB := addr(0xa), addr(0xb)
	alice, bob, carol := addr(1), addr(2), addr(3)
	var all []model.Transfer
	for n := uint64(1); n <= 6; n++ {
		all = append(all,
			transfer(n, 0, tokA, alice, bob, int64(n)),
			transfer(n, 1, tokB, bob, carol, int64(10*n)),
			transfer(n, 5, tokA, carol, alice, int64(100*n)))
	}
	update(t, s, func(tx store.Tx) error {
		for _, tr := range all {
			if _, err := tx.InsertTransfer(tr); err != nil {
				return err
			}
		}
		return nil
	})
	p := func(v uint64) *uint64 { return &v }
	a := func(v common.Address) *common.Address { return &v }
	cases := []struct {
		name string
		f    store.TransferFilter
		want func(model.Transfer) bool
	}{
		{"all", store.TransferFilter{}, func(model.Transfer) bool { return true }},
		{"token", store.TransferFilter{Token: a(tokA)}, func(t model.Transfer) bool { return t.Token == tokA }},
		{"address from or to", store.TransferFilter{Address: a(bob)}, func(t model.Transfer) bool { return t.From == bob || t.To == bob }},
		{"from", store.TransferFilter{From: a(carol)}, func(t model.Transfer) bool { return t.From == carol }},
		{"to", store.TransferFilter{To: a(carol)}, func(t model.Transfer) bool { return t.To == carol }},
		{"block range", store.TransferFilter{FromBlock: p(2), ToBlock: p(4)}, func(t model.Transfer) bool { return t.Block.Number >= 2 && t.Block.Number <= 4 }},
		{"combined", store.TransferFilter{Token: a(tokA), Address: a(alice), FromBlock: p(3)}, func(t model.Transfer) bool {
			return t.Token == tokA && (t.From == alice || t.To == alice) && t.Block.Number >= 3
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var want []model.Transfer
			for _, tr := range all {
				if tc.want(tr) {
					want = append(want, tr)
				}
			}
			// Page through with every page size: the concatenation must be exactly `want`.
			for size := 1; size <= len(want)+1; size++ {
				f := tc.f
				var got []model.Transfer
				for {
					f.Limit = size
					var page []model.Transfer
					view(t, s, func(r store.Reader) error {
						var err error
						page, err = r.Transfers(f)
						return err
					})
					got = append(got, page...)
					if len(page) < size {
						break
					}
					last := page[len(page)-1]
					f.After = &store.Position{Block: last.Block.Number, LogIndex: last.LogIndex}
				}
				if err := sameTransfers(got, want); err != nil {
					t.Fatalf("page size %d: %v", size, err)
				}
			}
		})
	}
	view(t, s, func(r store.Reader) error {
		from, err := r.TransfersFrom(5)
		if err != nil {
			return err
		}
		if len(from) != 6 || from[0].Block.Number != 5 {
			return fmt.Errorf("TransfersFrom(5) = %d rows", len(from))
		}
		return nil
	})
}

func sameTransfers(got, want []model.Transfer) error {
	if len(got) != len(want) {
		return fmt.Errorf("got %d transfers, want %d", len(got), len(want))
	}
	for i := range got {
		g, w := got[i], want[i]
		if g.Block != w.Block || g.LogIndex != w.LogIndex || g.Token != w.Token || g.From != w.From || g.To != w.To ||
			g.Value.String() != w.Value.String() || g.TxHash != w.TxHash || g.BlockTime != w.BlockTime {
			return fmt.Errorf("row %d: got %+v, want %+v", i, g, w)
		}
	}
	return nil
}

func testVaultQueries(t *testing.T, s store.Store) {
	v1, v2 := addr(0x71), addr(0x72)
	update(t, s, func(tx store.Tx) error {
		for n := uint64(1); n <= 4; n++ {
			for _, v := range []common.Address{v1, v2} {
				ev := model.VaultEvent{Block: chain.BlockRef{Number: n, Hash: hash(n, 0)}, BlockTime: 1000 + n, LogIndex: uint64(v[19]),
					Vault: v, Kind: model.VaultWithdraw, Sender: addr(1), Owner: addr(1), Receiver: addr(2),
					Assets: model.NewAmount(big.NewInt(int64(n))), Shares: model.NewAmount(big.NewInt(int64(n * 1000)))}
				if _, err := tx.InsertVaultEvent(ev); err != nil {
					return err
				}
				p := model.SharePrice{Block: ev.Block, BlockTime: ev.BlockTime, Vault: v, TotalAssets: model.NewAmount(big.NewInt(int64(n))),
					TotalSupply: model.NewAmount(big.NewInt(int64(n * 10))), PriceWad: model.ComputePriceWad(big.NewInt(int64(n)), big.NewInt(int64(n*10)))}
				if n == 4 {
					p.TotalSupply, p.PriceWad = model.NewAmount(new(big.Int)), nil
				}
				if err := tx.InsertSharePrice(p); err != nil {
					return err
				}
			}
		}
		// Upsert: the same (block, vault) point is replaced, not duplicated.
		return tx.InsertSharePrice(model.SharePrice{Block: chain.BlockRef{Number: 1, Hash: hash(1, 0)}, BlockTime: 1001, Vault: v1,
			TotalAssets: model.NewAmount(big.NewInt(7)), TotalSupply: model.NewAmount(big.NewInt(7)), PriceWad: model.ComputePriceWad(big.NewInt(7), big.NewInt(7))})
	})
	view(t, s, func(r store.Reader) error {
		two := uint64(2)
		evs, err := r.VaultEvents(store.VaultEventFilter{Vault: v1, FromBlock: &two, Limit: 10})
		if err != nil {
			return err
		}
		if len(evs) != 3 || evs[0].Block.Number != 2 || evs[0].Receiver != addr(2) || evs[0].Shares.String() != "2000" {
			return fmt.Errorf("vault events %+v", evs)
		}
		evs, err = r.VaultEvents(store.VaultEventFilter{Vault: v1, After: &store.Position{Block: 3, LogIndex: 999}, Limit: 10})
		if err != nil || len(evs) != 1 || evs[0].Block.Number != 4 {
			return fmt.Errorf("after position: %+v %v", evs, err)
		}
		pts, err := r.SharePrices(store.SharePriceFilter{Vault: v1, Limit: 10})
		if err != nil {
			return err
		}
		if len(pts) != 4 || pts[0].TotalAssets.String() != "7" || pts[0].PriceWad.String() != "1000000000000000000" {
			return fmt.Errorf("share prices %+v", pts)
		}
		if pts[3].PriceWad != nil || pts[3].TotalSupply.String() != "0" {
			return fmt.Errorf("zero-supply point must have a null price: %+v", pts[3])
		}
		after := uint64(2)
		three := uint64(3)
		pts, err = r.SharePrices(store.SharePriceFilter{Vault: v2, After: &after, ToBlock: &three, Limit: 10})
		if err != nil || len(pts) != 1 || pts[0].Block.Number != 3 {
			return fmt.Errorf("filtered share prices %+v %v", pts, err)
		}
		from, err := r.VaultEventsFrom(4)
		if err != nil || len(from) != 2 {
			return fmt.Errorf("VaultEventsFrom %d %v", len(from), err)
		}
		pfrom, err := r.SharePricesFrom(4)
		if err != nil || len(pfrom) != 2 {
			return fmt.Errorf("SharePricesFrom %d %v", len(pfrom), err)
		}
		return nil
	})
}

func testBalances(t *testing.T, s store.Store) {
	tok := addr(0xa)
	holders := []common.Address{addr(5), addr(1), addr(3), addr(2), addr(4)}
	update(t, s, func(tx store.Tx) error {
		for i, h := range holders {
			if err := tx.SetBalance(tok, h, big.NewInt(int64(i+1))); err != nil {
				return err
			}
		}
		if err := tx.SetBalance(tok, addr(3), big.NewInt(0)); err != nil { // zero deletes
			return err
		}
		if err := tx.SetBalance(addr(0xb), addr(1), big.NewInt(-4)); err != nil { // anomalies are stored as is
			return err
		}
		if err := tx.SetSupply(tok, big.NewInt(15)); err != nil {
			return err
		}
		return tx.SetSupply(addr(0xb), big.NewInt(0))
	})
	view(t, s, func(r store.Reader) error {
		rows, err := r.Balances(store.BalanceFilter{Token: tok, Limit: 10})
		if err != nil {
			return err
		}
		var got []common.Address
		for _, b := range rows {
			got = append(got, b.Holder)
		}
		if want := []common.Address{addr(1), addr(2), addr(4), addr(5)}; !slices.Equal(got, want) {
			return fmt.Errorf("holders %v, want %v (ordered, zero removed)", got, want)
		}
		after := addr(2)
		rows, err = r.Balances(store.BalanceFilter{Token: tok, After: &after, Limit: 1})
		if err != nil || len(rows) != 1 || rows[0].Holder != addr(4) || rows[0].Balance.String() != "5" {
			return fmt.Errorf("page after %v: %+v %v", after, rows, err)
		}
		rows, err = r.Balances(store.BalanceFilter{Token: tok, Holders: []common.Address{addr(5), addr(3), addr(9)}, Limit: 10})
		if err != nil || len(rows) != 1 || rows[0].Holder != addr(5) {
			return fmt.Errorf("holder filter: %+v %v", rows, err)
		}
		bal, err := r.Balance(tok, addr(3))
		if err != nil || bal.Sign() != 0 {
			return fmt.Errorf("deleted balance reads %v %v", bal, err)
		}
		bal, err = r.Balance(addr(0xb), addr(1))
		if err != nil || bal.Int64() != -4 {
			return fmt.Errorf("negative balance reads %v %v", bal, err)
		}
		hb, err := r.HolderBalances(addr(1))
		if err != nil || len(hb) != 2 || hb[0].Token != tok {
			return fmt.Errorf("holder balances %+v %v", hb, err)
		}
		sup, err := r.Supply(tok)
		if err != nil || sup.Int64() != 15 {
			return fmt.Errorf("supply %v %v", sup, err)
		}
		sup, err = r.Supply(addr(0xb))
		if err != nil || sup.Sign() != 0 {
			return fmt.Errorf("zero supply %v %v", sup, err)
		}
		return nil
	})
}

func testOutbox(t *testing.T, s store.Store) {
	view(t, s, func(r store.Reader) error {
		oldest, newest, err := r.EventBounds()
		if err != nil || newest != 0 || oldest != 1 {
			return fmt.Errorf("fresh outbox bounds %d..%d %v", oldest, newest, err)
		}
		return nil
	})
	update(t, s, func(tx store.Tx) error {
		for i := range 5 {
			seq, err := tx.AppendEvent("transfer", uint64(i), []byte(fmt.Sprintf(`{"i":%d}`, i)))
			if err != nil {
				return err
			}
			if seq != uint64(i+1) {
				return fmt.Errorf("seq %d, want %d", seq, i+1)
			}
		}
		return nil
	})
	// A rolled-back transaction must not consume sequence numbers.
	_ = s.Update(ctx, func(tx store.Tx) error {
		if _, err := tx.AppendEvent("transfer", 9, []byte(`{}`)); err != nil {
			return err
		}
		return errors.New("abort")
	})
	update(t, s, func(tx store.Tx) error {
		seq, err := tx.AppendEvent("reorg", 9, []byte(`{"r":1}`))
		if err != nil || seq != 6 {
			return fmt.Errorf("seq after abort %d %v", seq, err)
		}
		return tx.PruneEventsBelow(3)
	})
	view(t, s, func(r store.Reader) error {
		oldest, newest, err := r.EventBounds()
		if err != nil || oldest != 3 || newest != 6 {
			return fmt.Errorf("bounds %d..%d %v", oldest, newest, err)
		}
		evs, err := r.EventsAfter(3, 2)
		if err != nil || len(evs) != 2 || evs[0].Seq != 4 || string(evs[0].Payload) != `{"i":3}` || evs[1].Kind != "transfer" {
			return fmt.Errorf("events after 3: %+v %v", evs, err)
		}
		return nil
	})
	update(t, s, func(tx store.Tx) error { return tx.PruneEventsBelow(100) })
	view(t, s, func(r store.Reader) error {
		oldest, newest, err := r.EventBounds()
		if err != nil || oldest != 7 || newest != 6 {
			return fmt.Errorf("fully pruned bounds %d..%d %v", oldest, newest, err)
		}
		return nil
	})
}

func testDeleteFrom(t *testing.T, s store.Store) {
	update(t, s, func(tx store.Tx) error {
		for n := uint64(1); n <= 5; n++ {
			if err := tx.InsertBlock(header(n, 0)); err != nil {
				return err
			}
			if _, err := tx.InsertLog(model.Log{Block: chain.BlockRef{Number: n, Hash: hash(n, 0)}, Address: addr(1), Topics: []common.Hash{}, Data: []byte{}}); err != nil {
				return err
			}
			if _, err := tx.InsertTransfer(transfer(n, 0, addr(1), addr(2), addr(3), 1)); err != nil {
				return err
			}
			if _, err := tx.InsertVaultEvent(model.VaultEvent{Block: chain.BlockRef{Number: n, Hash: hash(n, 0)}, LogIndex: 1, Vault: addr(9),
				Kind: model.VaultDeposit, Assets: model.NewAmount(big.NewInt(1)), Shares: model.NewAmount(big.NewInt(1))}); err != nil {
				return err
			}
			if err := tx.InsertSharePrice(model.SharePrice{Block: chain.BlockRef{Number: n, Hash: hash(n, 0)}, Vault: addr(9),
				TotalAssets: model.NewAmount(big.NewInt(1)), TotalSupply: model.NewAmount(big.NewInt(1))}); err != nil {
				return err
			}
		}
		return nil
	})
	update(t, s, func(tx store.Tx) error {
		d, err := tx.DeleteFrom(4)
		if err != nil {
			return err
		}
		if d != (store.Deleted{Blocks: 2, Logs: 2, Transfers: 2, VaultEvents: 2, SharePrices: 2}) {
			return fmt.Errorf("deleted %+v", d)
		}
		return nil
	})
	view(t, s, func(r store.Reader) error {
		snap, err := r.Snapshot()
		if err != nil {
			return err
		}
		for table, want := range map[string]int{"logs": 3, "transfers": 3, "vault_events": 3, "share_prices": 3} {
			if got := len(snap.Tables[table]); got != want {
				return fmt.Errorf("%s has %d rows, want %d", table, got, want)
			}
		}
		return nil
	})
}

func testReorgs(t *testing.T, s store.Store) {
	view(t, s, func(r store.Reader) error {
		if _, ok, err := r.LastReorg(); ok || err != nil {
			return fmt.Errorf("fresh store has a reorg: %v %v", ok, err)
		}
		return nil
	})
	anc := chain.BlockRef{Number: 3, Hash: hash(3, 0)}
	update(t, s, func(tx store.Tx) error {
		if err := tx.InsertReorg(model.Reorg{DetectedAt: 1, OldTip: chain.BlockRef{Number: 5, Hash: hash(5, 0)}, Ancestor: &anc,
			NewHead: chain.BlockRef{Number: 6, Hash: hash(6, 1)}, Depth: 2}); err != nil {
			return err
		}
		return tx.InsertReorg(model.Reorg{DetectedAt: 2, OldTip: chain.BlockRef{Number: 1, Hash: hash(1, 1)}, NewHead: chain.BlockRef{Number: 1, Hash: hash(1, 2)}, Depth: 1})
	})
	view(t, s, func(r store.Reader) error {
		n, err := r.ReorgCount()
		if err != nil || n != 2 {
			return fmt.Errorf("count %d %v", n, err)
		}
		last, ok, err := r.LastReorg()
		if err != nil || !ok || last.DetectedAt != 2 || last.Ancestor != nil || last.NewHead.Hash != hash(1, 2) {
			return fmt.Errorf("last reorg %+v %v %v", last, ok, err)
		}
		return nil
	})
}

func testAtomicity(t *testing.T, s store.Store) {
	boom := errors.New("boom")
	err := s.Update(ctx, func(tx store.Tx) error {
		if err := tx.InsertBlock(header(1, 0)); err != nil {
			return err
		}
		if _, err := tx.InsertTransfer(transfer(1, 0, addr(1), addr(2), addr(3), 9)); err != nil {
			return err
		}
		if err := tx.SetBalance(addr(1), addr(3), big.NewInt(9)); err != nil {
			return err
		}
		return boom
	})
	if !errors.Is(err, boom) {
		t.Fatalf("Update returned %v", err)
	}
	view(t, s, func(r store.Reader) error {
		snap, err := r.Snapshot()
		if err != nil {
			return err
		}
		if snap.Rows() != 0 {
			return fmt.Errorf("a failed transaction left %d rows", snap.Rows())
		}
		n, _ := r.BlockCount()
		if n != 0 {
			return fmt.Errorf("a failed transaction left %d blocks", n)
		}
		return nil
	})
	// A read transaction keeps its snapshot while a writer commits.
	err = s.View(ctx, func(r store.Reader) error {
		before, err := r.BlockCount()
		if err != nil {
			return err
		}
		update(t, s, func(tx store.Tx) error { return tx.InsertBlock(header(1, 0)) })
		after, err := r.BlockCount()
		if err != nil {
			return err
		}
		if before != after {
			return fmt.Errorf("read transaction saw a concurrent commit (%d -> %d)", before, after)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func testSnapshot(t *testing.T, s store.Store) {
	fill := func(tx store.Tx, v int64) error {
		tip := chain.BlockRef{Number: 2, Hash: hash(2, 0)}
		if err := tx.MoveTip(nil, &tip, 2, 0); err != nil {
			return err
		}
		if _, err := tx.InsertTransfer(transfer(2, 0, addr(1), addr(2), addr(3), v)); err != nil {
			return err
		}
		return tx.SetBalance(addr(1), addr(3), big.NewInt(v))
	}
	update(t, s, func(tx store.Tx) error { return fill(tx, 5) })
	var a *store.Snapshot
	view(t, s, func(r store.Reader) error {
		var err error
		a, err = r.Snapshot()
		return err
	})
	if a.Tip == nil || a.Counts()["transfers"] != 1 || a.Counts()["balances"] != 1 {
		t.Fatalf("snapshot %+v", a.Counts())
	}
	if d := store.Diff(a, a); d != nil {
		t.Fatalf("self diff: %v", d)
	}
	// Mutate a copy: one changed value, one extra row, one missing row, a different tip.
	b := &store.Snapshot{Tip: &chain.BlockRef{Number: 3}, Tables: map[string][]store.Row{}}
	for k, v := range a.Tables {
		b.Tables[k] = slices.Clone(v)
	}
	b.Tables["balances"][0].Value += "0"
	b.Tables["supplies"] = append(b.Tables["supplies"], store.Row{Key: "zz", Value: "1"})
	b.Tables["transfers"] = nil
	diffs := store.Diff(a, b)
	if len(diffs) != 4 {
		t.Fatalf("want 4 differences, got %v", diffs)
	}
	for _, d := range diffs {
		if d.String() == "" {
			t.Fatal("empty difference string")
		}
	}
}

func testLargeValues(t *testing.T, s store.Store) {
	maxU256 := new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 256), big.NewInt(1))
	tr := transfer(1, 0, addr(1), addr(2), addr(3), 0)
	tr.Value = model.NewAmount(maxU256)
	update(t, s, func(tx store.Tx) error {
		if _, err := tx.InsertTransfer(tr); err != nil {
			return err
		}
		return tx.SetBalance(addr(1), addr(3), maxU256)
	})
	view(t, s, func(r store.Reader) error {
		got, err := r.TransfersFrom(0)
		if err != nil || len(got) != 1 || got[0].Value.Big().Cmp(maxU256) != 0 {
			return fmt.Errorf("uint256 max round trip: %+v %v", got, err)
		}
		bal, err := r.Balance(addr(1), addr(3))
		if err != nil || bal.Cmp(maxU256) != 0 {
			return fmt.Errorf("balance round trip %v %v", bal, err)
		}
		return nil
	})
}
