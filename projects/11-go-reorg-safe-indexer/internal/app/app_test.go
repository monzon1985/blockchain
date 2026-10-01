// SPDX-License-Identifier: MIT

package app

import (
	"bytes"
	"context"
	"encoding/json"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/fakechain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/rpcfault"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store/sqlite"
)

// syncBuffer is a goroutine-safe bytes.Buffer.
type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

// node serves a fake chain with traffic over HTTP.
type node struct {
	fc  *fakechain.Chain
	w   *fakechain.World
	url string
	rng *rand.Rand
}

func newNode(t *testing.T, blocks int) *node {
	t.Helper()
	n := &node{fc: fakechain.New(31337), w: fakechain.NewWorld(5), rng: rand.New(rand.NewPCG(1, 1))}
	for range blocks {
		n.mine()
	}
	srv := httptest.NewServer(n.fc.Handler())
	t.Cleanup(srv.Close)
	n.url = srv.URL
	return n
}

func (n *node) mine() { n.fc.Mine(n.w.Block(n.rng, n.fc.Canonical(0), n.rng.IntN(6))) }

// contractFlags configures every watched contract explicitly (the fake node has no eth_call).
func (n *node) contractFlags() []string {
	return []string{"--token", n.w.Tokens[0].Hex() + "," + n.w.Tokens[1].Hex(), "--token", n.w.Asset.Hex(),
		"--vault", n.w.Vault.Hex() + "=" + n.w.Asset.Hex()}
}

type run struct {
	done   chan struct{} // closed when MainEnv returns
	code   int
	stderr *syncBuffer
	stdout *syncBuffer
	cancel context.CancelFunc
}

var listenRe = regexp.MustCompile(`"msg":"http listening","addr":"([^"]+)"`)

// start runs the command line in the background and returns once its HTTP server listens.
func start(t *testing.T, env map[string]string, args ...string) (*run, string) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	r := &run{done: make(chan struct{}), stderr: &syncBuffer{}, stdout: &syncBuffer{}, cancel: cancel}
	go func() {
		defer close(r.done)
		r.code = MainEnv(ctx, args, r.stdout, r.stderr, func(k string) string { return env[k] })
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case <-r.done:
		case <-time.After(30 * time.Second):
			t.Error("command did not stop")
		}
	})
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		if m := listenRe.FindStringSubmatch(r.stderr.String()); m != nil {
			return r, "http://" + m[1]
		}
		select {
		case <-r.done:
			t.Fatalf("exited with %d during start-up:\n%s", r.code, r.stderr.String())
		case <-time.After(10 * time.Millisecond):
		}
	}
	t.Fatalf("no listener:\n%s", r.stderr.String())
	return nil, ""
}

// stop cancels the context (SIGINT) and returns the exit code.
func (r *run) stop(t *testing.T) int {
	t.Helper()
	r.cancel()
	select {
	case <-r.done:
		return r.code
	case <-time.After(30 * time.Second):
		t.Fatal("command did not stop")
	}
	return -1
}

func getJSON(t *testing.T, url string, out any) int {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if out != nil {
		_ = json.NewDecoder(resp.Body).Decode(out)
	}
	return resp.StatusCode
}

func waitTip(t *testing.T, base string, hash common.Hash) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		var s struct {
			Tip *struct {
				Hash common.Hash `json:"hash"`
			} `json:"tip"`
		}
		if getJSON(t, base+"/v1/status", &s) == 200 && s.Tip != nil && s.Tip.Hash == hash {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("tip did not reach %s", hash)
}

func verify(t *testing.T, args ...string) (int, string) {
	t.Helper()
	var out, errOut syncBuffer
	code := MainEnv(context.Background(), append([]string{"verify", "--log-level", "error"}, args...), &out, &errOut, func(string) string { return "" })
	return code, out.String() + errOut.String()
}

