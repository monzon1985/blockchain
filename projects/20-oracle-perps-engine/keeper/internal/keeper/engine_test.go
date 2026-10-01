// SPDX-License-Identifier: MIT

package keeper

import (
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/eth/ethconfig"
	"github.com/ethereum/go-ethereum/ethclient/simulated"
	"github.com/ethereum/go-ethereum/node"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/bindings"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/deploy"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/pricepath"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/report"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/retry"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/signer"
)

var simChainID = big.NewInt(1337)

// clockLead is how far the signers' wall clocks run ahead of the chain head, as on any real chain between blocks
// (12 s L1 slots, 1-2 s L2 blocks). Nodes simulate transactions against the head, so a report dated "now" would be
// from the verifier's future: the keeper must ask for reports dated no later than the head.
const clockLead = 5 * time.Second

// osakaOnly pins the simulated chain to Osaka, the EVM version the contracts are compiled for (and anvil's default).
// geth's dev config also activates later forks whose gas accounting would make estimates differ from mainnet.
func osakaOnly(_ *node.Config, eth *ethconfig.Config) {
	cfg := *eth.Genesis.Config
	cfg.BogotaTime = nil
	cfg.AmsterdamTime = nil
	eth.Genesis.Config = &cfg
}

// autoMine commits a block after every transaction, like anvil's automine mode.
type autoMine struct {
	simulated.Client
	sim *simulated.Backend
}

func (a autoMine) SendTransaction(ctx context.Context, tx *types.Transaction) error {
	if err := a.Client.SendTransaction(ctx, tx); err != nil {
		return err
	}
	a.sim.Commit()
	return nil
}

// blackHole accepts transactions but swallows the next `drop` of them (-1: all) without ever mining them, like a
// node that evicts an underpriced transaction or loses its mempool on a restart.
type blackHole struct {
	autoMine
	mu   sync.Mutex
	drop int
	sent []*types.Transaction
}

func (b *blackHole) SendTransaction(ctx context.Context, tx *types.Transaction) error {
	b.mu.Lock()
	b.sent = append(b.sent, tx)
	swallow := b.drop != 0
	if b.drop > 0 {
		b.drop--
	}
	b.mu.Unlock()
	if swallow {
		return nil
	}
	return b.autoMine.SendTransaction(ctx, tx)
}

func (b *blackHole) setDrop(n int) {
	b.mu.Lock()
	b.drop = n
	b.mu.Unlock()
}

func (b *blackHole) transactions() []*types.Transaction {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]*types.Transaction(nil), b.sent...)
}

// swapHandler lets a test replace a signer's HTTP handler after the keeper has been given its URL.
type swapHandler struct {
	mu sync.Mutex
	h  http.Handler
}

func (s *swapHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	h := s.h
	s.mu.Unlock()
	h.ServeHTTP(w, r)
}

func (s *swapHandler) set(h http.Handler) {
	s.mu.Lock()
	s.h = h
	s.mu.Unlock()
}

func wad(v int64) *big.Int { return new(big.Int).Mul(big.NewInt(v), big.NewInt(1e18)) }

type harness struct {
	t          *testing.T
	sim        *simulated.Backend
	backend    autoMine
	hole       *blackHole
	sys        *deploy.System
	usd        *bindings.MockUSD
	book       *bindings.OrderBook
	vault      *bindings.LPVault
	market     *bindings.PerpsMarket
	engine     *Engine
	metrics    *Metrics
	users      map[string]*ecdsa.PrivateKey
	signerKeys []*ecdsa.PrivateKey
	signers    []*signer.Server
	handlers   []*swapHandler
	urls       []string
	path       *pricepath.Path
	start      time.Time
}

type settings struct {
	contractSigner int // index of a signer-set member that is an ERC-1271 wallet (-1: none)
	receiptTimeout time.Duration
}

type option func(*settings)

// withContractSigner makes signer i an ERC-1271 contract wallet owned by its key.
func withContractSigner(i int) option { return func(s *settings) { s.contractSigner = i } }

// withReceiptTimeout shortens the wait before a transaction is replaced.
func withReceiptTimeout(d time.Duration) option { return func(s *settings) { s.receiptTimeout = d } }

