// SPDX-License-Identifier: MIT

// Package keeper runs the exchange: every tick it collects signed price reports from the signer set, keeps the ones
// the on-chain OracleVerifier would accept at the latest block, and submits LP requests, pending orders,
// liquidations and auto-deleveraging transactions that the fresh batch allows.
package keeper

import (
	"bytes"
	"cmp"
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"maps"
	"math/big"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/bindings"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/deploy"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/report"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/retry"
)

// maxTxGas stays under EIP-7825's per-transaction gas cap (2^24) introduced in Osaka.
const maxTxGas = 16_000_000

// Backend is the node interface the engine needs.
type Backend interface {
	bind.ContractBackend
	bind.DeployBackend
	BlockNumber(ctx context.Context) (uint64, error)
	NonceAt(ctx context.Context, account common.Address, blockNumber *big.Int) (uint64, error)
}

// Config configures an Engine.
type Config struct {
	Backend    Backend
	ChainID    *big.Int
	Market     common.Address
	SignerURLs []string
	Key        *ecdsa.PrivateKey
	// Poll is the interval between ticks in Run (default 1 s).
	Poll time.Duration
	// HTTPClient fetches reports (default: 2 s timeout).
	HTTPClient *http.Client
	// Retry governs transaction submission (default retry.DefaultPolicy).
	Retry retry.Policy
	// ReceiptPoll is the receipt polling interval (default 100 ms).
	ReceiptPoll time.Duration
	// ReceiptTimeout bounds the wait for one submitted transaction (default 30 s, a few L1 slots). A transaction
	// that is not mined by then (underpriced after a base-fee rise, evicted, lost by a restarting node) is re-sent
	// with the same nonce and higher fees, so one stuck transaction never stalls the keeper.
	ReceiptTimeout time.Duration
	// MaxReplacements is how many times a stuck transaction is replaced before the action is dropped until the
	// next tick (default 3). The nonce and its last fees are remembered, so the next transaction replaces it.
	MaxReplacements int
	// FeeBumpPercent raises both fee caps of a replacement over the previous transaction (default 25; nodes
	// require at least 10).
	FeeBumpPercent uint64
	// FreshnessMargin is how long a report must stay fresh after the latest block, i.e. the expected delay before
	// inclusion (default 15 s). Reports older than maxReportAge - FreshnessMargin at the head are dropped.
	FreshnessMargin time.Duration
	// MaxBatchChecks caps the fallback batches checked on-chain per tick (default 8).
	MaxBatchChecks int
	// GasBufferPercent and GasBufferFixed are added on top of the node's gas estimate (defaults 30% and 250,000).
	// Estimates are taken against the latest block, where fees may already have been accrued in that second; the
	// including block is later and first accrues funding and borrow indices (a handful of storage writes). An
	// under-supplied fill would trip the order book's out-of-gas guard and revert the whole transaction. Unused
	// gas is not charged, so generous headroom is cheap.
	GasBufferPercent uint64
	GasBufferFixed   uint64
	// FromBlock is where position discovery starts (usually the deployment block).
	FromBlock uint64
	Logger    *slog.Logger
	Metrics   *Metrics
}

type posKey struct {
	account common.Address
	isLong  bool
}

type feeCaps struct {
	tip, cap *big.Int
}

// Engine is a single keeper. It is not safe for concurrent use; Run drives it from one goroutine.
type Engine struct {
	cfg       Config
	log       *slog.Logger
	metrics   *Metrics
	from      common.Address
	market    *bindings.PerpsMarket
	orderBook *bindings.OrderBook
	vault     *bindings.LPVault
	oracle    *bindings.OracleVerifier
	marketID  [32]byte
	domain    report.Domain

	nextOrder    uint64
	nextRequest  uint64
	scannedBlock uint64
	orders       map[uint64]struct{}
	requests     map[uint64]struct{}
	positions    map[posKey]struct{}
	// sentFees remembers the fee caps last used for each pending nonce, so a replacement outbids it.
	sentFees map[uint64]feeCaps
}

