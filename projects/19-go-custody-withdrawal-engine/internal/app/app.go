// SPDX-License-Identifier: MIT

// Package app wires the engine's components together and runs their loops. The same wiring
// serves the custodyd binary, the anvil integration tests and the in-process simulator, so
// what the tests exercise is what ships.
package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/audit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/bindings"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/chain"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/clock"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/config"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/deposit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/failpoint"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/fees"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/metrics"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/policy"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/recon"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/signer"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/txmgr"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/withdrawal"
)

// Deps are the external dependencies, injectable for tests.
type Deps struct {
	Chain      chain.Client
	Signer     signer.Signer
	Clock      clock.Clock
	Failpoints *failpoint.Set
	Log        *slog.Logger
	Metrics    *metrics.Metrics
	// Store overrides database options (tests only; production always uses the defaults).
	Store *store.Options
}

// App is a fully wired engine.
type App struct {
	Cfg         *config.Config
	DB          *store.DB
	Chain       chain.Client
	Clock       clock.Clock
	Failpoints  *failpoint.Set
	Log         *slog.Logger
	Metrics     *metrics.Metrics
	Firewall    *signer.Firewall
	TxMgr       *txmgr.Manager
	Withdrawals *withdrawal.Service
	Scanner     *deposit.Scanner
	Sweeper     *deposit.Sweeper
	Deriver     *deposit.Deriver
	Recon       *recon.Reconciler
	Audit       *audit.Shipper
	Allowlist   *policy.Allowlist
	HotWallet   common.Address
	Tokens      map[string]common.Address

	dispatchWake chan struct{}
	roundsMu     sync.Mutex
	rounds       int
}

// New builds the engine, verifies the on-chain setup and runs first-start bootstrapping.
func New(ctx context.Context, cfg *config.Config, d Deps) (*App, error) {
	if d.Clock == nil {
		d.Clock = clock.Real{}
	}
	if d.Log == nil {
		d.Log = slog.Default()
	}
	if d.Metrics == nil {
		d.Metrics = metrics.New()
	}
	chainID, err := d.Chain.ChainID(ctx)
	if err != nil {
		return nil, fmt.Errorf("app: chain id: %w", err)
	}
	if chainID.Uint64() != cfg.Chain.ChainID {
		return nil, fmt.Errorf("app: node is on chain %s, configuration says %d", chainID, cfg.Chain.ChainID)
	}
	opts := store.Options{}
	if d.Store != nil {
		opts = *d.Store
	}
	db, err := store.OpenWith(ctx, cfg.Database.Path, opts)
	if err != nil {
		return nil, err
	}
	a := &App{Cfg: cfg, DB: db, Chain: d.Chain, Clock: d.Clock, Failpoints: d.Failpoints, Log: d.Log, Metrics: d.Metrics,
		HotWallet: d.Signer.Address(), Tokens: map[string]common.Address{}, dispatchWake: make(chan struct{}, 1)}
	if err := a.wire(ctx, d); err != nil {
		_ = db.Close()
		return nil, err
	}
	return a, nil
}

