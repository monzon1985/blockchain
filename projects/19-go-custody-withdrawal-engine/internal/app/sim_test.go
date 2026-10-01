// SPDX-License-Identifier: MIT

package app_test

import (
	"errors"
	"fmt"
	"math/big"
	"math/rand/v2"
	"net/http"
	"os"
	"runtime/debug"
	"slices"
	"strconv"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/audit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/config"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/failpoint"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/testenv"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/txmgr"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/withdrawal"
)

// simSeeds is the number of random schedules TestSimulation runs; CUSTODY_SIM_SEEDS overrides it.
func simSeeds() int {
	if v, err := strconv.Atoi(os.Getenv("CUSTODY_SIM_SEEDS")); err == nil && v > 0 {
		return v
	}
	if testing.Short() {
		return 5
	}
	return 40
}

// simStats aggregates what the schedules actually exercised, so a green run is also evidence
// that the interesting paths were hit.
type simStats struct {
	crashes, restarts, reorgs, truncations, shorterForks, drops, spikes, bumps, cancels, withdrawals, replays, sendFaults, readFaults, stepErrors int
	deepSeeds, lowLiquiditySeeds, reservationsReleased, staleDeposits                                                                             int
	byFailpoint                                                                                                                                   map[string]int
	outcomes                                                                                                                                      map[withdrawal.Status]int
}

// simVariant derives a seed's environment. One seed in three runs with 6 confirmations instead
// of 3, so reorgs and head regressions up to 5 blocks deep, and a reorg followed by a shorter
// fork, are inside the guarantee; one seed in four starts with almost no hot-wallet liquidity,
// so withdrawals wait for sweeps, gas estimation fails, and crashes leave reservations that a
// failing retry must release.
func simVariant(seed uint64) (conf uint64, hotTokens *big.Int) {
	conf, hotTokens = testenv.Confirmations, big.NewInt(1_000_000_000_000)
	if seed%3 == 0 {
		conf = 6
	}
	if seed%4 == 1 {
		hotTokens = big.NewInt(50_000_000) // 50 tUSD against 6,000 tUSD of customer deposits
	}
	return conf, hotTokens
}

// TestSimulation runs randomized schedules of withdrawals, approvals, cancellations, deposits,
// sweeps, fee spikes, dropped transactions, reorgs and crashes at every failpoint against the
// chain simulator, then drains the system and checks every invariant. Each seed is
// deterministic: a failure prints the seed, and CUSTODY_SIM_SEED=<n> replays just that one.
func TestSimulation(t *testing.T) {
	seeds := make([]uint64, 0)
	if v, err := strconv.ParseUint(os.Getenv("CUSTODY_SIM_SEED"), 10, 64); err == nil {
		seeds = append(seeds, v)
	} else {
		for i := 1; i <= simSeeds(); i++ {
			seeds = append(seeds, uint64(i))
		}
	}
	total := simStats{byFailpoint: map[string]int{}, outcomes: map[withdrawal.Status]int{}}
	for _, seed := range seeds {
		t.Run(fmt.Sprintf("seed=%d", seed), func(t *testing.T) {
			st := runSchedule(t, seed, 220)
			total.crashes += st.crashes
			total.restarts += st.restarts
			total.reorgs += st.reorgs
			total.truncations += st.truncations
			total.shorterForks += st.shorterForks
			total.deepSeeds += st.deepSeeds
			total.lowLiquiditySeeds += st.lowLiquiditySeeds
			total.reservationsReleased += st.reservationsReleased
			total.staleDeposits += st.staleDeposits
			total.drops += st.drops
			total.spikes += st.spikes
			total.bumps += st.bumps
			total.cancels += st.cancels
			total.withdrawals += st.withdrawals
			total.replays += st.replays
			total.sendFaults += st.sendFaults
			total.readFaults += st.readFaults
			total.stepErrors += st.stepErrors
			for k, v := range st.byFailpoint {
				total.byFailpoint[k] += v
			}
			for k, v := range st.outcomes {
				total.outcomes[k] += v
			}
		})
	}
	t.Logf("simulation totals over %d seeds (%d with 6 confirmations, %d with low hot-wallet liquidity): withdrawals=%d outcomes=%v crashes=%d by_failpoint=%v reorgs=%d head_regressions=%d shorter_forks=%d drops=%d fee_spikes=%d fee_bumps=%d cancels=%d idempotent_replays=%d send_faults=%d read_faults=%d step_errors_tolerated=%d reservations_released=%d stale_pending_deposits=%d",
		len(seeds), total.deepSeeds, total.lowLiquiditySeeds, total.withdrawals, total.outcomes, total.crashes, total.byFailpoint, total.reorgs, total.truncations,
		total.shorterForks, total.drops, total.spikes, total.bumps, total.cancels, total.replays, total.sendFaults, total.readFaults, total.stepErrors,
		total.reservationsReleased, total.staleDeposits)
	if len(seeds) >= 20 {
		for _, fp := range failpoint.All {
			if total.byFailpoint[fp] == 0 {
				t.Errorf("failpoint %s never fired across %d seeds; the schedule generator is not covering it", fp, len(seeds))
			}
		}
	}
}

