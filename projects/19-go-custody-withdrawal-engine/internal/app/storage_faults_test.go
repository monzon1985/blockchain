// SPDX-License-Identifier: MIT

package app_test

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/api"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/testenv"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/testenv/faultdb"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/txmgr"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/withdrawal"
)

// storageSeed fixes the hot-wallet key and therefore every hash of the workload.
const storageSeed = 77

// TestStorageFaultInjection fails every database operation of a full engine workload, one at a
// time, and checks that the engine converges to a correct state anyway.
//
// The workload drives the real HTTP API and engine loops through deposits to counterfactual
// addresses, crediting, a batch sweep, three withdrawals (one needing 2-of-3 approvals, one
// cancelled after broadcast), allowlist changes, a base-fee spike that forces a replacement, a
// dropped transaction, a reorg and a reconciliation. A reference run counts its BEGIN,
// statement and COMMIT operations; then, for each index k, a fresh engine replays the workload
// with operation k failing:
//
//   - "fail": the operation is not applied (a failed COMMIT rolls back);
//   - "ambiguous": a COMMIT is applied but reported as failed, the outcome-unknown case.
//
// Every error the engine or the API surfaces must be that one injected failure, at the step
// where it fired: a 500 from the API, an error from an engine loop. Clients then retry the way
// a gateway does (same Idempotency-Key), and after the system drains the test checks the
// simulation's global properties against chain ground truth: exactly one on-chain transfer per
// confirmed withdrawal, legal state histories, nothing stuck in withdrawals_pending or
// in_flight, customer balances equal to deposits minus withdrawals, reconciliation to the wei,
// no nonce gaps and a verifying audit hash chain.
//
// The default run tests every 4th operation (every 16th with -short) to keep `go test ./...`
// fast; CUSTODY_FAULT_STRIDE=1 tests every one of them, which CI does in a dedicated step.
func TestStorageFaultInjection(t *testing.T) {
	var ops []faultdb.Op
	t.Run("reference", func(t *testing.T) {
		in := runStorageWorkload(t, 0, faultdb.Fail)
		if _, fired := in.Fired(); fired {
			t.Fatal("the reference run must not inject anything")
		}
		ops = in.Ops()
	})
	if len(ops) == 0 {
		t.Fatal("the reference run counted no database operations")
	}
	stride := 4
	if testing.Short() {
		stride = 16
	}
	if v, err := strconv.Atoi(os.Getenv("CUSTODY_FAULT_STRIDE")); err == nil && v > 0 {
		stride = v
	}
	kinds := map[string]int{}
	var commits []int
	for _, op := range ops {
		kinds[op.Kind]++
		if op.Kind == faultdb.KindCommit {
			commits = append(commits, op.Index)
		}
	}
	t.Logf("workload: %d database operations %v; testing every %d", len(ops), kinds, stride)

	sem := make(chan struct{}, 4) // CPU budget: four engines at a time
	for k := 1; k <= len(ops); k += stride {
		t.Run(fmt.Sprintf("fail/%04d_%s", k, ops[k-1].Kind), func(t *testing.T) {
			t.Parallel()
			sem <- struct{}{}
			defer func() { <-sem }()
			in := runStorageWorkload(t, k, faultdb.Fail)
			if _, fired := in.Fired(); !fired {
				// The run diverged from the reference before reaching k (map order, for
				// example); it still had to pass every check, but say so.
				t.Logf("operation %d was not reached in this run (%d operations)", k, len(in.Ops()))
			}
		})
	}
	for i := 0; i < len(commits); i += stride {
		k := commits[i]
		t.Run(fmt.Sprintf("ambiguous/%04d_commit", k), func(t *testing.T) {
			t.Parallel()
			sem <- struct{}{}
			defer func() { <-sem }()
			runStorageWorkload(t, k, faultdb.AmbiguousCommit)
		})
	}
}

// faultRun is one execution of the workload.
type faultRun struct {
	t  *testing.T
	e  *testenv.Env
	in *faultdb.Injector
	h  http.Handler
}