// New binds the market and its components.
func New(ctx context.Context, cfg Config) (*Engine, error) {
	if cfg.Backend == nil || cfg.Key == nil || cfg.ChainID == nil || len(cfg.SignerURLs) == 0 {
		return nil, errors.New("keeper: backend, key, chain id and signer URLs are required")
	}
	if cfg.Poll <= 0 {
		cfg.Poll = time.Second
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{Timeout: 2 * time.Second}
	}
	if cfg.Retry.Attempts == 0 {
		cfg.Retry = retry.DefaultPolicy
	}
	if cfg.ReceiptTimeout <= 0 {
		cfg.ReceiptTimeout = 30 * time.Second
	}
	if cfg.MaxReplacements <= 0 {
		cfg.MaxReplacements = 3
	}
	if cfg.FeeBumpPercent < 10 {
		cfg.FeeBumpPercent = 25
	}
	if cfg.FreshnessMargin <= 0 {
		cfg.FreshnessMargin = 15 * time.Second
	}
	if cfg.MaxBatchChecks <= 0 {
		cfg.MaxBatchChecks = 8
	}
	if cfg.GasBufferPercent == 0 {
		cfg.GasBufferPercent = 30
	}
	if cfg.GasBufferFixed == 0 {
		cfg.GasBufferFixed = 250_000
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	if cfg.Metrics == nil {
		cfg.Metrics = NewMetrics()
	}
	e := &Engine{
		cfg: cfg, log: cfg.Logger, metrics: cfg.Metrics, from: crypto.PubkeyToAddress(cfg.Key.PublicKey),
		nextOrder: 1, nextRequest: 1, scannedBlock: cfg.FromBlock,
		orders: map[uint64]struct{}{}, requests: map[uint64]struct{}{}, positions: map[posKey]struct{}{},
		sentFees: map[uint64]feeCaps{},
	}
	var err error
	if e.market, err = bindings.NewPerpsMarket(cfg.Market, cfg.Backend); err != nil {
		return nil, err
	}
	call := &bind.CallOpts{Context: ctx}
	orderBook, err := e.market.OrderBook(call)
	if err != nil {
		return nil, fmt.Errorf("read orderBook(): %w", err)
	}
	vault, err := e.market.Vault(call)
	if err != nil {
		return nil, fmt.Errorf("read vault(): %w", err)
	}
	oracle, err := e.market.Oracle(call)
	if err != nil {
		return nil, fmt.Errorf("read oracle(): %w", err)
	}
	if e.marketID, err = e.market.MarketId(call); err != nil {
		return nil, err
	}
	if e.orderBook, err = bindings.NewOrderBook(orderBook, cfg.Backend); err != nil {
		return nil, err
	}
	if e.vault, err = bindings.NewLPVault(vault, cfg.Backend); err != nil {
		return nil, err
	}
	if e.oracle, err = bindings.NewOracleVerifier(oracle, cfg.Backend); err != nil {
		return nil, err
	}
	e.domain = report.Domain{ChainID: cfg.ChainID, Verifier: oracle}
	return e, nil
}

// Address is the keeper's transaction sender.
func (e *Engine) Address() common.Address { return e.from }

// Run ticks until ctx is cancelled. Tick errors are logged and retried on the next tick.
func (e *Engine) Run(ctx context.Context) error {
	t := time.NewTicker(e.cfg.Poll)
	defer t.Stop()
	for {
		if err := e.Tick(ctx); err != nil && ctx.Err() == nil {
			e.log.Error("tick failed", "err", err)
		}
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		}
	}
}

