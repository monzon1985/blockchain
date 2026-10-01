// SPDX-License-Identifier: MIT

// Package indexer is the sync engine: it follows the node head, commits validated segments in
// block order, detects forks from the stored (number, hash, parentHash) chain, and rolls back
// orphaned data (logs, derived tables, balances) in the same transaction that moves the
// checkpoint and appends the matching `retract` events to the SSE outbox.
//
// The engine's correctness property, tested against fake chains, anvil, restarts and injected
// RPC faults, is that the database it maintains incrementally is identical to a from-scratch
// reindex of the canonical chain.
package indexer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/decode"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/fetch"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/metrics"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/model"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/reorg"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store"
)

// ErrConfigMismatch means the database was built for another chain, start block or contract set.
var ErrConfigMismatch = errors.New("indexer: database was built with a different configuration")

// MetaConfigKey is the meta-table key holding the configuration fingerprint.
const MetaConfigKey = "config"

// Config configures an Engine.
type Config struct {
	// Start is the first block to index (typically the contracts' deployment block).
	Start uint64
	// Confirmations is the depth after which a block counts as safe; blocks inside it are
	// fetched per block by hash, and a reorg deeper than it is logged as an incident.
	Confirmations uint64
	// PollInterval is the delay between head polls once caught up.
	PollInterval time.Duration
	// ReorgWindow is the number of recent headers kept to find fork points.
	ReorgWindow int
	// EventRetention is the number of outbox events kept for SSE resumption.
	EventRetention uint64
	// StopAt, when set, caps indexing at that block (used by verify's reindex).
	StopAt *uint64
	// Contracts is the watched set.
	Contracts decode.Contracts
	// Fetch tunes the fetcher; its Addresses are derived from Contracts.
	Fetch fetch.Config
}

func (c *Config) setDefaults() error {
	if len(c.Contracts.Addresses()) == 0 {
		return errors.New("indexer: no contracts to index")
	}
	if c.PollInterval <= 0 {
		c.PollInterval = 2 * time.Second
	}
	if c.ReorgWindow == 0 {
		c.ReorgWindow = 1024
	}
	if c.ReorgWindow < 2 {
		return fmt.Errorf("indexer: reorg window %d is too small", c.ReorgWindow)
	}
	if c.EventRetention == 0 {
		c.EventRetention = 100_000
	}
	c.Fetch.Addresses = c.Contracts.Addresses()
	return nil
}

// Fingerprint is the configuration recorded in the database; a database is only ever extended
// by an indexer with the same fingerprint.
type Fingerprint struct {
	ChainID uint64                            `json:"chainId"`
	Start   uint64                            `json:"start"`
	Tokens  []common.Address                  `json:"tokens"`
	Vaults  map[common.Address]common.Address `json:"vaults"`
}

// NewFingerprint builds the fingerprint of a configuration.
func NewFingerprint(chainID, start uint64, c decode.Contracts) Fingerprint {
	tokens := slices.Clone(c.Tokens)
	slices.SortFunc(tokens, func(a, b common.Address) int { return a.Cmp(b) })
	tokens = slices.Compact(tokens)
	vaults := map[common.Address]common.Address{}
	for v, a := range c.Vaults {
		vaults[v] = a
	}
	return Fingerprint{ChainID: chainID, Start: start, Tokens: tokens, Vaults: vaults}
}

// Contracts returns the watched set described by the fingerprint.
func (f Fingerprint) Contracts() decode.Contracts {
	return decode.Contracts{Tokens: slices.Clone(f.Tokens), Vaults: f.Vaults}
}

// ReadFingerprint returns the fingerprint stored in a database, if any.
func ReadFingerprint(ctx context.Context, st store.Store) (Fingerprint, bool, error) {
	var fp Fingerprint
	var found bool
	err := st.View(ctx, func(r store.Reader) error {
		raw, ok, err := r.Meta(MetaConfigKey)
		if err != nil || !ok {
			return err
		}
		found = true
		return json.Unmarshal([]byte(raw), &fp)
	})
	return fp, found, err
}

// Outcome is what one sync iteration did.
type Outcome int