// newHarness deploys the system on an in-process chain and starts three in-process signers that quote a
// three-step path (3000, 3300, 5000; one step per hour of chain time) with wall clocks clockLead ahead of the head.
// The keeper's transactions go through a blackHole backend that tests can make lose transactions.
func newHarness(t *testing.T, opts ...option) *harness {
	t.Helper()
	cfg := settings{contractSigner: -1, receiptTimeout: 2 * time.Second}
	for _, o := range opts {
		o(&cfg)
	}
	names := []string{"admin", "keeper", "lp", "alice", "bob", "carol"}
	users := map[string]*ecdsa.PrivateKey{}
	alloc := types.GenesisAlloc{}
	for _, n := range names {
		k, _ := crypto.GenerateKey()
		users[n] = k
		alloc[crypto.PubkeyToAddress(k.PublicKey)] = types.Account{Balance: new(big.Int).Mul(big.NewInt(100), big.NewInt(1e18))}
	}
	sim := simulated.NewBackend(alloc, osakaOnly)
	t.Cleanup(func() { _ = sim.Close() })
	b := autoMine{Client: sim.Client(), sim: sim}
	h := &harness{t: t, sim: sim, backend: b, users: users}
	h.hole = &blackHole{autoMine: b}

	ctx := context.Background()
	h.signerKeys = make([]*ecdsa.PrivateKey, 3)
	members := make([]common.Address, 3)
	for i := range h.signerKeys {
		h.signerKeys[i], _ = crypto.GenerateKey()
		members[i] = crypto.PubkeyToAddress(h.signerKeys[i].PublicKey)
	}
	if i := cfg.contractSigner; i >= 0 {
		wallet, tx, _, err := bindings.DeployMockERC1271Signer(h.opts("admin"), b, members[i])
		if err != nil {
			t.Fatal(err)
		}
		if _, err := deploy.WaitMined(ctx, b, tx.Hash(), time.Millisecond); err != nil {
			t.Fatal(err)
		}
		members[i] = wallet
	}
	sys, err := deploy.Deploy(ctx, b, h.opts("admin"), deploy.Config{
		Signers: members, MinSigners: 2, MaxReportAge: 60, MaxSpreadBps: 50,
		Keepers:   []common.Address{h.addr("keeper")},
		RiskAdmin: h.addr("admin"), OracleAdmin: h.addr("admin"), Guardian: h.addr("admin"),
		MarketName: "ETH-USD", Params: deploy.DefaultRiskParams(), ReceiptPoll: 5 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("deploy: %v", err)
	}
	h.sys = sys
	h.usd, _ = bindings.NewMockUSD(sys.USD, b)
	h.book, _ = bindings.NewOrderBook(sys.OrderBook, b)
	h.vault, _ = bindings.NewLPVault(sys.Vault, b)
	h.market, _ = bindings.NewPerpsMarket(sys.Market, b)

	h.path, err = pricepath.Parse([]byte(`{"name":"test","dtSeconds":3600,"prices":[` +
		`"3000000000000000000000","3300000000000000000000","5000000000000000000000"]}`))
	if err != nil {
		t.Fatal(err)
	}
	h.start = h.chainNow()
	for i, k := range h.signerKeys {
		account := common.Address{}
		if i == cfg.contractSigner {
			account = members[i]
		}
		s, err := signer.New(signer.Config{
			Key: k, Domain: h.domain(), MarketID: sys.MarketID, Path: h.path, Start: h.start, NoiseBps: int64(i) - 1,
			Account: account, Now: h.wallClock, Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		})
		if err != nil {
			t.Fatal(err)
		}
		sw := &swapHandler{h: s.Handler()}
		srv := httptest.NewServer(sw)
		t.Cleanup(srv.Close)
		h.signers = append(h.signers, s)
		h.handlers = append(h.handlers, sw)
		h.urls = append(h.urls, srv.URL)
	}

	h.metrics = NewMetrics()
	h.engine, err = New(ctx, Config{
		Backend: h.hole, ChainID: simChainID, Market: sys.Market, SignerURLs: h.urls, Key: users["keeper"],
		Retry: retry.Policy{Attempts: 2, Initial: time.Millisecond}, ReceiptPoll: 5 * time.Millisecond,
		ReceiptTimeout: cfg.receiptTimeout, Logger: testLogger(), Metrics: h.metrics,
	})
	if err != nil {
		t.Fatal(err)
	}
	return h
}

// testLogger discards logs unless PERPS_KEEPER_DEBUG=1.
func testLogger() *slog.Logger {
	if os.Getenv("PERPS_KEEPER_DEBUG") == "1" {
		return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
	}
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func (h *harness) domain() report.Domain {
	return report.Domain{ChainID: simChainID, Verifier: h.sys.Oracle}
}

// chainNow is the chain head's timestamp.
func (h *harness) chainNow() time.Time {
	head, err := h.backend.HeaderByNumber(context.Background(), nil)
	if err != nil {
		h.t.Fatal(err)
	}
	return time.Unix(int64(head.Time), 0)
}

// wallClock is the signers' clock: clockLead ahead of the head, as between two blocks of a live chain.
func (h *harness) wallClock() time.Time { return h.chainNow().Add(clockLead) }

func (h *harness) addr(name string) common.Address {
	return crypto.PubkeyToAddress(h.users[name].PublicKey)
}

func (h *harness) opts(name string) *bind.TransactOpts {
	o, err := bind.NewKeyedTransactorWithChainID(h.users[name], simChainID)
	if err != nil {
		h.t.Fatal(err)
	}
	return o
}

func (h *harness) do(name string, f func(*bind.TransactOpts) (*types.Transaction, error)) {
	h.t.Helper()
	tx, err := f(h.opts(name))
	if err != nil {
		h.t.Fatalf("%s: %v", name, err)
	}
	if _, err := deploy.WaitMined(context.Background(), h.backend, tx.Hash(), time.Millisecond); err != nil {
		h.t.Fatalf("%s: %v", name, err)
	}
}

func (h *harness) fund(name string, amount *big.Int) {
	h.do(name, func(o *bind.TransactOpts) (*types.Transaction, error) { return h.usd.Mint(o, h.addr(name), amount) })
	h.do(name, func(o *bind.TransactOpts) (*types.Transaction, error) {
		return h.usd.Approve(o, h.sys.OrderBook, new(big.Int).Lsh(big.NewInt(1), 255))
	})
	h.do(name, func(o *bind.TransactOpts) (*types.Transaction, error) {
		return h.usd.Approve(o, h.sys.Vault, new(big.Int).Lsh(big.NewInt(1), 255))
	})
}

func (h *harness) order(name string, kind uint8, isLong bool, size, collateral, trigger *big.Int) {
	acceptable := new(big.Int)
	increase := kind == 0 || kind == 2
	if isLong == increase {
		acceptable = new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 128), big.NewInt(1))
	}
	fee := new(big.Int).Div(wad(1), big.NewInt(10))
	h.do(name, func(o *bind.TransactOpts) (*types.Transaction, error) {
		return h.book.CreateOrder(o, kind, isLong, size, collateral, trigger, acceptable, fee)
	})
}