// Tick performs one iteration: discovery, report collection, then LP requests, orders, liquidations and ADL.
func (e *Engine) Tick(ctx context.Context) error {
	start := time.Now()
	defer func() { e.metrics.TickSeconds.Observe(time.Since(start).Seconds()) }()
	call := &bind.CallOpts{Context: ctx}

	if err := e.discover(ctx, call); err != nil {
		return fmt.Errorf("discover: %w", err)
	}
	batch, err := e.collectReports(ctx, call)
	if err != nil {
		// No usable quorum this tick (signers down, stale or outlying reports): nothing can be settled.
		e.log.Warn("no usable report batch", "err", err)
		e.metrics.Ticks.Inc()
		return nil
	}
	price := batch.Median
	e.metrics.Price.Set(toFloat(price))
	oldest := report.OldestTimestamp(batch.Reports)
	signed := toSigned(batch.Reports)

	e.settleRequests(ctx, call, signed, oldest)
	e.settleOrders(ctx, call, signed, price, oldest)
	e.liquidate(ctx, call, signed, price, oldest)
	if err := e.deleverage(ctx, call, signed, price, oldest); err != nil {
		e.log.Warn("adl scan failed", "err", err)
	}

	e.metrics.Pending.WithLabelValues("orders").Set(float64(len(e.orders)))
	e.metrics.Pending.WithLabelValues("lp_requests").Set(float64(len(e.requests)))
	e.metrics.Pending.WithLabelValues("positions").Set(float64(len(e.positions)))
	e.metrics.Ticks.Inc()
	return nil
}

// discover picks up new order and request identifiers and new positions (from PositionIncreased logs).
func (e *Engine) discover(ctx context.Context, call *bind.CallOpts) error {
	next, err := e.orderBook.NextOrderId(call)
	if err != nil {
		return err
	}
	for ; e.nextOrder < next.Uint64(); e.nextOrder++ {
		e.orders[e.nextOrder] = struct{}{}
	}
	next, err = e.vault.NextRequestId(call)
	if err != nil {
		return err
	}
	for ; e.nextRequest < next.Uint64(); e.nextRequest++ {
		e.requests[e.nextRequest] = struct{}{}
	}
	head, err := e.cfg.Backend.BlockNumber(ctx)
	if err != nil {
		return err
	}
	if head < e.scannedBlock {
		return nil
	}
	it, err := e.market.FilterPositionIncreased(&bind.FilterOpts{Start: e.scannedBlock, End: &head, Context: ctx}, nil, nil)
	if err != nil {
		return err
	}
	defer it.Close()
	for it.Next() {
		e.positions[posKey{it.Event.Account, it.Event.IsLong}] = struct{}{}
	}
	if err := it.Error(); err != nil {
		return err
	}
	e.scannedBlock = head + 1
	return nil
}

// reportWindow is what the verifier will require of a report at the latest block (nodes simulate transactions
// against it) and at inclusion: dated no later than the head, and still fresh FreshnessMargin later.
type reportWindow struct {
	notAfter  uint64
	notBefore uint64
}

func (w reportWindow) check(ts uint64) error {
	switch {
	case ts > w.notAfter:
		return fmt.Errorf("%w: dated %d, after the latest block (%d)", errFuture, ts, w.notAfter)
	case ts < w.notBefore:
		return fmt.Errorf("%w: dated %d, oldest usable %d", errStale, ts, w.notBefore)
	}
	return nil
}

var (
	errFuture    = errors.New("report from the future")
	errStale     = errors.New("stale report")
	errNotInSet  = errors.New("signer not in the on-chain set")
	errNoBatch   = errors.New("no candidate batch passed the on-chain verifier")
	errNotMined  = errors.New("transaction not mined")
	erc1271Magic = [4]byte{0x16, 0x26, 0xba, 0x7e}
	erc1271ABI   = mustABI(`[{"type":"function","name":"isValidSignature","stateMutability":"view",
		"inputs":[{"name":"hash","type":"bytes32"},{"name":"signature","type":"bytes"}],
		"outputs":[{"name":"magicValue","type":"bytes4"}]}]`)
)

func mustABI(def string) abi.ABI {
	parsed, err := abi.JSON(strings.NewReader(def))
	if err != nil {
		panic(err)
	}
	return parsed
}