type pendingCreate struct {
	key, user string
	amount    int64
	dest      common.Address
}

func runSchedule(t *testing.T, seed uint64, steps int) simStats {
	st := simStats{byFailpoint: map[string]int{}, outcomes: map[withdrawal.Status]int{}}
	rng := rand.New(rand.NewPCG(seed, 0x19c))
	conf, hotTokens := simVariant(seed)
	e := testenv.NewWith(t, seed, hotTokens, func(c *config.Config) { c.Chain.Confirmations = conf })
	if conf != testenv.Confirmations {
		st.deepSeeds++
	}
	if hotTokens.Cmp(big.NewInt(1_000_000_000)) < 0 {
		st.lowLiquiditySeeds++
	}
	users := []string{"u1", "u2", "u3"}
	dests := map[string][]common.Address{}
	for i, u := range users {
		e.FundUser(u, 2_000_000_000)
		for j := range 40 {
			dests[u] = append(dests[u], testenv.Addr(i*1000+j))
		}
		for _, d := range dests[u] {
			if _, err := e.App.Withdrawals.AddAllowlist(e.Ctx, "gateway", u, d, "sim"); err != nil {
				t.Fatal(err)
			}
		}
	}
	e.Clock.Advance(25 * time.Hour)
	// Flaky RPC: about 3 % of sends and 2 % of reads fail with a transient transport error.
	sendFault := func(*types.Transaction) error {
		if rng.IntN(100) < 3 {
			st.sendFaults++
			return errors.New("connection reset by peer")
		}
		return nil
	}
	readFault := func(string) error {
		if rng.IntN(100) < 2 {
			st.readFaults++
			return errors.New("503 service unavailable")
		}
		return nil
	}
	setFaults := func(on bool) {
		if on {
			e.Chain.SetSendFault(sendFault)
			e.Chain.SetReadFault(readFault)
		} else {
			e.Chain.SetSendFault(nil)
			e.Chain.SetReadFault(nil)
		}
	}
	faultsOn := true
	setFaults(true)
	nextDest := map[string]int{}
	created := map[string]pendingCreate{} // idempotency key -> request, for retries after crashes
	var keys []string

	// guarded runs f, turning a failpoint crash into a restart on the same database.
	guarded := func(what string, f func()) (crashed bool) {
		func() {
			defer func() {
				if v := recover(); v != nil {
					c, ok := failpoint.AsCrash(v)
					if !ok {
						t.Fatalf("seed %d: unexpected panic in %s: %v\n%s", seed, what, v, debug.Stack())
					}
					st.crashes++
					st.byFailpoint[c.Name]++
					crashed = true
				}
			}()
			f()
		}()
		if crashed {
			setFaults(false) // the restart itself talks to a healthy node
			e.Restart()
			setFaults(faultsOn)
			st.restarts++
		}
		return crashed
	}
	stepOK := func(name string, f func() error) {
		guarded(name, func() {
			if err := f(); err != nil {
				if faultsOn {
					st.stepErrors++ // an injected RPC failure surfaced; the next round retries
					return
				}
				t.Fatalf("seed %d: %s: %v", seed, name, err)
			}
		})
	}
	submit := func(p pendingCreate) {
		guarded("create", func() {
			resp := e.Create(p.key, p.user, p.amount, p.dest)
			if resp.Code != http.StatusCreated && resp.Code != http.StatusUnprocessableEntity {
				t.Fatalf("seed %d: create returned %d: %s", seed, resp.Code, resp.Body)
			}
			if resp.Replayed {
				st.replays++
			}
		})
	}

	for i := 0; i < steps; i++ {
		switch r := rng.IntN(100); {
		case r < 14: // new withdrawal (some above the approval threshold)
			u := users[rng.IntN(len(users))]
			if nextDest[u] >= len(dests[u]) {
				continue
			}
			amount := int64(1+rng.IntN(40)) * 1_000_000
			if rng.IntN(5) == 0 {
				amount = 600_000_000 // needs 2 of 3 approvals
			}
			p := pendingCreate{key: fmt.Sprintf("k-%d-%d", seed, i), user: u, amount: amount, dest: dests[u][nextDest[u]]}
			nextDest[u]++
			created[p.key] = p
			keys = append(keys, p.key)
			st.withdrawals++
			submit(p)
		case r < 18 && len(keys) > 0: // client retry of an earlier request (network timeout)
			submit(created[keys[rng.IntN(len(keys))]])
		case r < 30:
			stepOK("dispatch", func() error { _, err := e.App.Withdrawals.DispatchOnce(e.Ctx); return err })
		case r < 48:
			stepOK("track", func() error { _, _, err := e.App.TrackRound(e.Ctx, false); return err })
		case r < 52:
			stepOK("scan", func() error { return e.App.Scanner.ScanOnce(e.Ctx) })
		case r < 54:
			stepOK("sweep", func() error { return e.App.Sweeper.SweepOnce(e.Ctx) })
		case r < 72:
			e.Chain.Mine()
		case r < 75: // base-fee spike for the next block
			e.Chain.SetNextBaseFee(big.NewInt(int64(20+rng.IntN(200)) * testenv.Gwei))
			e.Chain.Mine()
			st.spikes++
		case r < 78:
			if pool := e.Chain.PoolHashes(); len(pool) > 0 {
				e.Chain.Drop(pool[rng.IntN(len(pool))])
				st.drops++
			}
		case r < 81: // reorg shallower than the confirmation depth; sometimes the head goes backwards
			// The guarantee covers reorgs shallower than the confirmation depth, measured from the
			// highest head the engine may have seen: after the head went back `lag` blocks, a
			// further reorg or truncation may only touch what is still unconfirmed. (Deeper
			// reorgs are detected and flagged for an operator; see TestScenarioDeepReorgIsFlagged.)
			head, highest := e.Chain.Height()
			maxDepth := int(conf) - 1 - int(highest-head)
			if maxDepth < 1 {
				continue
			}
			switch k := rng.IntN(8); {
			case k < 2: // the head goes backwards
				e.Chain.Truncate(1 + rng.IntN(maxDepth))
				st.truncations++
			case k < 4: // a shorter fork that also replaces blocks below its head, sometimes seen mid-way
				e.Chain.Reorg(1+rng.IntN(maxDepth), rng.IntN(2) == 0)
				if rng.IntN(2) == 0 {
					stepOK("scan", func() error { return e.App.Scanner.ScanOnce(e.Ctx) })
				}
				e.Chain.Truncate(1 + rng.IntN(maxDepth))
				st.shorterForks++
			default:
				e.Chain.Reorg(1+rng.IntN(maxDepth), rng.IntN(2) == 0)
				st.reorgs++
			}
		case r < 85: // arm a failpoint; the next step that reaches it crashes the "process"
			e.FP.Arm(failpoint.All[rng.IntN(len(failpoint.All))])
		case r < 90: // an approver decides on a large withdrawal
			approveRandom(t, e, rng)
		case r < 92:
			if cancelRandom(t, e, rng) {
				st.cancels++
			}
		case r < 95: // another customer deposit
			u := users[rng.IntN(len(users))]
			a, _ := e.App.Deriver.Address(u)
			e.Chain.ExternalTransfer(testenv.TokenAddr, common.HexToAddress("0xC0FFEE0000000000000000000000000000000000"), a, big.NewInt(int64(1+rng.IntN(100))*1_000_000))
		default:
			e.Clock.Advance(time.Duration(1+rng.IntN(30)) * time.Second)
		}
	}

	// Drain: no more faults. Approve everything waiting, retry every request once more (a
	// client whose connection died on after_request_commit retries), then run to quiescence.
	e.FP.Disarm()
	faultsOn = false
	setFaults(false)
	for _, k := range keys {
		submit(created[k])
	}
	quiet := func() bool {
		all, err := withdrawal.All(e.Ctx, e.App.DB)
		if err != nil {
			t.Fatal(err)
		}
		for _, w := range all {
			if !w.Status.Terminal() {
				return false
			}
		}
		live, err := txmgr.LiveSlots(e.Ctx, e.App.DB)
		if err != nil {
			t.Fatal(err)
		}
		return len(live) == 0
	}
	for i := 0; i < 600 && !quiet(); i++ {
		approveAll(t, e)
		e.Step()
		e.Chain.Mine()
		e.Clock.Advance(2 * time.Second)
	}
	if !quiet() {
		dumpState(t, e)
		t.Fatalf("seed %d: system did not quiesce", seed)
	}
	// Settle deposits and sweeps as well, then finish with a few empty rounds.
	for range 3 * conf {
		e.Step()
		e.Chain.Mine()
		e.Clock.Advance(2 * time.Second)
	}
	for range conf + 1 {
		e.Step()
		e.Chain.Mine()
	}
	assertSimInvariants(t, e, seed, &st)
	st.reservationsReleased = int(testutil.ToFloat64(e.App.Metrics.ReservationsReleased))
	st.staleDeposits = int(testutil.ToFloat64(e.App.Metrics.DepositsStale))
	return st
}