func (h *harness) requestDeposit(name string, amount *big.Int) {
	fee := new(big.Int).Div(wad(1), big.NewInt(10))
	h.do(name, func(o *bind.TransactOpts) (*types.Transaction, error) {
		return h.vault.RequestDeposit(o, amount, big.NewInt(0), fee)
	})
}

// tick mines an empty block (time passes between keeper iterations, as on a live chain) and runs one iteration.
func (h *harness) tick() {
	h.t.Helper()
	h.sim.Commit()
	h.tickNoCommit()
}

// tickNoCommit runs one iteration on the current head.
func (h *harness) tickNoCommit() {
	h.t.Helper()
	if err := h.engine.Tick(context.Background()); err != nil {
		h.t.Fatalf("tick: %v", err)
	}
}

func (h *harness) size(name string, isLong bool) *big.Int {
	p, err := h.market.GetPosition(&bind.CallOpts{}, h.addr(name), isLong)
	if err != nil {
		h.t.Fatal(err)
	}
	return p.SizeUsd
}

func (h *harness) shares(name string) *big.Int {
	s, err := h.vault.BalanceOf(&bind.CallOpts{}, h.addr(name))
	if err != nil {
		h.t.Fatal(err)
	}
	return s
}

func (h *harness) actions(action, result string) float64 {
	return testutil.ToFloat64(h.metrics.Actions.WithLabelValues(action, result))
}

// serve answers GET /report with r.
func serve(r report.Report) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(r)
	})
}