func (a *App) wire(ctx context.Context, d Deps) error {
	cfg := a.Cfg
	factory := common.HexToAddress(cfg.Deposits.Factory)
	fwAssets := map[string]signer.Asset{}
	rules := policy.Rules{
		Assets:            map[string]policy.AssetRules{},
		AllowlistCooldown: cfg.Policy.AllowlistCooldown.Duration,
		ApprovalsRequired: cfg.Policy.ApprovalsRequired,
	}
	for _, ap := range cfg.Policy.Approvers {
		rules.Approvers = append(rules.Approvers, policy.Approver{ID: ap.ID, TokenSHA256: ap.TokenSHA256})
	}
	forbidden := []common.Address{a.HotWallet, factory}
	scanTokens := map[common.Address]string{}
	for _, as := range cfg.Assets {
		tok := common.HexToAddress(as.Token)
		a.Tokens[as.Symbol] = tok
		fwAssets[as.Symbol] = signer.Asset{Token: tok, MaxPerTx: as.MaxPerTx.Int}
		rules.Assets[as.Symbol] = policy.AssetRules{MaxPerTx: as.MaxPerTx.Int, Velocity24h: as.Velocity24h.Int, ApprovalThreshold: as.ApprovalThreshold.Int}
		forbidden = append(forbidden, tok)
		scanTokens[tok] = as.Symbol
	}

	impl, err := a.verifyFactory(ctx, factory)
	if err != nil {
		return err
	}
	a.Deriver = deposit.NewDeriver(factory, impl)

	a.Allowlist = policy.NewAllowlist(a.DB)
	a.Firewall, err = signer.NewFirewall(d.Signer, signer.FirewallConfig{
		ChainID: new(big.Int).SetUint64(cfg.Chain.ChainID), Factory: factory, MaxFeeCap: cfg.Fees.MaxFeeWei.Int, Assets: fwAssets,
	}, a.Allowlist, a.Clock)
	if err != nil {
		return err
	}
	est, err := fees.NewEstimator(a.Chain, fees.Config{
		HistoryBlocks: cfg.Fees.HistoryBlocks, RewardPercentile: cfg.Fees.RewardPercentile,
		MinTip: cfg.Fees.MinTipWei.Int, MaxFee: cfg.Fees.MaxFeeWei.Int, BumpBps: cfg.Fees.BumpBps,
	})
	if err != nil {
		return err
	}
	a.TxMgr, err = txmgr.New(a.DB, a.Chain, a.Firewall, est, a.Clock, a.Failpoints, a.Metrics, a.Log, txmgr.Config{
		Confirmations: cfg.Chain.Confirmations, BumpAfterBlocks: cfg.Fees.BumpAfterBlocks,
		GapGraceBlocks: cfg.Nonces.GapGraceBlocks, GasLimitBps: cfg.Fees.GasLimitBps, NativeAsset: cfg.NativeAsset,
	})
	if err != nil {
		return err
	}
	a.Withdrawals, err = withdrawal.NewService(a.DB, a.Clock, a.Failpoints, a.Metrics, a.Log, withdrawal.Config{
		Rules: rules, Tokens: a.Tokens, Forbidden: forbidden,
	}, a.TxMgr)
	if err != nil {
		return err
	}
	a.Scanner, err = deposit.NewScanner(a.DB, a.Chain, a.Clock, a.Metrics, a.Log, deposit.ScannerConfig{
		Tokens: scanTokens, Confirmations: cfg.Chain.Confirmations, MaxRange: cfg.Deposits.MaxBlockRange,
	})
	if err != nil {
		return err
	}
	a.Sweeper, err = deposit.NewSweeper(a.DB, a.Clock, a.Metrics, a.Log, a.TxMgr, deposit.SweeperConfig{
		Factory: factory, HotWallet: a.HotWallet, Tokens: a.Tokens, BatchSize: cfg.Deposits.SweepBatchSize,
		MinAmount: cfg.Deposits.SweepMinAmount.Int,
	})
	if err != nil {
		return err
	}
	a.TxMgr.Register(signer.PurposeWithdrawal, a.Withdrawals.Owner())
	a.TxMgr.Register(signer.PurposeSweep, a.Sweeper.Owner())
	a.Recon = recon.New(a.DB, a.Chain, a.Clock, a.Metrics, a.Log, a.HotWallet, cfg.NativeAsset, a.Tokens)
	a.Audit = audit.NewShipper(a.DB, cfg.Audit.Path, a.Log, a.Metrics.AuditShipFailures)

	// First-start bootstrapping; every step is a no-op on later starts.
	if err := a.TxMgr.Bootstrap(ctx); err != nil {
		return err
	}
	if err := a.Recon.Opening(ctx); err != nil {
		return err
	}
	return a.Scanner.Bootstrap(ctx, cfg.Deposits.StartBlock)
}

