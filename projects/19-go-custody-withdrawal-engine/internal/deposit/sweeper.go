// SPDX-License-Identifier: MIT

package deposit

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"slices"
	"strings"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/audit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/bindings"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/chain"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/clock"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/metrics"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/signer"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/txmgr"
)

// SweeperConfig parameterises the sweeper.
type SweeperConfig struct {
	Factory   common.Address
	HotWallet common.Address
	Tokens    map[string]common.Address // asset symbol -> token
	BatchSize int
	MinAmount *big.Int // skip batches whose credited total is below this (per asset, base units)
}

// Sweeper batches credited deposits into flushMany transactions.
type Sweeper struct {
	db      *store.DB
	clock   clock.Clock
	metrics *metrics.Metrics
	log     *slog.Logger
	txm     *txmgr.Manager
	cfg     SweeperConfig
	abi     *bindings.ForwarderFactory
}

// NewSweeper returns a Sweeper.
func NewSweeper(db *store.DB, clk clock.Clock, m *metrics.Metrics, log *slog.Logger, txm *txmgr.Manager, cfg SweeperConfig) (*Sweeper, error) {
	if cfg.BatchSize <= 0 {
		return nil, errors.New("deposit: sweep batch size must be positive")
	}
	if cfg.MinAmount == nil {
		cfg.MinAmount = new(big.Int)
	}
	return &Sweeper{db: db, clock: clk, metrics: m, log: log, txm: txm, cfg: cfg, abi: bindings.NewForwarderFactory()}, nil
}

func newSweepID() (string, error) {
	var b [12]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return "sw_" + hex.EncodeToString(b[:]), nil
}

type sweepItem struct {
	salt      common.Hash
	forwarder common.Address
}