const (
	// Idle means the indexer is at the head.
	Idle Outcome = iota
	// Progressed means blocks were committed.
	Progressed
	// RolledBack means a reorg was rolled back.
	RolledBack
	// Retry means the node's answers were inconsistent (usually a reorg in progress). SyncOnce
	// returns it with the inconsistency (an error wrapping fetch.ErrInconsistent); Run and
	// SyncUntil retry it quickly up to inconsistentRetries times in a row, then report it as a
	// sync error and back off.
	Retry
)

// inconsistentRetries is the number of consecutive Retry outcomes retried at a short interval
// before they count as a sync error (metric, LastError, warning) with exponential backoff. A
// reorg in progress resolves within an iteration or two; an inconsistency that persists (a
// provider that ignores the address filter, a chain whose header blooms miss logs) is a fault
// the operator has to see, not a silent loop.
const inconsistentRetries = 10

// Status is a snapshot of the engine's progress, for /v1/status and /readyz.
type Status struct {
	Tip       *chain.BlockRef
	ChainHead uint64
	SafeHead  *uint64
	Lag       uint64
	Synced    bool
	LastSync  time.Time
	LastError string
}

// Engine is the indexer. Run it with Run; everything else is safe for concurrent use.
type Engine struct {
	cfg     Config
	chainID uint64
	src     chain.Source
	st      store.Store
	m       *metrics.Metrics
	log     *slog.Logger
	fetcher *fetch.Fetcher
	decoder *decode.Decoder
	tracker *reorg.Tracker // owned by the Run goroutine

	// OnCommit is called after every committed transaction (the API wakes SSE streams).
	OnCommit func()
	// Now is the clock (tests replace it).
	Now func() time.Time

	// unconfirmed is the tip of the last write transaction whose Store.Update returned an error
	// other than a checkpoint conflict. Such an error can arrive after the transaction committed
	// (an ambiguous COMMIT: the connection dropped while the server committed), so a later
	// checkpoint conflict is checked against it before the engine concludes that another writer
	// exists. Owned by the goroutine that runs SyncOnce.
	unconfirmed *pendingWrite

	mu            sync.Mutex
	status        Status
	lastHeartbeat time.Time
}

// pendingWrite is a write whose outcome is unknown; tip nil means "nothing indexed".
type pendingWrite struct{ tip *chain.BlockRef }

// New validates the node and the database against cfg and restores the tracker.
func New(ctx context.Context, cfg Config, src chain.Source, st store.Store, m *metrics.Metrics, log *slog.Logger) (*Engine, error) {
	if err := cfg.setDefaults(); err != nil {
		return nil, err
	}
	if m == nil {
		m = metrics.New()
	}
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	var chainID uint64
	err := chain.Retry(ctx, chain.RetryPolicy{Attempts: 10}, func() error {
		var err error
		chainID, err = src.ChainID(ctx)
		return err
	})
	if err != nil {
		return nil, fmt.Errorf("indexer: read chain id: %w", err)
	}
	e := &Engine{cfg: cfg, chainID: chainID, src: src, st: st, m: m, log: log.With("component", "indexer"),
		decoder: decode.New(cfg.Contracts), Now: time.Now}
	if err := e.checkFingerprint(ctx); err != nil {
		return nil, err
	}
	if err := e.restore(ctx); err != nil {
		return nil, err
	}
	e.fetcher = fetch.New(src, cfg.Fetch, fetch.Hooks{
		Split: func() {
			m.RangeSplits.Inc()
			m.RangeSpan.Set(float64(e.fetcher.Planner().Span()))
		},
		Retry: func(op string, _ error) { m.RPCRetries.WithLabelValues(op).Inc() },
		BloomRefetch: func(recovered bool) {
			result := "false_positive"
			if recovered {
				result = "recovered"
			}
			m.BloomRefetches.WithLabelValues(result).Inc()
		},
		ReceiptFallback: m.ReceiptFallbacks.Inc,
	})
	m.RangeSpan.Set(float64(e.fetcher.Planner().Span()))
	return e, nil
}

// ChainID returns the node's chain id.
func (e *Engine) ChainID() uint64 { return e.chainID }

// Config returns the effective configuration.
func (e *Engine) Config() Config { return e.cfg }

