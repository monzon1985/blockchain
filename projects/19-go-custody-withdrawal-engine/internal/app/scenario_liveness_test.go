// SPDX-License-Identifier: MIT

package app_test

import (
	"context"
	"math/big"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/core/types"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/config"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/failpoint"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/signer"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/testenv"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/txmgr"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/withdrawal"
)

// Liveness scenarios: each one pins a way the engine used to stop crediting deposits or stop
// sending transactions for good, without any error a caller would see.

// TestScenarioShorterForkReplacingBlocksBelowTheHead: a reorg to a shorter fork that also
// replaces blocks below its new head, observed by the scanner once. One scan covered the deposit
// block D and the two blocks after it, so only D and D+2 were remembered. The new fork re-includes
// the same transfer in a new block D and ends at D+1, below the cursor. Rewinding to the new head
// (the old behaviour) kept the row from the abandoned fork pending forever, never scanned the
// re-inclusion, and stopped every later credit at that row: bob and carol were never credited.
func TestScenarioShorterForkReplacingBlocksBelowTheHead(t *testing.T) {
	e := testenv.NewWith(t, 33, big.NewInt(1_000_000_000_000), func(c *config.Config) {
		testenv.NoSweep(c)
		c.Chain.Confirmations = 6
	})
	addr := e.Register("bob", "carol")
	for range 3 {
		e.Chain.Mine()
		e.Step()
	}
	e.Chain.ExternalTransfer(testenv.TokenAddr, testenv.Addr(900), addr["bob"], big.NewInt(7_000_000))
	e.Chain.MineN(3) // the deposit in block D, then D+1 and D+2
	e.Step()         // one scan range D..D+2
	if n := countDeposits(t, e, "bob", "pending"); n != 1 {
		t.Fatalf("setup: bob has %d pending deposits", n)
	}
	e.Chain.Reorg(3, true) // D..D+2 replaced; the transfer is re-included in the new D
	e.Chain.Truncate(1)    // and the new fork is one block shorter
	e.Step()               // the scanner sees the shorter head once
	for range 12 {
		e.Chain.Mine()
		e.Step()
	}
	if v, _ := ledger.Available(e.Ctx, e.App.DB, "bob", testenv.Asset); v.Cmp(big.NewInt(7_000_000)) != 0 {
		t.Fatalf("bob available %s, want 7000000 (the re-included deposit)", v)
	}
	e.Chain.ExternalTransfer(testenv.TokenAddr, testenv.Addr(901), addr["carol"], big.NewInt(5_000))
	for range 8 {
		e.Chain.Mine()
		e.Step()
	}
	if v, _ := ledger.Available(e.Ctx, e.App.DB, "carol", testenv.Asset); v.Cmp(big.NewInt(5_000)) != 0 {
		t.Fatalf("carol available %s: a later, unrelated deposit was not credited", v)
	}
	if got := testutil.ToFloat64(e.App.Metrics.DepositsStale); got != 0 {
		t.Fatalf("the cursor check must handle this reorg itself; the credit-time safety net fired %v times", got)
	}
	e.CheckDeposits()
	e.CheckInvariants()
}

// TestScenarioReorgRightAfterALongScanRange: one scan covered more blocks than the scanner keeps
// hashes for, so pruning used to delete every remembered hash below that range's end. A 2-block
// reorg (well within 3 confirmations) then put a deposit into the block just below the old end;
// with nothing canonical left to rewind to, the scanner rewound to one block below the oldest
// hash it had, which was the replaced block itself, and that deposit was never scanned. Found
// by the simulator's chain-ground-truth deposit check (P7).
func TestScenarioReorgRightAfterALongScanRange(t *testing.T) {
	e := testenv.Quiet(t, 42)
	bob := e.Register("bob")["bob"]
	e.Step()
	e.Chain.MineN(7)
	e.Step() // one scan range of 7 blocks: more than the 2 x 3 blocks of remembered hashes
	e.Chain.ExternalTransfer(testenv.TokenAddr, testenv.Addr(900), bob, big.NewInt(7_000_000))
	e.Chain.Reorg(2, true) // the last 2 blocks replaced; the deposit lands in the first new one
	for range testenv.Confirmations + 2 {
		e.Step()
		e.Chain.Mine()
	}
	if v, _ := ledger.Available(e.Ctx, e.App.DB, "bob", testenv.Asset); v.Cmp(big.NewInt(7_000_000)) != 0 {
		t.Fatalf("bob available %s, want 7000000", v)
	}
	e.CheckDeposits()
	e.CheckInvariants()
}

