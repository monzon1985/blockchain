// SPDX-License-Identifier: MIT

package app_test

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/core/types"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/config"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/policy"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/signer"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/testenv"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/txmgr"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/withdrawal"
)

func TestScenarioFeeSpikeTriggersReplaceByFee(t *testing.T) {
	e, id := testenv.Setup(t, 11)
	e.Dispatch()
	e.Track() // original sent
	for range 4 {
		e.Chain.SetNextBaseFee(big.NewInt(200 * testenv.Gwei))
		e.Chain.Mine()
		e.Track()
	}
	e.RunUntil(20, func() bool { return e.Status(id) == withdrawal.Confirmed })
	_, atts := e.Attempts(id)
	if len(atts) < 2 {
		t.Fatalf("expected a replacement, got %d attempts", len(atts))
	}
	for i := 1; i < len(atts); i++ {
		prev, cur := atts[i-1].Fees, atts[i].Fees
		if new(big.Int).Mul(cur.MaxFee, big.NewInt(8)).Cmp(new(big.Int).Mul(prev.MaxFee, big.NewInt(9))) < 0 ||
			new(big.Int).Mul(cur.Tip, big.NewInt(8)).Cmp(new(big.Int).Mul(prev.Tip, big.NewInt(9))) < 0 {
			t.Fatalf("attempt %d bumped by less than 12.5%%: %s -> %s", i, prev, cur)
		}
		if atts[i].Nonce != atts[0].Nonce {
			t.Fatal("replacement used a different nonce")
		}
	}
	if e.TransfersTo(testenv.Addr(1)) != 1 {
		t.Fatal("expected exactly one transfer")
	}
	if testutil.ToFloat64(e.App.Metrics.FeeBumps) == 0 {
		t.Fatal("bump metric not incremented")
	}
	e.CheckInvariants()
}

func TestScenarioDroppedTransactionIsRebroadcast(t *testing.T) {
	e, id := testenv.Setup(t, 12)
	e.Dispatch()
	e.Track()
	_, atts := e.Attempts(id)
	if !e.Chain.Drop(atts[0].Hash) {
		t.Fatalf("transaction was not in the pool: %+v pool=%v status=%s", atts, e.Chain.PoolHashes(), e.Status(id))
	}
	e.Track() // notices the drop, re-sends the same signed bytes
	if known, _ := e.Chain.TransactionKnown(e.Ctx, atts[0].Hash); !known {
		t.Fatal("not rebroadcast")
	}
	e.RunUntil(10, func() bool { return e.Status(id) == withdrawal.Confirmed })
	if _, atts2 := e.Attempts(id); len(atts2) != 1 {
		t.Fatalf("a rebroadcast must reuse the signed transaction, got %d attempts", len(atts2))
	}
	if testutil.ToFloat64(e.App.Metrics.Rebroadcasts) < 1 {
		t.Fatal("rebroadcast metric not incremented")
	}
	e.CheckInvariants()
}

func TestScenarioReorgReturnsWithdrawalToBroadcast(t *testing.T) {
	e, id := testenv.Setup(t, 13)
	e.Dispatch()
	e.Track()
	e.MineAndTrack(1)
	if e.Status(id) != withdrawal.Mined {
		t.Fatalf("status %s", e.Status(id))
	}
	e.Reconcile() // in-flight effect already booked
	snap, _ := ledger.Balances(e.Ctx, e.App.DB)
	if snap.Get(ledger.InFlight, testenv.Asset).Sign() >= 0 {
		t.Fatal("in-flight outflow not booked at inclusion")
	}
	e.Chain.Reorg(1, false) // the block with our transaction disappears
	e.Track()
	if e.Status(id) != withdrawal.Broadcast {
		t.Fatalf("after reorg status %s", e.Status(id))
	}
	snap, _ = ledger.Balances(e.Ctx, e.App.DB)
	if snap.Get(ledger.InFlight, testenv.Asset).Sign() != 0 || snap.Get(ledger.InFlight, "ETH").Sign() != 0 {
		t.Fatal("inclusion not reversed")
	}
	e.Reconcile()
	e.RunUntil(10, func() bool { return e.Status(id) == withdrawal.Confirmed })
	got := strings.Join(e.Transitions(id), " ")
	if !strings.Contains(got, "mined>broadcast") {
		t.Fatalf("transition log %q lacks mined>broadcast", got)
	}
	e.CheckInvariants()
}