func (sw *Sweeper) items(ctx context.Context, q store.Querier, sweepID string) ([]sweepItem, error) {
	rows, err := q.QueryContext(ctx, `SELECT salt, forwarder FROM sweep_items WHERE sweep_id = ? ORDER BY forwarder`, sweepID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []sweepItem
	for rows.Next() {
		var s, f string
		if err := rows.Scan(&s, &f); err != nil {
			return nil, err
		}
		out = append(out, sweepItem{common.HexToHash(s), common.HexToAddress(f)})
	}
	return out, rows.Err()
}

// SweepOnce submits at most one sweep per asset. A sweep whose transaction is still live blocks
// the next one for that asset, so a forwarder is never in two concurrent sweeps.
func (sw *Sweeper) SweepOnce(ctx context.Context) error {
	assets := make([]string, 0, len(sw.cfg.Tokens))
	for a := range sw.cfg.Tokens {
		assets = append(assets, a)
	}
	slices.Sort(assets)
	for _, asset := range assets {
		if err := sw.sweepAsset(ctx, asset); err != nil {
			return fmt.Errorf("deposit: sweep %s: %w", asset, err)
		}
	}
	return nil
}

func (sw *Sweeper) sweepAsset(ctx context.Context, asset string) error {
	token := sw.cfg.Tokens[asset]
	// Resume a pending sweep that has no signed transaction yet (crash or transient error
	// between creating the sweep and signing it).
	var pendingID string
	err := sw.db.QueryRowContext(ctx, `SELECT id FROM sweeps WHERE asset = ? AND status = 'pending' ORDER BY created_at LIMIT 1`, asset).Scan(&pendingID)
	switch {
	case err == nil:
		slot, err := txmgr.SlotFor(ctx, sw.db, signer.PurposeSweep, pendingID)
		if err == nil && slot.State != txmgr.StateReserved {
			return nil // live transaction; the tracker owns it
		}
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			return err
		}
		return sw.submit(ctx, pendingID, asset, token)
	case !errors.Is(err, sql.ErrNoRows):
		return err
	}

	rows, err := sw.db.QueryContext(ctx, `
		SELECT a.salt, d.forwarder, d.amount FROM deposits d JOIN deposit_addresses a ON a.address = d.forwarder
		WHERE d.status = 'credited' AND d.swept_by IS NULL AND d.asset = ? ORDER BY d.block_number, d.log_index`, asset)
	if err != nil {
		return err
	}
	var batch []sweepItem
	total := new(big.Int)
	seen := map[common.Address]bool{}
	for rows.Next() {
		var salt, fwd, amt string
		if err := rows.Scan(&salt, &fwd, &amt); err != nil {
			rows.Close()
			return err
		}
		v, _ := new(big.Int).SetString(amt, 10)
		f := common.HexToAddress(fwd)
		if !seen[f] {
			if len(batch) == sw.cfg.BatchSize {
				continue
			}
			seen[f] = true
			batch = append(batch, sweepItem{common.HexToHash(salt), f})
		}
		total.Add(total, v)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	if len(batch) == 0 || total.Cmp(sw.cfg.MinAmount) < 0 {
		return nil
	}
	id, err := newSweepID()
	if err != nil {
		return err
	}
	if err := sw.db.WithTx(ctx, func(tx *store.Tx) error {
		now := sw.clock.Now()
		if _, err := tx.ExecContext(ctx, `INSERT INTO sweeps (id, asset, status, created_at, updated_at) VALUES (?, ?, 'pending', ?, ?)`,
			id, asset, now.UnixNano(), now.UnixNano()); err != nil {
			return err
		}
		fwds := make([]string, 0, len(batch))
		for _, it := range batch {
			if _, err := tx.ExecContext(ctx, `INSERT INTO sweep_items (sweep_id, salt, forwarder) VALUES (?, ?, ?)`, id, it.salt.Hex(), it.forwarder.Hex()); err != nil {
				return err
			}
			fwds = append(fwds, it.forwarder.Hex())
		}
		return audit.Record(ctx, tx, now, audit.Event{Type: "sweep.created", Actor: "engine", Subject: id,
			Data: map[string]any{"asset": asset, "forwarders": fwds, "credited_total": total.String()}})
	}); err != nil {
		return err
	}
	return sw.submit(ctx, id, asset, token)
}

func (sw *Sweeper) submit(ctx context.Context, id, asset string, token common.Address) error {
	items, err := sw.items(ctx, sw.db, id)
	if err != nil {
		return err
	}
	salts := make([][32]byte, len(items))
	for i, it := range items {
		salts[i] = it.salt
	}
	data := sw.abi.PackFlushMany(salts, token)
	// No GasLimit: Submit estimates flushMany before reserving a nonce, and releases a
	// reservation left by an interrupted earlier attempt if the estimate now fails.
	err = sw.txm.Submit(ctx, signer.PurposeSweep, id, txmgr.Payload{To: sw.cfg.Factory, Data: data}, txmgr.SubmitHooks{
		Refused: func(ctx context.Context, tx *store.Tx, reason error) error {
			return sw.fail(ctx, tx, id, "signing refused: "+reason.Error())
		},
	})
	if errors.Is(err, txmgr.ErrRefused) {
		return nil
	}
	return err
}

func (sw *Sweeper) fail(ctx context.Context, tx *store.Tx, id, reason string) error {
	now := sw.clock.Now()
	if _, err := tx.ExecContext(ctx, `UPDATE sweeps SET status = 'failed', updated_at = ? WHERE id = ?`, now.UnixNano(), id); err != nil {
		return err
	}
	tx.OnCommit(func() { sw.metrics.Sweeps.WithLabelValues("failed").Inc() })
	return audit.Record(ctx, tx, now, audit.Event{Type: "sweep.failed", Actor: "engine", Subject: id, Data: map[string]any{"reason": reason}})
}

// Owner returns the transaction-manager owner for sweep slots.
func (sw *Sweeper) Owner() txmgr.Owner { return sweepOwner{sw} }

type sweepOwner struct{ sw *Sweeper }

func (o sweepOwner) asset(ctx context.Context, q store.Querier, id string) (string, error) {
	var asset string
	err := q.QueryRowContext(ctx, `SELECT asset FROM sweeps WHERE id = ?`, id).Scan(&asset)
	return asset, err
}

func (o sweepOwner) SignRequest(ctx context.Context, q store.Querier, s txmgr.Slot) (signer.Request, error) {
	asset, err := o.asset(ctx, q, s.RefID)
	if err != nil {
		return signer.Request{}, err
	}
	return signer.Request{Purpose: signer.PurposeSweep, Asset: asset}, nil
}

// swept sums the Transfer logs moving tokens from the sweep's forwarders to the hot wallet.
func (o sweepOwner) swept(ctx context.Context, q store.Querier, s txmgr.Slot, r *types.Receipt) (string, *big.Int, uint, bool, error) {
	asset, err := o.asset(ctx, q, s.RefID)
	if err != nil {
		return "", nil, 0, false, err
	}
	items, err := o.sw.items(ctx, q, s.RefID)
	if err != nil {
		return "", nil, 0, false, err
	}
	fwds := map[common.Address]bool{}
	for _, it := range items {
		fwds[it.forwarder] = true
	}
	token := o.sw.cfg.Tokens[asset]
	total := new(big.Int)
	var firstLog uint
	found := false
	for _, l := range r.Logs {
		tl, ok := chain.DecodeTransferLog(l)
		if !ok || tl.Token != token || tl.To != o.sw.cfg.HotWallet || !fwds[tl.From] {
			continue
		}
		if !found || l.Index < firstLog {
			firstLog = l.Index
		}
		found = true
		total.Add(total, tl.Amount)
	}
	return asset, total, firstLog, found, nil
}

func (o sweepOwner) InclusionPostings(ctx context.Context, q store.Querier, s txmgr.Slot, a txmgr.Attempt, r *types.Receipt) ([]ledger.Posting, error) {
	if a.Kind == txmgr.KindCancel || r.Status != types.ReceiptStatusSuccessful {
		return nil, nil
	}
	asset, total, _, _, err := o.swept(ctx, q, s, r)
	if err != nil || total.Sign() == 0 {
		return nil, err
	}
	return []ledger.Posting{
		ledger.Debit(ledger.InFlight, asset, total),
		ledger.Credit(ledger.Forwarders, asset, total),
	}, nil
}

func (o sweepOwner) OnSent(context.Context, *store.Tx, txmgr.Slot) error    { return nil }
func (o sweepOwner) OnReorged(context.Context, *store.Tx, txmgr.Slot) error { return nil }
func (o sweepOwner) OnIncluded(context.Context, *store.Tx, txmgr.Slot, txmgr.Attempt, *types.Receipt) error {
	return nil
}

// OnFinal marks the sweep done and attributes deposits to it: every deposit to one of its
// forwarders that happened before the flush (earlier block, or same block with a lower log
// index), including deposits still waiting for confirmations, which the flush also moved.
func (o sweepOwner) OnFinal(ctx context.Context, tx *store.Tx, s txmgr.Slot, a txmgr.Attempt, r *types.Receipt, out txmgr.Outcome) error {
	now := o.sw.clock.Now()
	if out != txmgr.Succeeded {
		return o.sw.fail(ctx, tx, s.RefID, "sweep transaction "+out.String())
	}
	asset, total, firstLog, found, err := o.swept(ctx, tx, s, r)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE sweeps SET status = 'done', swept = ?, updated_at = ? WHERE id = ?`, total.String(), now.UnixNano(), s.RefID); err != nil {
		return err
	}
	items, err := o.sw.items(ctx, tx, s.RefID)
	if err != nil {
		return err
	}
	block := r.BlockNumber.Uint64()
	// Within the sweep's own block, only deposits logged before the flush's first transfer were
	// moved by it. When the flush moved nothing at all, no deposit to these forwarders preceded
	// it in that block (the flush would have moved it), so none of that block's deposits is
	// attributed: they came after the flush and still sit in their forwarders.
	sameBlockBefore := int64(-1)
	if found {
		sameBlockBefore = int64(firstLog)
	}
	fwds := make([]string, 0, len(items))
	for _, it := range items {
		if _, err := tx.ExecContext(ctx, `
			UPDATE deposits SET swept_by = ? WHERE forwarder = ? AND asset = ? AND swept_by IS NULL
			AND (block_number < ? OR (block_number = ? AND log_index < ?))`,
			s.RefID, it.forwarder.Hex(), asset, block, block, sameBlockBefore); err != nil {
			return err
		}
		fwds = append(fwds, it.forwarder.Hex())
	}
	tx.OnCommit(func() { o.sw.metrics.Sweeps.WithLabelValues("done").Inc() })
	return audit.Record(ctx, tx, now, audit.Event{Type: "sweep.done", Actor: "engine", Subject: s.RefID,
		Data: map[string]any{"asset": asset, "swept": total.String(), "tx": a.Hash.Hex(), "gas_used": r.GasUsed,
			"forwarders": strings.Join(fwds, ",")}})
}