// collectReports fetches one report per signer URL concurrently (asking for reports dated no later than the latest
// block), keeps the ones the verifier would accept, deduplicates them by signer, and returns the best candidate
// batch that the deployed OracleVerifier accepts in an eth_call at the latest block. Each check mirrors one way a
// faulty signer could otherwise halt settlement: a clock ahead of the chain (future-dated), a clock behind it
// (stale), a malformed signature (raw recovery id, high s), a report served twice, or a contract signer.
func (e *Engine) collectReports(ctx context.Context, call *bind.CallOpts) (report.Batch, error) {
	head, err := e.cfg.Backend.HeaderByNumber(ctx, nil)
	if err != nil {
		return report.Batch{}, err
	}
	members, err := e.oracle.Signers(call)
	if err != nil {
		return report.Batch{}, err
	}
	quorum, err := e.oracle.MinSigners(call)
	if err != nil {
		return report.Batch{}, err
	}
	spread, err := e.oracle.MaxSpreadBps(call)
	if err != nil {
		return report.Batch{}, err
	}
	maxAge, err := e.oracle.MaxReportAge(call)
	if err != nil {
		return report.Batch{}, err
	}
	allowed := make(map[common.Address]bool, len(members))
	for _, m := range members {
		allowed[m] = true
	}
	window := reportWindow{notAfter: head.Time}
	if margin := uint64(e.cfg.FreshnessMargin / time.Second); head.Time+margin > uint64(maxAge) {
		window.notBefore = head.Time + margin - uint64(maxAge)
	}

	var (
		mu      sync.Mutex
		wg      sync.WaitGroup
		reports []report.Report
	)
	for _, base := range e.cfg.SignerURLs {
		wg.Go(func() {
			r, err := e.fetch(ctx, base, head.Time)
			reason := "fetch"
			if err == nil {
				reason, err = e.validate(ctx, r, allowed, window)
			}
			if err != nil {
				e.metrics.ReportErrors.WithLabelValues(base, reason).Inc()
				e.log.Debug("report rejected", "signer", base, "reason", reason, "err", err)
				return
			}
			mu.Lock()
			reports = append(reports, r)
			mu.Unlock()
		})
	}
	wg.Wait()

	batches, err := report.Candidates(reports, int(quorum), spread)
	if err != nil {
		return report.Batch{}, err
	}
	return e.firstAccepted(call, batches)
}

// validate applies the verifier's per-report rules: membership, market and price, the time window, and the
// signature (ECDSA for EOAs, ERC-1271 for signers with code, as OpenZeppelin's SignatureChecker does).
func (e *Engine) validate(ctx context.Context, r report.Report, allowed map[common.Address]bool, w reportWindow) (string, error) {
	if !allowed[r.Signer] {
		return "not_in_set", fmt.Errorf("%w: %s", errNotInSet, r.Signer)
	}
	if err := report.CheckFields(e.marketID, r); err != nil {
		return "malformed", err
	}
	if err := w.check(r.Timestamp); err != nil {
		if errors.Is(err, errFuture) {
			return "future", err
		}
		return "stale", err
	}
	if err := e.verifySignature(ctx, r); err != nil {
		return "signature", err
	}
	return "", nil
}

func (e *Engine) verifySignature(ctx context.Context, r report.Report) error {
	code, err := e.cfg.Backend.CodeAt(ctx, r.Signer, nil)
	if err != nil {
		return err
	}
	if len(code) == 0 {
		return report.Verify(e.domain, e.marketID, r)
	}
	digest := report.Digest(e.domain, e.marketID, r.Price, r.Timestamp)
	data, err := erc1271ABI.Pack("isValidSignature", digest, r.Signature)
	if err != nil {
		return err
	}
	signer := r.Signer
	out, err := e.cfg.Backend.CallContract(ctx, ethereum.CallMsg{To: &signer, Data: data}, nil)
	if err != nil {
		return fmt.Errorf("%w: isValidSignature reverted: %v", report.ErrBadSignature, err)
	}
	// SignatureChecker accepts exactly the magic value, left-aligned in a 32-byte word.
	want := common.RightPadBytes(erc1271Magic[:], 32)
	if len(out) < 32 || !bytes.Equal(out[:32], want) {
		return fmt.Errorf("%w: ERC-1271 wallet %s rejected the signature", report.ErrBadSignature, r.Signer)
	}
	return nil
}

