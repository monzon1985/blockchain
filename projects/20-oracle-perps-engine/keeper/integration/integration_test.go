// SPDX-License-Identifier: MIT

//go:build integration

// The test spawns anvil, three signer processes and the keeper process, then settles a scripted session end to
// end: an LP deposit, three market orders, a take-profit, a liquidation during a +10% move and auto-deleveraging
// during a +67% squeeze, followed by a user close and a full LP redemption. Anvil mines a block every second, like
// a live chain whose head lags the signers' wall clocks, rather than one block per transaction.
//
//	go test -count=1 -tags integration -timeout 15m ./integration/...
package integration

import (
	"bufio"
	"context"
	"crypto/ecdsa"
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
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"

	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/bindings"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/deploy"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/keys"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/report"
)

const (
	password    = "integration-only-password"
	setupWindow = 60 // seconds of flat price before the scripted moves start
)

func wad(v int64) *big.Int { return new(big.Int).Mul(big.NewInt(v), big.NewInt(1e18)) }

// scriptedPath is one price per second: flat 3,000 during setup, a ramp to 3,300 (liquidation and take-profit),
// a plateau, then a ramp to 5,000 (auto-deleveraging) and a final plateau.
func scriptedPath() []string {
	var prices []*big.Int
	flat := func(p int64, n int) {
		for range n {
			prices = append(prices, wad(p))
		}
	}
	ramp := func(from, to int64, n int) {
		for i := 1; i <= n; i++ {
			prices = append(prices, wad(from+(to-from)*int64(i)/int64(n)))
		}
	}
	flat(3_000, setupWindow)
	ramp(3_000, 3_300, 10)
	flat(3_300, 15)
	ramp(3_300, 5_000, 20)
	flat(5_000, 600)
	out := make([]string, len(prices))
	for i, p := range prices {
		out[i] = p.String()
	}
	return out
}

type proc struct {
	name string
	cmd  *exec.Cmd
	log  *os.File
}

func start(t *testing.T, dir, name string, bin string, args ...string) *proc {
	t.Helper()
	logFile, err := os.Create(filepath.Join(dir, name+".log"))
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(bin, args...)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	if err := cmd.Start(); err != nil {
		t.Fatalf("start %s: %v", name, err)
	}
	p := &proc{name: name, cmd: cmd, log: logFile}
	t.Cleanup(func() {
		// Terminate by PID only (never by image name: other processes may share the binary).
		_ = p.cmd.Process.Kill()
		_, _ = p.cmd.Process.Wait()
		_ = p.log.Close()
		if t.Failed() {
			raw, _ := os.ReadFile(logFile.Name())
			t.Logf("---- %s log (tail) ----\n%s", name, tail(string(raw), 4000))
		}
	})
	return p
}

func tail(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[len(s)-n:]
}

func exe(name string) string {
	if runtime.GOOS == "windows" {
		return name + ".exe"
	}
	return name
}

func buildBinaries(t *testing.T, dir string) (signerBin, keeperBin string) {
	t.Helper()
	signerBin = filepath.Join(dir, exe("signer"))
	keeperBin = filepath.Join(dir, exe("keeper"))
	for pkg, out := range map[string]string{"../cmd/signer": signerBin, "../cmd/keeper": keeperBin} {
		cmd := exec.Command("go", "build", "-o", out, pkg)
		cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
		if raw, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("go build %s: %v\n%s", pkg, err, raw)
		}
	}
	return signerBin, keeperBin
}

