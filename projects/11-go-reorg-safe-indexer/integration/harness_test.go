// SPDX-License-Identifier: MIT

//go:build integration

package integration

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/rpc"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/bindings"
)

// indexerBin is the indexer binary built once by TestMain.
var indexerBin string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "indexer-it-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	name := "indexer"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	indexerBin = filepath.Join(dir, name)
	build := exec.Command("go", "build", "-o", indexerBin, "../cmd/indexer")
	build.Env = append(os.Environ(), "CGO_ENABLED=0")
	if os.Getenv("INDEXER_IT_RACE") == "1" {
		// CI: the subprocesses run under the race detector too; a report fails the test that
		// started the process (see StartIndexer). checkptr is off because modernc.org/sqlite's
		// transpiled C does pointer arithmetic it rejects; race detection itself stays on.
		build = exec.Command("go", "build", "-race", "-gcflags=all=-d=checkptr=0", "-o", indexerBin, "../cmd/indexer")
		build.Env = append(os.Environ(), "CGO_ENABLED=1")
	}
	build.Stdout, build.Stderr = os.Stderr, os.Stderr
	if err := build.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "build indexer:", err)
		os.Exit(1)
	}
	code := m.Run()
	_ = os.RemoveAll(dir)
	os.Exit(code)
}

// Anvil is a running anvil process on an OS-assigned port, with manual mining.
type Anvil struct {
	t        testing.TB
	URL      string
	RPC      *rpc.Client
	Eth      *ethclient.Client
	Accounts []common.Address
	mu       sync.Mutex // serialises chain mutations (send+mine, reorg)
}

var listenRe = regexp.MustCompile(`Listening on (\S+)`)

// StartAnvil launches `anvil --port 0 --no-mining`, reads the bound address from its output,
// and kills the process (by PID) when the test ends.
func StartAnvil(t testing.TB) *Anvil {
	t.Helper()
	cmd := exec.Command("anvil", "--port", "0", "--chain-id", "31337", "--no-mining", "--accounts", "10")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		t.Fatalf("start anvil (is Foundry installed?): %v", err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	})
	addr := make(chan string, 1)
	go func() {
		sc := bufio.NewScanner(stdout)
		sent := false
		for sc.Scan() {
			if m := listenRe.FindStringSubmatch(sc.Text()); m != nil && !sent {
				addr <- m[1]
				sent = true
			}
		}
	}()
	a := &Anvil{t: t}
	select {
	case s := <-addr:
		a.URL = "http://" + s
	case <-time.After(30 * time.Second):
		t.Fatal("anvil did not report its listening address")
	}
	if a.RPC, err = rpc.Dial(a.URL); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(a.RPC.Close)
	a.Eth = ethclient.NewClient(a.RPC)
	a.call(&a.Accounts, "eth_accounts")
	return a
}

func (a *Anvil) call(result any, method string, params ...any) {
	a.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := a.RPC.CallContext(ctx, result, method, params...); err != nil {
		a.t.Fatalf("%s: %v", method, err)
	}
}

// txRequest is an eth_sendTransaction request; anvil signs for its unlocked dev accounts.
type txRequest struct {
	From common.Address  `json:"from"`
	To   *common.Address `json:"to,omitempty"`
	Data hexutil.Bytes   `json:"data"`
	Gas  hexutil.Uint64  `json:"gas"`
}

// Send submits a transaction to the pool (mined by the next Mine).
func (a *Anvil) Send(from common.Address, to *common.Address, data []byte) common.Hash {
	a.t.Helper()
	var h common.Hash
	a.call(&h, "eth_sendTransaction", txRequest{From: from, To: to, Data: data, Gas: 3_000_000})
	return h
}

// Mine mines n blocks.
func (a *Anvil) Mine(n int) {
	a.t.Helper()
	for range n {
		a.call(nil, "evm_mine")
	}
}

// Receipt returns a mined transaction's receipt and fails the test if it reverted.
func (a *Anvil) Receipt(h common.Hash) *types.Receipt {
	a.t.Helper()
	r, err := a.Eth.TransactionReceipt(context.Background(), h)
	if err != nil {
		a.t.Fatalf("receipt %s: %v", h, err)
	}
	if r.Status != types.ReceiptStatusSuccessful {
		a.t.Fatalf("transaction %s reverted", h)
	}
	return r
}

// Reorg replaces the last depth blocks with depth new blocks containing txs (each paired with
// the offset of the new block it goes into).
func (a *Anvil) Reorg(depth int, txs []ReorgTx) {
	a.t.Helper()
	pairs := make([][]any, 0, len(txs))
	for _, tx := range txs {
		pairs = append(pairs, []any{tx.Req, tx.Offset})
	}
	a.call(nil, "anvil_reorg", depth, pairs)
}

// ReorgTx is a transaction for anvil_reorg.
type ReorgTx struct {
	Req    txRequest
	Offset int
}

// HeadRef returns the latest block number and hash (as reported by the node).
func (a *Anvil) HeadRef() (uint64, common.Hash) {
	a.t.Helper()
	var raw struct {
		Number hexutil.Uint64 `json:"number"`
		Hash   common.Hash    `json:"hash"`
	}
	a.call(&raw, "eth_getBlockByNumber", "latest", false)
	return uint64(raw.Number), raw.Hash
}

// Fixtures are the deployed contracts.
type Fixtures struct {
	TokenA, TokenB, Vault common.Address
	Owner                 common.Address
}

var (
	tokenABI = bindings.NewFixtureToken()
	vaultABI = bindings.NewFixtureVault()
)