func TestScenarioReorgMovesReceiptToAnotherBlock(t *testing.T) {
	e, id := testenv.Setup(t, 14)
	e.Dispatch()
	e.Track()
	e.MineAndTrack(1)
	s1, _ := e.Attempts(id)
	e.Chain.Reorg(1, true) // same transaction, new block hash
	e.Track()
	s2, _ := e.Attempts(id)
	if s2.State != txmgr.StateIncluded || s2.IncludedBlockHash == s1.IncludedBlockHash || s2.InclusionEpoch != s1.InclusionEpoch+1 {
		t.Fatalf("inclusion not moved: before %+v after %+v", s1, s2)
	}
	if e.Status(id) != withdrawal.Mined {
		t.Fatalf("status %s", e.Status(id))
	}
	e.Reconcile()
	e.RunUntil(10, func() bool { return e.Status(id) == withdrawal.Confirmed })
	e.CheckInvariants()
}

func TestScenarioCancelBeforeSigning(t *testing.T) {
	e := testenv.Quiet(t, 15)
	e.FundUser("alice", 1_000_000_000)
	e.Allowlist("alice", testenv.Addr(1))
	id := testenv.CreatedID(t, e.Create("big", "alice", 600_000_000, testenv.Addr(1))) // needs approvals
	e.Dispatch()
	if e.Status(id) != withdrawal.Requested {
		t.Fatal("large withdrawal did not wait for approvals")
	}
	if _, err := e.App.Withdrawals.Cancel(e.Ctx, id, "approver-0"); err != nil {
		t.Fatal(err)
	}
	if e.Status(id) != withdrawal.Failed {
		t.Fatalf("status %s", e.Status(id))
	}
	if v, _ := ledger.Available(e.Ctx, e.App.DB, "alice", testenv.Asset); v.Cmp(big.NewInt(1_000_000_000)) != 0 {
		t.Fatalf("funds not returned: %s", v)
	}
	if _, err := e.App.Withdrawals.Cancel(e.Ctx, id, "approver-0"); !errors.Is(err, withdrawal.ErrNotCancellable) {
		t.Fatalf("second cancel: %v", err)
	}
	e.CheckInvariants()
}

func TestScenarioCancelAfterBroadcastReplacesTransaction(t *testing.T) {
	e, id := testenv.Setup(t, 16)
	e.Dispatch()
	e.Track() // sent, not mined
	if _, err := e.App.Withdrawals.Cancel(e.Ctx, id, "approver-1"); err != nil {
		t.Fatal(err)
	}
	e.Track() // sends the zero-value self-send at the same nonce
	_, atts := e.Attempts(id)
	if atts[len(atts)-1].Kind != txmgr.KindCancel || atts[len(atts)-1].To != e.Hot {
		t.Fatalf("no cancellation attempt: %+v", atts[len(atts)-1])
	}
	e.RunUntil(10, func() bool { return e.Status(id).Terminal() })
	if e.Status(id) != withdrawal.Replaced || e.TransfersTo(testenv.Addr(1)) != 0 {
		t.Fatalf("status %s, transfers %d", e.Status(id), e.TransfersTo(testenv.Addr(1)))
	}
	if v, _ := ledger.Available(e.Ctx, e.App.DB, "alice", testenv.Asset); v.Cmp(big.NewInt(1_000_000_000)) != 0 {
		t.Fatalf("funds not returned: %s", v)
	}
	snap, _ := ledger.Balances(e.Ctx, e.App.DB)
	if snap.Get(ledger.Fees, "ETH").Sign() <= 0 {
		t.Fatal("cancellation gas not booked")
	}
	e.CheckInvariants()
}

func TestScenarioAllowlistRemovalTurnsBumpIntoCancellation(t *testing.T) {
	e, id := testenv.Setup(t, 17)
	e.Dispatch()
	e.Track()
	if removed, err := e.App.Withdrawals.RemoveAllowlist(e.Ctx, "gateway", "alice", testenv.Addr(1)); err != nil || !removed {
		t.Fatal(err)
	}
	for range 3 { // stuck: every block's base fee is above the transaction's fee cap
		e.Chain.SetNextBaseFee(big.NewInt(300 * testenv.Gwei))
		e.Chain.Mine()
		e.Track()
	}
	e.RunUntil(10, func() bool { return e.Status(id).Terminal() })
	if e.Status(id) != withdrawal.Replaced || e.TransfersTo(testenv.Addr(1)) != 0 {
		t.Fatalf("status %s transfers %d", e.Status(id), e.TransfersTo(testenv.Addr(1)))
	}
	e.CheckInvariants()
}