func TestServeVerifyAndGracefulShutdown(t *testing.T) {
	n := newNode(t, 40)
	db := filepath.Join(t.TempDir(), "idx.db")
	args := append([]string{"serve", "--rpc-url", n.url, "--db", db, "--listen", "127.0.0.1:0", "--poll-interval", "10ms",
		"--confirmations", "3", "--log-format", "json"}, n.contractFlags()...)
	r, base := start(t, nil, args...)
	waitTip(t, base, n.fc.Head().Hash)
	var page struct {
		Data []json.RawMessage `json:"data"`
	}
	if code := getJSON(t, base+"/v1/transfers?limit=5", &page); code != 200 || len(page.Data) != 5 {
		t.Fatalf("transfers %d %d", code, len(page.Data))
	}
	if code := getJSON(t, base+"/readyz", nil); code != 200 {
		t.Fatalf("readyz %d", code)
	}
	// Live: a new block shows up without restarting.
	n.mine()
	waitTip(t, base, n.fc.Head().Hash)
	if code := r.stop(t); code != ExitOK {
		t.Fatalf("graceful stop exited %d:\n%s", code, r.stderr.String())
	}
	if !strings.Contains(r.stderr.String(), `"msg":"indexer stopped"`) || !strings.Contains(r.stderr.String(), `"msg":"http stopped"`) {
		t.Fatalf("shutdown not logged:\n%s", r.stderr.String())
	}

	// verify: identical to a reindex.
	code, out := verify(t, "--rpc-url", n.url, "--db", db)
	if code != ExitOK || !strings.Contains(out, "OK: identical") || !strings.Contains(out, "transfers") {
		t.Fatalf("verify exited %d:\n%s", code, out)
	}

	// verify catches a corrupted row.
	st, err := sqlite.Open(context.Background(), db)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.DB().Exec(`UPDATE balances SET balance = '12345' WHERE rowid IN (SELECT rowid FROM balances LIMIT 2)`); err != nil {
		t.Fatal(err)
	}
	if _, err := st.DB().Exec(`DELETE FROM transfers WHERE rowid IN (SELECT rowid FROM transfers LIMIT 3)`); err != nil {
		t.Fatal(err)
	}
	_ = st.Close()
	code, out = verify(t, "--rpc-url", n.url, "--db", db, "--max-diffs", "2")
	if code != ExitDiff || !strings.Contains(out, "MISMATCH: 5 differences") || !strings.Contains(out, "... 3 more") {
		t.Fatalf("verify of a corrupted database exited %d:\n%s", code, out)
	}

	// verify reports a database whose tip a reorg has orphaned as stale, not as corrupt.
	if err := n.fc.Reorg(2, make([][]fakechain.LogSpec, 2)); err != nil {
		t.Fatal(err)
	}
	code, out = verify(t, "--rpc-url", n.url, "--db", db)
	if code != ExitStale || !strings.Contains(out, "STALE") {
		t.Fatalf("verify of a stale database exited %d:\n%s", code, out)
	}

	// Resume after the restart: the same database catches up with the reorg.
	_, base = start(t, nil, args...)
	waitTip(t, base, n.fc.Head().Hash)
}

// TestBloomCheckMissesPartialLossVerifyCatchesIt pins down what --bloom-check does not cover:
// it re-reads blocks that came back without logs, so a provider that drops one of several logs
// of a block slips past it. Only `indexer verify` against an honest endpoint finds the loss.
func TestBloomCheckMissesPartialLossVerifyCatchesIt(t *testing.T) {
	n := newNode(t, 40)
	target, err := url.Parse(n.url)
	if err != nil {
		t.Fatal(err)
	}
	faults := rpcfault.New(nil, rpcfault.Config{Seed: 3, DropLogRate: 1})
	proxy := httptest.NewServer(rpcfault.NewProxy(target, faults))
	t.Cleanup(proxy.Close)
	db := filepath.Join(t.TempDir(), "partial.db")
	r, base := start(t, nil, append([]string{"serve", "--rpc-url", proxy.URL, "--db", db, "--listen", "127.0.0.1:0",
		"--poll-interval", "10ms", "--confirmations", "2", "--bloom-check", "--log-format", "json"}, n.contractFlags()...)...)
	waitTip(t, base, n.fc.Head().Hash)
	if code := r.stop(t); code != ExitOK {
		t.Fatalf("serve exited %d", code)
	}
	if faults.Stats.DroppedLogs.Load() == 0 {
		t.Fatal("the proxy dropped nothing")
	}
	code, out := verify(t, "--rpc-url", n.url, "--db", db)
	if code != ExitDiff || !strings.Contains(out, "MISMATCH") || !strings.Contains(out, "only on the right") {
		t.Fatalf("verify after %d partially dropped answers exited %d:\n%s", faults.Stats.DroppedLogs.Load(), code, out)
	}
}

