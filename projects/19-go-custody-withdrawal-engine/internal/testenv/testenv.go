// SPDX-License-Identifier: MIT

// Package testenv runs the complete engine against the in-memory chain simulator with a fake
// clock. It is shared by the app and api test suites and is never linked into the binary.
package testenv

import (
	"context"
	"crypto/ecdsa"
	"database/sql/driver"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/app"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/chainsim"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/clock"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/config"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/deposit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/failpoint"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/metrics"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/policy"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/signer"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/txmgr"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/withdrawal"
)

// Defaults of the simulated deployment.
const (
	Asset         = "tUSD"        // the only customer asset
	Confirmations = 3             // default confirmation depth (NewWith can change it)
	Gwei          = 1_000_000_000 // wei per gwei
)

// Fixed addresses and credentials of the simulated deployment.
var (
	TokenAddr   = common.HexToAddress("0x7070707070707070707070707070707070707070")
	FactoryAddr = common.HexToAddress("0xFAc7000000000000000000000000000000000001")
	ImplAddr    = common.HexToAddress("0x1117000000000000000000000000000000000002")
	Approvers   = []string{"approver-a-token", "approver-b-token", "approver-c-token"}
)

// Env is a full engine running against the chain simulator with a fake clock.
type Env struct {
	T     testing.TB
	Ctx   context.Context
	Chain *chainsim.Chain
	Clock *clock.Fake
	Cfg   *config.Config
	Key   *ecdsa.PrivateKey
	Hot   common.Address
	FP    *failpoint.Set
	App   *app.App
	Dir   string

	// wrapConn, when set, interposes on the engine's database connection (fault injection).
	wrapConn func(driver.Conn) driver.Conn
	// WrapSigner, when set before Start (or a Restart), wraps the hot-wallet signer, so a test
	// can act at the moment a transaction is being signed.
	WrapSigner func(signer.Signer) signer.Signer
}

// Config returns the engine configuration the simulator runs with, storing its files in dir.
func Config(dir string, hot common.Address) *config.Config {
	appr := ""
	for i, tok := range Approvers {
		if i > 0 {
			appr += ","
		}
		appr += fmt.Sprintf(`{"id": "approver-%d", "token_sha256": %q}`, i, policy.HashToken(tok))
	}
	raw := fmt.Sprintf(`{
		"chain": {"rpc_url": "sim://", "chain_id": 31337, "confirmations": %d, "poll_interval": "10ms"},
		"database": {"path": %q},
		"audit": {"path": %q},
		"hot_wallet": {"keystore": "unused", "password_file": "unused"},
		"fees": {"min_tip_wei": "1000000000", "max_fee_wei": "2000000000000", "bump_after_blocks": 2},
		"assets": [{"symbol": %q, "token": %q, "max_per_tx": "1000000000000", "velocity_24h": "5000000000000", "approval_threshold": "500000000"}],
		"policy": {"allowlist_cooldown": "24h", "approvals_required": 2, "approvers": [%s]},
		"clients": [{"id": "gateway", "token_sha256": %q}],
		"deposits": {"factory": %q, "sweep_batch_size": 10},
		"reconcile": {"every_rounds": 1}
	}`, Confirmations, filepath.Join(dir, "custody.db"), filepath.Join(dir, "audit.jsonl"), Asset, TokenAddr.Hex(), appr,
		policy.HashToken("gateway-token"), FactoryAddr.Hex())
	cfg, err := config.Parse([]byte(raw))
	if err != nil {
		panic(err)
	}
	_ = hot
	return cfg
}

// New starts an engine whose hot wallet (derived from seed) holds 1,000,000 tUSD of liquidity.
func New(t testing.TB, seed uint64) *Env {
	t.Helper()
	return NewWith(t, seed, big.NewInt(1_000_000_000_000), nil)
}

// NewWith lets a test choose the hot wallet's token liquidity and tweak the configuration.
func NewWith(t testing.TB, seed uint64, hotTokens *big.Int, tweak func(*config.Config)) *Env {
	t.Helper()
	return NewWithConn(t, seed, hotTokens, tweak, nil)
}