// Deploy deploys two tokens and a vault over the first, owned by Accounts[0].
func (a *Anvil) Deploy() Fixtures {
	a.t.Helper()
	a.mu.Lock()
	defer a.mu.Unlock()
	owner := a.Accounts[0]
	deploy := func(bin string, args []byte) common.Hash {
		return a.Send(owner, nil, append(common.FromHex(bin), args...))
	}
	ha := deploy(bindings.FixtureTokenMetaData.Bin, tokenABI.PackConstructor("Fixture USD", "fUSD", 6, owner))
	hb := deploy(bindings.FixtureTokenMetaData.Bin, tokenABI.PackConstructor("Fixture ETH", "fETH", 18, owner))
	a.Mine(1)
	f := Fixtures{Owner: owner, TokenA: a.Receipt(ha).ContractAddress, TokenB: a.Receipt(hb).ContractAddress}
	hv := deploy(bindings.FixtureVaultMetaData.Bin, vaultABI.PackConstructor(f.TokenA, "Fixture Vault", "fvUSD"))
	a.Mine(1)
	f.Vault = a.Receipt(hv).ContractAddress
	return f
}

// CallUint reads a uint256 view function at a block hash.
func (a *Anvil) CallUint(to common.Address, data []byte, block common.Hash) *big.Int {
	a.t.Helper()
	out, err := a.Eth.CallContractAtHash(context.Background(), ethereum.CallMsg{To: &to, Data: data}, block)
	if err != nil {
		a.t.Fatalf("eth_call: %v", err)
	}
	return new(big.Int).SetBytes(out)
}

// Indexer is a running indexer subprocess.
type Indexer struct {
	t       testing.TB
	cmd     *exec.Cmd
	URL     string
	logs    *lockedBuffer
	exited  chan struct{}
	waitErr error // valid once exited is closed
}

type lockedBuffer struct {
	mu sync.Mutex
	sb strings.Builder
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.sb.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.sb.String()
}

var httpAddrRe = regexp.MustCompile(`"msg":"http listening","addr":"([^"]+)"`)

// StartIndexer runs `indexer <args>` and waits for its HTTP listener (it is started with
// --listen 127.0.0.1:0, so every run gets a fresh OS-assigned port).
func StartIndexer(t testing.TB, args ...string) *Indexer {
	t.Helper()
	args = append(args, "--listen", "127.0.0.1:0", "--log-format", "json")
	cmd := exec.Command(indexerBin, args...)
	logs := &lockedBuffer{}
	pr, pw := io.Pipe()
	cmd.Stdout = logs
	cmd.Stderr = io.MultiWriter(logs, pw)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	ix := &Indexer{t: t, cmd: cmd, logs: logs, exited: make(chan struct{})}
	go func() {
		ix.waitErr = cmd.Wait()
		_ = pw.Close()
		close(ix.exited)
	}()
	addr := make(chan string, 1)
	go func() {
		sc := bufio.NewScanner(pr)
		sc.Buffer(make([]byte, 1<<20), 1<<20)
		sent := false
		for sc.Scan() {
			if m := httpAddrRe.FindStringSubmatch(sc.Text()); m != nil && !sent {
				addr <- m[1]
				sent = true
			}
		}
	}()
	t.Cleanup(func() {
		ix.Kill()
		if logs := ix.Logs(); strings.Contains(logs, "WARNING: DATA RACE") {
			t.Errorf("the indexer subprocess reported a data race:\n%s", tail(logs, 120))
		}
	})
	select {
	case a := <-addr:
		ix.URL = "http://" + a
	case <-ix.exited:
		t.Fatalf("indexer exited during start-up:\n%s", logs.String())
	case <-time.After(60 * time.Second):
		t.Fatalf("indexer did not start:\n%s", logs.String())
	}
	return ix
}

// Kill terminates the process abruptly (a crash: no graceful shutdown), by PID.
func (ix *Indexer) Kill() {
	select {
	case <-ix.exited:
		return
	default:
	}
	_ = ix.cmd.Process.Kill()
	<-ix.exited
}

// Logs returns everything the process printed.
func (ix *Indexer) Logs() string { return ix.logs.String() }

// GetJSON fetches a JSON document from the indexer.
func GetJSON(url string, out any) (int, error) {
	resp, err := http.Get(url)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, err
	}
	if out != nil {
		if err := json.Unmarshal(body, out); err != nil {
			return resp.StatusCode, fmt.Errorf("decode %s: %w: %s", url, err, body)
		}
	}
	return resp.StatusCode, nil
}

// Status is the subset of /v1/status the tests read.
type Status struct {
	Tip *struct {
		Number uint64      `json:"number"`
		Hash   common.Hash `json:"hash"`
	} `json:"tip"`
	ChainHead uint64 `json:"chainHead"`
	Reorgs    int64  `json:"reorgs"`
}

// tail returns the last n lines of s.
func tail(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

// WaitForTip polls /v1/status until the indexer's tip is the given block. On timeout it prints
// the tail of logs().
func WaitForTip(t testing.TB, url func() string, number uint64, hash common.Hash, timeout time.Duration, logs func() string) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	var last Status
	for time.Now().Before(deadline) {
		var s Status
		if code, err := GetJSON(url()+"/v1/status", &s); err == nil && code == http.StatusOK {
			last = s
			if s.Tip != nil && s.Tip.Number == number && s.Tip.Hash == hash {
				return
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	tip := "none"
	if last.Tip != nil {
		tip = fmt.Sprintf("%d/%s", last.Tip.Number, last.Tip.Hash.Hex())
	}
	t.Fatalf("indexer did not reach %d/%s (last tip %s, chain head %d)\n%s", number, hash.Hex(), tip, last.ChainHead, tail(logs(), 80))
}