func TestScenarioSigningRefusedReleasesNonce(t *testing.T) {
	e := testenv.Quiet(t, 18)
	e.FundUser("alice", 1_000_000_000)
	e.Allowlist("alice", testenv.Addr(1), testenv.Addr(2))
	bad := testenv.CreatedID(t, e.Create("a", "alice", 1_000_000, testenv.Addr(1)))
	if _, err := e.App.Withdrawals.RemoveAllowlist(e.Ctx, "gateway", "alice", testenv.Addr(1)); err != nil {
		t.Fatal(err)
	}
	next, _ := e.Chain.NonceAt(e.Ctx, e.Hot)
	e.Dispatch()
	w, _ := withdrawal.Load(e.Ctx, e.App.DB, bad)
	if w.Status != withdrawal.Failed || w.FailureReason != "signing_refused" || w.Nonce != nil {
		t.Fatalf("refused withdrawal: %+v", w)
	}
	good := testenv.CreatedID(t, e.Create("b", "alice", 1_000_000, testenv.Addr(2)))
	e.Dispatch()
	w, _ = withdrawal.Load(e.Ctx, e.App.DB, good)
	if w.Nonce == nil || *w.Nonce != next {
		t.Fatalf("the released nonce %d must be reused, got %v", next, w.Nonce)
	}
	e.RunUntil(10, func() bool { return e.Status(good) == withdrawal.Confirmed })
	e.CheckInvariants()
}

func TestScenarioNonceGapIsFilled(t *testing.T) {
	e := testenv.Quiet(t, 19)
	e.FundUser("alice", 1_000_000_000)
	e.Allowlist("alice", testenv.Addr(1))
	// A reservation that will never be signed occupies the next nonce...
	var ghost txmgr.Slot
	if err := e.App.DB.WithTx(e.Ctx, func(tx *store.Tx) error {
		var err error
		ghost, err = txmgr.Reserve(e.Ctx, tx, signer.PurposeWithdrawal, "ghost", e.Clock.Now())
		return err
	}); err != nil {
		t.Fatal(err)
	}
	id := testenv.CreatedID(t, e.Create("k", "alice", 1_000_000, testenv.Addr(1)))
	e.Dispatch()
	e.Track()
	// ...and is then released, leaving a hole below a broadcast transaction.
	if err := e.App.DB.WithTx(e.Ctx, func(tx *store.Tx) error {
		_, err := txmgr.Release(e.Ctx, tx, signer.PurposeWithdrawal, "ghost")
		return err
	}); err != nil {
		t.Fatal(err)
	}
	e.RunUntil(20, func() bool { return e.Status(id) == withdrawal.Confirmed })
	filler, err := txmgr.LoadSlot(e.Ctx, e.App.DB, ghost.Nonce)
	if err != nil || filler.Purpose != signer.PurposeFiller || filler.State != txmgr.StateFinal {
		t.Fatalf("gap not filled: %+v %v", filler, err)
	}
	if testutil.ToFloat64(e.App.Metrics.NonceGapsFilled) != 1 {
		t.Fatal("gap metric")
	}
	e.CheckInvariants()
}

func TestScenarioNonceDriftRaisesFloorAndReconciliationFlagsIt(t *testing.T) {
	e := testenv.Quiet(t, 20)
	e.FundUser("alice", 1_000_000_000)
	e.Allowlist("alice", testenv.Addr(1))
	// Someone uses the hot-wallet key outside the engine.
	n, _ := e.Chain.NonceAt(e.Ctx, e.Hot)
	rogue := types.NewTx(&types.DynamicFeeTx{ChainID: big.NewInt(31337), Nonce: n, GasTipCap: big.NewInt(testenv.Gwei),
		GasFeeCap: big.NewInt(100 * testenv.Gwei), Gas: 21_000, To: &e.Hot, Value: new(big.Int)})
	signed, _ := signer.NewLocalKeystoreSigner(e.Key).SignTx(e.Ctx, rogue, big.NewInt(31337))
	if err := e.Chain.SendTransaction(e.Ctx, signed); err != nil {
		t.Fatal(err)
	}
	e.Chain.Mine()
	_, rep, err := e.App.TrackRound(e.Ctx, true)
	if err != nil {
		t.Fatal(err)
	}
	if testutil.ToFloat64(e.App.Metrics.NonceDrift) != 1 {
		t.Fatal("drift not detected")
	}
	if rep.OK || rep.Assets[0].Asset != "ETH" || !strings.HasPrefix(rep.Assets[0].Delta, "-") {
		t.Fatalf("the unexplained gas spend must show as a negative ETH delta: %+v", rep)
	}
	id := testenv.CreatedID(t, e.Create("k", "alice", 1_000_000, testenv.Addr(1)))
	e.RunUntil(10, func() bool { return e.Status(id) == withdrawal.Confirmed })
	if w, _ := withdrawal.Load(e.Ctx, e.App.DB, id); *w.Nonce != n+1 {
		t.Fatalf("withdrawal used nonce %d, expected %d", *w.Nonce, n+1)
	}
}