// firstAccepted returns the first candidate the deployed verifier accepts at the latest block. A batch that passes
// every off-chain check but still fails on-chain (a rule the keeper does not mirror, or a signer set changed
// since the read) falls back to the next candidate instead of reverting every action of the tick.
func (e *Engine) firstAccepted(call *bind.CallOpts, batches []report.Batch) (report.Batch, error) {
	var lastErr error
	for i, b := range batches {
		if i == e.cfg.MaxBatchChecks {
			break
		}
		if _, err := e.oracle.VerifyReports(call, e.marketID, toSigned(b.Reports), new(big.Int)); err != nil {
			lastErr = err
			e.metrics.BatchFallbacks.Inc()
			e.log.Debug("candidate batch rejected on-chain", "size", len(b.Reports), "err", err)
			continue
		}
		return b, nil
	}
	return report.Batch{}, fmt.Errorf("%w: %v", errNoBatch, lastErr)
}

func (e *Engine) fetch(ctx context.Context, base string, notAfter uint64) (report.Report, error) {
	u := strings.TrimRight(base, "/") + "/report?" + url.Values{"notAfter": {strconv.FormatUint(notAfter, 10)}}.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return report.Report{}, err
	}
	resp, err := e.cfg.HTTPClient.Do(req)
	if err != nil {
		return report.Report{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return report.Report{}, fmt.Errorf("status %d", resp.StatusCode)
	}
	var r report.Report
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<16)).Decode(&r); err != nil {
		return report.Report{}, err
	}
	return r, nil
}

func (e *Engine) settleRequests(ctx context.Context, call *bind.CallOpts, signed []bindings.IOracleVerifierSignedPriceReport, oldest uint64) {
	for _, id := range sortedIDs(e.requests) {
		req, err := e.vault.GetRequest(call, new(big.Int).SetUint64(id))
		if err != nil {
			e.log.Warn("read request", "id", id, "err", err)
			continue
		}
		if req.Account == (common.Address{}) {
			delete(e.requests, id)
			continue
		}
		if oldest <= req.CreatedAt {
			continue // reports must postdate the request
		}
		if e.send(ctx, "lp_request", func(o *bind.TransactOpts) (*types.Transaction, error) {
			return e.vault.ExecuteRequest(o, new(big.Int).SetUint64(id), signed)
		}) {
			delete(e.requests, id)
		}
	}
}

func (e *Engine) settleOrders(ctx context.Context, call *bind.CallOpts, signed []bindings.IOracleVerifierSignedPriceReport, price *big.Int, oldest uint64) {
	for _, id := range sortedIDs(e.orders) {
		bid := new(big.Int).SetUint64(id)
		o, err := e.orderBook.GetOrder(call, bid)
		if err != nil {
			e.log.Warn("read order", "id", id, "err", err)
			continue
		}
		if o.Account == (common.Address{}) {
			delete(e.orders, id)
			continue
		}
		if oldest <= o.CreatedAt {
			continue // reports must postdate the order (the latency-arbitrage guard, mirrored off-chain)
		}
		ok, err := e.orderBook.IsExecutable(call, bid, price)
		if err != nil || !ok {
			continue // trigger not met at this price
		}
		if e.send(ctx, "order", func(opts *bind.TransactOpts) (*types.Transaction, error) {
			return e.orderBook.ExecuteOrder(opts, bid, signed)
		}) {
			delete(e.orders, id)
		}
	}
}

func (e *Engine) liquidate(ctx context.Context, call *bind.CallOpts, signed []bindings.IOracleVerifierSignedPriceReport, price *big.Int, oldest uint64) {
	for _, k := range sortedPositions(e.positions) {
		pos, err := e.market.GetPosition(call, k.account, k.isLong)
		if err != nil {
			continue
		}
		if pos.SizeUsd.Sign() == 0 {
			delete(e.positions, k)
			continue
		}
		if oldest <= pos.LastUpdatedAt {
			continue
		}
		info, err := e.market.PositionInfo(call, k.account, k.isLong, price)
		if err != nil || !info.Liquidatable {
			continue
		}
		e.log.Info("liquidating", "account", k.account, "long", k.isLong, "remaining", info.RemainingCollateral)
		e.send(ctx, "liquidation", func(o *bind.TransactOpts) (*types.Transaction, error) {
			return e.market.Liquidate(o, k.account, k.isLong, signed)
		})
	}
}

