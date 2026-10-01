// SPDX-License-Identifier: MIT

//go:build integration

package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/audit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/failpoint"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/recon"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/txmgr"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/withdrawal"
)

// custodydBin is built once for the whole package by TestMain.
var custodydBin string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "custodyd-bin-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	name := "custodyd"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	custodydBin = filepath.Join(dir, name)
	// CUSTODY_RACE=1 builds the binary with the race detector, so the chaos runs (the real
	// process, all loops and the HTTP server concurrent) are instrumented too. It needs cgo.
	// checkptr is off because modernc.org/sqlite's transpiled C trips it; races are still
	// detected, and runChaos fails on any race report in the process output.
	args, env := []string{"build", "-o", custodydBin}, "CGO_ENABLED=0"
	if os.Getenv("CUSTODY_RACE") == "1" {
		args, env = append(args, "-race", "-gcflags=all=-d=checkptr=0"), "CGO_ENABLED=1"
		fmt.Fprintln(os.Stderr, "chaos: custodyd is built with -race")
	}
	build := exec.Command("go", append(args, "./cmd/custodyd")...)
	build.Dir = ".."
	build.Env = append(os.Environ(), env)
	if out, err := build.CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "build custodyd: %v\n%s", err, out)
		os.Exit(1)
	}
	code := m.Run()
	_ = os.RemoveAll(dir)
	os.Exit(code)
}

// process is one custodyd run.
type process struct {
	cmd    *exec.Cmd
	out    *syncBuffer
	url    string
	exited chan struct{}
	err    error
}

// startCustodyd launches the binary on dir's configuration and waits for its address file.
func startCustodyd(t *testing.T, dir, failpointName string) *process {
	t.Helper()
	addrFile := filepath.Join(dir, "addr.txt")
	_ = os.Remove(addrFile)
	p := &process{out: &syncBuffer{}, exited: make(chan struct{})}
	p.cmd = exec.Command(custodydBin, "serve", "-config", filepath.Join(dir, "custody.json"))
	p.cmd.Env = append(os.Environ(), failpoint.EnvVar+"="+failpointName)
	p.cmd.Stdout, p.cmd.Stderr = p.out, p.out
	if err := p.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	go func() {
		p.err = p.cmd.Wait()
		close(p.exited)
	}()
	t.Cleanup(func() { p.kill() })
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		if b, err := os.ReadFile(addrFile); err == nil && len(b) > 0 {
			p.url = "http://" + string(b)
			return p
		}
		select {
		case <-p.exited:
			t.Fatalf("custodyd exited during startup: %v\n%s", p.err, p.out)
		case <-time.After(50 * time.Millisecond):
		}
	}
	t.Fatalf("custodyd did not start\n%s", p.out)
	return nil
}

// kill terminates the process by PID if it is still running.
func (p *process) kill() {
	select {
	case <-p.exited:
	default:
		_ = p.cmd.Process.Kill()
		<-p.exited
	}
}

// waitCrash waits for the failpoint to take the process down and checks it died the way a
// panic does (exit status 2, failpoint named on stderr).
func (p *process) waitCrash(t *testing.T, name string, timeout time.Duration) {
	t.Helper()
	select {
	case <-p.exited:
	case <-time.After(timeout):
		t.Fatalf("custodyd did not crash at %s within %s\n%s", name, timeout, p.out)
	}
	var ee *exec.ExitError
	if !errors.As(p.err, &ee) || ee.ExitCode() != failpoint.ExitCode {
		t.Fatalf("expected exit status %d, got %v\n%s", failpoint.ExitCode, p.err, p.out)
	}
	if !strings.Contains(p.out.String(), "failpoint: "+name) {
		t.Fatalf("crash output does not name %s:\n%s", name, p.out)
	}
}

func (p *process) call(t *testing.T, method, path, token string, body any, key string) (int, []byte, error) {
	t.Helper()
	var r io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		r = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, p.url+path, r)
	req.Header.Set("Authorization", "Bearer "+token)
	if key != "" {
		req.Header.Set("Idempotency-Key", key)
	}
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out, nil
}

func (p *process) mustCall(t *testing.T, method, path, token string, body any, key string) (int, []byte) {
	t.Helper()
	code, out, err := p.call(t, method, path, token, body, key)
	if err != nil {
		t.Fatalf("%s %s: %v\n%s", method, path, err, p.out)
	}
	return code, out
}

type chaosWithdrawal struct {
	key    string
	user   string
	amount int64
	dest   common.Address
	id     string
}