func TestScenarioFeeCapStopsBumpingUntilFeesFall(t *testing.T) {
	e := testenv.NewWith(t, 21, big.NewInt(1_000_000_000_000), func(c *config.Config) {
		testenv.NoSweep(c)
		c.Fees.MaxFeeWei.Int = big.NewInt(60 * testenv.Gwei)
	})
	e.FundUser("alice", 1_000_000_000)
	e.Allowlist("alice", testenv.Addr(1))
	id := testenv.CreatedID(t, e.Create("k", "alice", 1_000_000, testenv.Addr(1)))
	e.Dispatch()
	e.Track()
	for range 4 {
		e.Chain.SetNextBaseFee(big.NewInt(500 * testenv.Gwei))
		e.Chain.Mine()
		e.Track()
	}
	if testutil.ToFloat64(e.App.Metrics.FeeCapReached) == 0 || e.Status(id) != withdrawal.Broadcast {
		t.Fatalf("cap not enforced: status %s", e.Status(id))
	}
	_, atts := e.Attempts(id)
	for _, a := range atts {
		if a.Fees.MaxFee.Cmp(big.NewInt(60*testenv.Gwei)) > 0 {
			t.Fatalf("attempt above the cap: %s", a.Fees)
		}
	}
	e.Chain.SetNextBaseFee(big.NewInt(testenv.Gwei))
	e.RunUntil(20, func() bool { return e.Status(id) == withdrawal.Confirmed })
	e.CheckInvariants()
}

func TestScenarioLiquidityRaceRevertsAndRefunds(t *testing.T) {
	e := testenv.NewWith(t, 22, big.NewInt(100_000_000), testenv.NoSweep)
	e.FundUser("alice", 80_000_000)
	e.FundUser("bob", 80_000_000)
	e.Allowlist("alice", testenv.Addr(1))
	e.Allowlist("bob", testenv.Addr(2))
	w1 := testenv.CreatedID(t, e.Create("a", "alice", 70_000_000, testenv.Addr(1)))
	w2 := testenv.CreatedID(t, e.Create("b", "bob", 70_000_000, testenv.Addr(2)))
	for range 2 {
		e.Dispatch()
	}
	e.Track()
	e.RunUntil(10, func() bool { return e.Status(w1).Terminal() && e.Status(w2).Terminal() })
	if e.Status(w1) != withdrawal.Confirmed || e.Status(w2) != withdrawal.Failed {
		t.Fatalf("statuses %s %s", e.Status(w1), e.Status(w2))
	}
	w, _ := withdrawal.Load(e.Ctx, e.App.DB, w2)
	if w.FailureReason != "reverted_on_chain" {
		t.Fatalf("reason %q", w.FailureReason)
	}
	if v, _ := ledger.Available(e.Ctx, e.App.DB, "bob", testenv.Asset); v.Cmp(big.NewInt(80_000_000)) != 0 {
		t.Fatalf("bob not refunded: %s", v)
	}
	e.CheckInvariants()
}

func TestScenarioBatchSweep(t *testing.T) {
	e := testenv.New(t, 23)
	before := e.Chain.TokenBalance(testenv.TokenAddr, e.Hot)
	users := []string{"s1", "s2", "s3", "s4", "s5"}
	for _, u := range users {
		e.FundUser(u, 10_000_000)
	}
	e.RunUntil(30, func() bool {
		var n int
		_ = e.App.DB.QueryRowContext(e.Ctx, `SELECT COUNT(*) FROM sweeps WHERE status = 'done'`).Scan(&n)
		return n >= 1
	})
	for range testenv.Confirmations + 2 {
		e.Step()
		e.Chain.Mine()
	}
	gained := new(big.Int).Sub(e.Chain.TokenBalance(testenv.TokenAddr, e.Hot), before)
	if gained.Cmp(big.NewInt(50_000_000)) != 0 {
		t.Fatalf("hot wallet gained %s", gained)
	}
	snap, _ := ledger.Balances(e.Ctx, e.App.DB)
	if snap.Get(ledger.Forwarders, testenv.Asset).Sign() != 0 {
		t.Fatalf("forwarders account %s after sweep", snap.Get(ledger.Forwarders, testenv.Asset))
	}
	var unswept int
	_ = e.App.DB.QueryRowContext(e.Ctx, `SELECT COUNT(*) FROM deposits WHERE swept_by IS NULL`).Scan(&unswept)
	if unswept != 0 {
		t.Fatalf("%d deposits not attributed to a sweep", unswept)
	}
	e.CheckInvariants()
}