// Candidate is a position eligible for auto-deleveraging.
type Candidate struct {
	Account common.Address
	IsLong  bool
	Pnl     *big.Int
	Size    *big.Int
	// SidePnl is the netted PnL of the candidate's side. Deleveraging a winner on a side that nets to a loss pays
	// it out of the pool without lowering aggregate positive PnL, so the market refuses it.
	SidePnl *big.Int
}

// RankForADL keeps profitable candidates on sides whose netted PnL is positive and orders them by PnL per unit of
// size, highest first (ties: larger PnL, then address).
func RankForADL(cands []Candidate) []Candidate {
	out := slices.DeleteFunc(slices.Clone(cands), func(c Candidate) bool {
		return c.Pnl.Sign() <= 0 || c.Size.Sign() <= 0 || c.SidePnl == nil || c.SidePnl.Sign() <= 0
	})
	wadPnl := func(c Candidate) *big.Int {
		return new(big.Int).Quo(new(big.Int).Mul(c.Pnl, big.NewInt(1e18)), c.Size)
	}
	slices.SortStableFunc(out, func(a, b Candidate) int {
		if c := wadPnl(b).Cmp(wadPnl(a)); c != 0 {
			return c
		}
		if c := b.Pnl.Cmp(a.Pnl); c != 0 {
			return c
		}
		return a.Account.Cmp(b.Account)
	})
	return out
}

// SidePnl mirrors PerpMath.pnl over a side's aggregates: floor(tokens * price) - size for longs and
// size - ceil(tokens * price) for shorts (WAD prices).
func SidePnl(isLong bool, openInterest, openInterestInTokens, price *big.Int) *big.Int {
	wad := big.NewInt(1e18)
	value, rem := new(big.Int).QuoRem(new(big.Int).Mul(openInterestInTokens, price), wad, new(big.Int))
	if isLong {
		return value.Sub(value, openInterest)
	}
	if rem.Sign() != 0 {
		value.Add(value, big.NewInt(1))
	}
	return new(big.Int).Sub(openInterest, value)
}

func (e *Engine) deleverage(ctx context.Context, call *bind.CallOpts, signed []bindings.IOracleVerifierSignedPriceReport, price *big.Int, oldest uint64) error {
	factor, err := e.market.PnlToPoolFactor(call, price)
	if err != nil {
		return err
	}
	e.metrics.PnlFactor.Set(toFloat(factor.Factor))
	params, err := e.market.GetRiskParams(call)
	if err != nil {
		return err
	}
	if factor.Factor.Cmp(new(big.Int).SetUint64(params.AdlThresholdFactor)) <= 0 {
		return nil
	}
	sidePnl := map[bool]*big.Int{}
	for _, isLong := range []bool{true, false} {
		side, err := e.market.GetSide(call, isLong)
		if err != nil {
			return err
		}
		sidePnl[isLong] = SidePnl(isLong, side.OpenInterest, side.OpenInterestInTokens, price)
	}
	var cands []Candidate
	for _, k := range sortedPositions(e.positions) {
		pos, err := e.market.GetPosition(call, k.account, k.isLong)
		if err != nil || pos.SizeUsd.Sign() == 0 || oldest <= pos.LastUpdatedAt {
			continue
		}
		info, err := e.market.PositionInfo(call, k.account, k.isLong, price)
		if err != nil {
			continue
		}
		cands = append(cands, Candidate{
			Account: k.account, IsLong: k.isLong, Pnl: info.Pnl, Size: pos.SizeUsd, SidePnl: sidePnl[k.isLong],
		})
	}
	// The market refuses an ADL that would not lower the factor (e.g. a pool-fronted funding credit larger than
	// the PnL removed); the next candidate is tried instead.
	for _, c := range RankForADL(cands) {
		e.log.Info("auto-deleveraging", "account", c.Account, "long", c.IsLong, "pnl", c.Pnl, "factor", factor.Factor)
		if e.send(ctx, "adl", func(o *bind.TransactOpts) (*types.Transaction, error) {
			return e.market.AutoDeleverage(o, c.Account, c.IsLong, signed)
		}) {
			break
		}
	}
	return nil
}

