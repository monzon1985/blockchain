// SPDX-License-Identifier: MIT

package app_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"math/rand/v2"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/api"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/config"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/testenv"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/txmgr"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/withdrawal"
)

// Every other engine test drives the loops one after another through App.Step. Production runs
// them concurrently (App.Run), next to the HTTP handlers (App.Serve). The tests in this file run
// them that way, and under `go test -race` they are what lets the race detector see the real
// interleavings.

// TestReconciliationUnderConcurrentWrites: reconciliation used to read the ledger's postings and
// its cached balances in two separate queries; an API write committed in between was reported as
// a cache mismatch (300 out of 300 runs in the review's reproduction). Both reads, and the
// balances behind the per-asset lines, now come from one read snapshot.
func TestReconciliationUnderConcurrentWrites(t *testing.T) {
	e := testenv.Quiet(t, 40)
	e.FundUser("alice", 1_000_000_000)
	e.Allowlist("alice", testenv.Addr(1))
	stop := make(chan struct{})
	var created atomic.Int64
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		body := []byte(fmt.Sprintf(`{"account_id":"alice","asset":"tUSD","amount":"1","destination":%q}`, testenv.Addr(1).Hex()))
		for i := 0; i < 400; i++ {
			select {
			case <-stop:
				return
			default:
			}
			if resp, err := e.App.Withdrawals.Create(e.Ctx, "gateway", fmt.Sprintf("k%d", i), body); err == nil && resp.Code == http.StatusCreated {
				created.Add(1)
			}
		}
	}()
	runs, mismatches := 0, 0
	var example []string
	for range 200 {
		_, rep, err := e.App.TrackRound(e.Ctx, true)
		if err != nil || rep == nil {
			continue
		}
		runs++
		if !rep.OK {
			mismatches++
			example = rep.LedgerIssues
		}
	}
	close(stop)
	wg.Wait()
	if runs < 150 || created.Load() < 50 {
		t.Fatalf("not enough overlap to mean anything: %d reconciliations, %d concurrent writes", runs, created.Load())
	}
	if mismatches > 0 {
		t.Fatalf("%d of %d reconciliations reported a mismatch while the API was writing; e.g. %v", mismatches, runs, example)
	}
	e.Reconcile()
}