func TestIndexAndReadonlyServe(t *testing.T) {
	n := newNode(t, 20)
	db := filepath.Join(t.TempDir(), "idx.db")
	// Flags from the environment.
	env := map[string]string{"INDEXER_RPC_URL": n.url, "INDEXER_DB": db, "INDEXER_LISTEN": "127.0.0.1:0",
		"INDEXER_POLL_INTERVAL": "10ms", "INDEXER_TOKEN": n.w.Asset.Hex(), "INDEXER_VAULT": n.w.Vault.Hex() + "=" + n.w.Asset.Hex(),
		"INDEXER_LOG_FORMAT": "json"}
	ix, ops := start(t, env, "index")
	if code := getJSON(t, ops+"/v1/transfers", nil); code != http.StatusNotFound {
		t.Fatalf("index serves the data API: %d", code)
	}
	deadline := time.Now().Add(30 * time.Second)
	for getJSON(t, ops+"/readyz", nil) != 200 {
		if time.Now().After(deadline) {
			t.Fatal("index never became ready")
		}
		time.Sleep(10 * time.Millisecond)
	}
	ro, api := start(t, nil, "serve", "--readonly", "--db", db, "--listen", "127.0.0.1:0", "--log-format", "json")
	waitTip(t, api, n.fc.Head().Hash)
	var s struct {
		ChainID   uint64 `json:"chainId"`
		Contracts struct {
			Tokens []common.Address `json:"tokens"`
		} `json:"contracts"`
	}
	if getJSON(t, api+"/v1/status", &s); s.ChainID != 31337 || len(s.Contracts.Tokens) != 2 {
		t.Fatalf("read-only status %+v", s)
	}
	// The read-only server follows the other process's commits.
	n.mine()
	waitTip(t, api, n.fc.Head().Hash)
	if code := ro.stop(t); code != ExitOK {
		t.Fatalf("read-only serve exited %d", code)
	}
	if code := ix.stop(t); code != ExitOK {
		t.Fatalf("index exited %d", code)
	}
	var out syncBuffer
	code := MainEnv(context.Background(), []string{"serve", "--readonly", "--db", filepath.Join(t.TempDir(), "empty.db")}, &out, &out, func(string) string { return "" })
	if code != ExitFailure || !strings.Contains(out.String(), "never been indexed") {
		t.Fatalf("read-only serve of an empty database: %d %s", code, out.String())
	}
}