// NewWithConn is NewWith with every database connection of the engine passed through wrap,
// across restarts too. The storage fault-injection tests use it with faultdb.Injector.Wrap.
func NewWithConn(t testing.TB, seed uint64, hotTokens *big.Int, tweak func(*config.Config), wrap func(driver.Conn) driver.Conn) *Env {
	t.Helper()
	key, err := crypto.ToECDSA(crypto.Keccak256([]byte(fmt.Sprintf("custody-sim-%d", seed))))
	if err != nil {
		t.Fatal(err)
	}
	hot := crypto.PubkeyToAddress(key.PublicKey)
	dir := t.TempDir()
	c := chainsim.New(chainsim.Config{
		ChainID:          big.NewInt(31337),
		MinBaseFee:       big.NewInt(Gwei / 4),
		EvictUnderpriced: true,
		Tokens:           []common.Address{TokenAddr},
		Factory:          &chainsim.Factory{Address: FactoryAddr, Implementation: ImplAddr, Destination: hot, Owner: hot, Token: TokenAddr},
		EthAlloc:         map[common.Address]*big.Int{hot: new(big.Int).Mul(big.NewInt(1_000), big.NewInt(1e18))},
		TokenAlloc:       map[common.Address]map[common.Address]*big.Int{TokenAddr: {hot: hotTokens}},
	})
	fp, _ := failpoint.New()
	cfg := Config(dir, hot)
	if tweak != nil {
		tweak(cfg)
	}
	e := &Env{T: t, Ctx: context.Background(), Chain: c, Clock: clock.NewFake(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)),
		Cfg: cfg, Key: key, Hot: hot, FP: fp, Dir: dir, wrapConn: wrap}
	e.Start()
	t.Cleanup(func() {
		if e.App != nil {
			_ = e.App.Close()
		}
	})
	return e
}

// Start builds the engine on the environment's database and chain.
func (e *Env) Start() {
	e.T.Helper()
	var s signer.Signer = signer.NewLocalKeystoreSigner(e.Key)
	if e.WrapSigner != nil {
		s = e.WrapSigner(s)
	}
	a, err := app.New(e.Ctx, e.Cfg, app.Deps{
		Chain: e.Chain, Signer: s, Clock: e.Clock, Failpoints: e.FP,
		Log: Logger(), Metrics: metrics.New(), Store: &store.Options{Synchronous: "OFF", WrapConn: e.wrapConn},
	})
	if err != nil {
		e.T.Fatalf("start engine: %v", err)
	}
	e.App = a
}

// Restart simulates a process crash and restart on the same database: every in-memory
// structure is discarded.
func (e *Env) Restart() {
	e.T.Helper()
	_ = e.App.Close()
	e.App = nil
	e.FP.Disarm()
	e.Start()
}

// FundUser deposits amount to the user's forwarder and runs the engine until it is credited.
func (e *Env) FundUser(user string, amount int64) common.Address {
	e.T.Helper()
	var addr deposit.Address
	if err := e.App.DB.WithTx(e.Ctx, func(tx *store.Tx) error {
		var err error
		addr, err = deposit.Register(e.Ctx, tx, e.App.Deriver, user, e.Clock.Now())
		return err
	}); err != nil {
		e.T.Fatal(err)
	}
	e.Chain.ExternalTransfer(TokenAddr, common.HexToAddress("0xC0FFEE0000000000000000000000000000000000"), addr.Address, big.NewInt(amount))
	for range e.Cfg.Chain.Confirmations + 1 {
		e.Chain.Mine()
		e.Step()
	}
	return addr.Address
}

// Allowlist adds destinations and advances the clock past the cool-down.
func (e *Env) Allowlist(user string, dests ...common.Address) {
	e.T.Helper()
	for _, d := range dests {
		if _, err := e.App.Withdrawals.AddAllowlist(e.Ctx, "gateway", user, d, "test"); err != nil {
			e.T.Fatal(err)
		}
	}
	e.Clock.Advance(25 * time.Hour)
}

// Step runs one round of every engine loop and fails the test on error.
func (e *Env) Step() {
	e.T.Helper()
	if err := e.App.Step(e.Ctx); err != nil {
		e.T.Fatalf("step: %v", err)
	}
}

// Create requests a withdrawal with an idempotency key, as the gateway would.
func (e *Env) Create(key, user string, amount int64, dest common.Address) withdrawal.Response {
	e.T.Helper()
	body, _ := json.Marshal(withdrawal.CreateRequest{AccountID: user, Asset: Asset, Amount: fmt.Sprint(amount), Destination: dest.Hex()})
	resp, err := e.App.Withdrawals.Create(e.Ctx, "gateway", key, body)
	if err != nil {
		e.T.Fatalf("create: %v", err)
	}
	return resp
}

// CreatedID returns the id of the withdrawal a 201 response created.
func CreatedID(t testing.TB, resp withdrawal.Response) string {
	t.Helper()
	if resp.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", resp.Code, resp.Body)
	}
	var v withdrawal.View
	if err := json.Unmarshal(resp.Body, &v); err != nil {
		t.Fatal(err)
	}
	return v.ID
}

// Status returns a withdrawal's current state.
func (e *Env) Status(id string) withdrawal.Status {
	e.T.Helper()
	w, err := withdrawal.Load(e.Ctx, e.App.DB, id)
	if err != nil {
		e.T.Fatal(err)
	}
	return w.Status
}