// byDestination returns every withdrawal ordered by destination. withdrawal.All orders by
// creation time and then by the random ID, and the fake clock gives many withdrawals the same
// creation time; every destination is used once per schedule, so this order is a function of
// the seed alone and random picks from it replay exactly.
func byDestination(t *testing.T, e *testenv.Env) []withdrawal.Withdrawal {
	all, err := withdrawal.All(e.Ctx, e.App.DB)
	if err != nil {
		t.Fatal(err)
	}
	slices.SortFunc(all, func(a, b withdrawal.Withdrawal) int { return a.Destination.Cmp(b.Destination) })
	return all
}

func approveRandom(t *testing.T, e *testenv.Env, rng *rand.Rand) {
	all := byDestination(t, e)
	var waiting []withdrawal.Withdrawal
	for _, w := range all {
		if w.Status == withdrawal.Requested && w.ApprovalsRequired > 0 {
			waiting = append(waiting, w)
		}
	}
	if len(waiting) == 0 {
		return
	}
	w := waiting[rng.IntN(len(waiting))]
	decision := "approve"
	if rng.IntN(8) == 0 {
		decision = "reject"
	}
	_, _ = e.App.Withdrawals.Approve(e.Ctx, w.ID, fmt.Sprintf("approver-%d", rng.IntN(3)), decision)
}