// TestScenarioStalePendingDepositIsRescanned: whatever leaves a pending deposit from an
// abandoned fork behind, crediting must not stall on it. The row's remembered block hash is
// corrupted the way such a reorg would leave it; at depth the scanner notices, counts it, rewinds
// below it and credits the canonical transfer, and later deposits keep flowing (the old code
// returned silently at that row on every round, so nothing after it was ever credited).
func TestScenarioStalePendingDepositIsRescanned(t *testing.T) {
	e := testenv.Quiet(t, 34)
	addr := e.Register("bob", "carol")
	e.Chain.ExternalTransfer(testenv.TokenAddr, testenv.Addr(900), addr["bob"], big.NewInt(7_000_000))
	e.Chain.Mine()
	e.Step()
	if _, err := e.App.DB.ExecContext(e.Ctx, `UPDATE deposits SET block_hash = ? WHERE account_id = 'bob'`,
		"0x"+strings.Repeat("ab", 32)); err != nil {
		t.Fatal(err)
	}
	e.Chain.ExternalTransfer(testenv.TokenAddr, testenv.Addr(901), addr["carol"], big.NewInt(5_000))
	for range testenv.Confirmations + 3 {
		e.Chain.Mine()
		e.Step()
	}
	if v, _ := ledger.Available(e.Ctx, e.App.DB, "bob", testenv.Asset); v.Cmp(big.NewInt(7_000_000)) != 0 {
		t.Fatalf("bob available %s, want 7000000", v)
	}
	if v, _ := ledger.Available(e.Ctx, e.App.DB, "carol", testenv.Asset); v.Cmp(big.NewInt(5_000)) != 0 {
		t.Fatalf("carol available %s, want 5000", v)
	}
	if got := testutil.ToFloat64(e.App.Metrics.DepositsStale); got != 1 {
		t.Fatalf("custody_deposits_stale_pending_total = %v, want 1", got)
	}
	e.CheckDeposits()
	e.CheckInvariants()
}

// TestScenarioCrashBeforeSignThenLiquidityDrop: the process crashes right after reserving a
// nonce for w2, and by the time it restarts the hot wallet can no longer cover w2 (w1 was mined
// meanwhile). The retry fails at gas estimation; it must release the orphaned reservation, or
// every later transaction (w3, fully funded) queues behind a nonce nobody will ever sign.
func TestScenarioCrashBeforeSignThenLiquidityDrop(t *testing.T) {
	e := testenv.NewWith(t, 35, big.NewInt(10_000_000), testenv.NoSweep) // 10 tUSD of hot liquidity
	e.FundUser("alice", 1_000_000_000)
	e.Allowlist("alice", testenv.Addr(1), testenv.Addr(2), testenv.Addr(3))
	w1 := testenv.CreatedID(t, e.Create("k1", "alice", 6_000_000, testenv.Addr(1)))
	e.Dispatch()
	e.Track() // w1 broadcast at the next nonce, not mined yet
	w2 := testenv.CreatedID(t, e.Create("k2", "alice", 6_000_000, testenv.Addr(2)))
	if _, err := e.App.Withdrawals.DispatchOnce(e.Ctx); err != nil { // evaluate: approved
		t.Fatal(err)
	}
	crashAtBeforeSign(t, e)
	e.Chain.Mine() // w1 mined: 4 tUSD left, w2 (6 tUSD) can no longer be estimated
	w3 := testenv.CreatedID(t, e.Create("k3", "alice", 1_000_000, testenv.Addr(3)))
	e.RunUntil(60, func() bool { return e.Status(w3) == withdrawal.Confirmed })
	if e.Status(w1) != withdrawal.Confirmed || e.Status(w2) != withdrawal.Approved {
		t.Fatalf("w1 %s, w2 %s (w2 waits for liquidity)", e.Status(w1), e.Status(w2))
	}
	if testutil.ToFloat64(e.App.Metrics.ReservationsReleased) < 1 || countAudit(t, e, "nonce.reservation_released") < 1 {
		t.Fatal("the orphaned reservation was not released, or not reported")
	}
	if n := countReserved(t, e); n != 0 {
		t.Fatalf("%d reservations still held", n)
	}
	e.CheckInvariants()
}