// fired reports whether the injected failure has happened yet.
func (r *faultRun) fired() bool {
	_, ok := r.in.Fired()
	return ok
}

// tolerate accepts err only if it is the injected failure and it fired during this step.
func (r *faultRun) tolerate(step string, firedBefore bool, err error) {
	r.t.Helper()
	if err == nil {
		return
	}
	if !errors.Is(err, faultdb.ErrInjected) || firedBefore || !r.fired() {
		op, _ := r.in.Fired()
		r.t.Fatalf("%s: unexpected error %v (injected: %v at %s)", step, err, r.fired(), op)
	}
}

// engine runs one engine operation under the tolerate rule.
func (r *faultRun) engine(step string, f func() error) {
	r.t.Helper()
	before := r.fired()
	r.tolerate(step, before, f())
}

// call sends one API request. A 500 is accepted only as the visible effect of the injected
// failure, and the client then retries once, as a gateway would after a server error.
func (r *faultRun) call(method, path, token string, body any, key string, ok ...int) (int, []byte) {
	r.t.Helper()
	for attempt := 0; ; attempt++ {
		before := r.fired()
		code, out := r.do(method, path, token, body, key)
		if code == http.StatusInternalServerError {
			if before || !r.fired() || attempt > 0 {
				r.t.Fatalf("%s %s: 500 without an injected failure behind it: %s", method, path, out)
			}
			continue
		}
		for _, c := range ok {
			if code == c {
				return code, out
			}
		}
		r.t.Fatalf("%s %s: %d %s (accepted: %v)", method, path, code, out, ok)
	}
}

func (r *faultRun) do(method, path, token string, body any, key string) (int, []byte) {
	var raw []byte
	if body != nil {
		raw, _ = json.Marshal(body)
	}
	req := httptest.NewRequest(method, path, bytes.NewReader(raw))
	req.Header.Set("Authorization", "Bearer "+token)
	if key != "" {
		req.Header.Set("Idempotency-Key", key)
	}
	rec := httptest.NewRecorder()
	r.h.ServeHTTP(rec, req)
	return rec.Code, rec.Body.Bytes()
}

const (
	gatewayToken   = "gateway-token"
	approverAToken = "approver-a-token"
	approverBToken = "approver-b-token"
)

type faultWithdrawal struct {
	key, user string
	amount    int64
	dest      common.Address
}