// TestEngineRunsTheExchange drives a full session in-process: an LP deposit, three opens and a take-profit,
// a liquidation after a +10% move, and auto-deleveraging after a +67% squeeze. The signers' clocks run ahead of
// the chain head throughout.
func TestEngineRunsTheExchange(t *testing.T) {
	h := newHarness(t)
	for _, n := range []string{"lp", "alice", "bob", "carol"} {
		h.fund(n, wad(1_000_000))
	}
	h.requestDeposit("lp", wad(200_000))
	h.tick()
	if h.shares("lp").Cmp(wad(200_000)) != 0 {
		t.Fatalf("LP deposit not settled: %s shares", h.shares("lp"))
	}

	h.order("alice", 0, true, wad(150_000), wad(20_000), big.NewInt(0))
	h.order("bob", 0, false, wad(20_000), wad(1_500), big.NewInt(0))
	h.order("carol", 0, true, wad(10_000), wad(2_000), big.NewInt(0))
	h.order("carol", 3, true, new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 128), big.NewInt(1)), big.NewInt(0), wad(3_200))
	h.tick()
	if h.size("alice", true).Sign() == 0 || h.size("bob", false).Sign() == 0 || h.size("carol", true).Sign() == 0 {
		t.Fatal("market orders not filled")
	}
	if got := h.actions("order", "success"); got != 3 {
		t.Fatalf("expected 3 fills (take-profit waits for its trigger), got %v", got)
	}

	// SidePnl mirrors the contract's side PnL (and its rounding): their positive parts sum to positivePnl.
	call := &bind.CallOpts{}
	for _, price := range []*big.Int{wad(2_777), wad(3_000), wad(3_333)} {
		sum := new(big.Int)
		for _, isLong := range []bool{true, false} {
			side, _ := h.market.GetSide(call, isLong)
			if p := SidePnl(isLong, side.OpenInterest, side.OpenInterestInTokens, price); p.Sign() > 0 {
				sum.Add(sum, p)
			}
		}
		onchain, err := h.market.PnlToPoolFactor(call, price)
		if err != nil || onchain.PositivePnl.Cmp(sum) != 0 {
			t.Fatalf("price %s: SidePnl sum %s, market %v (%v)", price, sum, onchain.PositivePnl, err)
		}
	}

	// +10%: bob's 13x short is liquidated and carol's take-profit at 3,200 fills.
	if err := h.sim.AdjustTime(time.Hour); err != nil {
		t.Fatal(err)
	}
	h.tick()
	h.tick() // positions discovered in the first tick are liquidatable from the next report
	if h.size("bob", false).Sign() != 0 {
		t.Fatal("bob not liquidated")
	}
	if h.size("carol", true).Sign() != 0 {
		t.Fatal("take-profit not executed")
	}
	if h.actions("liquidation", "success") != 1 {
		t.Fatalf("liquidations: %v", h.actions("liquidation", "success"))
	}

	// +67% squeeze: alice's PnL exceeds 45% of the pool and she is deleveraged towards the 40% target.
	if err := h.sim.AdjustTime(time.Hour); err != nil {
		t.Fatal(err)
	}
	before := h.size("alice", true)
	h.tick()
	after := h.size("alice", true)
	if after.Cmp(before) >= 0 {
		t.Fatalf("alice not deleveraged: %s -> %s", before, after)
	}
	if h.actions("adl", "success") != 1 {
		t.Fatalf("adl count %v", h.actions("adl", "success"))
	}
	factor, err := h.market.PnlToPoolFactor(call, wad(5_000))
	if err != nil {
		t.Fatal(err)
	}
	limit := new(big.Int).SetUint64(450_000_000_000_000_000)
	if factor.Factor.Cmp(limit) > 0 {
		t.Fatalf("pnl factor still above the ADL threshold: %s", factor.Factor)
	}
	for _, result := range []string{"reverted", "error"} {
		for _, action := range []string{"lp_request", "order", "liquidation", "adl"} {
			if h.actions(action, result) != 0 {
				t.Fatalf("%s %s: %v", action, result, h.actions(action, result))
			}
		}
	}
	if testutil.ToFloat64(h.metrics.Ticks) < 5 {
		t.Fatal("ticks not counted")
	}
}