func (e *Engine) checkFingerprint(ctx context.Context) error {
	want, err := json.Marshal(NewFingerprint(e.chainID, e.cfg.Start, e.cfg.Contracts))
	if err != nil {
		return err
	}
	return e.st.Update(ctx, func(tx store.Tx) error {
		have, ok, err := tx.Meta(MetaConfigKey)
		if err != nil {
			return err
		}
		if !ok {
			return tx.PutMeta(MetaConfigKey, string(want))
		}
		if have != string(want) {
			return fmt.Errorf("%w: stored %s, configured %s", ErrConfigMismatch, have, want)
		}
		return nil
	})
}

func (e *Engine) restore(ctx context.Context) error {
	var (
		cp     model.Checkpoint
		blocks []chain.Header
	)
	err := e.st.View(ctx, func(r store.Reader) error {
		var err error
		if cp, err = r.Checkpoint(); err != nil {
			return err
		}
		blocks, err = r.RecentBlocks(e.cfg.ReorgWindow)
		return err
	})
	if err != nil {
		return err
	}
	switch {
	case cp.Tip == nil && len(blocks) > 0:
		return errors.New("indexer: database has headers but no checkpoint")
	case cp.Tip != nil && (len(blocks) == 0 || blocks[len(blocks)-1].Ref() != *cp.Tip):
		return fmt.Errorf("indexer: checkpoint %s does not match the stored headers", cp.Tip)
	}
	tracked := make([]reorg.Block, len(blocks))
	for i, h := range blocks {
		tracked[i] = reorg.FromHeader(h)
	}
	pruned := len(blocks) > 0 && blocks[0].Number > e.cfg.Start
	if e.tracker, err = reorg.NewTracker(e.cfg.Start, e.cfg.ReorgWindow, tracked, pruned); err != nil {
		return err
	}
	e.updateStatus(func(s *Status) {
		s.Tip = cp.Tip
		s.ChainHead = max(s.ChainHead, cp.ChainHead)
	})
	if cp.Tip != nil {
		e.log.Info("resuming from checkpoint", "tip", cp.Tip.String(), "tracked_headers", len(blocks))
	}
	return nil
}

func sameTip(a, b *chain.BlockRef) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

// ownWriteCommitted resolves a checkpoint conflict (store.ErrTipConflict). If the stored tip is
// exactly the one an earlier write of this engine tried to set when its Update reported an
// error, that write committed after all: the engine reloads its tracker from the database and
// carries on (true). Any other stored tip was written by someone else (false: the caller halts).
// An error means the checkpoint could not be read, so the question stays open.
func (e *Engine) ownWriteCommitted(ctx context.Context) (bool, error) {
	if e.unconfirmed == nil {
		return false, nil
	}
	var cp model.Checkpoint
	if err := e.st.View(ctx, func(r store.Reader) error {
		var err error
		cp, err = r.Checkpoint()
		return err
	}); err != nil {
		return false, err
	}
	if !sameTip(cp.Tip, e.unconfirmed.tip) {
		return false, nil
	}
	if err := e.restore(ctx); err != nil {
		return false, err
	}
	e.unconfirmed = nil
	tip := "none"
	if cp.Tip != nil {
		tip = cp.Tip.String()
	}
	e.log.Warn("a write reported as failed had committed; continuing from the stored checkpoint", "tip", tip)
	if e.OnCommit != nil {
		e.OnCommit()
	}
	return true, nil
}

// Status returns a snapshot of the engine's progress.
func (e *Engine) Status() Status {
	e.mu.Lock()
	defer e.mu.Unlock()
	s := e.status
	if s.Tip != nil {
		t := *s.Tip
		s.Tip = &t
	}
	return s
}

// SafeHead is the highest block with at least confirmations confirmations, if any.
func SafeHead(tip *chain.BlockRef, chainHead, confirmations uint64) *uint64 {
	if tip == nil || chainHead < confirmations {
		return nil
	}
	safe := min(tip.Number, chainHead-confirmations)
	return &safe
}

func (e *Engine) updateStatus(fn func(s *Status)) {
	e.mu.Lock()
	defer e.mu.Unlock()
	fn(&e.status)
	e.status.SafeHead = SafeHead(e.status.Tip, e.status.ChainHead, e.cfg.Confirmations)
	e.status.Lag = 0
	if e.status.Tip != nil && e.status.ChainHead > e.status.Tip.Number {
		e.status.Lag = e.status.ChainHead - e.status.Tip.Number
	} else if e.status.Tip == nil && e.status.ChainHead+1 > e.cfg.Start {
		e.status.Lag = e.status.ChainHead + 1 - e.cfg.Start
	}
	e.m.ChainHead.Set(float64(e.status.ChainHead))
	e.m.HeadLag.Set(float64(e.status.Lag))
	if e.status.Tip != nil {
		e.m.IndexedHead.Set(float64(e.status.Tip.Number))
	}
	if e.status.SafeHead != nil {
		e.m.SafeHead.Set(float64(*e.status.SafeHead))
	}
}

