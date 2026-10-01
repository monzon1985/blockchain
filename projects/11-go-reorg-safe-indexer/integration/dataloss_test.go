// SPDX-License-Identifier: MIT

//go:build integration

package integration

import (
	"bytes"
	"errors"
	"math/big"
	"math/rand/v2"
	"net/http/httptest"
	"net/url"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/rpcfault"
)

// TestSilentLogLossIsDetectedAndPrevented runs the indexer behind a provider that silently
// drops one block's logs from every eth_getLogs range answer, a well-formed but incomplete
// response that no retry or timeout can notice.
//
//  1. Without --bloom-check the indexer loses data, and `indexer verify` (exit code 1) proves it
//     against a reindex from an honest endpoint.
//  2. With --bloom-check, every block whose header bloom admits a watched contract but which came
//     back without logs is re-read by block hash, and verify passes.
func TestSilentLogLossIsDetectedAndPrevented(t *testing.T) {
	a := StartAnvil(t)
	f := a.Deploy()
	w := &workload{a: a, f: f, rng: rand.New(rand.NewPCG(77, 78)), holders: a.Accounts[1:6]}
	w.setup()
	for i := range 30 {
		for range 1 + i%3 {
			to := w.pick()
			a.Send(w.pick(), &f.TokenA, tokenABI.PackTransfer(to, big.NewInt(int64(1+i))))
		}
		a.Mine(1)
	}
	headNum, headHash := a.HeadRef()

	faults := rpcfault.New(nil, rpcfault.Config{Seed: 1, DropBlockRate: 1})
	target, _ := url.Parse(a.URL)
	proxy := httptest.NewServer(rpcfault.NewProxy(target, faults))
	t.Cleanup(proxy.Close)

	run := func(name string, extra ...string) (string, int) {
		db := filepath.Join(t.TempDir(), name+".db")
		args := append([]string{"index", "--rpc-url", proxy.URL, "--db", db, "--token", f.TokenA.Hex(),
			"--confirmations", "1", "--poll-interval", "25ms"}, extra...)
		ix := StartIndexer(t, args...)
		waitForCheckpoint(t, ix, headNum, headHash)
		ix.Kill()
		var out bytes.Buffer
		verify := exec.Command(indexerBin, "verify", "--rpc-url", a.URL, "--db", db, "--log-level", "error")
		verify.Stdout, verify.Stderr = &out, &out
		err := verify.Run()
		code := 0
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			code = exitErr.ExitCode()
		} else if err != nil {
			t.Fatal(err)
		}
		return out.String(), code
	}

	out, code := run("plain")
	if code != 1 || !strings.Contains(out, "MISMATCH") || !strings.Contains(out, "only on the right") {
		t.Fatalf("without --bloom-check: verify exited %d, want 1 (data loss detected):\n%s", code, out)
	}
	dropped := faults.Stats.DroppedBlocks.Load()
	if dropped == 0 {
		t.Fatal("the provider dropped nothing")
	}
	t.Logf("without --bloom-check, blocks dropped by the provider: %d; verify said:\n%s", dropped, out)

	out, code = run("checked", "--bloom-check")
	if code != 0 || !strings.Contains(out, "OK: identical") {
		t.Fatalf("with --bloom-check: verify exited %d:\n%s", code, out)
	}
	if faults.Stats.DroppedBlocks.Load() == dropped {
		t.Fatal("the second run met no dropped blocks; it proves nothing")
	}
}

// waitForCheckpoint polls /readyz (the index command serves no data API) until the indexed tip
// is the given block.
func waitForCheckpoint(t *testing.T, ix *Indexer, number uint64, hash common.Hash) {
	t.Helper()
	deadline := time.Now().Add(time.Minute)
	for time.Now().Before(deadline) {
		var r struct {
			Tip *struct {
				Number uint64      `json:"number"`
				Hash   common.Hash `json:"hash"`
			} `json:"tip"`
		}
		if _, err := GetJSON(ix.URL+"/readyz", &r); err == nil && r.Tip != nil && r.Tip.Number == number && r.Tip.Hash == hash {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("indexer did not reach %d:\n%s", number, tail(ix.Logs(), 40))
}