// TestEngineWaitsForReportsNewerThanTheOrder checks the latency-arbitrage guard from the keeper's side. Right after
// the order's block, the newest report the chain accepts is dated at that block, i.e. not newer than the order:
// the keeper must not even try. Once a later block exists, the order fills.
func TestEngineWaitsForReportsNewerThanTheOrder(t *testing.T) {
	h := newHarness(t)
	h.fund("lp", wad(1_000_000))
	h.fund("alice", wad(100_000))
	h.requestDeposit("lp", wad(500_000))
	h.tick()
	h.order("alice", 0, true, wad(10_000), wad(2_000), big.NewInt(0))
	o, _ := h.book.GetOrder(&bind.CallOpts{}, big.NewInt(1))
	if o.CreatedAt == 0 || o.CreatedAt != uint64(h.chainNow().Unix()) {
		t.Fatal("order not stored in the head block")
	}

	h.tickNoCommit()
	if h.size("alice", true).Sign() != 0 {
		t.Fatal("order filled with reports that do not postdate it")
	}
	for _, result := range []string{"success", "reverted", "error"} {
		if got := h.actions("order", result); got != 0 {
			t.Fatalf("keeper attempted the order (%s = %v) before a newer report could exist", result, got)
		}
	}

	h.tick()
	if h.size("alice", true).Sign() == 0 {
		t.Fatal("fresh reports should settle the order")
	}
	if h.actions("order", "reverted") != 0 || h.actions("order", "success") != 1 {
		t.Fatal("expected exactly one successful order and no revert")
	}
}

// TestEngineSurvivesOneFaultySigner is the regression for a review finding: one faulty or malicious signer out of
// three used to halt all settlement, because its report was included in the batch and every transaction then
// reverted on-chain (or Aggregate failed outright). Each case replaces signer 3; the two honest signers must still
// settle an LP deposit in the very next tick without a single reverted transaction.
func TestEngineSurvivesOneFaultySigner(t *testing.T) {
	type faulty func(h *harness) http.Handler
	signAt := func(h *harness, key *ecdsa.PrivateKey, market [32]byte, ts time.Time) report.Report {
		price := pricepath.ApplyBps(h.path.PriceAt(h.start, ts), 1)
		r, err := report.Sign(key, h.domain(), market, price, uint64(ts.Unix()))
		if err != nil {
			h.t.Fatal(err)
		}
		return r
	}
	// reason is the off-chain check expected to drop the report ("" when it is never rejected: an echo is merged
	// with the original, an outlier is left out of the batch).
	cases := []struct {
		name   string
		reason string
		signer faulty
	}{
		{"honest clock ahead of the head, ignoring notAfter", "future", func(h *harness) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				_ = json.NewEncoder(w).Encode(signAt(h, h.signerKeys[2], h.sys.MarketID, h.wallClock()))
			})
		}},
		{"honest clock 90 s behind", "stale", func(h *harness) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				_ = json.NewEncoder(w).Encode(signAt(h, h.signerKeys[2], h.sys.MarketID, h.chainNow().Add(-90*time.Second)))
			})
		}},
		{"raw recovery id (v - 27)", "signature", func(h *harness) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				r := signAt(h, h.signerKeys[2], h.sys.MarketID, h.chainNow())
				r.Signature[64] -= 27
				_ = json.NewEncoder(w).Encode(r)
			})
		}},
		{"high-s twin of a valid signature", "signature", func(h *harness) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				r := signAt(h, h.signerKeys[2], h.sys.MarketID, h.chainNow())
				n := crypto.S256().Params().N
				s := new(big.Int).SetBytes(r.Signature[32:64])
				copy(r.Signature[32:64], common.LeftPadBytes(new(big.Int).Sub(n, s).Bytes(), 32))
				r.Signature[64] = 27 + 28 - r.Signature[64]
				_ = json.NewEncoder(w).Encode(r)
			})
		}},
		{"echoes signer 1's report", "", func(h *harness) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				resp, err := http.Get(h.urls[0] + req.URL.RequestURI())
				if err != nil {
					http.Error(w, err.Error(), http.StatusBadGateway)
					return
				}
				defer resp.Body.Close()
				_, _ = io.Copy(w, resp.Body)
			})
		}},
		{"wrong market", "malformed", func(h *harness) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				_ = json.NewEncoder(w).Encode(signAt(h, h.signerKeys[2], report.MarketID("BTC-USD"), h.chainNow()))
			})
		}},
		{"outlier price (+10%)", "", func(h *harness) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				ts := h.chainNow()
				price := pricepath.ApplyBps(h.path.PriceAt(h.start, ts), 1_000)
				r, _ := report.Sign(h.signerKeys[2], h.domain(), h.sys.MarketID, price, uint64(ts.Unix()))
				_ = json.NewEncoder(w).Encode(r)
			})
		}},
		{"key outside the signer set", "not_in_set", func(h *harness) http.Handler {
			stranger, _ := crypto.GenerateKey()
			return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				_ = json.NewEncoder(w).Encode(signAt(h, stranger, h.sys.MarketID, h.chainNow()))
			})
		}},
		{"down", "fetch", func(*harness) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				http.Error(w, "unavailable", http.StatusServiceUnavailable)
			})
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t)
			h.handlers[2].set(tc.signer(h))
			h.fund("lp", wad(1_000_000))
			h.requestDeposit("lp", wad(100_000))
			h.tick()
			if h.shares("lp").Sign() == 0 {
				t.Fatal("LP deposit not settled with two honest signers")
			}
			if h.actions("lp_request", "reverted") != 0 || h.actions("lp_request", "error") != 0 {
				t.Fatal("the keeper submitted a batch the chain rejected")
			}
			// Each fault is caught by its own off-chain rule; no batch had to be rejected on-chain first.
			if tc.reason != "" {
				if got := testutil.ToFloat64(h.metrics.ReportErrors.WithLabelValues(h.urls[2], tc.reason)); got != 1 {
					t.Fatalf("report not dropped as %q (%v)", tc.reason, got)
				}
			}
			if got := testutil.ToFloat64(h.metrics.BatchFallbacks); got != 0 {
				t.Fatalf("%v candidate batches failed on-chain", got)
			}
		})
	}
}