// Run syncs until ctx is cancelled (returning nil: a graceful stop) or a fatal error occurs.
// Transient failures are retried with exponential backoff, and so are inconsistent node answers
// that persist (see inconsistentRetries). Two conditions are fatal because retrying cannot fix
// them: a fork below the retained header window (reorg.ErrBeyondWindow) and a checkpoint moved
// by another writer (store.ErrTipConflict: two indexers share a database). A checkpoint conflict
// caused by this engine's own write, one that committed although Update reported an error, is
// recognised and is not fatal.
func (e *Engine) Run(ctx context.Context) error {
	e.log.Info("indexer started", "chain_id", e.chainID, "start", e.cfg.Start, "confirmations", e.cfg.Confirmations,
		"reorg_window", e.cfg.ReorgWindow, "contracts", len(e.cfg.Fetch.Addresses))
	failures, retries := 0, 0
	for {
		outcome, err := e.SyncOnce(ctx)
		if ctx.Err() != nil {
			tip := "none"
			if s := e.Status(); s.Tip != nil {
				tip = s.Tip.String()
			}
			e.log.Info("indexer stopped", "checkpoint", tip)
			return nil
		}
		if outcome == Retry {
			if retries++; retries < inconsistentRetries {
				e.log.Debug("inconsistent node answers; retrying", "err", err, "attempt", retries)
				sleep(ctx, min(e.cfg.PollInterval, 200*time.Millisecond))
				continue
			}
			err = persistentInconsistency(retries, err)
		} else {
			retries = 0
		}
		if err != nil {
			if errors.Is(err, reorg.ErrBeyondWindow) {
				e.log.Error("reorg beyond the retained window; stopping", "err", err, "reorg_window", e.cfg.ReorgWindow)
				return err
			}
			if errors.Is(err, store.ErrTipConflict) {
				own, rerr := e.ownWriteCommitted(ctx)
				if own {
					failures = 0
					continue
				}
				if rerr == nil {
					e.log.Error("another writer moved the checkpoint; stopping (run one indexer per database)", "err", err)
					return err
				}
				err = fmt.Errorf("%w (checking the stored checkpoint: %v)", err, rerr)
			}
			failures++
			e.m.SyncErrors.WithLabelValues(errKind(err)).Inc()
			e.updateStatus(func(s *Status) { s.LastError = err.Error() })
			wait := min(e.cfg.PollInterval<<min(failures, 5), 30*time.Second)
			e.log.Warn("sync failed", "err", err, "attempt", failures, "retry_in", wait)
			sleep(ctx, wait)
			continue
		}
		failures = 0
		switch outcome {
		case Progressed, RolledBack:
			continue
		default:
			sleep(ctx, e.cfg.PollInterval)
		}
	}
}

// persistentInconsistency turns the n-th inconsistent iteration in a row into a sync error.
func persistentInconsistency(n int, err error) error {
	if err == nil {
		err = fetch.ErrInconsistent
	}
	return fmt.Errorf("node answers stayed inconsistent for %d iterations in a row: %w", n, err)
}

func sleep(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return true
	case <-ctx.Done():
		return false
	}
}

func errKind(err error) string {
	switch {
	case errors.Is(err, store.ErrTipConflict):
		return "tip_conflict"
	case errors.Is(err, fetch.ErrInconsistent):
		return "inconsistent"
	}
	if k := chain.Kind(err); k != "transport" {
		return k
	}
	return "other"
}

// forkError aborts a stream when a segment does not link to the tracked tip.
type forkError struct{ header chain.Header }

func (f *forkError) Error() string {
	return fmt.Sprintf("indexer: block %d (%s) does not link to the indexed chain", f.header.Number, f.header.Hash.TerminalString())
}