// TestChaos crashes custodyd at each of the seven failpoints of the withdrawal state machine,
// restarts it on the same database, and checks that every withdrawal produced exactly one
// on-chain transfer, that no request was duplicated, and that the ledger reconciles.
func TestChaos(t *testing.T) {
	sem := make(chan struct{}, 3) // at most three anvil+custodyd pairs at a time
	for _, fp := range failpoint.All {
		t.Run(fp, func(t *testing.T) {
			t.Parallel()
			sem <- struct{}{}
			defer func() { <-sem }()
			runChaos(t, fp)
		})
	}
}

func runChaos(t *testing.T, fp string) {
	a := StartAnvil(t)
	d := Deploy(t, a)
	d.Mint(a, d.Hot, big.NewInt(1_000_000_000_000)) // treasury liquidity
	dir := t.TempDir()
	WriteConfig(t, dir, a, d, nil)
	stopMiner := a.Miner(150 * time.Millisecond)
	defer stopMiner()

	p1 := startCustodyd(t, dir, fp)
	// Customers fund their deposit addresses; the engine credits them after 3 confirmations.
	users := []string{"alice", "bob"}
	for _, u := range users {
		code, body := p1.mustCall(t, "POST", "/v1/accounts/"+u+"/deposit-address", ClientToken, nil, "")
		if code != http.StatusOK {
			t.Fatalf("deposit address: %d %s", code, body)
		}
		var resp struct{ Address string }
		_ = json.Unmarshal(body, &resp)
		d.Mint(a, common.HexToAddress(resp.Address), big.NewInt(500_000_000))
	}
	for _, u := range users {
		waitFor(t, p1, 60*time.Second, func() bool {
			_, body, err := p1.call(t, "GET", "/v1/accounts/"+u+"/balances", ClientToken, nil, "")
			return err == nil && strings.Contains(string(body), `"tUSD":"500000000"`)
		})
	}
	ws := []chaosWithdrawal{
		{key: fp + "-1", user: "alice", amount: 11_000_000, dest: dest(100)},
		{key: fp + "-2", user: "bob", amount: 22_000_000, dest: dest(200)},
		{key: fp + "-3", user: "alice", amount: 33_000_000, dest: dest(300)},
	}
	for _, w := range ws {
		code, body := p1.mustCall(t, "POST", "/v1/accounts/"+w.user+"/allowlist", ClientToken, map[string]string{"address": w.dest.Hex()}, "")
		if code != http.StatusCreated {
			t.Fatalf("allowlist: %d %s", code, body)
		}
	}
	if fp == failpoint.AfterBumpBroadcast {
		// Make the first withdrawal stuck so the engine must replace it: stop the miner, let the
		// transaction reach the pool, then mine blocks whose base fee is above its fee cap.
		stopMiner()
		submitAll(t, p1, ws[:1], true)
		waitFor(t, p1, 30*time.Second, func() bool { return statusOf(t, p1, ws[0].id) == "broadcast" })
		for i := 0; i < 40; i++ {
			select {
			case <-p1.exited:
				i = 40
				continue
			default:
			}
			a.MineWithBaseFee(300 * gwei)
			time.Sleep(150 * time.Millisecond)
		}
		stopMiner = a.Miner(150 * time.Millisecond)
		defer stopMiner()
	} else {
		submitAll(t, p1, ws, fp != failpoint.AfterRequestCommit)
	}
	p1.waitCrash(t, fp, 90*time.Second)
	t.Logf("%s: first process crashed as intended", fp)

	// Restart on the same database without failpoints. Clients retry every request with the
	// same Idempotency-Key, which is what a gateway does after a timeout.
	p2 := startCustodyd(t, dir, "")
	for i := range ws {
		w := &ws[i]
		req := map[string]string{"account_id": w.user, "asset": "tUSD", "amount": fmt.Sprint(w.amount), "destination": w.dest.Hex()}
		code, body := p2.mustCall(t, "POST", "/v1/withdrawals", ClientToken, req, w.key)
		if code != http.StatusCreated {
			t.Fatalf("retry %s: %d %s", w.key, code, body)
		}
		var v withdrawal.View
		_ = json.Unmarshal(body, &v)
		if w.id != "" && v.ID != w.id {
			t.Fatalf("retry of %s returned %s, first attempt returned %s", w.key, v.ID, w.id)
		}
		w.id = v.ID
	}
	for _, w := range ws {
		waitFor(t, p2, 120*time.Second, func() bool { return statusOf(t, p2, w.id) == "confirmed" })
	}
	// Let the tracker reach a reconciliation past the last confirmation.
	var rep recon.Report
	waitFor(t, p2, 60*time.Second, func() bool {
		code, body, err := p2.call(t, "GET", "/v1/reconciliation", ClientToken, nil, "")
		if err != nil || code != http.StatusOK {
			return false
		}
		_ = json.Unmarshal(body, &rep)
		return rep.OK
	})
	stopMiner()
	p2.kill()
	for _, p := range []*process{p1, p2} {
		if strings.Contains(p.out.String(), "DATA RACE") {
			t.Fatalf("the race detector reported a data race in custodyd:\n%s", p.out)
		}
	}

	// Ground truth: the chain.
	transfers := d.TransfersFromHot(t, a)
	for _, w := range ws {
		n := 0
		for _, tr := range transfers {
			if tr.To == w.dest {
				n++
				if tr.Amount.Int64() != w.amount {
					t.Fatalf("%s: transfer of %s, want %d", w.key, tr.Amount, w.amount)
				}
			}
		}
		if n != 1 {
			t.Fatalf("%s: %d on-chain transfers to %s, want exactly 1", w.key, n, w.dest)
		}
	}
	// The database after the final (hard-killed) process: WAL recovery, then invariants.
	ctx := context.Background()
	db, err := store.Open(ctx, filepath.Join(dir, "custody.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	all, err := withdrawal.All(ctx, db)
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != len(ws) {
		t.Fatalf("%d withdrawals in the database, want %d (a retry created a duplicate?)", len(all), len(ws))
	}
	res, err := ledger.Check(ctx, db)
	if err != nil || !res.OK() {
		t.Fatalf("ledger invariants: %+v %v", res, err)
	}
	snap, _ := ledger.Balances(ctx, db)
	if v := snap.Get(ledger.WithdrawalsPending, "tUSD"); v.Sign() != 0 {
		t.Fatalf("withdrawals_pending %s", v)
	}
	chainNonce, _ := a.RPC.NonceAt(ctx, d.Hot)
	if gaps, _ := txmgr.FindGaps(ctx, db, chainNonce); len(gaps) != 0 {
		t.Fatalf("nonce gaps %v", gaps)
	}
	f, err := os.Open(filepath.Join(dir, "audit.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := audit.Verify(f); err != nil {
		t.Fatalf("audit log: %v", err)
	}
	t.Logf("%s: 3 withdrawals confirmed once each, reconciliation ok at block %d, %d audit events", fp, rep.Block, countAudit(ctx, db))
}

func countAudit(ctx context.Context, db *store.DB) int {
	var n int
	_ = db.QueryRowContext(ctx, `SELECT COUNT(*) FROM audit_events`).Scan(&n)
	return n
}

// submitAll posts each withdrawal once. When mustSucceed is false (after_request_commit), the
// first request is expected to lose its connection because the process crashes mid-response.
func submitAll(t *testing.T, p *process, ws []chaosWithdrawal, mustSucceed bool) {
	t.Helper()
	for i := range ws {
		w := &ws[i]
		req := map[string]string{"account_id": w.user, "asset": "tUSD", "amount": fmt.Sprint(w.amount), "destination": w.dest.Hex()}
		code, body, err := p.call(t, "POST", "/v1/withdrawals", ClientToken, req, w.key)
		if err != nil {
			if mustSucceed {
				select {
				case <-p.exited: // the failpoint fired in a background loop meanwhile
					return
				case <-time.After(10 * time.Second):
				}
				t.Fatalf("submit %s: %v", w.key, err)
			}
			return // connection dropped: the process crashed after committing
		}
		if code != http.StatusCreated {
			t.Fatalf("submit %s: %d %s", w.key, code, body)
		}
		var v withdrawal.View
		_ = json.Unmarshal(body, &v)
		w.id = v.ID
	}
}

func statusOf(t *testing.T, p *process, id string) string {
	if id == "" {
		return ""
	}
	_, body, err := p.call(t, "GET", "/v1/withdrawals/"+id, ClientToken, nil, "")
	if err != nil {
		return ""
	}
	var v withdrawal.View
	_ = json.Unmarshal(body, &v)
	return string(v.Status)
}

// waitFor polls cond until it holds, the process exits, or the timeout expires.
func waitFor(t *testing.T, p *process, timeout time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		select {
		case <-p.exited:
			if cond() {
				return
			}
			t.Fatalf("custodyd exited unexpectedly: %v\n%s", p.err, p.out)
		case <-time.After(100 * time.Millisecond):
		}
	}
	t.Fatalf("condition not met within %s\n%s", timeout, tail(p.out.String(), 4000))
}

func tail(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[len(s)-n:]
}