func TestScenarioDepositReorgedOutIsNeverCredited(t *testing.T) {
	e := testenv.New(t, 24)
	a, _ := e.App.Deriver.Address("carol")
	if err := e.App.DB.WithTx(e.Ctx, func(tx *store.Tx) error {
		_, err := testenv.RegisterFor(e, tx, "carol")
		return err
	}); err != nil {
		t.Fatal(err)
	}
	e.Chain.ExternalTransfer(testenv.TokenAddr, e.Hot, a, big.NewInt(5))
	e.Chain.Mine()
	e.Step() // seen, pending
	e.Chain.Reorg(1, false)
	for range testenv.Confirmations + 2 {
		e.Chain.Mine()
		e.Step()
	}
	if v, _ := ledger.Available(e.Ctx, e.App.DB, "carol", testenv.Asset); v.Sign() != 0 {
		t.Fatalf("orphaned deposit credited: %s", v)
	}
	if testutil.ToFloat64(e.App.Metrics.DepositsOrphaned) != 1 {
		t.Fatal("orphan metric")
	}
}

func TestScenarioDeepReorgIsFlagged(t *testing.T) {
	e := testenv.New(t, 25)
	e.FundUser("dave", 7_000_000) // credited at depth 3
	e.Chain.Reorg(testenv.Confirmations+1, false)
	e.Step()
	if testutil.ToFloat64(e.App.Metrics.DeepReorgs) != 1 {
		t.Fatal("deep reorg not flagged")
	}
	var n int
	_ = e.App.DB.QueryRowContext(e.Ctx, `SELECT COUNT(*) FROM audit_events WHERE type = 'deposit.deep_reorg'`).Scan(&n)
	if n != 1 {
		t.Fatal("deep reorg not audited")
	}
}

func TestScenarioApprovalsMofN(t *testing.T) {
	e := testenv.Quiet(t, 26)
	e.FundUser("erin", 2_000_000_000)
	e.Allowlist("erin", testenv.Addr(1), testenv.Addr(2))
	id := testenv.CreatedID(t, e.Create("big", "erin", 600_000_000, testenv.Addr(1)))
	e.Dispatch()
	if _, err := e.App.Withdrawals.Approve(e.Ctx, id, "approver-0", "approve"); err != nil {
		t.Fatal(err)
	}
	if _, err := e.App.Withdrawals.Approve(e.Ctx, id, "approver-0", "approve"); !errors.Is(err, withdrawal.ErrAlreadyDecided) {
		t.Fatalf("duplicate approval: %v", err)
	}
	e.Dispatch()
	if e.Status(id) != withdrawal.Requested {
		t.Fatal("one approval must not be enough")
	}
	if _, err := e.App.Withdrawals.Approve(e.Ctx, id, "approver-2", "maybe"); !errors.Is(err, withdrawal.ErrInvalidDecision) {
		t.Fatalf("invalid decision: %v", err)
	}
	if _, err := e.App.Withdrawals.Approve(e.Ctx, id, "approver-2", "approve"); err != nil {
		t.Fatal(err)
	}
	e.RunUntil(10, func() bool { return e.Status(id) == withdrawal.Confirmed })
	if _, err := e.App.Withdrawals.Approve(e.Ctx, id, "approver-1", "approve"); !errors.Is(err, withdrawal.ErrNotPending) {
		t.Fatalf("late approval: %v", err)
	}
	rej := testenv.CreatedID(t, e.Create("big2", "erin", 600_000_000, testenv.Addr(2)))
	if _, err := e.App.Withdrawals.Approve(e.Ctx, rej, "approver-1", "reject"); err != nil {
		t.Fatal(err)
	}
	if w, _ := withdrawal.Load(e.Ctx, e.App.DB, rej); w.Status != withdrawal.Failed || w.FailureReason != policy.ReasonRejectedByApprover {
		t.Fatalf("rejected withdrawal: %+v", w)
	}
	if v, _ := ledger.Available(e.Ctx, e.App.DB, "erin", testenv.Asset); v.Cmp(big.NewInt(1_400_000_000)) != 0 {
		t.Fatalf("available %s", v)
	}
	e.CheckInvariants()
}