// runStorageWorkload runs the workload with operation k failing in mode m (k = 0: no failure)
// and checks the outcome. It returns the injector so the caller can read the operation log.
func runStorageWorkload(t *testing.T, k int, m faultdb.Mode) *faultdb.Injector {
	in := &faultdb.Injector{}
	e := testenv.NewWithConn(t, storageSeed, big.NewInt(1_000_000_000_000), nil, in.Wrap)
	r := &faultRun{t: t, e: e, in: in, h: api.NewRouter(e.App)}

	// Setup, not counted: two funded customers with active allowlists.
	e.FundUser("alice", 2_000_000_000)
	e.FundUser("bob", 2_000_000_000)
	e.Allowlist("alice", testenv.Addr(1), testenv.Addr(2))
	e.Allowlist("bob", testenv.Addr(3))

	in.FailAt(k, m)
	in.Start()

	// A new customer gets a counterfactual deposit address and funds it.
	_, body := r.call("POST", "/v1/accounts/carol/deposit-address", gatewayToken, nil, "", http.StatusOK)
	var dep struct{ Address string }
	if err := json.Unmarshal(body, &dep); err != nil || !common.IsHexAddress(dep.Address) {
		t.Fatalf("deposit address: %s", body)
	}
	e.Chain.ExternalTransfer(testenv.TokenAddr, common.HexToAddress("0xC0FFEE0000000000000000000000000000000000"),
		common.HexToAddress(dep.Address), big.NewInt(300_000_000))

	// Allowlist churn: add (cool-down starts), list, remove.
	extra := testenv.Addr(4).Hex()
	r.call("POST", "/v1/accounts/alice/allowlist", gatewayToken, map[string]string{"address": extra, "label": "new"}, "", http.StatusCreated)
	r.call("GET", "/v1/accounts/alice/allowlist", gatewayToken, nil, "", http.StatusOK)
	// After an ambiguous commit the retry finds the entry already gone.
	r.call("DELETE", "/v1/accounts/alice/allowlist/"+extra, gatewayToken, nil, "", http.StatusNoContent, http.StatusNotFound)

	ws := []faultWithdrawal{
		{key: "w-small", user: "alice", amount: 5_000_000, dest: testenv.Addr(1)},
		{key: "w-large", user: "bob", amount: 600_000_000, dest: testenv.Addr(3)}, // needs 2 of 3 approvals
		{key: "w-cancel", user: "alice", amount: 7_000_000, dest: testenv.Addr(2)},
	}
	ids := map[string]string{}
	create := func(w faultWithdrawal) {
		req := withdrawal.CreateRequest{AccountID: w.user, Asset: testenv.Asset, Amount: fmt.Sprint(w.amount), Destination: w.dest.Hex()}
		_, out := r.call("POST", "/v1/withdrawals", gatewayToken, req, w.key, http.StatusCreated)
		var v withdrawal.View
		if err := json.Unmarshal(out, &v); err != nil || v.ID == "" {
			t.Fatalf("create %s: %s", w.key, out)
		}
		if prev, seen := ids[w.key]; seen && prev != v.ID {
			t.Fatalf("retry of %s returned %s, first attempt %s", w.key, v.ID, prev)
		}
		ids[w.key] = v.ID
	}
	for _, w := range ws {
		create(w)
	}

	// The harness's own reads are not part of the workload: counting pauses around them.
	status := func(key string) withdrawal.Status {
		in.Stop()
		defer in.Start()
		return e.Status(ids[key])
	}
	sweepPending := func() bool {
		in.Stop()
		defer in.Start()
		var n int
		if err := e.App.DB.QueryRowContext(e.Ctx, `SELECT COUNT(*) FROM sweeps WHERE status = 'pending'`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n > 0
	}
	// Chain events fire on observed state rather than at fixed steps, so they still hit their
	// target when an injected failure shifts the pipeline by a round.
	var cancelled, spiked, reorged, dropped bool
	for i := 0; i < 24; i++ {
		r.engine(fmt.Sprintf("step %d", i), func() error { return e.App.Step(e.Ctx) })
		if i == 0 { // two approvers release the large withdrawal; a retry after an ambiguous commit gets 409
			for _, tok := range []string{approverAToken, approverBToken} {
				r.call("POST", "/v1/withdrawals/"+ids["w-large"]+"/approvals", tok, map[string]string{"decision": "approve"}, "",
					http.StatusOK, http.StatusConflict)
			}
		}
		mine := true
		switch {
		case !cancelled && status("w-cancel") == withdrawal.Broadcast:
			// Cancel while the transfer sits in the pool; no block until the cancellation is out.
			r.call("POST", "/v1/withdrawals/"+ids["w-cancel"]+"/cancel", approverAToken, nil, "", http.StatusAccepted)
			cancelled, mine = true, false
		case !spiked && status("w-large") == withdrawal.Broadcast:
			// Base-fee spike: everything in the pool is now underpriced and evicted.
			e.Chain.SetNextBaseFee(big.NewInt(300 * testenv.Gwei))
			spiked = true
		case spiked && !reorged && status("w-large") == withdrawal.Mined:
			// The block holding the (replaced) transfer is reorged out; it lands in a new block.
			e.Chain.Reorg(1, true)
			reorged, mine = true, false
		case !dropped && sweepPending():
			if pool := e.Chain.PoolHashes(); len(pool) > 0 {
				dropped = e.Chain.Drop(pool[0])
			}
		}
		switch i {
		case 12:
			r.engine("reconcile", func() error { _, _, err := e.App.TrackRound(e.Ctx, true); return err })
			r.call("GET", "/v1/reconciliation", gatewayToken, nil, "", http.StatusOK)
		case 14: // read models
			r.call("GET", "/v1/withdrawals/"+ids["w-small"], gatewayToken, nil, "", http.StatusOK)
			for _, path := range []string{"balances", "deposits", "withdrawals"} {
				r.call("GET", "/v1/accounts/alice/"+path, gatewayToken, nil, "", http.StatusOK)
			}
			r.call("GET", "/v1/accounts/carol/deposit-address", gatewayToken, nil, "", http.StatusOK)
			r.call("GET", "/readyz", "", nil, "", http.StatusOK)
		}
		if mine {
			e.Chain.Mine()
		}
		e.Clock.Advance(time.Second)
	}
	in.Stop()

	// Drain without faults. The gateway retries every request once more with its key: each one
	// must replay the withdrawal it created, never create another.
	for _, w := range ws {
		create(w)
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
	for i := 0; i < 200 && !quiet(); i++ {
		e.Step()
		e.Chain.Mine()
		e.Clock.Advance(2 * time.Second)
	}
	if !quiet() {
		dumpState(t, e)
		op, _ := in.Fired()
		t.Fatalf("did not quiesce after failing %s (%s)", op, m)
	}
	for range 3 * testenv.Confirmations {
		e.Step()
		e.Chain.Mine()
		e.Clock.Advance(2 * time.Second)
	}

	// Outcomes the fault must not change: the plain and the approved withdrawals are paid; the
	// cancelled one ended either way; carol's deposit is credited and swept.
	for _, key := range []string{"w-small", "w-large"} {
		if s := e.Status(ids[key]); s != withdrawal.Confirmed {
			t.Fatalf("%s ended %s", key, s)
		}
	}
	if s := e.Status(ids["w-cancel"]); !s.Terminal() {
		t.Fatalf("w-cancel ended %s", s)
	}
	if got, err := ledger.Available(e.Ctx, e.App.DB, "carol", testenv.Asset); err != nil || got.Cmp(big.NewInt(300_000_000)) != 0 {
		t.Fatalf("carol available %s (%v), want 300000000", got, err)
	}
	all, err := withdrawal.All(e.Ctx, e.App.DB)
	if err != nil || len(all) != len(ws) {
		t.Fatalf("%d withdrawals in the database, want %d (%v)", len(all), len(ws), err)
	}
	st := simStats{byFailpoint: map[string]int{}, outcomes: map[withdrawal.Status]int{}}
	assertSimInvariants(t, e, storageSeed, &st)
	if k == 0 {
		// The reference run must reach the paths the faults are injected into; otherwise a
		// green sweep would prove less than it claims.
		for what, q := range map[string]string{
			"a fee-bumped replacement":      `SELECT COUNT(*) FROM tx_attempts WHERE kind = 'bump'`,
			"a same-nonce cancellation":     `SELECT COUNT(*) FROM tx_attempts WHERE kind = 'cancel'`,
			"an inclusion reorged out":      `SELECT COUNT(*) FROM audit_events WHERE type = 'tx.reorged'`,
			"a batch sweep":                 `SELECT COUNT(*) FROM sweeps WHERE status = 'done'`,
			"a 2-of-3 approval":             `SELECT COUNT(*) FROM approvals WHERE decision = 'approve'`,
			"a removed allowlist entry":     `SELECT COUNT(*) FROM audit_events WHERE type = 'allowlist.removed'`,
			"a credited counterfactual one": `SELECT COUNT(*) FROM deposits WHERE account_id = 'carol' AND status = 'credited'`,
		} {
			var n int
			if err := e.App.DB.QueryRowContext(e.Ctx, q).Scan(&n); err != nil || n == 0 {
				t.Errorf("the reference workload never produced %s (%d, %v)", what, n, err)
			}
		}
	}
	return in
}