// startAnvil launches anvil on a free port (port 0) and returns its RPC URL.
func startAnvil(t *testing.T, dir string) string {
	t.Helper()
	anvil, err := exec.LookPath("anvil")
	if err != nil {
		t.Fatalf("anvil not found on PATH (install Foundry 1.8.3): %v", err)
	}
	// Interval mining: the head lags wall time by up to a block, so reports dated "now" would be from the
	// verifier's future when the keeper simulates against the head; the keeper must ask for reports dated at it.
	cmd := exec.Command(anvil, "--port", "0", "--hardfork", "osaka", "--chain-id", "31337", "--block-time", "1")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	logFile, _ := os.Create(filepath.Join(dir, "anvil.log"))
	cmd.Stderr = logFile
	if err := cmd.Start(); err != nil {
		t.Fatalf("start anvil: %v", err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
		_ = logFile.Close()
	})
	re := regexp.MustCompile(`Listening on ([0-9.]+:[0-9]+)`)
	found := make(chan string, 1)
	go func() {
		sc := bufio.NewScanner(stdout)
		for sc.Scan() {
			line := sc.Text()
			_, _ = logFile.WriteString(line + "\n")
			if m := re.FindStringSubmatch(line); m != nil {
				select {
				case found <- m[1]:
				default:
				}
			}
		}
	}()
	select {
	case addr := <-found:
		return "http://" + addr
	case <-time.After(60 * time.Second):
		t.Fatal("anvil did not report its listening address")
		return ""
	}
}

func waitFile(t *testing.T, path string, timeout time.Duration) string {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if raw, err := os.ReadFile(path); err == nil && len(raw) > 0 {
			return strings.TrimSpace(string(raw))
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("%s not written within %s", path, timeout)
	return ""
}

func eventually(t *testing.T, what string, timeout time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(250 * time.Millisecond)
	}
	t.Fatalf("timed out after %s waiting for: %s", timeout, what)
}

type session struct {
	t       *testing.T
	ctx     context.Context
	client  *ethclient.Client
	chainID *big.Int
	sys     *deploy.System
	usd     *bindings.MockUSD
	book    *bindings.OrderBook
	vault   *bindings.LPVault
	market  *bindings.PerpsMarket
	users   map[string]*ecdsa.PrivateKey
}

func (s *session) addr(name string) common.Address {
	return crypto.PubkeyToAddress(s.users[name].PublicKey)
}

func (s *session) send(name string, f func(*bind.TransactOpts) (*types.Transaction, error)) {
	s.t.Helper()
	opts, err := bind.NewKeyedTransactorWithChainID(s.users[name], s.chainID)
	if err != nil {
		s.t.Fatal(err)
	}
	opts.Context = s.ctx
	tx, err := f(opts)
	if err != nil {
		s.t.Fatalf("%s: %v", name, err)
	}
	if _, err := deploy.WaitMined(s.ctx, s.client, tx.Hash(), 50*time.Millisecond); err != nil {
		s.t.Fatalf("%s: %v", name, err)
	}
}

func (s *session) fund(name string) {
	max := new(big.Int).Lsh(big.NewInt(1), 255)
	s.send(name, func(o *bind.TransactOpts) (*types.Transaction, error) {
		return s.usd.Mint(o, s.addr(name), wad(1_000_000))
	})
	s.send(name, func(o *bind.TransactOpts) (*types.Transaction, error) { return s.usd.Approve(o, s.sys.OrderBook, max) })
	s.send(name, func(o *bind.TransactOpts) (*types.Transaction, error) { return s.usd.Approve(o, s.sys.Vault, max) })
}

var (
	fee        = new(big.Int).Div(wad(1), big.NewInt(10))
	maxUint128 = new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 128), big.NewInt(1))
)

func (s *session) order(name string, kind uint8, isLong bool, size, collateral, trigger *big.Int) {
	acceptable := new(big.Int)
	increase := kind == 0 || kind == 2
	if isLong == increase {
		acceptable = maxUint128
	}
	s.send(name, func(o *bind.TransactOpts) (*types.Transaction, error) {
		return s.book.CreateOrder(o, kind, isLong, size, collateral, trigger, acceptable, fee)
	})
}

func (s *session) size(name string, isLong bool) *big.Int {
	p, err := s.market.GetPosition(&bind.CallOpts{Context: s.ctx}, s.addr(name), isLong)
	if err != nil {
		s.t.Fatal(err)
	}
	return p.SizeUsd
}

func scrape(t *testing.T, url string) string {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	return string(raw)
}