// send simulates, then submits a transaction and waits for it with a bounded timeout. Reverts in simulation or
// on-chain are permanent for this tick (the item stays tracked and is re-evaluated with fresh reports). A
// transaction that is not mined within ReceiptTimeout is replaced with the same nonce and fees raised by
// FeeBumpPercent, up to MaxReplacements times; after that the action is dropped until the next tick, whose
// transaction reuses (and outbids) the stuck nonce. Transport errors are retried with backoff.
func (e *Engine) send(ctx context.Context, action string, build func(*bind.TransactOpts) (*types.Transaction, error)) bool {
	attempts, err := retry.Do(ctx, e.cfg.Retry, func(ctx context.Context) error {
		// First pass: simulate and estimate gas without broadcasting.
		dry, err := e.txOpts(ctx)
		if err != nil {
			return retry.Permanent(err)
		}
		dry.NoSend = true
		estimated, err := build(dry)
		if err != nil {
			if IsRevert(err) {
				return retry.Permanent(err)
			}
			return err
		}
		// The confirmed nonce: a transaction stuck in the mempool under it is replaced, not queued behind.
		nonce, err := e.cfg.Backend.NonceAt(ctx, e.from, nil)
		if err != nil {
			return err
		}
		for n := range e.sentFees {
			if n < nonce {
				delete(e.sentFees, n)
			}
		}
		gasLimit := min(estimated.Gas()+estimated.Gas()*e.cfg.GasBufferPercent/100+e.cfg.GasBufferFixed, maxTxGas)

		var hashes []common.Hash
		for replacement := 0; ; replacement++ {
			fees, err := e.fees(ctx, nonce)
			if err != nil {
				return err
			}
			opts, err := e.txOpts(ctx)
			if err != nil {
				return retry.Permanent(err)
			}
			opts.Nonce = new(big.Int).SetUint64(nonce)
			opts.GasLimit = gasLimit
			opts.GasTipCap = fees.tip
			opts.GasFeeCap = fees.cap
			tx, err := build(opts)
			if err != nil {
				if IsRevert(err) {
					return retry.Permanent(err)
				}
				// The previous transaction may have been mined meanwhile ("nonce too low").
				if len(hashes) > 0 {
					if _, ok, rerr := e.findReceipt(ctx, hashes); ok {
						if errors.Is(rerr, deploy.ErrReverted) {
							return retry.Permanent(rerr)
						}
						return rerr
					}
				}
				return err
			}
			e.sentFees[nonce] = fees
			hashes = append(hashes, tx.Hash())
			err = e.waitMined(ctx, hashes)
			if !errors.Is(err, errNotMined) {
				if errors.Is(err, deploy.ErrReverted) {
					return retry.Permanent(err)
				}
				return err
			}
			if replacement == e.cfg.MaxReplacements {
				// Dropped until the next tick; retrying now would only wait again.
				return retry.Permanent(fmt.Errorf("%w after %d replacements (nonce %d)", errNotMined, replacement, nonce))
			}
			e.metrics.Replacements.Inc()
			e.log.Warn("transaction not mined, replacing", "action", action, "nonce", nonce, "tx", tx.Hash())
		}
	})
	if attempts > 1 {
		e.metrics.Retries.Add(float64(attempts - 1))
	}
	switch {
	case err == nil:
		e.metrics.Actions.WithLabelValues(action, "success").Inc()
		return true
	case IsRevert(err) || errors.Is(err, deploy.ErrReverted):
		e.metrics.Actions.WithLabelValues(action, "reverted").Inc()
		e.log.Debug("transaction would revert", "action", action, "err", err)
	default:
		e.metrics.Actions.WithLabelValues(action, "error").Inc()
		e.log.Warn("transaction failed", "action", action, "attempts", attempts, "err", err)
	}
	return false
}