// TestServeUnderConcurrentLoad runs the production loops (App.Serve: HTTP API, dispatcher,
// tracker, scanner, sweeper, audit shipper) against a chain that mines on its own, while clients
// create, retry, approve and cancel withdrawals, manage allowlists, read balances and register
// deposit addresses, and customers deposit. Every reconciliation that ran meanwhile must have
// been OK, and after draining, every global property of the simulator must hold.
func TestServeUnderConcurrentLoad(t *testing.T) {
	e := testenv.NewWith(t, 41, big.NewInt(1_000_000_000_000), func(c *config.Config) {
		c.Chain.PollInterval.Duration = 5 * time.Millisecond
		c.Deposits.ScanInterval.Duration = 5 * time.Millisecond
		c.Deposits.SweepInterval.Duration = 25 * time.Millisecond
		c.Audit.ShipInterval.Duration = 25 * time.Millisecond
		c.Reconcile.EveryRounds = 1
		c.Policy.AllowlistCooldown.Duration = 0
	})
	users := []string{"cu0", "cu1", "cu2", "cu3"}
	for _, u := range users {
		e.FundUser(u, 3_000_000_000)
	}
	ctx, cancel := context.WithCancel(e.Ctx)
	defer cancel()
	addrFile := filepath.Join(t.TempDir(), "addr.txt")
	served := make(chan error, 1)
	go func() { served <- e.App.Serve(ctx, api.NewRouter(e.App), "127.0.0.1:0", addrFile) }()
	var base string
	for deadline := time.Now().Add(10 * time.Second); base == "" && time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if b, err := os.ReadFile(addrFile); err == nil && len(b) > 0 {
			base = "http://" + string(b)
		}
	}
	if base == "" {
		t.Fatal("server did not start")
	}

	// Background world: blocks every few milliseconds, time passing (outbox backoffs elapse),
	// and customer deposits to the funded accounts' forwarders.
	world, stopWorld := context.WithCancel(context.Background())
	var bg sync.WaitGroup
	every := func(d time.Duration, f func()) {
		bg.Add(1)
		go func() {
			defer bg.Done()
			tk := time.NewTicker(d)
			defer tk.Stop()
			for {
				select {
				case <-world.Done():
					return
				case <-tk.C:
					f()
				}
			}
		}()
	}
	every(3*time.Millisecond, func() { e.Chain.Mine() })
	every(2*time.Millisecond, func() { e.Clock.Advance(100 * time.Millisecond) })
	var depositSeq atomic.Int64
	every(7*time.Millisecond, func() {
		i := depositSeq.Add(1)
		a, _ := e.App.Deriver.Address(users[int(i)%len(users)])
		e.Chain.ExternalTransfer(testenv.TokenAddr, testenv.Addr(9000), a, big.NewInt(1_000_000+i))
	})

	// Clients.
	var errsMu sync.Mutex
	var errs []string
	fail := func(format string, args ...any) {
		errsMu.Lock()
		defer errsMu.Unlock()
		if len(errs) < 20 {
			errs = append(errs, fmt.Sprintf(format, args...))
		}
	}
	client := &http.Client{Timeout: 30 * time.Second}
	call := func(method, path, token string, body any, key string) (int, []byte, http.Header) {
		var r io.Reader
		if body != nil {
			b, _ := json.Marshal(body)
			r = bytes.NewReader(b)
		}
		req, _ := http.NewRequest(method, base+path, r)
		req.Header.Set("Authorization", "Bearer "+token)
		if key != "" {
			req.Header.Set("Idempotency-Key", key)
		}
		resp, err := client.Do(req)
		if err != nil {
			fail("%s %s: %v", method, path, err)
			return 0, nil, nil
		}
		defer resp.Body.Close()
		out, _ := io.ReadAll(resp.Body)
		if resp.StatusCode >= 500 {
			fail("%s %s: %d %s", method, path, resp.StatusCode, out)
		}
		return resp.StatusCode, out, resp.Header
	}
	const gateway, approverA, approverB = "gateway-token", "approver-a-token", "approver-b-token"
	var created atomic.Int64
	mismatchesBefore := testutil.ToFloat64(e.App.Metrics.ReconciliationRuns.WithLabelValues("mismatch"))
	okBefore := testutil.ToFloat64(e.App.Metrics.ReconciliationRuns.WithLabelValues("ok"))
	stopLoad := make(chan struct{})
	var load sync.WaitGroup
	for w, u := range users {
		load.Add(1)
		go func() {
			defer load.Done()
			rng := rand.New(rand.NewPCG(uint64(w), 0x41))
			type sent struct {
				key, id string
				req     withdrawal.CreateRequest
			}
			var mine []sent
			for i := 0; ; i++ {
				select {
				case <-stopLoad:
					return
				default:
				}
				if len(mine) >= 50 { // enough withdrawals; keep reading while the loops catch up
					call("GET", "/v1/accounts/"+u+"/balances", gateway, nil, "")
					call("GET", "/v1/reconciliation", gateway, nil, "")
					time.Sleep(2 * time.Millisecond)
					continue
				}
				dest := testenv.Addr(100_000*(w+1) + i) // one destination per withdrawal (P1 counts transfers by destination)
				if code, out, _ := call("POST", "/v1/accounts/"+u+"/allowlist", gateway, map[string]string{"address": dest.Hex()}, ""); code != http.StatusCreated {
					fail("allowlist %s: %d %s", u, code, out)
					continue
				}
				amount := int64(1+rng.IntN(5)) * 1_000_000
				large := rng.IntN(10) == 0
				if large {
					amount = 600_000_000 // needs 2 of 3 approvals
				}
				key := fmt.Sprintf("%s-%d", u, i)
				req := withdrawal.CreateRequest{AccountID: u, Asset: testenv.Asset, Amount: fmt.Sprint(amount), Destination: dest.Hex()}
				code, out, _ := call("POST", "/v1/withdrawals", gateway, req, key)
				if code == http.StatusUnprocessableEntity {
					continue // policy (balance or velocity); fine under load
				}
				var v withdrawal.View
				if code != http.StatusCreated || json.Unmarshal(out, &v) != nil || v.ID == "" {
					fail("create %s: %d %s", key, code, out)
					continue
				}
				created.Add(1)
				mine = append(mine, sent{key, v.ID, req})
				if large {
					call("POST", "/v1/withdrawals/"+v.ID+"/approvals", approverA, map[string]string{"decision": "approve"}, "")
					call("POST", "/v1/withdrawals/"+v.ID+"/approvals", approverB, map[string]string{"decision": "approve"}, "")
				}
				switch r := rng.IntN(10); {
				case r < 2: // a gateway retry of an earlier request
					old := mine[rng.IntN(len(mine))]
					_, out, h := call("POST", "/v1/withdrawals", gateway, old.req, old.key)
					var rv withdrawal.View
					if json.Unmarshal(out, &rv) != nil || rv.ID != old.id || h.Get("Idempotent-Replayed") != "true" {
						fail("retry of %s returned %s (replayed %q), want %s", old.key, rv.ID, h.Get("Idempotent-Replayed"), old.id)
					}
				case r < 3:
					call("POST", "/v1/withdrawals/"+mine[rng.IntN(len(mine))].id+"/cancel", approverA, nil, "")
				case r < 5:
					call("GET", "/v1/accounts/"+u+"/balances", gateway, nil, "")
					call("GET", "/v1/withdrawals/"+v.ID, gateway, nil, "")
				case r < 6:
					call("POST", fmt.Sprintf("/v1/accounts/%s-new-%d/deposit-address", u, i), gateway, nil, "")
				default:
					call("GET", "/v1/reconciliation", gateway, nil, "")
				}
			}
		}()
	}
	reconRuns := func() float64 {
		return testutil.ToFloat64(e.App.Metrics.ReconciliationRuns.WithLabelValues("ok")) +
			testutil.ToFloat64(e.App.Metrics.ReconciliationRuns.WithLabelValues("mismatch")) - okBefore - mismatchesBefore
	}
	// Generous deadlines: under the race detector everything runs several times slower.
	for deadline := time.Now().Add(3 * time.Minute); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		if created.Load() >= 150 && reconRuns() >= 40 {
			break
		}
	}
	close(stopLoad)
	load.Wait()
	runsDuringLoad := reconRuns()

	// Let the live loops settle everything that was created, still with blocks being mined.
	quiet := func() bool {
		all, err := withdrawal.All(e.Ctx, e.App.DB)
		if err != nil {
			return false
		}
		for _, w := range all {
			if !w.Status.Terminal() {
				return false
			}
		}
		live, err := txmgr.LiveSlots(e.Ctx, e.App.DB)
		return err == nil && len(live) == 0
	}
	for deadline := time.Now().Add(5 * time.Minute); !quiet() && time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
	}
	stopWorld()
	bg.Wait()
	cancel()
	select {
	case err := <-served:
		if err != nil {
			t.Fatalf("serve: %v", err)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("serve did not return after cancellation")
	}
	for _, msg := range errs {
		t.Error(msg)
	}
	if t.Failed() {
		t.FailNow()
	}
	if !quiet() {
		dumpState(t, e)
		t.Fatal("the live loops did not settle the load")
	}
	if got := testutil.ToFloat64(e.App.Metrics.ReconciliationRuns.WithLabelValues("mismatch")) - mismatchesBefore; got != 0 {
		t.Fatalf("%v reconciliations reported a mismatch under concurrent load", got)
	}
	t.Logf("under load: %d withdrawals created, %.0f reconciliations ran concurrently, all ok", created.Load(), runsDuringLoad)
	if created.Load() < 150 || runsDuringLoad < 40 {
		t.Fatalf("not enough concurrency to mean anything: %d withdrawals, %.0f reconciliations", created.Load(), runsDuringLoad)
	}
	// Settle deposits and sweeps one step at a time, then check every global property.
	for range 3 * testenv.Confirmations {
		e.Step()
		e.Chain.Mine()
		e.Clock.Advance(2 * time.Second)
	}
	for range testenv.Confirmations + 1 {
		e.Step()
		e.Chain.Mine()
	}
	st := simStats{byFailpoint: map[string]int{}, outcomes: map[withdrawal.Status]int{}}
	assertSimInvariants(t, e, 41, &st)
}