// SyncOnce performs one iteration: read the head, then either do nothing, roll back a fork, or
// fetch and commit everything up to the head.
func (e *Engine) SyncOnce(ctx context.Context) (Outcome, error) {
	var latest chain.Header
	err := e.fetcher.Do(ctx, "head", func() error {
		var err error
		latest, err = e.src.LatestHeader(ctx)
		return err
	})
	if err != nil {
		return Idle, fmt.Errorf("read head: %w", err)
	}
	e.updateStatus(func(s *Status) { s.ChainHead = latest.Number })
	target := latest
	if e.cfg.StopAt != nil && latest.Number > *e.cfg.StopAt {
		err = e.fetcher.Do(ctx, "stop_block", func() error {
			var err error
			target, err = e.src.HeaderByNumber(ctx, *e.cfg.StopAt)
			return err
		})
		if err != nil {
			return Idle, fmt.Errorf("read stop block: %w", err)
		}
	}
	switch e.tracker.Check(target) {
	case reorg.Known, reorg.Untracked:
		e.markSynced(ctx, latest.Number)
		return Idle, nil
	case reorg.Forked:
		return e.rollback(ctx, target, latest.Number)
	}

	from, to := e.tracker.Next(), target.Number
	window := max(e.cfg.Confirmations, 1)
	hashFrom := uint64(0)
	if latest.Number+1 > window {
		hashFrom = latest.Number + 1 - window
	}
	err = e.fetcher.Stream(ctx, from, to, hashFrom, func(seg fetch.Segment) error {
		return e.commit(ctx, seg, latest.Number)
	})
	var fork *forkError
	switch {
	case errors.As(err, &fork):
		return e.rollback(ctx, fork.header, latest.Number)
	case errors.Is(err, fetch.ErrInconsistent):
		return Retry, err
	case err != nil:
		return Progressed, err
	}
	e.markSynced(ctx, latest.Number)
	return Progressed, nil
}

// SyncUntil runs SyncOnce until the tip reaches target or ctx ends. Transient errors, and
// inconsistent answers that persist past inconsistentRetries iterations, are retried up to 20
// times in a row; the next one is returned. Fatal errors are those of Run.
func (e *Engine) SyncUntil(ctx context.Context, target uint64) error {
	failures, retries := 0, 0
	for {
		if tip, ok := e.tracker.Tip(); ok && tip.Number >= target {
			return nil
		}
		outcome, err := e.SyncOnce(ctx)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if outcome == Retry {
			if retries++; retries < inconsistentRetries {
				sleep(ctx, min(e.cfg.PollInterval, 100*time.Millisecond))
				continue
			}
			err = persistentInconsistency(retries, err)
		} else {
			retries = 0
		}
		if err != nil {
			if errors.Is(err, store.ErrTipConflict) {
				own, rerr := e.ownWriteCommitted(ctx)
				if own {
					continue
				}
				if rerr == nil {
					return err
				}
			}
			if errors.Is(err, reorg.ErrBeyondWindow) || failures >= 20 {
				return err
			}
			failures++
			sleep(ctx, min(e.cfg.PollInterval<<min(failures, 4), 5*time.Second))
			continue
		}
		failures = 0
		if outcome == Idle {
			sleep(ctx, min(e.cfg.PollInterval, 100*time.Millisecond))
		}
	}
}

func (e *Engine) markSynced(ctx context.Context, chainHead uint64) {
	now := e.Now()
	e.updateStatus(func(s *Status) {
		s.Synced = s.Tip != nil && s.Tip.Number >= chainHead || (e.cfg.StopAt != nil && s.Tip != nil && s.Tip.Number >= *e.cfg.StopAt)
		if s.Tip == nil && chainHead < e.cfg.Start {
			s.Synced = true
		}
		s.LastSync = now
		s.LastError = ""
	})
	// Persist the node head for read-only API processes, at most every few seconds.
	e.mu.Lock()
	due := now.Sub(e.lastHeartbeat) >= 5*time.Second
	if due {
		e.lastHeartbeat = now
	}
	e.mu.Unlock()
	if due {
		wctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		defer cancel()
		if err := e.st.Update(wctx, func(tx store.Tx) error { return tx.Heartbeat(chainHead, now.UnixMilli()) }); err != nil {
			e.log.Warn("heartbeat failed", "err", err)
		}
	}
}