// fees suggests EIP-1559 fee caps (tip, and 2 x base fee + tip) and, for a nonce already used by a stuck
// transaction, raises both by at least FeeBumpPercent over what that transaction offered.
func (e *Engine) fees(ctx context.Context, nonce uint64) (feeCaps, error) {
	tip, err := e.cfg.Backend.SuggestGasTipCap(ctx)
	if err != nil {
		return feeCaps{}, err
	}
	head, err := e.cfg.Backend.HeaderByNumber(ctx, nil)
	if err != nil {
		return feeCaps{}, err
	}
	feeCap := new(big.Int).Set(tip)
	if head.BaseFee != nil {
		feeCap.Add(feeCap, new(big.Int).Mul(head.BaseFee, big.NewInt(2)))
	}
	if prev, ok := e.sentFees[nonce]; ok {
		tip = bigMax(tip, e.bump(prev.tip))
		feeCap = bigMax(feeCap, e.bump(prev.cap))
	}
	return feeCaps{tip: tip, cap: bigMax(feeCap, tip)}, nil
}

// bump returns x raised by FeeBumpPercent, and by at least one wei.
func (e *Engine) bump(x *big.Int) *big.Int {
	raised := new(big.Int).Mul(x, new(big.Int).SetUint64(100+e.cfg.FeeBumpPercent))
	raised.Quo(raised, big.NewInt(100))
	return bigMax(raised, new(big.Int).Add(x, big.NewInt(1)))
}

func bigMax(a, b *big.Int) *big.Int {
	if a.Cmp(b) >= 0 {
		return a
	}
	return b
}

// waitMined polls the receipts of every transaction sent for one nonce (the original and its replacements: any of
// them may be the one mined) until one exists or ReceiptTimeout elapses (errNotMined).
func (e *Engine) waitMined(ctx context.Context, hashes []common.Hash) error {
	poll := e.cfg.ReceiptPoll
	if poll <= 0 {
		poll = 100 * time.Millisecond
	}
	deadline := time.NewTimer(e.cfg.ReceiptTimeout)
	defer deadline.Stop()
	tick := time.NewTicker(poll)
	defer tick.Stop()
	for {
		if _, ok, err := e.findReceipt(ctx, hashes); ok {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			return errNotMined
		case <-tick.C:
		}
	}
}

// findReceipt returns the receipt of the first mined transaction among hashes (ok = true), with ErrReverted when
// it failed.
func (e *Engine) findReceipt(ctx context.Context, hashes []common.Hash) (*types.Receipt, bool, error) {
	for _, h := range hashes {
		receipt, err := e.cfg.Backend.TransactionReceipt(ctx, h)
		if err != nil || receipt == nil {
			continue
		}
		if receipt.Status != types.ReceiptStatusSuccessful {
			return receipt, true, fmt.Errorf("%w: %s", deploy.ErrReverted, h)
		}
		return receipt, true, nil
	}
	return nil, false, nil
}

func (e *Engine) txOpts(ctx context.Context) (*bind.TransactOpts, error) {
	opts, err := bind.NewKeyedTransactorWithChainID(e.cfg.Key, e.cfg.ChainID)
	if err != nil {
		return nil, err
	}
	opts.Context = ctx
	return opts, nil
}

// IsRevert reports whether err is an EVM revert surfaced by the node (as opposed to a transport error).
func IsRevert(err error) bool {
	return err != nil && strings.Contains(strings.ToLower(err.Error()), "revert")
}

func toSigned(batch []report.Report) []bindings.IOracleVerifierSignedPriceReport {
	out := make([]bindings.IOracleVerifierSignedPriceReport, len(batch))
	for i, r := range batch {
		out[i] = bindings.IOracleVerifierSignedPriceReport{
			Signer: r.Signer, Price: r.Price, Timestamp: r.Timestamp, Signature: r.Signature,
		}
	}
	return out
}

func sortedIDs(m map[uint64]struct{}) []uint64 {
	return slices.Sorted(maps.Keys(m))
}

func sortedPositions(m map[posKey]struct{}) []posKey {
	return slices.SortedFunc(maps.Keys(m), func(a, b posKey) int {
		if c := a.account.Cmp(b.account); c != 0 {
			return c
		}
		return cmp.Compare(boolInt(a.isLong), boolInt(b.isLong))
	})
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func toFloat(wadValue *big.Int) float64 {
	f, _ := new(big.Float).Quo(new(big.Float).SetInt(wadValue), big.NewFloat(1e18)).Float64()
	return f
}