// TestEngineFallsBackWhenTheChainRejectsABatch covers reports that pass every off-chain check but fail on-chain:
// the next candidate batch is used instead of reverting every action of the tick.
func TestEngineFallsBackWhenTheChainRejectsABatch(t *testing.T) {
	h := newHarness(t)
	h.sim.Commit()
	now := uint64(h.chainNow().Unix())
	good := make([]report.Report, 2)
	for i := range good {
		r, err := report.Sign(h.signerKeys[i], h.domain(), h.sys.MarketID, wad(3_000), now)
		if err != nil {
			t.Fatal(err)
		}
		good[i] = r
	}
	// Signed for another verifier deployment: a valid ECDSA signature, but not over this domain's digest.
	other := report.Domain{ChainID: simChainID, Verifier: common.HexToAddress("0x1234")}
	bad, _ := report.Sign(h.signerKeys[2], other, h.sys.MarketID, wad(3_000), now)
	batches := []report.Batch{
		{Reports: []report.Report{good[0], good[1], bad}, Median: wad(3_000)},
		{Reports: good, Median: wad(3_000)},
	}
	got, err := h.engine.firstAccepted(&bind.CallOpts{}, batches)
	if err != nil || len(got.Reports) != 2 {
		t.Fatalf("fallback not used: %v", err)
	}
	if testutil.ToFloat64(h.metrics.BatchFallbacks) != 1 {
		t.Fatal("fallback not counted")
	}
	if _, err := h.engine.firstAccepted(&bind.CallOpts{}, batches[:1]); !errors.Is(err, errNoBatch) {
		t.Fatalf("a rejected-only list must fail: %v", err)
	}
}

// TestEngineSettlesWithAContractSigner: with an ERC-1271 wallet in the signer set, the keeper verifies it with an
// eth_call to isValidSignature instead of dropping it, so the set keeps its redundancy when an EOA signer is down.
func TestEngineSettlesWithAContractSigner(t *testing.T) {
	h := newHarness(t, withContractSigner(2))
	h.handlers[0].set(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
	}))
	h.fund("lp", wad(1_000_000))
	h.requestDeposit("lp", wad(100_000))
	h.tick()
	if h.shares("lp").Sign() == 0 {
		t.Fatal("deposit not settled by the EOA signer and the contract signer")
	}
	if got := testutil.ToFloat64(h.metrics.ReportErrors.WithLabelValues(h.urls[2], "signature")); got != 0 {
		t.Fatalf("contract signer's report rejected %v times", got)
	}

	// A wallet that does not accept the signature is dropped (here: signed by a key that is not the owner).
	stranger, _ := crypto.GenerateKey()
	h.handlers[2].set(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		r, _ := report.Sign(stranger, h.domain(), h.sys.MarketID, wad(3_000), uint64(h.chainNow().Unix()))
		r.Signer = h.signers[2].Address()
		_ = json.NewEncoder(w).Encode(r)
	}))
	h.tick()
	if got := testutil.ToFloat64(h.metrics.ReportErrors.WithLabelValues(h.urls[2], "signature")); got != 1 {
		t.Fatalf("invalid ERC-1271 signature not rejected off-chain (%v)", got)
	}
}