func TestScenarioPolicyRejections(t *testing.T) {
	e := testenv.NewWith(t, 27, big.NewInt(1_000_000_000_000), func(c *config.Config) {
		testenv.NoSweep(c)
		c.Assets[0].Velocity24h.Int = big.NewInt(150_000_000)
	})
	e.FundUser("fay", 1_000_000_000)
	e.Allowlist("fay", testenv.Addr(1))
	reason := func(r withdrawal.Response) string {
		if r.Code != http.StatusUnprocessableEntity {
			t.Fatalf("expected 422, got %d %s", r.Code, r.Body)
		}
		var body withdrawal.ErrorBody
		_ = testenv.JSONUnmarshal(r.Body, &body)
		return body.Error.Code
	}
	testenv.CreatedID(t, e.Create("1", "fay", 100_000_000, testenv.Addr(1)))
	if got := reason(e.Create("2", "fay", 60_000_000, testenv.Addr(1))); got != policy.ReasonVelocityExceeded {
		t.Fatalf("got %s", got)
	}
	if got := reason(e.Create("3", "fay", 1, testenv.Addr(9))); got != policy.ReasonNotAllowlisted {
		t.Fatalf("got %s", got)
	}
	if _, err := e.App.Withdrawals.AddAllowlist(e.Ctx, "gateway", "fay", testenv.Addr(9), "new"); err != nil {
		t.Fatal(err)
	}
	if got := reason(e.Create("4", "fay", 1, testenv.Addr(9))); got != policy.ReasonInCooldown {
		t.Fatalf("got %s", got)
	}
	if got := reason(e.Create("5", "fay", 1, e.Hot)); got != policy.ReasonBadDestination {
		t.Fatalf("got %s", got)
	}
	if got := reason(e.Create("6", "fay", 2_000_000_000, testenv.Addr(1))); got != policy.ReasonVelocityExceeded {
		t.Fatalf("got %s", got)
	}
	if _, err := e.App.Withdrawals.AddAllowlist(e.Ctx, "gateway", "fay", e.Hot, "self"); !errors.Is(err, withdrawal.ErrForbiddenDestination) {
		t.Fatalf("hot wallet allowlisted: %v", err)
	}
	e.Clock.Advance(24*time.Hour + time.Second)
	testenv.CreatedID(t, e.Create("7", "fay", 60_000_000, testenv.Addr(1)))
	if got := reason(e.Create("8", "fay", 950_000_000, testenv.Addr(1))); got != policy.ReasonVelocityExceeded {
		t.Fatalf("got %s", got)
	}
	bad := e.Create("9", "fay", 1, testenv.Addr(1))
	bad2, _ := e.App.Withdrawals.Create(context.Background(), "gateway", "", []byte(`{}`))
	if bad.Code != http.StatusCreated || bad2.Code != http.StatusBadRequest {
		t.Fatalf("codes %d %d", bad.Code, bad2.Code)
	}
}

// TestScenarioUnsendableReplacementDoesNotBlockInclusion: a cancellation is persisted but every
// attempt to send it fails, while the original transfer is mined anyway. The tracker must still
// see the inclusion and confirm the withdrawal (regression: a failing send used to stop the
// slot's round before the inclusion check).
func TestScenarioUnsendableReplacementDoesNotBlockInclusion(t *testing.T) {
	e, id := testenv.Setup(t, 28)
	e.Dispatch()
	e.Track()
	_, atts := e.Attempts(id)
	orig := atts[0].Hash
	e.Chain.SetSendFault(func(tx *types.Transaction) error {
		if tx.Hash() != orig {
			return errors.New("insufficient funds for gas * price + value")
		}
		return nil
	})
	if _, err := e.App.Withdrawals.Cancel(e.Ctx, id, "approver-0"); err != nil {
		t.Fatal(err)
	}
	e.Track() // persists the cancellation; sending it fails
	_, atts = e.Attempts(id)
	if last := atts[len(atts)-1]; last.Kind != txmgr.KindCancel || last.Status != txmgr.AttemptSigned {
		t.Fatalf("expected an unsent cancellation, got %+v", last)
	}
	e.RunUntil(10, func() bool { return e.Status(id).Terminal() })
	if e.Status(id) != withdrawal.Confirmed || e.TransfersTo(testenv.Addr(1)) != 1 {
		t.Fatalf("status %s transfers %d", e.Status(id), e.TransfersTo(testenv.Addr(1)))
	}
	e.CheckInvariants()
}