// decodeSegment decodes every log and groups them by block.
func (e *Engine) decodeSegment(seg fetch.Segment) map[uint64][]decodedLog {
	out := make(map[uint64][]decodedLog, len(seg.Headers))
	for i := range seg.Logs {
		l := &seg.Logs[i]
		dl := decodedLog{raw: l}
		dec, err := e.decoder.Decode(l)
		switch {
		case err == nil:
			dl.transfer, dl.vault = dec.Transfer, dec.Vault
		case errors.Is(err, decode.ErrMalformed):
			e.m.Undecodable.Inc()
			e.log.Debug("undecodable log stored raw", "block", l.BlockNumber, "index", l.Index, "address", l.Address, "err", err)
		}
		out[l.BlockNumber] = append(out[l.BlockNumber], dl)
	}
	return out
}

// writeContext detaches a commit from cancellation: a shutdown signal waits for the running
// transaction instead of aborting it (it would roll back anyway, but finishing is cheaper).
func writeContext(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(ctx), 2*time.Minute)
}

func tipRef(t *reorg.Tracker) *chain.BlockRef {
	if b, ok := t.Tip(); ok {
		r := b.Ref()
		return &r
	}
	return nil
}

// commit applies one validated segment.
func (e *Engine) commit(ctx context.Context, seg fetch.Segment, chainHead uint64) error {
	first := seg.Headers[0]
	switch v := e.tracker.Check(first); v {
	case reorg.Extends:
	case reorg.Forked:
		return &forkError{header: first}
	default:
		return fmt.Errorf("indexer: segment %d..%d is %s relative to the tip", seg.From, seg.To, v)
	}
	decoded := e.decodeSegment(seg)
	expected := tipRef(e.tracker)
	next := seg.Headers[len(seg.Headers)-1].Ref()
	now := e.Now()
	var stats applyStats
	wctx, cancel := writeContext(ctx)
	defer cancel()
	start := time.Now()
	err := e.st.Update(wctx, func(tx store.Tx) error {
		if err := tx.MoveTip(expected, &next, chainHead, now.UnixMilli()); err != nil {
			return err
		}
		d := newDeriver(tx, e.cfg.Contracts)
		for _, h := range seg.Headers {
			if err := d.applyBlock(h, decoded[h.Number]); err != nil {
				return err
			}
		}
		if err := d.flush(); err != nil {
			return err
		}
		if err := e.prune(tx, next.Number); err != nil {
			return err
		}
		stats = d.stats
		return nil
	})
	if err != nil {
		e.noteFailedWrite(err, &next)
		return fmt.Errorf("commit %d..%d: %w", seg.From, seg.To, err)
	}
	e.unconfirmed = nil
	e.m.CommitDuration.Observe(time.Since(start).Seconds())
	if err := e.tracker.Append(seg.Headers); err != nil {
		return err
	}
	e.m.ObserveBlocks(len(seg.Headers), now)
	e.m.LogsIndexed.Add(float64(stats.logs))
	e.m.BalanceAnomalies.Add(float64(stats.anomalies))
	for k, n := range stats.events {
		e.m.EventsPublished.WithLabelValues(k).Add(float64(n))
	}
	if stats.anomalies > 0 {
		e.log.Warn("negative balances after commit (a token moved balances without Transfer events)", "count", stats.anomalies)
	}
	e.updateStatus(func(s *Status) { s.Tip = &next })
	e.log.Debug("committed", "from", seg.From, "to", seg.To, "mode", seg.Mode.String(), "logs", stats.logs)
	if e.OnCommit != nil {
		e.OnCommit()
	}
	return nil
}

// noteFailedWrite records the tip a failed write transaction tried to set, unless the failure
// was the checkpoint conflict itself (then nothing was written, and an earlier unconfirmed write
// stays the one to check).
func (e *Engine) noteFailedWrite(err error, tip *chain.BlockRef) {
	if errors.Is(err, store.ErrTipConflict) {
		return
	}
	e.unconfirmed = &pendingWrite{tip: tip}
}

// storeAncestor keeps a stored header for the target of a rollback whose ancestor had already
// been pruned from the header window (a reorg exactly as deep as the window): the checkpoint
// must point at a stored header for the next start-up to restore the tracker.
func storeAncestor(tx store.Tx, h chain.Header) error {
	top, err := tx.RecentBlocks(1)
	if err != nil {
		return err
	}
	if len(top) == 1 && top[0].Number == h.Number {
		if top[0].Hash != h.Hash {
			return fmt.Errorf("indexer: stored header %d is %s, the common ancestor is %s", h.Number,
				top[0].Hash.TerminalString(), h.Hash.TerminalString())
		}
		return nil // still stored (the window was larger when it was written)
	}
	return tx.InsertBlock(h)
}