func TestCommandLineErrors(t *testing.T) {
	n := newNode(t, 3)
	token := n.w.Tokens[0].Hex()
	db := filepath.Join(t.TempDir(), "flags.db")
	cases := []struct {
		name string
		args []string
		env  map[string]string
		code int
		want string
	}{
		{"no command", nil, nil, ExitFailure, "Usage:"},
		{"help", []string{"help"}, nil, ExitOK, "Usage:"},
		{"command help", []string{"serve", "-h"}, nil, ExitOK, "-rpc-url"},
		{"unknown command", []string{"frobnicate"}, nil, ExitFailure, `unknown command "frobnicate"`},
		{"unknown flag", []string{"index", "--nope"}, nil, ExitFailure, "flag provided but not defined"},
		{"positional argument", []string{"index", "extra"}, nil, ExitFailure, `unexpected argument "extra"`},
		{"bad log level", []string{"index", "--log-level", "loud"}, nil, ExitFailure, "invalid --log-level"},
		{"bad log format", []string{"index", "--log-format", "xml"}, nil, ExitFailure, "invalid --log-format"},
		{"bad env value", []string{"index"}, map[string]string{"INDEXER_MAX_LAG": "many"}, ExitFailure, "INDEXER_MAX_LAG"},
		{"no rpc url", []string{"index", "--db", db}, nil, ExitFailure, "--rpc-url"},
		{"nothing to index", []string{"index", "--db", db, "--rpc-url", n.url}, nil, ExitFailure, "nothing to index"},
		{"bad token", []string{"index", "--db", db, "--rpc-url", n.url, "--token", "0x12"}, nil, ExitFailure, "--token"},
		{"bad vault", []string{"index", "--db", db, "--rpc-url", n.url, "--vault", "nope"}, nil, ExitFailure, "--vault"},
		{"bad vault asset", []string{"index", "--db", db, "--rpc-url", n.url, "--vault", token + "=nope"}, nil, ExitFailure, "--vault"},
		// The fake node has no eth_call, so reading asset() fails like it would on a non-vault.
		{"vault without asset", []string{"index", "--db", db, "--rpc-url", n.url, "--vault", token}, nil, ExitFailure, "read asset()"},
		{"unreachable postgres", []string{"index", "--db", "postgres://x@127.0.0.1:1/x?sslmode=disable&connect_timeout=1", "--rpc-url", n.url, "--token", token}, nil, ExitFailure, "postgres"},
		{"unopenable sqlite", []string{"serve", "--db", t.TempDir(), "--rpc-url", n.url, "--token", token}, nil, ExitFailure, "sqlite"},
		{"listen error", []string{"serve", "--db", db, "--rpc-url", n.url, "--token", token, "--listen", "256.0.0.1:1"}, nil, ExitFailure, "listen"},
		{"verify without rpc", []string{"verify", "--db", filepath.Join(t.TempDir(), "v.db")}, nil, ExitFailure, "never been indexed"},
		// Every pooled connection to :memory: would be a separate empty database.
		{"in-memory sqlite", []string{"serve", "--db", ":memory:", "--rpc-url", n.url, "--token", token}, nil, ExitFailure, "in-memory databases are not supported"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var out syncBuffer
			env := tc.env
			code := MainEnv(context.Background(), tc.args, &out, &out, func(k string) string { return env[k] })
			if code != tc.code || !strings.Contains(out.String(), tc.want) {
				t.Fatalf("exit %d (want %d), output:\n%s", code, tc.code, out.String())
			}
		})
	}
}

func TestVerifyRejectsAnotherChain(t *testing.T) {
	n := newNode(t, 5)
	db := filepath.Join(t.TempDir(), "idx.db")
	r, base := start(t, nil, append([]string{"index", "--rpc-url", n.url, "--db", db, "--listen", "127.0.0.1:0", "--poll-interval", "10ms"}, n.contractFlags()...)...)
	deadline := time.Now().Add(30 * time.Second)
	for getJSON(t, base+"/readyz", nil) != 200 {
		if time.Now().After(deadline) {
			t.Fatal("not ready")
		}
		time.Sleep(10 * time.Millisecond)
	}
	r.stop(t)
	other := fakechain.New(1)
	srv := httptest.NewServer(other.Handler())
	defer srv.Close()
	code, out := verify(t, "--rpc-url", srv.URL, "--db", db)
	if code != ExitFailure || !strings.Contains(out, "database was indexed from chain 31337") {
		t.Fatalf("verify against another chain exited %d:\n%s", code, out)
	}
	// An unreachable node.
	code, out = verify(t, "--rpc-url", "http://127.0.0.1:1", "--rpc-timeout", "1s", "--db", db)
	if code != ExitFailure {
		t.Fatalf("verify against a dead node exited %d:\n%s", code, out)
	}
}

func TestListFlag(t *testing.T) {
	var l listFlag
	for _, v := range []string{"a, b", "", "c,,"} {
		if err := l.Set(v); err != nil {
			t.Fatal(err)
		}
	}
	if l.String() != "a,b,c" {
		t.Fatalf("listFlag = %q", l.String())
	}
	if getenv("INDEXER_TEST_SURELY_UNSET_VARIABLE") != "" {
		t.Fatal("getenv")
	}
}