// RunUntil mines and steps until cond holds.
func (e *Env) RunUntil(max int, cond func() bool) {
	e.T.Helper()
	for i := 0; i < max; i++ {
		if cond() {
			return
		}
		e.Step()
		e.Chain.Mine()
		e.Clock.Advance(time.Second)
	}
	if !cond() {
		e.T.Fatalf("condition not reached after %d iterations", max)
	}
}

// CheckInvariants asserts the ledger, reconciliation and nonce invariants at the current head.
func (e *Env) CheckInvariants() {
	e.T.Helper()
	res, err := ledger.Check(e.Ctx, e.App.DB)
	if err != nil {
		e.T.Fatal(err)
	}
	if !res.OK() {
		e.T.Fatalf("ledger invariants broken: %+v", res)
	}
	_, rep, err := e.App.TrackRound(e.Ctx, true)
	if err != nil {
		e.T.Fatal(err)
	}
	if rep == nil || !rep.OK {
		e.T.Fatalf("reconciliation failed: %+v", rep)
	}
	n, _ := e.Chain.NonceAt(e.Ctx, e.Hot)
	gaps, err := txmgr.FindGaps(e.Ctx, e.App.DB, n)
	if err != nil {
		e.T.Fatal(err)
	}
	if len(gaps) != 0 {
		e.T.Fatalf("nonce gaps remain: %v", gaps)
	}
}

// RegisterFor registers user's deposit address inside tx.
func RegisterFor(e *Env, tx *store.Tx, user string) (deposit.Address, error) {
	return deposit.Register(e.Ctx, tx, e.App.Deriver, user, e.Clock.Now())
}

// Register registers the deposit addresses of users and returns them.
func (e *Env) Register(users ...string) map[string]common.Address {
	e.T.Helper()
	out := map[string]common.Address{}
	if err := e.App.DB.WithTx(e.Ctx, func(tx *store.Tx) error {
		for _, u := range users {
			a, err := RegisterFor(e, tx, u)
			if err != nil {
				return err
			}
			out[u] = a.Address
		}
		return nil
	}); err != nil {
		e.T.Fatal(err)
	}
	return out
}

// CheckDeposits compares the engine's deposit records with chain ground truth: every canonical
// Transfer of the token to a registered deposit address that is at the confirmation depth is
// credited exactly once, with the canonical block hash and amount; nothing else is credited;
// and no deposit at that depth is still pending. A deposit the scanner lost (never scanned,
// stuck pending, or recorded from an abandoned fork) fails here even if every customer balance
// agrees with the engine's own tables.
func (e *Env) CheckDeposits() {
	e.T.Helper()
	head, err := e.Chain.Head(e.Ctx)
	if err != nil {
		e.T.Fatal(err)
	}
	conf := e.Cfg.Chain.Confirmations
	if head.Number+1 < conf {
		return
	}
	maxBlock := head.Number + 1 - conf
	registered := map[common.Address]bool{}
	rows, err := e.App.DB.QueryContext(e.Ctx, `SELECT address FROM deposit_addresses`)
	if err != nil {
		e.T.Fatal(err)
	}
	for rows.Next() {
		var a string
		if err := rows.Scan(&a); err != nil {
			e.T.Fatal(err)
		}
		registered[common.HexToAddress(a)] = true
	}
	rows.Close()
	type key struct {
		tx    common.Hash
		index uint
	}
	want := map[key]chainsim.TransferEvent{}
	for _, ev := range e.Chain.TransferEvents(TokenAddr) {
		if registered[ev.To] && ev.Amount.Sign() > 0 && ev.Block <= maxBlock {
			want[key{ev.TxHash, ev.LogIndex}] = ev
		}
	}
	rows, err = e.App.DB.QueryContext(e.Ctx, `SELECT tx_hash, log_index, block_number, block_hash, amount, status FROM deposits`)
	if err != nil {
		e.T.Fatal(err)
	}
	defer rows.Close()
	credited := map[key]bool{}
	for rows.Next() {
		var txh, bh, amount, status string
		var idx int64
		var block uint64
		if err := rows.Scan(&txh, &idx, &block, &bh, &amount, &status); err != nil {
			e.T.Fatal(err)
		}
		k := key{common.HexToHash(txh), uint(idx)}
		switch status {
		case "credited":
			ev, ok := want[k]
			if !ok || ev.BlockHash != common.HexToHash(bh) || ev.Amount.String() != amount {
				e.T.Fatalf("deposit %s/%d (block %d, %s) is credited but is not a canonical transfer at depth", txh, idx, block, amount)
			}
			credited[k] = true
		case "pending":
			if block <= maxBlock {
				e.T.Fatalf("deposit %s/%d in block %d is still pending at head %d (confirmations %d)", txh, idx, block, head.Number, conf)
			}
		}
	}
	if err := rows.Err(); err != nil {
		e.T.Fatal(err)
	}
	for k, ev := range want {
		if !credited[k] {
			e.T.Fatalf("canonical deposit %s/%d of %s to %s in block %d was never credited", k.tx.Hex(), k.index, ev.Amount, ev.To.Hex(), ev.Block)
		}
	}
}

