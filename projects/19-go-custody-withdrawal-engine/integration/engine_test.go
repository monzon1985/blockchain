// SPDX-License-Identifier: MIT

//go:build integration

package integration

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/app"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/bindings"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/cli"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/clock"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/config"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/deposit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/signer"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/txmgr"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/withdrawal"
)

// Engine is the full engine running in-process against anvil, driven step by step.
type Engine struct {
	t     *testing.T
	a     *Anvil
	d     Deployment
	App   *app.App
	Clock *clock.Fake
	ctx   context.Context
}

func testLogger() *slog.Logger {
	if os.Getenv("CUSTODY_TEST_VERBOSE") != "" {
		return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	}
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func startEngine(t *testing.T, overrides map[string]any) *Engine {
	t.Helper()
	a := StartAnvil(t)
	d := Deploy(t, a)
	// Treasury liquidity: the hot wallet holds tokens before the engine adopts it.
	d.Mint(a, d.Hot, big.NewInt(1_000_000_000_000))
	p := WriteConfig(t, t.TempDir(), a, d, overrides)
	cfg, err := config.Load(p)
	if err != nil {
		t.Fatal(err)
	}
	e := &Engine{t: t, a: a, d: d, Clock: clock.NewFake(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)), ctx: context.Background()}
	e.App, err = app.New(e.ctx, cfg, app.Deps{Chain: a.RPC, Signer: signer.NewLocalKeystoreSigner(d.HotKey), Clock: e.Clock, Log: testLogger()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { e.App.Close() })
	return e
}

// startQuiet is startEngine with the sweeper idle, so a test owns every hot-wallet nonce.
func startQuiet(t *testing.T) *Engine {
	t.Helper()
	a := StartAnvil(t)
	d := Deploy(t, a)
	d.Mint(a, d.Hot, big.NewInt(1_000_000_000_000))
	dir := t.TempDir()
	p := WriteConfig(t, dir, a, d, map[string]any{
		"deposits": map[string]any{"factory": d.Factory.Hex(), "start_block": 0, "sweep_min_amount": "1000000000000000000000000"},
	})
	cfg, err := config.Load(p)
	if err != nil {
		t.Fatal(err)
	}
	e := &Engine{t: t, a: a, d: d, Clock: clock.NewFake(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)), ctx: context.Background()}
	e.App, err = app.New(e.ctx, cfg, app.Deps{Chain: a.RPC, Signer: signer.NewLocalKeystoreSigner(d.HotKey), Clock: e.Clock, Log: testLogger()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { e.App.Close() })
	return e
}

func (e *Engine) step() {
	e.t.Helper()
	if err := e.App.Step(e.ctx); err != nil {
		e.t.Fatalf("step: %v", err)
	}
}

func (e *Engine) dispatch() {
	e.t.Helper()
	for range 2 {
		if _, err := e.App.Withdrawals.DispatchOnce(e.ctx); err != nil {
			e.t.Fatal(err)
		}
	}
}

func (e *Engine) track() {
	e.t.Helper()
	if _, _, err := e.App.TrackRound(e.ctx, false); err != nil {
		e.t.Fatal(err)
	}
}

func (e *Engine) status(id string) withdrawal.Status {
	w, err := withdrawal.Load(e.ctx, e.App.DB, id)
	if err != nil {
		e.t.Fatal(err)
	}
	return w.Status
}

func (e *Engine) runUntil(max int, cond func() bool) {
	e.t.Helper()
	for range max {
		if cond() {
			return
		}
		e.step()
		e.a.Mine(1)
		e.Clock.Advance(time.Second)
	}
	if !cond() {
		e.t.Fatalf("condition not reached in %d rounds", max)
	}
}

// fund registers the account's deposit address, mints a deposit to it and waits for the credit.
func (e *Engine) fund(user string, amount int64) common.Address {
	e.t.Helper()
	var addr deposit.Address
	must(e.t, e.App.DB.WithTx(e.ctx, func(tx *store.Tx) error {
		var err error
		addr, err = deposit.Register(e.ctx, tx, e.App.Deriver, user, e.Clock.Now())
		return err
	}))
	e.d.Mint(e.a, addr.Address, big.NewInt(amount))
	e.runUntil(20, func() bool {
		v, _ := ledger.Available(e.ctx, e.App.DB, user, "tUSD")
		return v.Sign() > 0
	})
	return addr.Address
}

func (e *Engine) withdraw(user, key string, amount int64, dest common.Address) string {
	e.t.Helper()
	if _, err := e.App.Withdrawals.AddAllowlist(e.ctx, "gateway", user, dest, "it"); err != nil {
		e.t.Fatal(err)
	}
	body, _ := json.Marshal(withdrawal.CreateRequest{AccountID: user, Asset: "tUSD", Amount: fmt.Sprint(amount), Destination: dest.Hex()})
	resp, err := e.App.Withdrawals.Create(e.ctx, "gateway", key, body)
	if err != nil || resp.Code != http.StatusCreated {
		e.t.Fatalf("create: %v %d %s", err, resp.Code, resp.Body)
	}
	var v withdrawal.View
	_ = json.Unmarshal(resp.Body, &v)
	return v.ID
}

func (e *Engine) attempts(id string) []txmgr.Attempt {
	w, _ := withdrawal.Load(e.ctx, e.App.DB, id)
	if w.Nonce == nil {
		e.t.Fatalf("%s has no nonce", id)
	}
	atts, err := txmgr.Attempts(e.ctx, e.App.DB, *w.Nonce)
	if err != nil {
		e.t.Fatal(err)
	}
	return atts
}

func (e *Engine) transfersTo(dest common.Address) int {
	n := 0
	for _, tr := range e.d.TransfersFromHot(e.t, e.a) {
		if tr.To == dest {
			n++
		}
	}
	return n
}

// checkReconciled asserts the ledger invariants and the chain reconciliation at the head.
func (e *Engine) checkReconciled() {
	e.t.Helper()
	res, err := ledger.Check(e.ctx, e.App.DB)
	if err != nil || !res.OK() {
		e.t.Fatalf("ledger: %+v %v", res, err)
	}
	_, rep, err := e.App.TrackRound(e.ctx, true)
	if err != nil || rep == nil || !rep.OK {
		e.t.Fatalf("reconciliation: %+v %v", rep, err)
	}
}

func dest(i int) common.Address {
	return common.BigToAddress(new(big.Int).Add(big.NewInt(0xDE57_0000), big.NewInt(int64(i))))
}

// TestAnvilCreate2Differential compares the Go address derivation with the contract's own
// forwarderAddress for many account ids, then checks that the sweep deploys exactly there.
func TestAnvilCreate2Differential(t *testing.T) {
	e := startEngine(t, nil)
	ff := bindings.NewForwarderFactory()
	for i := range 64 {
		id := fmt.Sprintf("acct-%d-%x", i, i*7919)
		goAddr, salt := e.App.Deriver.Address(id)
		out, err := e.a.RPC.CallContractAtHash(e.ctx, callMsg(e.d.Factory, ff.PackForwarderAddress(salt)), headHash(t, e.a))
		if err != nil {
			t.Fatal(err)
		}
		onChain, _ := ff.UnpackForwarderAddress(out)
		if goAddr != onChain {
			t.Fatalf("%s: go %s, contract %s", id, goAddr, onChain)
		}
	}
	fwd := e.fund("diff-user", 5_000_000)
	e.runUntil(30, func() bool {
		code, _ := codeAt(e, fwd)
		return len(code) > 0
	})
	e.checkReconciled()
}

func codeAt(e *Engine, a common.Address) ([]byte, error) {
	var out string
	err := e.a.RPC.Raw().CallContext(e.ctx, &out, "eth_getCode", a, "latest")
	return common.FromHex(out), err
}

// TestAnvilFeeSpikeReplaceByFee: a base-fee spike evicts the withdrawal from anvil's pool (its
// fee cap is now below the base fee); the engine re-prices it at the same nonce with both fee
// fields raised by >= 12.5 % (and to at least the eth_feeHistory suggestion), and it confirms
// exactly once.
func TestAnvilFeeSpikeReplaceByFee(t *testing.T) {
	e := startQuiet(t)
	e.fund("alice", 1_000_000_000)
	id := e.withdraw("alice", "k1", 10_000_000, dest(1))
	e.dispatch()
	e.track() // original accepted
	orig := e.attempts(id)[0]
	if known, _ := e.a.RPC.TransactionKnown(e.ctx, orig.Hash); !known || orig.Fees.MaxFee.Cmp(big.NewInt(150*gwei)) >= 0 {
		t.Fatalf("setup: original known=%v, fees %s", known, orig.Fees)
	}
	e.a.MineWithBaseFee(150 * gwei)
	if known, _ := e.a.RPC.TransactionKnown(e.ctx, orig.Hash); known {
		t.Fatal("anvil kept the underpriced original in its pool")
	}
	e.track()
	for range 3 {
		e.a.MineWithBaseFee(150 * gwei)
		e.track()
	}
	e.runUntil(20, func() bool { return e.status(id) == withdrawal.Confirmed })
	atts := e.attempts(id)
	if len(atts) < 2 {
		t.Fatalf("expected a replacement, got %d attempts", len(atts))
	}
	// Both fields must clear the node's replacement rule: cur >= prev x 1.125, i.e. 8 cur >= 9 prev.
	for i := 1; i < len(atts); i++ {
		p, c := atts[i-1].Fees, atts[i].Fees
		if new(big.Int).Mul(c.MaxFee, big.NewInt(8)).Cmp(new(big.Int).Mul(p.MaxFee, big.NewInt(9))) < 0 ||
			new(big.Int).Mul(c.Tip, big.NewInt(8)).Cmp(new(big.Int).Mul(p.Tip, big.NewInt(9))) < 0 {
			t.Fatalf("bump below 12.5%% on a fee field: %s -> %s", p, c)
		}
		if atts[i].Nonce != orig.Nonce {
			t.Fatal("a replacement used another nonce")
		}
	}
	if e.transfersTo(dest(1)) != 1 {
		t.Fatal("expected exactly one transfer")
	}
	t.Logf("fee spike: %d attempts, final maxFee %s wei", len(atts), atts[len(atts)-1].Fees.MaxFee)
	e.checkReconciled()
}

// TestAnvilDroppedTransactionRebroadcast: anvil_dropTransaction removes the pending withdrawal;
// the engine notices and re-sends the same signed bytes.
func TestAnvilDroppedTransactionRebroadcast(t *testing.T) {
	e := startQuiet(t)
	e.fund("bob", 1_000_000_000)
	id := e.withdraw("bob", "k1", 10_000_000, dest(2))
	e.dispatch()
	e.track()
	h := e.attempts(id)[0].Hash
	e.a.Drop(h)
	if k, _ := e.a.RPC.TransactionKnown(e.ctx, h); k {
		t.Fatal("anvil did not drop the transaction")
	}
	e.track()
	if k, _ := e.a.RPC.TransactionKnown(e.ctx, h); !k {
		t.Fatal("engine did not rebroadcast")
	}
	e.runUntil(10, func() bool { return e.status(id) == withdrawal.Confirmed })
	if n := len(e.attempts(id)); n != 1 || e.transfersTo(dest(2)) != 1 {
		t.Fatalf("attempts %d transfers %d", n, e.transfersTo(dest(2)))
	}
	e.checkReconciled()
}

// TestAnvilReorgReceiptDisappears: anvil_reorg removes the block holding the withdrawal; the
// receipt disappears, the withdrawal returns to broadcast, the inclusion is reversed in the
// ledger, and the rebroadcast transaction confirms.
func TestAnvilReorgReceiptDisappears(t *testing.T) {
	e := startQuiet(t)
	e.fund("carol", 1_000_000_000)
	id := e.withdraw("carol", "k1", 10_000_000, dest(3))
	e.dispatch()
	e.track()
	e.a.Mine(1)
	e.track()
	if e.status(id) != withdrawal.Mined {
		t.Fatalf("status %s", e.status(id))
	}
	e.checkReconciled()
	e.a.Reorg(1, nil)
	e.track()
	if e.status(id) != withdrawal.Broadcast {
		t.Fatalf("after reorg: %s", e.status(id))
	}
	e.checkReconciled()
	e.runUntil(10, func() bool { return e.status(id) == withdrawal.Confirmed })
	if e.transfersTo(dest(3)) != 1 {
		t.Fatal("expected exactly one transfer")
	}
	e.checkReconciled()
}

// TestAnvilReorgReceiptMovesBlock: anvil_reorg re-includes the same signed transaction in a
// different block; the receipt's block hash changes and the engine re-books the inclusion.
func TestAnvilReorgReceiptMovesBlock(t *testing.T) {
	e := startQuiet(t)
	e.fund("dave", 1_000_000_000)
	id := e.withdraw("dave", "k1", 10_000_000, dest(4))
	e.dispatch()
	e.track()
	e.a.Mine(1)
	e.track()
	w, _ := withdrawal.Load(e.ctx, e.App.DB, id)
	before, _ := txmgr.LoadSlot(e.ctx, e.App.DB, *w.Nonce)
	raw := "0x" + hex.EncodeToString(e.attempts(id)[0].Raw)
	e.a.Reorg(1, [][]any{{raw, 0}})
	e.track()
	after, _ := txmgr.LoadSlot(e.ctx, e.App.DB, *w.Nonce)
	if after.State != txmgr.StateIncluded || after.IncludedBlockHash == before.IncludedBlockHash {
		t.Fatalf("inclusion did not move: %+v -> %+v", before, after)
	}
	e.checkReconciled()
	e.runUntil(10, func() bool { return e.status(id) == withdrawal.Confirmed })
	if e.transfersTo(dest(4)) != 1 {
		t.Fatal("expected exactly one transfer")
	}
	e.checkReconciled()
}

// TestAnvilCancelStuckWithdrawal: a stuck withdrawal is cancelled with a zero-value self-send at
// the same nonce; nothing reaches the destination and the customer is refunded.
func TestAnvilCancelStuckWithdrawal(t *testing.T) {
	e := startQuiet(t)
	e.fund("erin", 1_000_000_000)
	id := e.withdraw("erin", "k1", 10_000_000, dest(5))
	e.dispatch()
	e.track()
	if _, err := e.App.Withdrawals.Cancel(e.ctx, id, "approver-0"); err != nil {
		t.Fatal(err)
	}
	e.track()
	e.runUntil(10, func() bool { return e.status(id).Terminal() })
	if e.status(id) != withdrawal.Replaced || e.transfersTo(dest(5)) != 0 {
		t.Fatalf("status %s transfers %d", e.status(id), e.transfersTo(dest(5)))
	}
	if v, _ := ledger.Available(e.ctx, e.App.DB, "erin", "tUSD"); v.Cmp(big.NewInt(1_000_000_000)) != 0 {
		t.Fatalf("refund: %s", v)
	}
	e.checkReconciled()
}

// TestAnvilDepositReorgOrphaned: a deposit the scanner has seen, whose block is then reorged out
// before the confirmation depth, is dropped and never credited; a later deposit to the same
// address is credited normally.
func TestAnvilDepositReorgOrphaned(t *testing.T) {
	e := startQuiet(t)
	var addr deposit.Address
	must(t, e.App.DB.WithTx(e.ctx, func(tx *store.Tx) error {
		var err error
		addr, err = deposit.Register(e.ctx, tx, e.App.Deriver, "frank", e.Clock.Now())
		return err
	}))
	rows := func(status string) int {
		var n int
		must(t, e.App.DB.QueryRowContext(e.ctx, `SELECT COUNT(*) FROM deposits WHERE account_id = 'frank' AND status = ?`, status).Scan(&n))
		return n
	}
	e.d.Mint(e.a, addr.Address, big.NewInt(42))
	e.step()
	if rows("pending") != 1 {
		t.Fatal("setup: the scanner did not see the deposit before the reorg")
	}
	e.a.Reorg(1, nil)
	for range 6 {
		e.a.Mine(1)
		e.step()
	}
	if v, _ := ledger.Available(e.ctx, e.App.DB, "frank", "tUSD"); v.Sign() != 0 || rows("pending")+rows("credited") != 0 {
		t.Fatalf("orphaned deposit kept or credited: available %s, rows %d", v, rows("pending")+rows("credited"))
	}
	if got := testutil.ToFloat64(e.App.Metrics.DepositsOrphaned); got != 1 {
		t.Fatalf("custody_deposits_orphaned_total = %v, want 1", got)
	}
	e.d.Mint(e.a, addr.Address, big.NewInt(1_000))
	e.runUntil(10, func() bool { return rows("credited") == 1 })
	if v, _ := ledger.Available(e.ctx, e.App.DB, "frank", "tUSD"); v.Cmp(big.NewInt(1_000)) != 0 {
		t.Fatalf("later deposit: available %s, want 1000", v)
	}
	e.checkReconciled()
}

// TestAnvilReconciliationFlagsExternalInflow: tokens sent straight to the hot wallet are not in
// the ledger; reconciliation reports the positive delta.
func TestAnvilReconciliationFlagsExternalInflow(t *testing.T) {
	e := startQuiet(t)
	e.checkReconciled()
	e.d.Mint(e.a, e.d.Hot, big.NewInt(777))
	_, rep, err := e.App.TrackRound(e.ctx, true)
	if err != nil {
		t.Fatal(err)
	}
	var tok *struct{ Delta string }
	for _, l := range rep.Assets {
		if l.Asset == "tUSD" {
			tok = &struct{ Delta string }{l.Delta}
		}
	}
	if rep.OK || tok == nil || tok.Delta != "777" {
		t.Fatalf("unexplained inflow not reported: %+v", rep)
	}
}

// TestAnvilBatchSweepGas sweeps 1, 10 and 50 cold forwarders and then 50 warm ones through the
// engine and reports the receipt gas of each flushMany.
func TestAnvilBatchSweepGas(t *testing.T) {
	e := startEngine(t, nil)
	seen := map[string]bool{}
	sweepAll := func(users []string, amount int64) *types.Receipt {
		var fwds []common.Address
		for _, u := range users {
			var a deposit.Address
			must(t, e.App.DB.WithTx(e.ctx, func(tx *store.Tx) error {
				var err error
				a, err = deposit.Register(e.ctx, tx, e.App.Deriver, u, e.Clock.Now())
				return err
			}))
			e.d.Mint(e.a, a.Address, big.NewInt(amount))
			fwds = append(fwds, a.Address)
		}
		e.a.Mine(3) // every deposit reaches the confirmation depth before the next scan: one batch
		var sweepID string
		e.runUntil(40, func() bool {
			rows, err := e.App.DB.QueryContext(e.ctx, `SELECT id FROM sweeps WHERE status = 'done'`)
			if err != nil {
				t.Fatal(err)
			}
			defer rows.Close()
			for rows.Next() {
				var id string
				_ = rows.Scan(&id)
				if !seen[id] {
					sweepID = id
				}
			}
			return sweepID != ""
		})
		seen[sweepID] = true
		var items int
		_ = e.App.DB.QueryRowContext(e.ctx, `SELECT COUNT(*) FROM sweep_items WHERE sweep_id = ?`, sweepID).Scan(&items)
		if items != len(users) {
			t.Fatalf("sweep %s covered %d forwarders, want %d in one batch", sweepID, items, len(users))
		}
		s, err := txmgr.SlotFor(e.ctx, e.App.DB, signer.PurposeSweep, sweepID)
		if err != nil {
			t.Fatal(err)
		}
		r, err := e.a.RPC.TransactionReceipt(e.ctx, s.IncludedHash)
		if err != nil {
			t.Fatal(err)
		}
		for _, f := range fwds {
			if bal := e.d.TokenBalance(t, e.a, f); bal.Sign() != 0 {
				t.Fatalf("forwarder %s still holds %s", f, bal)
			}
		}
		return r
	}
	names := func(prefix string, n int) []string {
		out := make([]string, n)
		for i := range out {
			out[i] = fmt.Sprintf("%s-%d", prefix, i)
		}
		return out
	}
	one := names("one", 1)
	r1 := sweepAll(one, 1_000_000)
	w1 := sweepAll(one, 2_000_000)
	r10 := sweepAll(names("ten", 10), 1_000_000)
	cold50 := names("fifty", 50)
	r50 := sweepAll(cold50, 1_000_000)
	w50 := sweepAll(cold50, 2_000_000)
	t.Logf("flushMany receipt gas on anvil: cold x1=%d, warm x1=%d, cold x10=%d (%d/forwarder), cold x50=%d (%d/forwarder), warm x50=%d (%d/forwarder)",
		r1.GasUsed, w1.GasUsed, r10.GasUsed, r10.GasUsed/10, r50.GasUsed, r50.GasUsed/50, w50.GasUsed, w50.GasUsed/50)
	if r50.GasUsed/50 >= r1.GasUsed || w50.GasUsed/50 >= w1.GasUsed || w50.GasUsed >= r50.GasUsed {
		t.Fatalf("batching should amortise the base cost and warm sweeps should be cheaper")
	}
	snap, _ := ledger.Balances(e.ctx, e.App.DB)
	if snap.Get(ledger.Forwarders, "tUSD").Sign() != 0 {
		t.Fatalf("forwarders ledger %s", snap.Get(ledger.Forwarders, "tUSD"))
	}
	e.checkReconciled()
}

// TestAnvilServeGracefulShutdown runs `custodyd serve` through the CLI entry point against
// anvil, exercises the API, then cancels the context (what SIGINT/SIGTERM do in the binary):
// the command exits 0 promptly, the listener closes and the audit log is flushed.
func TestAnvilServeGracefulShutdown(t *testing.T) {
	a := StartAnvil(t)
	d := Deploy(t, a)
	stopMiner := a.Miner(100 * time.Millisecond)
	defer stopMiner()
	dir := t.TempDir()
	cfgPath := WriteConfig(t, dir, a, d, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var stderr syncBuffer
	exit := make(chan int, 1)
	go func() {
		exit <- cli.Run(ctx, []string{"serve", "-config", cfgPath}, cli.IO{In: strings.NewReader(""), Out: io.Discard, Err: &stderr})
	}()
	var addr string
	for i := 0; i < 200 && addr == ""; i++ {
		b, _ := os.ReadFile(filepath.Join(dir, "addr.txt"))
		addr = string(b)
		time.Sleep(50 * time.Millisecond)
	}
	if addr == "" {
		t.Fatalf("server did not start:%s", stderr.String())
	}
	for _, path := range []string{"/healthz", "/readyz", "/metrics"} {
		resp, err := http.Get("http://" + addr + path)
		if err != nil || resp.StatusCode != http.StatusOK {
			t.Fatalf("%s: %v", path, err)
		}
		resp.Body.Close()
	}
	req, _ := http.NewRequest("POST", "http://"+addr+"/v1/accounts/zed/deposit-address", nil)
	req.Header.Set("Authorization", "Bearer "+ClientToken)
	if resp, err := http.DefaultClient.Do(req); err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("deposit address: %v", err)
	} else {
		resp.Body.Close()
	}
	time.Sleep(500 * time.Millisecond) // let every loop run a few iterations
	start := time.Now()
	cancel()
	select {
	case code := <-exit:
		if code != 0 {
			t.Fatalf("exit code %d: %s", code, stderr.String())
		}
	case <-time.After(app.ShutdownTimeout + 5*time.Second):
		t.Fatal("serve did not return after cancellation")
	}
	t.Logf("graceful shutdown took %s", time.Since(start))
	if !strings.Contains(stderr.String(), "custodyd stopped") {
		t.Fatalf("no clean stop in the log: %s", stderr.String())
	}
	if _, err := http.Get("http://" + addr + "/healthz"); err == nil {
		t.Fatal("listener still accepting after shutdown")
	}
	// The final flush on shutdown leaves a log identical to the database's audit events.
	var stdout bytes.Buffer
	if code := cli.Run(context.Background(), []string{"audit-verify", "-file", filepath.Join(dir, "audit.jsonl"), "-db", filepath.Join(dir, "custody.db")},
		cli.IO{In: strings.NewReader(""), Out: &stdout, Err: &stdout}); code != 0 || !strings.Contains(stdout.String(), "identical to the database") {
		t.Fatalf("audit log not flushed on shutdown: %s", stdout.String())
	}
}