// TestEngineReplacesATransactionThatIsNeverMined is the regression for a keeper that waited forever on a
// transaction the node accepted but never mined: after ReceiptTimeout the same nonce is re-sent with higher fees.
func TestEngineReplacesATransactionThatIsNeverMined(t *testing.T) {
	h := newHarness(t, withReceiptTimeout(200*time.Millisecond))
	h.fund("lp", wad(1_000_000))
	h.requestDeposit("lp", wad(100_000))
	h.hole.setDrop(1)
	start := time.Now()
	h.tick()
	if elapsed := time.Since(start); elapsed > 10*time.Second {
		t.Fatalf("tick took %s", elapsed)
	}
	if h.shares("lp").Sign() == 0 || h.actions("lp_request", "success") != 1 {
		t.Fatal("deposit not settled by the replacement")
	}
	sent := h.hole.transactions()
	if len(sent) != 2 {
		t.Fatalf("expected the lost transaction and one replacement, got %d", len(sent))
	}
	first, second := sent[0], sent[1]
	if first.Nonce() != second.Nonce() {
		t.Fatalf("replacement used nonce %d, original %d", second.Nonce(), first.Nonce())
	}
	if second.GasTipCap().Cmp(first.GasTipCap()) <= 0 || second.GasFeeCap().Cmp(first.GasFeeCap()) <= 0 {
		t.Fatal("replacement must raise both fee caps")
	}
	minCap := new(big.Int).Div(new(big.Int).Mul(first.GasFeeCap(), big.NewInt(125)), big.NewInt(100))
	if second.GasFeeCap().Cmp(minCap) < 0 {
		t.Fatalf("fee cap raised by less than 25%%: %s -> %s", first.GasFeeCap(), second.GasFeeCap())
	}
	if testutil.ToFloat64(h.metrics.Replacements) != 1 {
		t.Fatal("replacement not counted")
	}
}

// TestEngineTickIsBoundedWhenNothingIsMined: a node that accepts but never mines anything cannot stall the keeper.
// The tick gives up after MaxReplacements, and once the node recovers the next tick reuses (and outbids) the stuck
// nonce, so later transactions are not queued behind it.
func TestEngineTickIsBoundedWhenNothingIsMined(t *testing.T) {
	h := newHarness(t, withReceiptTimeout(100*time.Millisecond))
	h.fund("lp", wad(1_000_000))
	h.requestDeposit("lp", wad(100_000))
	h.hole.setDrop(-1)
	start := time.Now()
	h.tick()
	if elapsed := time.Since(start); elapsed > 10*time.Second {
		t.Fatalf("tick took %s: the keeper waits on unmined transactions without bound", elapsed)
	}
	if h.shares("lp").Sign() != 0 || h.actions("lp_request", "error") != 1 {
		t.Fatal("expected the action to be dropped for this tick")
	}
	stuck := h.hole.transactions()
	if len(stuck) != 4 { // the original and MaxReplacements (3) replacements
		t.Fatalf("expected 4 attempts, got %d", len(stuck))
	}

	h.hole.setDrop(0)
	h.tick()
	if h.shares("lp").Sign() == 0 || h.actions("lp_request", "success") != 1 {
		t.Fatal("deposit not settled once the node recovered")
	}
	all := h.hole.transactions()
	last := all[len(all)-1]
	if last.Nonce() != stuck[0].Nonce() || last.GasFeeCap().Cmp(stuck[len(stuck)-1].GasFeeCap()) <= 0 {
		t.Fatal("the recovering tick must replace the stuck nonce with higher fees")
	}
}

func TestNewValidatesConfig(t *testing.T) {
	if _, err := New(context.Background(), Config{}); err == nil {
		t.Fatal("empty config accepted")
	}
}