// TestScenarioReservationDoesNotDeadlockSweeps: the same crash with sweeps on. The sweep that
// would restore the hot wallet's liquidity must not queue behind w2's orphaned reservation: it
// is mined, and w2 then goes through (before the fix the wallet deadlocked).
func TestScenarioReservationDoesNotDeadlockSweeps(t *testing.T) {
	e := testenv.NewWith(t, 36, big.NewInt(10_000_000), func(c *config.Config) {
		c.Deposits.SweepMinAmount.Int = big.NewInt(25_000_000) // sweep once 25 tUSD sit in forwarders
	})
	e.FundUser("alice", 10_000_000)
	e.FundUser("dave", 10_000_000)
	e.Allowlist("alice", testenv.Addr(1))
	e.Allowlist("dave", testenv.Addr(2))
	testenv.CreatedID(t, e.Create("k1", "alice", 6_000_000, testenv.Addr(1)))
	e.Dispatch()
	e.Track()
	w2 := testenv.CreatedID(t, e.Create("k2", "dave", 5_000_000, testenv.Addr(2)))
	if _, err := e.App.Withdrawals.DispatchOnce(e.Ctx); err != nil {
		t.Fatal(err)
	}
	crashAtBeforeSign(t, e)
	e.Chain.Mine() // 4 tUSD left: w2 (5 tUSD) cannot be estimated until a sweep lands
	bob := e.Register("bob")["bob"]
	e.Chain.ExternalTransfer(testenv.TokenAddr, testenv.Addr(900), bob, big.NewInt(500_000_000))
	e.RunUntil(200, func() bool { return e.Status(w2) == withdrawal.Confirmed })
	var done int
	_ = e.App.DB.QueryRowContext(e.Ctx, `SELECT COUNT(*) FROM sweeps WHERE status = 'done'`).Scan(&done)
	if done == 0 {
		t.Fatal("w2 confirmed without a sweep restoring liquidity?")
	}
	e.CheckInvariants()
}

// crashAtBeforeSign runs the dispatcher with before_sign armed (a nonce is reserved and
// committed, then the process dies) and restarts the engine on the same database.
func crashAtBeforeSign(t *testing.T, e *testenv.Env) {
	t.Helper()
	e.FP.Arm(failpoint.BeforeSign)
	crashed := false
	func() {
		defer func() { _, crashed = failpoint.AsCrash(recover()) }()
		_, _ = e.App.Withdrawals.DispatchOnce(e.Ctx)
	}()
	if !crashed {
		t.Fatal("setup: before_sign did not fire")
	}
	if countReserved(t, e) != 1 {
		t.Fatal("setup: the crash did not leave a reservation behind")
	}
	e.Restart()
}

// TestScenarioAbandonedFillerReservationIsReclaimed: a gap filler reserved its nonce and the
// process died before the signature was persisted. Fillers are never retried under the same
// reference, and a reserved nonce is not a gap, so before the fix nothing ever filled it and
// every later transaction waited forever.
func TestScenarioAbandonedFillerReservationIsReclaimed(t *testing.T) {
	e := testenv.Quiet(t, 37)
	e.FundUser("alice", 1_000_000_000)
	e.Allowlist("alice", testenv.Addr(1))
	ghost := reserve(t, e, signer.PurposeFiller, "gap:0:1")
	id := testenv.CreatedID(t, e.Create("k", "alice", 1_000_000, testenv.Addr(1)))
	e.Dispatch() // the withdrawal is signed at the nonce after the abandoned one
	if _, atts := e.Attempts(id); atts[0].Nonce != ghost.Nonce+1 {
		t.Fatalf("setup: withdrawal at nonce %d, abandoned filler at %d", atts[0].Nonce, ghost.Nonce)
	}
	e.RunUntil(20, func() bool { return e.Status(id) == withdrawal.Confirmed })
	filler, err := txmgr.LoadSlot(e.Ctx, e.App.DB, ghost.Nonce)
	if err != nil || filler.Purpose != signer.PurposeFiller || filler.RefID == ghost.RefID || filler.State != txmgr.StateFinal {
		t.Fatalf("nonce %d not refilled under a fresh reservation: %+v %v", ghost.Nonce, filler, err)
	}
	if testutil.ToFloat64(e.App.Metrics.ReservationsReleased) != 1 || testutil.ToFloat64(e.App.Metrics.NonceGapsFilled) != 1 {
		t.Fatal("release or fill not counted")
	}
	e.CheckInvariants()
}