func approveAll(t *testing.T, e *testenv.Env) {
	all, err := withdrawal.All(e.Ctx, e.App.DB)
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range all {
		if w.Status == withdrawal.Requested && w.ApprovalsRequired > 0 {
			for i := range 3 {
				_, _ = e.App.Withdrawals.Approve(e.Ctx, w.ID, fmt.Sprintf("approver-%d", i), "approve")
			}
		}
	}
}

func cancelRandom(t *testing.T, e *testenv.Env, rng *rand.Rand) bool {
	all := byDestination(t, e)
	var live []withdrawal.Withdrawal
	for _, w := range all {
		if !w.Status.Terminal() {
			live = append(live, w)
		}
	}
	if len(live) == 0 {
		return false
	}
	_, err := e.App.Withdrawals.Cancel(e.Ctx, live[rng.IntN(len(live))].ID, "approver-0")
	return err == nil
}

func dumpState(t *testing.T, e *testenv.Env) {
	all, _ := withdrawal.All(e.Ctx, e.App.DB)
	for _, w := range all {
		if !w.Status.Terminal() {
			nonce := "none"
			if w.Nonce != nil {
				nonce = fmt.Sprint(*w.Nonce)
			}
			t.Logf("stuck withdrawal %s status=%s nonce=%s", w.ID, w.Status, nonce)
		}
	}
	live, _ := txmgr.LiveSlots(e.Ctx, e.App.DB)
	for _, s := range live {
		atts, _ := txmgr.Attempts(e.Ctx, e.App.DB, s.Nonce)
		t.Logf("live slot %+v attempts=%d", s, len(atts))
		for _, a := range atts {
			t.Logf("   attempt %s kind=%s status=%s fees=%s", a.Hash, a.Kind, a.Status, a.Fees)
		}
	}
	h, _ := e.Chain.Head(e.Ctx)
	n, _ := e.Chain.NonceAt(e.Ctx, e.Hot)
	t.Logf("head=%d chain nonce=%d pool=%d", h.Number, n, len(e.Chain.PoolHashes()))
}

