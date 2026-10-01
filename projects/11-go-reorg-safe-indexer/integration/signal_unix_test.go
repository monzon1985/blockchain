// SPDX-License-Identifier: MIT

//go:build integration && !windows

package integration

import (
	"math/big"
	"strings"
	"syscall"
	"testing"
	"time"
)

// TestSIGTERMGracefulShutdownAndResume delivers SIGTERM to the real binary (POSIX only: Windows
// has no SIGTERM to send, and the in-process tests in internal/app cover the same cancellation
// path there). The process must exit 0 after logging that the indexer and the HTTP server
// stopped, and a restart must resume from the checkpoint.
func TestSIGTERMGracefulShutdownAndResume(t *testing.T) {
	a := StartAnvil(t)
	f := a.Deploy()
	alice := a.Accounts[1]
	a.Send(f.Owner, &f.TokenA, tokenABI.PackMint(alice, big.NewInt(1000)))
	a.Mine(3)
	db := t.TempDir() + "/idx.db"
	args := []string{"serve", "--rpc-url", a.URL, "--db", db, "--token", f.TokenA.Hex(), "--poll-interval", "25ms"}
	ix := StartIndexer(t, args...)
	n, h := a.HeadRef()
	WaitForTip(t, func() string { return ix.URL }, n, h, 30*time.Second, ix.Logs)

	if err := ix.cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	select {
	case <-ix.exited:
	case <-time.After(30 * time.Second):
		t.Fatalf("no exit after SIGTERM:\n%s", ix.Logs())
	}
	if ix.waitErr != nil {
		t.Fatalf("exit after SIGTERM: %v\n%s", ix.waitErr, ix.Logs())
	}
	for _, msg := range []string{`"msg":"indexer stopped"`, `"msg":"http stopped"`} {
		if !strings.Contains(ix.Logs(), msg) {
			t.Fatalf("shutdown log lacks %s:\n%s", msg, ix.Logs())
		}
	}

	a.Send(alice, &f.TokenA, tokenABI.PackTransfer(f.Owner, big.NewInt(1)))
	a.Mine(1)
	again := StartIndexer(t, args...)
	n, h = a.HeadRef()
	WaitForTip(t, func() string { return again.URL }, n, h, 30*time.Second, again.Logs)
	if !strings.Contains(again.Logs(), `"msg":"resuming from checkpoint"`) {
		t.Fatalf("restart did not resume:\n%s", again.Logs())
	}
}