func metricValue(body, series string) float64 {
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, series+" ") {
			var v float64
			_, _ = fmt.Sscanf(strings.TrimPrefix(line, series+" "), "%g", &v)
			return v
		}
	}
	return 0
}

func TestKeeperNetworkSettlesScriptedSession(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Minute)
	defer cancel()

	signerBin, keeperBin := buildBinaries(t, dir)
	rpcURL := startAnvil(t, dir)
	client, err := ethclient.DialContext(ctx, rpcURL)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	chainID, err := client.ChainID(ctx)
	if err != nil {
		t.Fatal(err)
	}

	// Fresh keys, funded through anvil_setBalance (no well-known dev keys are used).
	users := map[string]*ecdsa.PrivateKey{}
	for _, n := range []string{"admin", "keeper", "lp", "alice", "bob", "carol", "signer0", "signer1", "signer2"} {
		k, _ := crypto.GenerateKey()
		users[n] = k
		if err := client.Client().CallContext(ctx, nil, "anvil_setBalance",
			crypto.PubkeyToAddress(k.PublicKey), hexutil.EncodeBig(wad(1_000))); err != nil {
			t.Fatal(err)
		}
	}
	admin, _ := bind.NewKeyedTransactorWithChainID(users["admin"], chainID)
	admin.Context = ctx
	signerAddrs := []common.Address{
		crypto.PubkeyToAddress(users["signer0"].PublicKey),
		crypto.PubkeyToAddress(users["signer1"].PublicKey),
		crypto.PubkeyToAddress(users["signer2"].PublicKey),
	}
	sys, err := deploy.Deploy(ctx, client, admin, deploy.Config{
		Signers: signerAddrs, MinSigners: 2, MaxReportAge: 60, MaxSpreadBps: 50,
		Keepers:   []common.Address{crypto.PubkeyToAddress(users["keeper"].PublicKey)},
		RiskAdmin: admin.From, OracleAdmin: admin.From, Guardian: admin.From,
		MarketName: "ETH-USD", Params: deploy.DefaultRiskParams(), ReceiptPoll: 50 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("deploy: %v", err)
	}
	deployBlock, _ := client.BlockNumber(ctx)
	s := &session{t: t, ctx: ctx, client: client, chainID: chainID, sys: sys, users: users}
	s.usd, _ = bindings.NewMockUSD(sys.USD, client)
	s.book, _ = bindings.NewOrderBook(sys.OrderBook, client)
	s.vault, _ = bindings.NewLPVault(sys.Vault, client)
	s.market, _ = bindings.NewPerpsMarket(sys.Market, client)

	// Differential check against the deployed verifier: Go and Solidity agree on the EIP-712 digest.
	oracle, _ := bindings.NewOracleVerifier(sys.Oracle, client)
	onchain, err := oracle.ReportDigest(&bind.CallOpts{Context: ctx}, sys.MarketID, wad(3_000), 1_700_000_000)
	if err != nil {
		t.Fatal(err)
	}
	if want := report.Digest(report.Domain{ChainID: chainID, Verifier: sys.Oracle}, sys.MarketID, wad(3_000), 1_700_000_000); common.Hash(onchain) != want {
		t.Fatalf("digest mismatch: chain %x, go %s", onchain, want)
	}

	// Keystores, password file and the scripted path.
	pw := filepath.Join(dir, "password.txt")
	if err := os.WriteFile(pw, []byte(password+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	keystore := map[string]string{}
	for _, n := range []string{"keeper", "signer0", "signer1", "signer2"} {
		if keystore[n], err = keys.Write(dir, n, users[n], password, true); err != nil {
			t.Fatal(err)
		}
	}
	pathDoc, _ := json.Marshal(map[string]any{"name": "integration", "dtSeconds": 1, "prices": scriptedPath()})
	pathFile := filepath.Join(dir, "path.json")
	if err := os.WriteFile(pathFile, pathDoc, 0o644); err != nil {
		t.Fatal(err)
	}
	startAt := time.Now().Add(2 * time.Second).Unix()

	var signerURLs []string
	for i, noise := range []string{"-3", "0", "3"} {
		name := fmt.Sprintf("signer%d", i)
		addrFile := filepath.Join(dir, name+".addr")
		start(t, dir, name, signerBin,
			"-keystore", keystore[name], "-password-file", pw, "-path", pathFile,
			"-chain-id", chainID.String(), "-verifier", sys.Oracle.Hex(), "-listen", "127.0.0.1:0",
			"-addr-file", addrFile, "-start", fmt.Sprint(startAt), "-noise-bps", noise)
		signerURLs = append(signerURLs, "http://"+waitFile(t, addrFile, 60*time.Second))
	}
	metricsFile := filepath.Join(dir, "keeper.metrics.addr")
	start(t, dir, "keeper", keeperBin,
		"-rpc", rpcURL, "-market", sys.Market.Hex(), "-signers", strings.Join(signerURLs, ","),
		"-keystore", keystore["keeper"], "-password-file", pw, "-poll", "500ms",
		"-from-block", fmt.Sprint(deployBlock), "-metrics-listen", "127.0.0.1:0", "-metrics-addr-file", metricsFile,
		"-log-level", "debug")
	metricsURL := "http://" + waitFile(t, metricsFile, 60*time.Second) + "/metrics"

	// Setup phase (flat price): LP liquidity, three market orders and a take-profit.
	for _, n := range []string{"lp", "alice", "bob", "carol"} {
		s.fund(n)
	}
	s.send("lp", func(o *bind.TransactOpts) (*types.Transaction, error) {
		return s.vault.RequestDeposit(o, wad(200_000), big.NewInt(0), fee)
	})
	eventually(t, "LP deposit settled by the keeper", 30*time.Second, func() bool {
		b, _ := s.vault.BalanceOf(&bind.CallOpts{Context: ctx}, s.addr("lp"))
		return b.Sign() > 0
	})
	s.order("alice", 0, true, wad(150_000), wad(20_000), big.NewInt(0))
	s.order("bob", 0, false, wad(20_000), wad(1_500), big.NewInt(0))
	s.order("carol", 0, true, wad(10_000), wad(2_000), big.NewInt(0))
	s.order("carol", 3, true, maxUint128, big.NewInt(0), wad(3_200))
	eventually(t, "market orders filled", 30*time.Second, func() bool {
		return s.size("alice", true).Sign() > 0 && s.size("bob", false).Sign() > 0 && s.size("carol", true).Sign() > 0
	})
	if time.Now().Unix() >= startAt+setupWindow {
		t.Fatalf("setup took longer than the %ds flat window; the scripted moves already started", setupWindow)
	}
	aliceSize := s.size("alice", true)

	// +10%: the keeper liquidates bob and executes carol's take-profit.
	eventually(t, "bob liquidated and carol's take-profit executed", 3*time.Minute, func() bool {
		return s.size("bob", false).Sign() == 0 && s.size("carol", true).Sign() == 0
	})
	// +67%: trader PnL crosses 45% of the pool; the keeper deleverages alice.
	eventually(t, "alice auto-deleveraged", 3*time.Minute, func() bool {
		return s.size("alice", true).Cmp(aliceSize) < 0
	})
	call := &bind.CallOpts{Context: ctx}
	factor, err := s.market.PnlToPoolFactor(call, wad(5_000))
	if err != nil {
		t.Fatal(err)
	}
	if factor.Factor.Cmp(new(big.Int).SetUint64(450_000_000_000_000_000)) > 0 {
		t.Fatalf("PnL factor still above the ADL threshold: %s", factor.Factor)
	}

	// Wind down: alice closes, the LP redeems everything; the keeper settles both.
	s.order("alice", 1, true, maxUint128, big.NewInt(0), big.NewInt(0))
	eventually(t, "alice closed", time.Minute, func() bool { return s.size("alice", true).Sign() == 0 })
	shares, _ := s.vault.BalanceOf(call, s.addr("lp"))
	s.send("lp", func(o *bind.TransactOpts) (*types.Transaction, error) {
		return s.vault.RequestRedeem(o, shares, big.NewInt(0), fee)
	})
	eventually(t, "LP fully redeemed", time.Minute, func() bool {
		b, _ := s.vault.BalanceOf(call, s.addr("lp"))
		supply, _ := s.vault.TotalSupply(call)
		return b.Sign() == 0 && supply.Sign() == 0
	})

	// Events emitted along the way.
	fo := &bind.FilterOpts{Start: deployBlock, Context: ctx}
	count := func(it interface {
		Next() bool
		Close() error
	}) int {
		n := 0
		for it.Next() {
			n++
		}
		_ = it.Close()
		return n
	}
	liqIt, _ := s.market.FilterPositionLiquidated(fo, nil, nil, nil)
	adlIt, _ := s.market.FilterPositionAutoDeleveraged(fo, nil, nil)
	execIt, _ := s.book.FilterOrderExecuted(fo, nil, nil)
	if n := count(liqIt); n != 1 {
		t.Fatalf("liquidations: %d", n)
	}
	if n := count(adlIt); n < 1 {
		t.Fatalf("auto-deleverages: %d", n)
	}
	if n := count(execIt); n != 5 {
		t.Fatalf("executed orders: %d (3 opens, 1 take-profit, 1 close)", n)
	}

	// Custody conservation across the three contracts.
	bal := func(a common.Address) *big.Int { b, _ := s.usd.BalanceOf(call, a); return b }
	pool, _ := s.market.PoolAmount(call)
	impact, _ := s.market.ImpactPoolAmount(call)
	collateral, _ := s.market.TotalCollateral(call)
	if new(big.Int).Add(new(big.Int).Add(pool, impact), collateral).Cmp(bal(sys.Market)) != 0 {
		t.Fatal("market balance != pool + impact pool + collateral")
	}
	escrow, _ := s.book.TotalEscrow(call)
	vaultEscrow, _ := s.vault.EscrowedAssets(call)
	if escrow.Cmp(bal(sys.OrderBook)) != 0 || vaultEscrow.Cmp(bal(sys.Vault)) != 0 {
		t.Fatal("escrow balances out of sync")
	}

	// Keeper and signer metrics reflect the session. The keeper counts an action once it has polled the receipt,
	// which can be a moment after the test sees the state change.
	checks := map[string]float64{
		`keeper_actions_total{action="order",result="success"}`:       5,
		`keeper_actions_total{action="liquidation",result="success"}`: 1,
		`keeper_actions_total{action="lp_request",result="success"}`:  2,
	}
	var body string
	eventually(t, "keeper metrics up to date", 30*time.Second, func() bool {
		body = scrape(t, metricsURL)
		for series, want := range checks {
			if metricValue(body, series) != want {
				return false
			}
		}
		return true
	})
	if metricValue(body, `keeper_actions_total{action="adl",result="success"}`) < 1 {
		t.Fatal("adl metric not incremented")
	}
	// Against a head that lags the signers' clocks, no settlement was ever simulated with a report from the future.
	for _, action := range []string{"order", "lp_request", "liquidation"} {
		series := `keeper_actions_total{action="` + action + `",result="reverted"}`
		if got := metricValue(body, series); got != 0 {
			t.Fatalf("%s = %v, want 0", series, got)
		}
	}
	if metricValue(scrape(t, signerURLs[0]+"/metrics"), "signer_reports_backdated_total") < 1 {
		t.Fatal("signers never dated a report at the lagging head")
	}
	if metricValue(scrape(t, signerURLs[0]+"/metrics"), "signer_reports_served_total") < 10 {
		t.Fatal("signer metrics not incremented")
	}
	t.Logf("session settled: liquidations=1 adl=%v orders=5 lp=2 final pnl factor=%s",
		metricValue(body, `keeper_actions_total{action="adl",result="success"}`), factor.Factor)
}