// JSONUnmarshal is json.Unmarshal, for test packages that do not import encoding/json.
func JSONUnmarshal(b []byte, v any) error { return json.Unmarshal(b, v) }

// Logger discards engine logs unless CUSTODY_SIM_VERBOSE is set.
func Logger() *slog.Logger {
	if os.Getenv("CUSTODY_SIM_VERBOSE") != "" {
		return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	}
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// Addr returns the i-th withdrawal destination used by the tests.
func Addr(i int) common.Address {
	return common.BigToAddress(new(big.Int).Add(big.NewInt(0xD000_0000), big.NewInt(int64(i))))
}

// Dispatch runs the outbox twice: evaluate, then sign.
func (e *Env) Dispatch() {
	e.T.Helper()
	for range 2 { // evaluate, then sign
		if _, err := e.App.Withdrawals.DispatchOnce(e.Ctx); err != nil {
			e.T.Fatal(err)
		}
	}
}

// Track runs one tracker round (with a reconciliation when one is due).
func (e *Env) Track() {
	e.T.Helper()
	if _, _, err := e.App.TrackRound(e.Ctx, false); err != nil {
		e.T.Fatal(err)
	}
}

// Attempts returns a signed withdrawal's nonce slot and its signed transactions.
func (e *Env) Attempts(id string) (txmgr.Slot, []txmgr.Attempt) {
	e.T.Helper()
	w, err := withdrawal.Load(e.Ctx, e.App.DB, id)
	if err != nil || w.Nonce == nil {
		e.T.Fatalf("withdrawal %s has no nonce (%v)", id, err)
	}
	s, err := txmgr.LoadSlot(e.Ctx, e.App.DB, *w.Nonce)
	if err != nil {
		e.T.Fatal(err)
	}
	a, err := txmgr.Attempts(e.Ctx, e.App.DB, *w.Nonce)
	if err != nil {
		e.T.Fatal(err)
	}
	return s, a
}

// TransfersTo counts the canonical token transfers from the hot wallet to dest.
func (e *Env) TransfersTo(dest [20]byte) int {
	n := 0
	for _, tr := range e.Chain.Transfers(TokenAddr, e.Hot) {
		if tr.To == dest {
			n++
		}
	}
	return n
}

// MineAndTrack mines n blocks, running a tracker round after each.
func (e *Env) MineAndTrack(n int) {
	e.T.Helper()
	for range n {
		e.Chain.Mine()
		e.Track()
	}
}

// Reconcile runs a tracker round with a forced reconciliation and requires it to be OK.
func (e *Env) Reconcile() {
	e.T.Helper()
	_, rep, err := e.App.TrackRound(e.Ctx, true)
	if err != nil {
		e.T.Fatal(err)
	}
	if rep == nil || !rep.OK {
		e.T.Fatalf("reconciliation: %+v", rep)
	}
}

// Transitions returns a withdrawal's recorded transitions as "from>to" strings.
func (e *Env) Transitions(id string) []string {
	trs, _ := withdrawal.Transitions(e.Ctx, e.App.DB)
	var out []string
	for _, tr := range trs {
		if tr.WithdrawalID == id {
			out = append(out, string(tr.From)+">"+string(tr.To))
		}
	}
	return out
}

// NoSweep disables sweeping so a test controls every hot-wallet nonce itself.
func NoSweep(c *config.Config) { c.Deposits.SweepMinAmount.Int = new(big.Int).Lsh(big.NewInt(1), 200) }

// Quiet starts an engine with sweeping disabled.
func Quiet(t *testing.T, seed uint64) *Env {
	return NewWith(t, seed, big.NewInt(1_000_000_000_000), NoSweep)
}

// Setup starts a quiet engine with a funded customer (alice), three active allowlist entries
// and one 1 tUSD withdrawal to Addr(1); it returns the withdrawal id.
func Setup(t *testing.T, seed uint64) (*Env, string) {
	e := Quiet(t, seed)
	e.FundUser("alice", 1_000_000_000)
	e.Allowlist("alice", Addr(1), Addr(2), Addr(3))
	return e, CreatedID(t, e.Create("k", "alice", 1_000_000, Addr(1)))
}