// TestScenarioRevertedSweepIsRetried: the token starts reverting (for example it was paused)
// after the sweep was estimated and signed. The sweep is mined as reverted, marked failed, its
// gas is booked, the deposits stay unswept, and the next sweep succeeds.
func TestScenarioRevertedSweepIsRetried(t *testing.T) {
	e := testenv.New(t, 29)
	for _, u := range []string{"r1", "r2"} {
		addr, _ := e.App.Deriver.Address(u)
		if err := e.App.DB.WithTx(e.Ctx, func(tx *store.Tx) error {
			_, err := testenv.RegisterFor(e, tx, u)
			return err
		}); err != nil {
			t.Fatal(err)
		}
		e.Chain.ExternalTransfer(testenv.TokenAddr, testenv.Addr(900), addr, big.NewInt(3_000_000))
	}
	for range testenv.Confirmations {
		e.Chain.Mine()
	}
	// Credit, create the sweep and get its transaction into the pool, without mining.
	if err := e.App.Scanner.ScanOnce(e.Ctx); err != nil {
		t.Fatal(err)
	}
	if err := e.App.Sweeper.SweepOnce(e.Ctx); err != nil {
		t.Fatal(err)
	}
	e.Track()
	e.Chain.FlushReverts = true
	failed := func() bool {
		var n int
		_ = e.App.DB.QueryRowContext(e.Ctx, `SELECT COUNT(*) FROM sweeps WHERE status = 'failed'`).Scan(&n)
		return n == 1
	}
	// Only the tracker runs here: while the token reverts, new sweeps fail at gas estimation
	// (the production loop logs that and retries).
	for i := 0; i < 10 && !failed(); i++ {
		e.Chain.Mine()
		e.Track()
	}
	if !failed() {
		t.Fatal("the reverted sweep was not marked failed")
	}
	if err := e.App.Sweeper.SweepOnce(e.Ctx); err == nil || !strings.Contains(err.Error(), "reverted") {
		t.Fatalf("while the token reverts a new sweep must fail at estimation, got %v", err)
	}
	var unswept int
	_ = e.App.DB.QueryRowContext(e.Ctx, `SELECT COUNT(*) FROM deposits WHERE swept_by IS NULL`).Scan(&unswept)
	if unswept != 2 {
		t.Fatalf("%d deposits unswept after the failed sweep, want 2", unswept)
	}
	e.CheckInvariants()
	e.Chain.FlushReverts = false
	e.RunUntil(20, func() bool {
		var n int
		_ = e.App.DB.QueryRowContext(e.Ctx, `SELECT COUNT(*) FROM sweeps WHERE status = 'done'`).Scan(&n)
		return n == 1
	})
	if got := e.Chain.TokenBalance(testenv.TokenAddr, e.Hot); got.Cmp(big.NewInt(1_000_006_000_000)) != 0 {
		t.Fatalf("hot wallet token balance %s", got)
	}
	e.CheckInvariants()
}

// TestScenarioReconciliationFlagsLedgerTamperingAndStaleHeads: reconciliation recomputes the
// ledger instead of trusting its cached balances, so an edit made behind the ledger's back is
// reported even though the on-chain identity (hot wallet = hot_wallet + in_flight) still holds;
// and a reconciliation requested at a head that was reorged out in the meantime is reported as
// inconclusive rather than comparing balances read at a block that is no longer canonical.
func TestScenarioReconciliationFlagsLedgerTamperingAndStaleHeads(t *testing.T) {
	e := testenv.Quiet(t, 30)
	e.FundUser("alice", 50_000_000)
	e.Reconcile()

	round, _, err := e.App.TrackRound(e.Ctx, false)
	if err != nil {
		t.Fatal(err)
	}
	e.Chain.Reorg(1, false)
	rep, err := e.App.Recon.Run(e.Ctx, round.Head)
	if err != nil || !rep.Inconclusive || rep.OK || len(rep.Assets) != 0 {
		t.Fatalf("reconciliation at a reorged-out head: %+v %v", rep, err)
	}

	// Raise alice's cached balance by 10 tUSD without a ledger entry.
	if _, err := e.App.DB.ExecContext(e.Ctx, `UPDATE ledger_balances SET balance = '-60000000' WHERE account = ? AND asset = ?`,
		ledger.User("alice"), testenv.Asset); err != nil {
		t.Fatal(err)
	}
	_, rep2, err := e.App.TrackRound(e.Ctx, true)
	if err != nil || rep2 == nil {
		t.Fatalf("reconciliation: %v", err)
	}
	if rep2.OK || strings.Join(rep2.LedgerIssues, ",") != ledger.User("alice")+"/"+testenv.Asset {
		t.Fatalf("tampering not reported: %+v", rep2)
	}
	for _, line := range rep2.Assets {
		if !line.OK {
			t.Fatalf("the chain identity still holds, yet %s is flagged: %+v", line.Asset, line)
		}
	}
	if last, ok := e.App.Recon.Last(); !ok || last.OK {
		t.Fatalf("the API would serve a stale OK report: %+v", last)
	}
}