// verifyFactory checks that the configured factory pays this hot wallet, is owned by it (so
// sweeps can be signed), and that the Go address derivation matches the contract. It returns
// the forwarder implementation address.
func (a *App) verifyFactory(ctx context.Context, factory common.Address) (common.Address, error) {
	head, err := a.Chain.Head(ctx)
	if err != nil {
		return common.Address{}, err
	}
	ff := bindings.NewForwarderFactory()
	call := func(data []byte) ([]byte, error) {
		return a.Chain.CallContractAtHash(ctx, ethereum.CallMsg{To: &factory, Data: data}, head.Hash)
	}
	out, err := call(ff.PackIMPLEMENTATION())
	if err != nil {
		return common.Address{}, fmt.Errorf("app: factory %s does not answer IMPLEMENTATION() (is it a ForwarderFactory?): %w", factory, err)
	}
	impl, err := ff.UnpackIMPLEMENTATION(out)
	if err != nil {
		return common.Address{}, fmt.Errorf("app: factory %s is not a ForwarderFactory: %w", factory, err)
	}
	out, err = call(ff.PackDESTINATION())
	if err != nil {
		return common.Address{}, err
	}
	if dest, err := ff.UnpackDESTINATION(out); err != nil || dest != a.HotWallet {
		return common.Address{}, fmt.Errorf("app: factory pays %s, not the hot wallet %s", dest, a.HotWallet)
	}
	out, err = call(ff.PackOwner())
	if err != nil {
		return common.Address{}, err
	}
	if owner, err := ff.UnpackOwner(out); err != nil || owner != a.HotWallet {
		return common.Address{}, fmt.Errorf("app: factory is owned by %s; the hot wallet %s must own it to sweep", owner, a.HotWallet)
	}
	probe := deposit.Salt("custody-selfcheck")
	out, err = call(ff.PackForwarderAddress(probe))
	if err != nil {
		return common.Address{}, err
	}
	onChain, err := ff.UnpackForwarderAddress(out)
	if err != nil {
		return common.Address{}, err
	}
	if local := deposit.ForwarderAddress(factory, impl, probe); local != onChain {
		return common.Address{}, fmt.Errorf("app: CREATE2 derivation mismatch: go %s, contract %s", local, onChain)
	}
	return impl, nil
}

// Close closes the database.
func (a *App) Close() error { return a.DB.Close() }

// WakeDispatcher asks the dispatcher to run now.
func (a *App) WakeDispatcher() {
	select {
	case a.dispatchWake <- struct{}{}:
	default:
	}
}

// TrackRound runs one tracker round and, every Reconcile.EveryRounds complete rounds (or when
// force is set), a reconciliation at that round's head.
func (a *App) TrackRound(ctx context.Context, force bool) (txmgr.Round, *recon.Report, error) {
	round, err := a.TxMgr.Track(ctx)
	if err != nil || !round.Complete {
		return round, nil, err
	}
	a.roundsMu.Lock()
	a.rounds++
	due := force || a.rounds%a.Cfg.Reconcile.EveryRounds == 0
	a.roundsMu.Unlock()
	if !due {
		return round, nil, nil
	}
	rep, err := a.Recon.Run(ctx, round.Head)
	if err != nil {
		return round, nil, err
	}
	return round, &rep, nil
}

// Step runs one iteration of every loop in a fixed order. Tests use it to drive the engine
// deterministically; Run uses independent timers instead.
func (a *App) Step(ctx context.Context) error {
	if _, err := a.Withdrawals.DispatchOnce(ctx); err != nil {
		return err
	}
	if _, _, err := a.TrackRound(ctx, false); err != nil {
		return err
	}
	if err := a.Scanner.ScanOnce(ctx); err != nil {
		return err
	}
	if err := a.Sweeper.SweepOnce(ctx); err != nil {
		return err
	}
	_, err := a.Audit.Ship(ctx)
	return err
}

// Run starts every loop and blocks until ctx is cancelled and all loops have returned.
func (a *App) Run(ctx context.Context) {
	var wg sync.WaitGroup
	loop := func(name string, every time.Duration, wake <-chan struct{}, f func(context.Context) error) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			t := time.NewTicker(every)
			defer t.Stop()
			for {
				if err := f(ctx); err != nil && !errors.Is(err, context.Canceled) {
					a.Log.Warn("loop iteration failed", "loop", name, "err", err)
				}
				select {
				case <-ctx.Done():
					return
				case <-t.C:
				case <-wake:
				}
			}
		}()
	}
	poll := a.Cfg.Chain.PollInterval.Duration
	loop("dispatcher", poll, a.dispatchWake, func(ctx context.Context) error {
		_, err := a.Withdrawals.DispatchOnce(ctx)
		return err
	})
	loop("tracker", poll, a.TxMgr.WakeC(), func(ctx context.Context) error {
		_, _, err := a.TrackRound(ctx, false)
		return err
	})
	loop("scanner", a.Cfg.Deposits.ScanInterval.Duration, nil, a.Scanner.ScanOnce)
	loop("sweeper", a.Cfg.Deposits.SweepInterval.Duration, nil, a.Sweeper.SweepOnce)
	wg.Add(1)
	go func() {
		defer wg.Done()
		a.Audit.Run(ctx, a.Cfg.Audit.ShipInterval.Duration)
	}()
	wg.Wait()
}