func TestRankForADL(t *testing.T) {
	a := common.HexToAddress("0xa")
	b := common.HexToAddress("0xb")
	c := common.HexToAddress("0xc")
	up, down := big.NewInt(1), big.NewInt(-1)
	tests := []struct {
		name  string
		cands []Candidate
		want  []common.Address
	}{
		{"by pnl per size", []Candidate{
			{Account: a, Pnl: big.NewInt(10), Size: big.NewInt(100), SidePnl: up},
			{Account: b, Pnl: big.NewInt(30), Size: big.NewInt(100), SidePnl: up},
			{Account: c, Pnl: big.NewInt(50), Size: big.NewInt(1_000), SidePnl: up},
		}, []common.Address{b, a, c}},
		{"losers and empty positions excluded", []Candidate{
			{Account: a, Pnl: big.NewInt(-10), Size: big.NewInt(100), SidePnl: up},
			{Account: b, Pnl: big.NewInt(0), Size: big.NewInt(100), SidePnl: up},
			{Account: c, Pnl: big.NewInt(5), Size: big.NewInt(0), SidePnl: up},
		}, nil},
		{"ties broken by pnl then address", []Candidate{
			{Account: b, Pnl: big.NewInt(10), Size: big.NewInt(100), SidePnl: up},
			{Account: a, Pnl: big.NewInt(10), Size: big.NewInt(100), SidePnl: up},
			{Account: c, Pnl: big.NewInt(20), Size: big.NewInt(200), SidePnl: up},
		}, []common.Address{c, a, b}},
		// The review's counterexample: alice (long, PnL/size 1.0) sits on a long side netting -$650k; carol
		// (short, 0.75) on a short side netting +$1.125M. Only carol lowers the PnL-to-pool factor.
		{"only sides with positive netted PnL", []Candidate{
			{Account: a, IsLong: true, Pnl: wad(100_000), Size: wad(100_000), SidePnl: wad(-650_000)},
			{Account: c, IsLong: false, Pnl: wad(1_125_000), Size: wad(1_500_000), SidePnl: wad(1_125_000)},
			{Account: b, IsLong: true, Pnl: wad(1), Size: wad(1), SidePnl: down},
		}, []common.Address{c}},
		{"unknown side PnL excluded", []Candidate{
			{Account: a, Pnl: big.NewInt(10), Size: big.NewInt(100)},
		}, nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := RankForADL(tc.cands)
			if len(got) != len(tc.want) {
				t.Fatalf("got %d candidates, want %d", len(got), len(tc.want))
			}
			for i := range got {
				if got[i].Account != tc.want[i] {
					t.Fatalf("position %d: got %s want %s", i, got[i].Account, tc.want[i])
				}
			}
		})
	}
}

func TestSidePnlRounding(t *testing.T) {
	tests := []struct {
		name              string
		isLong            bool
		oi, tokens, price *big.Int
		want              *big.Int
	}{
		{"long floors tokens x price", true, big.NewInt(100), big.NewInt(3), wad(1), big.NewInt(-97)},
		{"long rounds a fraction down", true, big.NewInt(0), big.NewInt(1), big.NewInt(5e17), big.NewInt(0)},
		{"short rounds a fraction up", false, big.NewInt(1), big.NewInt(1), big.NewInt(5e17), big.NewInt(0)},
		{"short exact", false, wad(1_500_000), wad(375), wad(1_000), wad(1_125_000)},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := SidePnl(tc.isLong, tc.oi, tc.tokens, tc.price); got.Cmp(tc.want) != 0 {
				t.Fatalf("got %s want %s", got, tc.want)
			}
		})
	}
}

func TestReportWindow(t *testing.T) {
	w := reportWindow{notAfter: 1_000, notBefore: 955}
	tests := []struct {
		ts   uint64
		want error
	}{
		{1_000, nil}, {955, nil}, {1_001, errFuture}, {954, errStale},
	}
	for _, tc := range tests {
		if err := w.check(tc.ts); !errors.Is(err, tc.want) && !(err == nil && tc.want == nil) {
			t.Fatalf("ts %d: got %v want %v", tc.ts, err, tc.want)
		}
	}
}

func TestIsRevert(t *testing.T) {
	tests := []struct {
		err  error
		want bool
	}{
		{nil, false},
		{errors.New("execution reverted: custom error 0x1234"), true},
		{errors.New("Transaction Reverted"), true},
		{errors.New("connection refused"), false},
		{deploy.ErrReverted, true},
	}
	for _, tc := range tests {
		if got := IsRevert(tc.err); got != tc.want {
			t.Fatalf("IsRevert(%v) = %v", tc.err, got)
		}
	}
}