// TestScenarioStaleReservationIsReclaimed: the safety net for any other reservation nothing will
// ever retry (here a withdrawal reservation with no withdrawal behind it). It is kept while it
// could still be in the middle of being signed, and released once it has stayed unsigned for
// txmgr.ReservationTTL across the gap grace period; the gap is then filled.
func TestScenarioStaleReservationIsReclaimed(t *testing.T) {
	e := testenv.Quiet(t, 38)
	e.FundUser("alice", 1_000_000_000)
	e.Allowlist("alice", testenv.Addr(1))
	ghost := reserve(t, e, signer.PurposeWithdrawal, "ghost")
	id := testenv.CreatedID(t, e.Create("k", "alice", 1_000_000, testenv.Addr(1)))
	e.Dispatch()
	e.Track()
	e.MineAndTrack(4)
	if s, err := txmgr.LoadSlot(e.Ctx, e.App.DB, ghost.Nonce); err != nil || s.State != txmgr.StateReserved || s.RefID != "ghost" {
		t.Fatalf("a young reservation must be left alone: %+v %v", s, err)
	}
	e.Clock.Advance(txmgr.ReservationTTL)
	e.RunUntil(20, func() bool { return e.Status(id) == withdrawal.Confirmed })
	if s, err := txmgr.LoadSlot(e.Ctx, e.App.DB, ghost.Nonce); err != nil || s.Purpose != signer.PurposeFiller || s.State != txmgr.StateFinal {
		t.Fatalf("stale reservation not reclaimed and filled: %+v %v", s, err)
	}
	if countAudit(t, e, "nonce.reservation_released") != 1 {
		t.Fatal("release not audited")
	}
	e.CheckInvariants()
}