func (e *Engine) prune(tx store.Tx, tip uint64) error {
	if window := uint64(e.cfg.ReorgWindow); tip+1 > window {
		if err := tx.PruneBlocksBelow(tip + 1 - window); err != nil {
			return err
		}
	}
	_, newest, err := tx.EventBounds()
	if err != nil {
		return err
	}
	if newest > e.cfg.EventRetention {
		return tx.PruneEventsBelow(newest - e.cfg.EventRetention + 1)
	}
	return nil
}

// rollback resolves a fork revealed by header h and undoes the orphaned blocks.
func (e *Engine) rollback(ctx context.Context, h chain.Header, chainHead uint64) (Outcome, error) {
	byHash := func(ctx context.Context, hash common.Hash) (chain.Header, error) {
		var h chain.Header
		err := e.fetcher.Do(ctx, "ancestor", func() error {
			var err error
			h, err = e.src.HeaderByHash(ctx, hash)
			return err
		})
		return h, err
	}
	rb, err := e.tracker.FindAncestor(ctx, h, byHash)
	if err != nil {
		return Idle, fmt.Errorf("find common ancestor: %w", err)
	}
	now := e.Now()
	var ancestor *chain.BlockRef
	if rb.Ancestor != nil {
		r := rb.Ancestor.Ref()
		ancestor = &r
	}
	rec := model.Reorg{DetectedAt: now.UnixMilli(), OldTip: rb.OldTip.Ref(), Ancestor: ancestor, NewHead: h.Ref(), Depth: rb.Depth}
	expected := tipRef(e.tracker)
	var (
		stats   applyStats
		deleted store.Deleted
	)
	wctx, cancel := writeContext(ctx)
	defer cancel()
	start := time.Now()
	err = e.st.Update(wctx, func(tx store.Tx) error {
		if err := tx.MoveTip(expected, ancestor, chainHead, now.UnixMilli()); err != nil {
			return err
		}
		d := newDeriver(tx, e.cfg.Contracts)
		var err error
		if deleted, err = d.revertFrom(rb.From); err != nil {
			return err
		}
		if rb.AncestorHeader != nil {
			if err := storeAncestor(tx, *rb.AncestorHeader); err != nil {
				return err
			}
		}
		if err := d.emit(model.EventReorg, h.Number, rec); err != nil {
			return err
		}
		stats = d.stats
		return tx.InsertReorg(rec)
	})
	if err != nil {
		e.noteFailedWrite(err, ancestor)
		return Idle, fmt.Errorf("roll back to %d: %w", rb.From, err)
	}
	e.unconfirmed = nil
	e.m.CommitDuration.Observe(time.Since(start).Seconds())
	e.tracker.Undo(rb)
	e.m.Reorgs.Inc()
	e.m.ReorgDepth.Observe(float64(rb.Depth))
	for k, n := range stats.retracted {
		e.m.Retractions.WithLabelValues(k).Add(float64(n))
	}
	for k, n := range stats.events {
		e.m.EventsPublished.WithLabelValues(k).Add(float64(n))
	}
	attrs := []any{"depth", rb.Depth, "old_tip", rb.OldTip.Ref().String(), "new_head", h.Ref().String(),
		"blocks_deleted", deleted.Blocks, "logs_deleted", deleted.Logs, "transfers_retracted", deleted.Transfers,
		"vault_events_retracted", deleted.VaultEvents, "share_prices_retracted", deleted.SharePrices}
	if ancestor != nil {
		attrs = append(attrs, "ancestor", ancestor.String())
	}
	if rb.Depth > e.cfg.Confirmations {
		e.m.DeepReorgs.Inc()
		e.log.Error("reorg deeper than the confirmation depth: safe-view data was retracted", append(attrs, "confirmations", e.cfg.Confirmations)...)
	} else {
		e.log.Warn("reorg rolled back", attrs...)
	}
	e.updateStatus(func(s *Status) { s.Tip = ancestor })
	if e.OnCommit != nil {
		e.OnCommit()
	}
	return RolledBack, nil
}