// assertSimInvariants checks the properties listed in the README against chain ground truth
// (P1 to P7; P7 compares the deposit records with the chain's Transfer logs).
func assertSimInvariants(t *testing.T, e *testenv.Env, seed uint64, st *simStats) {
	t.Helper()
	all, err := withdrawal.All(e.Ctx, e.App.DB)
	if err != nil {
		t.Fatal(err)
	}
	transfers := e.Chain.Transfers(testenv.TokenAddr, e.Hot)
	confirmedPerUser := map[string]*big.Int{}
	for _, w := range all {
		st.outcomes[w.Status]++
		n := 0
		for _, tr := range transfers {
			if tr.To == w.Destination {
				n++
				if tr.Amount.Cmp(w.Amount) != 0 {
					t.Fatalf("seed %d: %s transfer amount %s != %s", seed, w.ID, tr.Amount, w.Amount)
				}
			}
		}
		// P1: exactly one on-chain transfer per confirmed withdrawal, none for the others.
		want := 0
		if w.Status == withdrawal.Confirmed {
			want = 1
			if confirmedPerUser[w.AccountID] == nil {
				confirmedPerUser[w.AccountID] = new(big.Int)
			}
			confirmedPerUser[w.AccountID].Add(confirmedPerUser[w.AccountID], w.Amount)
		}
		if n != want {
			t.Fatalf("seed %d: withdrawal %s is %s but has %d on-chain transfers", seed, w.ID, w.Status, n)
		}
		// P2: every terminal state is backed by the chain (confirmed/replaced/reverted need a final slot).
		if w.Status == withdrawal.Confirmed || w.Status == withdrawal.Replaced {
			if w.Nonce == nil {
				t.Fatalf("seed %d: %s is %s without a nonce", seed, w.ID, w.Status)
			}
			s, err := txmgr.LoadSlot(e.Ctx, e.App.DB, *w.Nonce)
			if err != nil || s.State != txmgr.StateFinal {
				t.Fatalf("seed %d: %s is %s but its slot is %+v (%v)", seed, w.ID, w.Status, s, err)
			}
		}
	}
	// P3: every recorded transition is an edge of the model, and each history is a path.
	trs, err := withdrawal.Transitions(e.Ctx, e.App.DB)
	if err != nil {
		t.Fatal(err)
	}
	last := map[string]withdrawal.Status{}
	for _, tr := range trs {
		if !withdrawal.CanTransition(tr.From, tr.To) {
			t.Fatalf("seed %d: illegal transition %s -> %s on %s", seed, tr.From, tr.To, tr.WithdrawalID)
		}
		if prev, ok := last[tr.WithdrawalID]; (ok && prev != tr.From) || (!ok && tr.From != withdrawal.Created) {
			t.Fatalf("seed %d: broken history for %s at seq %d", seed, tr.WithdrawalID, tr.Seq)
		}
		last[tr.WithdrawalID] = tr.To
	}
	for _, w := range all {
		if last[w.ID] != w.Status {
			t.Fatalf("seed %d: %s status %s but its history ends at %s", seed, w.ID, w.Status, last[w.ID])
		}
	}
	// P4: nothing left pending or in flight; the ledger and chain agree.
	snap, err := ledger.Balances(e.Ctx, e.App.DB)
	if err != nil {
		t.Fatal(err)
	}
	for _, acct := range []string{ledger.WithdrawalsPending, ledger.InFlight} {
		for _, a := range []string{testenv.Asset, "ETH"} {
			if v := snap.Get(acct, a); v.Sign() != 0 {
				t.Fatalf("seed %d: %s %s = %s at quiescence", seed, acct, a, v)
			}
		}
	}
	e.CheckInvariants()
	// P7: the deposit records match the chain: every canonical transfer to a deposit address at
	// the confirmation depth is credited exactly once, and nothing at that depth is still pending.
	e.CheckDeposits()
	// P5: each customer's balance equals credited deposits minus confirmed withdrawals.
	credited := map[string]*big.Int{}
	rows, err := e.App.DB.QueryContext(e.Ctx, `SELECT account_id, amount FROM deposits WHERE status = 'credited'`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var acct, amt string
		if err := rows.Scan(&acct, &amt); err != nil {
			t.Fatal(err)
		}
		v, _ := new(big.Int).SetString(amt, 10)
		if credited[acct] == nil {
			credited[acct] = new(big.Int)
		}
		credited[acct].Add(credited[acct], v)
	}
	rows.Close()
	for acct, dep := range credited {
		want := new(big.Int).Set(dep)
		if c := confirmedPerUser[acct]; c != nil {
			want.Sub(want, c)
		}
		got, err := ledger.Available(e.Ctx, e.App.DB, acct, testenv.Asset)
		if err != nil {
			t.Fatal(err)
		}
		if got.Cmp(want) != 0 {
			t.Fatalf("seed %d: %s available %s, expected deposits - confirmed = %s", seed, acct, got, want)
		}
	}
	// P6: the audit log ships completely and its hash chain verifies.
	if _, err := e.App.Audit.Ship(e.Ctx); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(e.Cfg.Audit.Path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	// Every line must be the database's event with the same sequence number, in order, and the
	// file must end at the database's last event.
	if err := e.App.DB.ReadTx(e.Ctx, func(q store.Querier) error {
		_, err := audit.VerifyAgainst(e.Ctx, f, q)
		return err
	}); err != nil {
		t.Fatalf("seed %d: audit log: %v", seed, err)
	}
	var bumps int
	_ = e.App.DB.QueryRowContext(e.Ctx, `SELECT COUNT(*) FROM tx_attempts WHERE kind != 'original'`).Scan(&bumps)
	st.bumps += bumps
}