func reserve(t *testing.T, e *testenv.Env, p signer.Purpose, ref string) txmgr.Slot {
	t.Helper()
	var s txmgr.Slot
	if err := e.App.DB.WithTx(e.Ctx, func(tx *store.Tx) error {
		var err error
		s, err = txmgr.Reserve(e.Ctx, tx, p, ref, e.Clock.Now())
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return s
}

// TestScenarioEmptySweepDoesNotClaimLaterDeposits: a sweep whose flush moved nothing (its
// forwarder had already been emptied by an earlier sweep the scanner had not caught up with)
// must not claim a deposit that landed later in its own block. The old attribution compared log
// indexes against "infinity" when nothing moved, marked that deposit swept, and its tokens stayed
// in the forwarder for good.
func TestScenarioEmptySweepDoesNotClaimLaterDeposits(t *testing.T) {
	e := testenv.New(t, 39)
	x := e.Register("xavier")["xavier"]
	scan := func() {
		t.Helper()
		if err := e.App.Scanner.ScanOnce(e.Ctx); err != nil {
			t.Fatal(err)
		}
	}
	sweep := func() {
		t.Helper()
		if err := e.App.Sweeper.SweepOnce(e.Ctx); err != nil {
			t.Fatal(err)
		}
	}
	sweepIDs := func() []string {
		rows, err := e.App.DB.QueryContext(e.Ctx, `SELECT id FROM sweeps ORDER BY created_at, rowid`)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var out []string
		for rows.Next() {
			var id string
			_ = rows.Scan(&id)
			out = append(out, id)
		}
		return out
	}
	// d_a is credited and the first sweep is signed for it.
	e.Chain.ExternalTransfer(testenv.TokenAddr, testenv.Addr(900), x, big.NewInt(1_000_000))
	e.Chain.Mine()
	scan()
	e.Chain.MineN(testenv.Confirmations - 1)
	scan()
	sweep()
	e.Track() // the first sweep is in the pool
	// d0 lands in the first sweep's block, before the flush, which moves it too; but the scanner
	// lags, so that sweep is final before d0 is recorded and cannot attribute it.
	e.Chain.ExternalTransfer(testenv.TokenAddr, testenv.Addr(901), x, big.NewInt(2_000_000))
	e.MineAndTrack(testenv.Confirmations)
	if ids := sweepIDs(); len(ids) != 1 || e.Chain.TokenBalance(testenv.TokenAddr, x).Sign() != 0 {
		t.Fatalf("setup: sweeps %v, forwarder balance %s", ids, e.Chain.TokenBalance(testenv.TokenAddr, x))
	}
	scan() // d0 recorded and credited, unswept: a second sweep is created for an empty forwarder
	sweep()
	e.Track() // the second sweep is in the pool
	// d1 lands in the second sweep's block after the flush, which therefore moves nothing.
	e.Chain.ExternalTransferLate(testenv.TokenAddr, testenv.Addr(902), x, big.NewInt(4_000_000))
	e.Chain.Mine()
	scan() // d1 recorded before the second sweep is final
	e.MineAndTrack(testenv.Confirmations)
	ids := sweepIDs()
	if len(ids) != 2 {
		t.Fatalf("setup: sweeps %v", ids)
	}
	var d1SweptBy string
	if err := e.App.DB.QueryRowContext(e.Ctx, `SELECT COALESCE(swept_by, '') FROM deposits WHERE amount = '4000000'`).Scan(&d1SweptBy); err != nil {
		t.Fatal(err)
	}
	if d1SweptBy == ids[1] {
		t.Fatalf("d1 attributed to the sweep that moved nothing (%s)", ids[1])
	}
	e.RunUntil(30, func() bool { return e.Chain.TokenBalance(testenv.TokenAddr, x).Sign() == 0 })
	for range testenv.Confirmations + 2 {
		e.Step()
		e.Chain.Mine()
	}
	var unswept int
	_ = e.App.DB.QueryRowContext(e.Ctx, `SELECT COUNT(*) FROM deposits WHERE swept_by IS NULL`).Scan(&unswept)
	snap, _ := ledger.Balances(e.Ctx, e.App.DB)
	if unswept != 0 || snap.Get(ledger.Forwarders, testenv.Asset).Sign() != 0 {
		t.Fatalf("%d deposits unswept, forwarders ledger %s", unswept, snap.Get(ledger.Forwarders, testenv.Asset))
	}
	e.CheckDeposits()
	e.CheckInvariants()
}

func countDeposits(t *testing.T, e *testenv.Env, account, status string) int {
	t.Helper()
	var n int
	if err := e.App.DB.QueryRowContext(e.Ctx, `SELECT COUNT(*) FROM deposits WHERE account_id = ? AND status = ?`, account, status).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func countAudit(t *testing.T, e *testenv.Env, typ string) int {
	t.Helper()
	var n int
	if err := e.App.DB.QueryRowContext(e.Ctx, `SELECT COUNT(*) FROM audit_events WHERE type = ?`, typ).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func countReserved(t *testing.T, e *testenv.Env) int {
	t.Helper()
	var n int
	if err := e.App.DB.QueryRowContext(e.Ctx, `SELECT COUNT(*) FROM nonce_slots WHERE state = 'reserved'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// TestScenarioReservationReclaimedWhileSigning: a withdrawal's nonce reservation is taken away
// while its transaction is being signed (what the tracker's safety net does to a reservation it
// believes abandoned, with a gap filler then taking the nonce). The signature must be discarded,
// and the withdrawal, still approved, must be signed again later at another nonce: marking its
// signing intent done at that point would leave it approved forever.
func TestScenarioReservationReclaimedWhileSigning(t *testing.T) {
	e := testenv.Quiet(t, 43)
	e.FundUser("alice", 1_000_000_000)
	e.Allowlist("alice", testenv.Addr(1))
	hijacked := false
	e.WrapSigner = func(s signer.Signer) signer.Signer {
		return hookSigner{Signer: s, before: func(tx *types.Transaction) {
			if hijacked || tx.To() == nil || *tx.To() != testenv.TokenAddr {
				return
			}
			hijacked = true
			if err := e.App.DB.WithTx(e.Ctx, func(dtx *store.Tx) error {
				if _, err := dtx.ExecContext(e.Ctx, `DELETE FROM nonce_slots WHERE nonce = ? AND state = 'reserved'`, tx.Nonce()); err != nil {
					return err
				}
				_, err := txmgr.Reserve(e.Ctx, dtx, signer.PurposeFiller, "gap:hijack", e.Clock.Now())
				return err
			}); err != nil {
				t.Error(err)
			}
		}}
	}
	e.Restart() // with the hook installed
	id := testenv.CreatedID(t, e.Create("k", "alice", 1_000_000, testenv.Addr(1)))
	e.Dispatch() // evaluate, then sign: the reservation is taken mid-signing
	if !hijacked {
		t.Fatal("setup: the hook did not fire")
	}
	var pending int
	if err := e.App.DB.QueryRowContext(e.Ctx, `SELECT COUNT(*) FROM outbox WHERE kind = 'withdrawal.sign' AND ref_id = ? AND done_at IS NULL`, id).Scan(&pending); err != nil {
		t.Fatal(err)
	}
	if e.Status(id) != withdrawal.Approved || pending != 1 {
		t.Fatalf("after the discarded signature: status %s, pending signing intents %d (want approved, 1)", e.Status(id), pending)
	}
	e.RunUntil(40, func() bool { return e.Status(id) == withdrawal.Confirmed })
	if n := e.TransfersTo(testenv.Addr(1)); n != 1 {
		t.Fatalf("%d transfers", n)
	}
	e.CheckInvariants()
}

// hookSigner runs before() on every transaction it is asked to sign.
type hookSigner struct {
	signer.Signer
	before func(*types.Transaction)
}

func (h hookSigner) SignTx(ctx context.Context, tx *types.Transaction, chainID *big.Int) (*types.Transaction, error) {
	h.before(tx)
	return h.Signer.SignTx(ctx, tx, chainID)
}

// TestScenarioReorgDeeperThanTheScannerWindow: a reorg replaces every block the scanner still
// knows (its window, its anchor and the block of a credited deposit). It cannot find a fork
// point, so it says so, flags the credited deposit that left the chain as a deep reorg (once,
// without rewriting the customer's balance), and goes on crediting new deposits.
func TestScenarioReorgDeeperThanTheScannerWindow(t *testing.T) {
	e := testenv.Quiet(t, 44)
	addr := e.Register("bob", "carol")
	e.Chain.ExternalTransfer(testenv.TokenAddr, testenv.Addr(900), addr["bob"], big.NewInt(7_000_000))
	for range testenv.Confirmations + 9 {
		e.Chain.Mine()
		e.Step()
	}
	if v, _ := ledger.Available(e.Ctx, e.App.DB, "bob", testenv.Asset); v.Cmp(big.NewInt(7_000_000)) != 0 {
		t.Fatalf("setup: bob available %s", v)
	}
	head, _ := e.Chain.Height()
	e.Chain.Reorg(int(head), false) // every block after genesis replaced; bob's deposit is gone
	e.Chain.ExternalTransfer(testenv.TokenAddr, testenv.Addr(901), addr["carol"], big.NewInt(5_000))
	for range testenv.Confirmations + 2 {
		e.Chain.Mine()
		e.Step()
	}
	if got := testutil.ToFloat64(e.App.Metrics.DeepReorgs); got != 1 || countAudit(t, e, "deposit.deep_reorg") != 1 {
		t.Fatalf("deep reorg reported %v times (audit events %d), want once", got, countAudit(t, e, "deposit.deep_reorg"))
	}
	if v, _ := ledger.Available(e.Ctx, e.App.DB, "bob", testenv.Asset); v.Cmp(big.NewInt(7_000_000)) != 0 {
		t.Fatalf("the engine rewrote a credited balance on its own: %s", v)
	}
	if v, _ := ledger.Available(e.Ctx, e.App.DB, "carol", testenv.Asset); v.Cmp(big.NewInt(5_000)) != 0 {
		t.Fatalf("carol available %s: scanning stopped after the deep reorg", v)
	}
	e.CheckInvariants()
}