// TestScenarioHeadGoesBackwards: the node's head moves back two blocks and stays there for a
// round (a reorg to a shorter fork, or a load balancer answering from a node that is behind).
// The withdrawal whose receipt was in a vanished block returns to broadcast, the deposit seen
// there is dropped and the scanner rewinds to the new head; once the chain grows again both are
// settled exactly once.
func TestScenarioHeadGoesBackwards(t *testing.T) {
	e := testenv.Quiet(t, 31)
	e.FundUser("alice", 1_000_000_000)
	e.Allowlist("alice", testenv.Addr(1))
	id := testenv.CreatedID(t, e.Create("k", "alice", 1_000_000, testenv.Addr(1)))
	e.Dispatch()
	e.Track() // broadcast
	if err := e.App.DB.WithTx(e.Ctx, func(tx *store.Tx) error {
		_, err := testenv.RegisterFor(e, tx, "bob")
		return err
	}); err != nil {
		t.Fatal(err)
	}
	bobAddr, _ := e.App.Deriver.Address("bob")
	e.Chain.ExternalTransfer(testenv.TokenAddr, testenv.Addr(900), bobAddr, big.NewInt(7_000_000))
	e.Chain.Mine() // one block with the withdrawal transfer and bob's deposit
	e.Step()
	pendingFor := func(acct string) int {
		var n int
		if err := e.App.DB.QueryRowContext(e.Ctx, `SELECT COUNT(*) FROM deposits WHERE account_id = ? AND status = 'pending'`, acct).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if e.Status(id) != withdrawal.Mined || pendingFor("bob") != 1 {
		t.Fatalf("before: withdrawal %s, bob pending deposits %d", e.Status(id), pendingFor("bob"))
	}
	before, _ := e.Chain.Head(e.Ctx)
	e.Chain.Truncate(2)
	e.Step()
	if e.Status(id) != withdrawal.Broadcast || pendingFor("bob") != 0 {
		t.Fatalf("after the head moved back: withdrawal %s, bob pending deposits %d", e.Status(id), pendingFor("bob"))
	}
	if cursor, _, _ := store.GetMeta(e.Ctx, e.App.DB, "scan_cursor"); cursor != fmt.Sprint(before.Number-2) {
		t.Fatalf("scan cursor %s, want the new head %d", cursor, before.Number-2)
	}
	e.RunUntil(20, func() bool {
		bal, _ := ledger.Available(e.Ctx, e.App.DB, "bob", testenv.Asset)
		return e.Status(id) == withdrawal.Confirmed && bal.Cmp(big.NewInt(7_000_000)) == 0
	})
	if n := e.TransfersTo(testenv.Addr(1)); n != 1 {
		t.Fatalf("%d transfers", n)
	}
	var credited int
	_ = e.App.DB.QueryRowContext(e.Ctx, `SELECT COUNT(*) FROM deposits WHERE account_id = 'bob' AND status = 'credited'`).Scan(&credited)
	if credited != 1 {
		t.Fatalf("bob's deposit credited %d times", credited)
	}
	e.CheckInvariants()
}

// TestScenarioDeepReorgOfAFinalizedWithdrawalIsFlagged: a reorg deeper than the confirmation
// depth removes a withdrawal the engine already confirmed. The engine cannot take back what it
// told the customer, so it must not rewrite anything on its own; it must say so, once, where an
// operator will see it (metric and audit event), instead of only stalling the nonce queue and
// leaving a reconciliation delta to explain the problem.
func TestScenarioDeepReorgOfAFinalizedWithdrawalIsFlagged(t *testing.T) {
	e, id := testenv.Setup(t, 32)
	e.RunUntil(20, func() bool { return e.Status(id) == withdrawal.Confirmed })
	slot, _ := e.Attempts(id)
	head, _ := e.Chain.Height()
	e.Chain.Reorg(int(head-slot.IncludedBlock)+1, false) // the transfer's block and everything after it
	if n, _ := e.Chain.NonceAt(e.Ctx, e.Hot); n > slot.Nonce {
		t.Fatalf("setup: the finalized transaction is still on chain (nonce %d)", n)
	}
	for range 3 {
		e.Step()
	}
	if got := testutil.ToFloat64(e.App.Metrics.DeepReorgs); got != 1 {
		t.Fatalf("custody_deep_reorgs_total = %v, want 1", got)
	}
	var n int
	_ = e.App.DB.QueryRowContext(e.Ctx, `SELECT COUNT(*) FROM audit_events WHERE type = 'tx.deep_reorg'`).Scan(&n)
	if n != 1 {
		t.Fatalf("%d tx.deep_reorg audit events, want exactly 1", n)
	}
	if e.Status(id) != withdrawal.Confirmed {
		t.Fatalf("the engine rewrote a confirmed withdrawal on its own: %s", e.Status(id))
	}
}
