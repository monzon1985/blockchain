// SPDX-License-Identifier: MIT

// Package txmgr owns every transaction the hot wallet sends: nonce allocation, signing through
// the firewall, write-ahead persistence, broadcasting, replace-by-fee, cancellation, nonce-gap
// filling and reorg-aware tracking up to the confirmation depth.
//
// The central safety rule is write-ahead: a signed transaction is committed to SQLite before it
// is ever handed to a node, and every transaction for a given business object (a withdrawal, a
// sweep) uses one nonce. Whatever the crash point, the database knows every transaction that
// could possibly be on the network, and at most one of them can ever be mined.
package txmgr

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/audit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/chain"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/clock"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/failpoint"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/fees"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/metrics"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/signer"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

// ErrAbort is returned by a SubmitHooks.Persisted callback to discard a freshly signed
// transaction (the business object changed while it was being signed).
var ErrAbort = errors.New("txmgr: submission aborted")

// ErrRefused wraps a firewall refusal returned by Submit.
var ErrRefused = errors.New("txmgr: signing refused by policy")

// Outcome is how a slot ended.
type Outcome int

// Slot outcomes.
const (
	Succeeded Outcome = iota // the payload transaction was mined and did not revert
	Reverted                 // the payload transaction was mined and reverted
	Cancelled                // the zero-value cancellation was mined instead
)

// String implements fmt.Stringer.
func (o Outcome) String() string {
	switch o {
	case Succeeded:
		return "succeeded"
	case Reverted:
		return "reverted"
	default:
		return "cancelled"
	}
}

// Owner is the business object behind a slot purpose (withdrawals, sweeps, gap fillers). All
// callbacks except SignRequest run inside the transaction that records the chain event.
type Owner interface {
	// SignRequest returns the firewall request (purpose, account, asset) for the slot's payload.
	SignRequest(ctx context.Context, q store.Querier, s Slot) (signer.Request, error)
	// InclusionPostings returns the value postings (not gas) of an included attempt.
	InclusionPostings(ctx context.Context, q store.Querier, s Slot, a Attempt, r *types.Receipt) ([]ledger.Posting, error)
	// OnSent runs the first time a node accepts one of the slot's transactions.
	OnSent(ctx context.Context, tx *store.Tx, s Slot) error
	// OnIncluded runs when an attempt is observed in a canonical block.
	OnIncluded(ctx context.Context, tx *store.Tx, s Slot, a Attempt, r *types.Receipt) error
	// OnReorged runs when a previously observed inclusion is no longer canonical.
	OnReorged(ctx context.Context, tx *store.Tx, s Slot) error
	// OnFinal runs once, when an inclusion reaches the confirmation depth.
	OnFinal(ctx context.Context, tx *store.Tx, s Slot, a Attempt, r *types.Receipt, o Outcome) error
}

// Config parameterises the manager.
type Config struct {
	Confirmations   uint64 // blocks, including the inclusion block
	BumpAfterBlocks uint64 // blocks without inclusion before a fee bump
	GapGraceBlocks  uint64 // blocks a nonce gap may persist before it is filled
	GasLimitBps     int64  // gas limit = estimate * GasLimitBps / 10000
	NativeAsset     string // ledger symbol of the native currency (gas)
}

// Manager coordinates hot-wallet transactions.
type Manager struct {
	db      *store.DB
	chain   chain.Client
	fw      *signer.Firewall
	fees    *fees.Estimator
	clock   clock.Clock
	fp      *failpoint.Set
	metrics *metrics.Metrics
	log     *slog.Logger
	cfg     Config

	owners map[signer.Purpose]Owner

	mu   sync.Mutex
	gaps map[uint64]uint64 // gap nonce -> head at which it was first seen
	// reserved remembers, per reserved slot without a signature, the head at which the tracker
	// first saw it, so an abandoned reservation can be told apart from one being signed now.
	reserved map[reservation]uint64
	// lostFinal latches once a finalized transaction was reported missing from the chain, so
	// the alarm is raised once per episode rather than every round.
	lostFinal bool
	wake      chan struct{}
}

// reservation identifies one nonce reservation.
type reservation struct {
	nonce   uint64
	purpose signer.Purpose
	ref     string
}

// ReservationTTL is how long a reservation may stay unsigned before the tracker treats it as
// abandoned and releases it (it must also have been seen across GapGraceBlocks blocks).
// Signing takes milliseconds; the owners of withdrawal and sweep reservations release their
// own on every failed retry, so this only catches what nothing else will ever retry.
const ReservationTTL = 5 * time.Minute

// New returns a Manager. Owners are registered with Register before the first round.
func New(db *store.DB, c chain.Client, fw *signer.Firewall, est *fees.Estimator, clk clock.Clock,
	fp *failpoint.Set, m *metrics.Metrics, log *slog.Logger, cfg Config) (*Manager, error) {
	if cfg.Confirmations == 0 {
		return nil, errors.New("txmgr: confirmations must be at least 1")
	}
	if cfg.BumpAfterBlocks == 0 {
		return nil, errors.New("txmgr: bump_after_blocks must be at least 1")
	}
	if cfg.GasLimitBps < 10_000 {
		return nil, errors.New("txmgr: gas_limit_bps must be at least 10000")
	}
	if cfg.NativeAsset == "" {
		return nil, errors.New("txmgr: native asset symbol required")
	}
	mgr := &Manager{
		db: db, chain: c, fw: fw, fees: est, clock: clk, fp: fp, metrics: m, log: log, cfg: cfg,
		owners: map[signer.Purpose]Owner{}, gaps: map[uint64]uint64{}, reserved: map[reservation]uint64{},
		wake: make(chan struct{}, 1),
	}
	mgr.Register(signer.PurposeFiller, fillerOwner{})
	return mgr, nil
}

// Register attaches the owner of a purpose.
func (m *Manager) Register(p signer.Purpose, o Owner) { m.owners[p] = o }

// From is the hot-wallet address.
func (m *Manager) From() common.Address { return m.fw.Address() }

// Config returns the manager configuration.
func (m *Manager) Config() Config { return m.cfg }

// Wake asks the tracker to run a round now (non-blocking).
func (m *Manager) Wake() {
	select {
	case m.wake <- struct{}{}:
	default:
	}
}

// WakeC is signalled by Wake.
func (m *Manager) WakeC() <-chan struct{} { return m.wake }

// hit fires withdrawal failpoints. Sweeps and gap fillers share the code path but the chaos
// suite targets the withdrawal state machine, so their crashes are driven separately.
func (m *Manager) hit(p signer.Purpose, name string) {
	if p == signer.PurposeWithdrawal {
		m.fp.Hit(name)
	}
}

func (m *Manager) owner(p signer.Purpose) (Owner, error) {
	o, ok := m.owners[p]
	if !ok {
		return nil, fmt.Errorf("txmgr: no owner registered for %q", p)
	}
	return o, nil
}

// Bootstrap records the nonce floor on first start: the account nonce at adoption time. From
// then on the engine assumes it is the only user of the key; drift is detected and reported.
func (m *Manager) Bootstrap(ctx context.Context) error {
	return m.db.WithTx(ctx, func(tx *store.Tx) error {
		if _, ok, err := store.GetMeta(ctx, tx, metaNonceFloor); err != nil || ok {
			return err
		}
		n, err := m.chain.NonceAt(ctx, m.From())
		if err != nil {
			return fmt.Errorf("txmgr: bootstrap nonce: %w", err)
		}
		return store.SetMeta(ctx, tx, metaNonceFloor, fmt.Sprint(n))
	})
}

// Payload is the call a slot's original transaction makes. A zero GasLimit asks Submit to
// estimate it (with the configured margin) before reserving a nonce.
type Payload struct {
	To       common.Address
	Data     []byte
	GasLimit uint64
}

// EstimateGas estimates p's gas from the hot wallet and applies the safety margin.
func (m *Manager) EstimateGas(ctx context.Context, to common.Address, data []byte) (uint64, error) {
	g, err := m.chain.EstimateGas(ctx, ethereumCall(m.From(), to, data))
	if err != nil {
		return 0, err
	}
	return g * uint64(m.cfg.GasLimitBps) / 10_000, nil
}

// SubmitHooks lets the owner update its own state atomically with the manager's writes.
type SubmitHooks struct {
	// Persisted runs in the transaction that stores the signed attempt. Returning ErrAbort
	// discards the signature and releases the nonce.
	Persisted func(ctx context.Context, tx *store.Tx, s Slot, hash common.Hash) error
	// Refused runs in the transaction that releases the nonce after a firewall refusal.
	Refused func(ctx context.Context, tx *store.Tx, reason error) error
}

// Submit reserves a nonce, signs the original transaction through the firewall and persists
// it. It never broadcasts: the tracker sends persisted attempts, which is what makes the
// persist-then-send order impossible to get wrong.
//
// With a zero p.GasLimit the call is estimated first, before any nonce is reserved, so a
// liquidity shortfall (the estimate reverts) never holds a nonce. If the estimate fails while
// a reservation for (purpose, ref) survives from an interrupted earlier run (a crash between
// reserving and persisting the signature), that reservation is released as well: left in
// place it would sit below every later nonce and freeze the queue, including the sweeps that
// would restore the liquidity.
func (m *Manager) Submit(ctx context.Context, purpose signer.Purpose, ref string, p Payload, h SubmitHooks) error {
	if p.GasLimit == 0 {
		gas, err := m.EstimateGas(ctx, p.To, p.Data)
		if err != nil {
			err = fmt.Errorf("txmgr: estimate gas for %s %s (hot-wallet liquidity?): %w", purpose, ref, err)
			if relErr := m.releaseUnsigned(ctx, purpose, ref, "gas estimation failed on retry"); relErr != nil {
				return errors.Join(err, relErr)
			}
			return err
		}
		p.GasLimit = gas
	}
	f, capped, err := m.fees.Suggest(ctx)
	if err != nil {
		return err
	}
	if capped {
		m.log.Warn("fee suggestion clamped to the cap", "purpose", purpose, "ref", ref, "fees", f)
	}
	var slot Slot
	if err := m.db.WithTx(ctx, func(tx *store.Tx) error {
		var err error
		slot, err = Reserve(ctx, tx, purpose, ref, m.clock.Now())
		return err
	}); err != nil {
		return err
	}
	if slot.State != StateReserved {
		return nil // an earlier run already persisted the signed transaction
	}
	m.hit(purpose, failpoint.BeforeSign)

	o, err := m.owner(purpose)
	if err != nil {
		return err
	}
	req, err := o.SignRequest(ctx, m.db, slot)
	if err != nil {
		return err
	}
	req.Tx = types.NewTx(&types.DynamicFeeTx{
		ChainID:   m.fw.ChainID(),
		Nonce:     slot.Nonce,
		GasTipCap: f.Tip,
		GasFeeCap: f.MaxFee,
		Gas:       p.GasLimit,
		To:        &p.To,
		Value:     new(big.Int),
		Data:      p.Data,
	})
	signed, signErr := m.fw.Sign(ctx, req)
	if signErr != nil {
		refused := errors.Is(signErr, signer.ErrPolicy)
		if err := m.db.WithTx(ctx, func(tx *store.Tx) error {
			if _, err := Release(ctx, tx, purpose, ref); err != nil {
				return err
			}
			if refused && h.Refused != nil {
				return h.Refused(ctx, tx, signErr)
			}
			return nil
		}); err != nil {
			return errors.Join(signErr, err)
		}
		if refused {
			return fmt.Errorf("%w: %v", ErrRefused, signErr)
		}
		return signErr
	}

	err = m.db.WithTx(ctx, func(tx *store.Tx) error {
		if err := m.persistAttempt(ctx, tx, slot, signed, KindOriginal); err != nil {
			return err
		}
		if h.Persisted != nil {
			if err := h.Persisted(ctx, tx, slot, signed.Hash()); err != nil {
				return err
			}
		}
		tx.OnCommit(func() { m.metrics.TxSigned.WithLabelValues(string(purpose), KindOriginal).Inc() })
		return nil
	})
	if errors.Is(err, ErrAbort) {
		relErr := m.db.WithTx(ctx, func(tx *store.Tx) error {
			_, err := Release(ctx, tx, purpose, ref)
			return err
		})
		return errors.Join(err, relErr)
	}
	if err != nil {
		return err
	}
	m.hit(purpose, failpoint.AfterSign)
	m.Wake()
	return nil
}

// releaseUnsigned releases the reservation of (purpose, ref) if it still has no signed
// transaction, and records why. It is a no-op when there is nothing to release.
func (m *Manager) releaseUnsigned(ctx context.Context, purpose signer.Purpose, ref, reason string) error {
	s, err := SlotFor(ctx, m.db, purpose, ref)
	if errors.Is(err, store.ErrNotFound) {
		return nil
	}
	if err != nil || s.State != StateReserved {
		return err
	}
	return m.db.WithTx(ctx, func(tx *store.Tx) error {
		return m.release(ctx, tx, s, reason)
	})
}

// release deletes a reservation that never produced a signature (inside tx), with an audit
// event and a metric. Release itself re-checks both conditions, so a slot that was signed in
// the meantime is left alone.
func (m *Manager) release(ctx context.Context, tx *store.Tx, s Slot, reason string) error {
	released, err := Release(ctx, tx, s.Purpose, s.RefID)
	if err != nil || !released {
		return err
	}
	tx.OnCommit(func() {
		m.metrics.ReservationsReleased.Inc()
		m.log.Warn("txmgr: released a nonce reservation that was never signed", "nonce", s.Nonce, "purpose", s.Purpose, "ref", s.RefID, "reason", reason)
	})
	return audit.Record(ctx, tx, m.clock.Now(), audit.Event{
		Type: "nonce.reservation_released", Actor: "engine", Subject: fmt.Sprintf("nonce:%d", s.Nonce),
		Data: map[string]any{"purpose": string(s.Purpose), "ref": s.RefID, "reason": reason},
	})
}

// persistAttempt stores a signed transaction. It re-checks that the slot still belongs to the
// same owner: a nonce released and re-reserved while this transaction was being signed must
// never receive it.
func (m *Manager) persistAttempt(ctx context.Context, tx *store.Tx, s Slot, signed *types.Transaction, kind string) error {
	cur, err := LoadSlot(ctx, tx, s.Nonce)
	if errors.Is(err, store.ErrNotFound) {
		return ErrAbort
	}
	if err != nil {
		return err
	}
	if cur.Purpose != s.Purpose || cur.RefID != s.RefID || cur.State == StateFinal {
		return ErrAbort
	}
	raw, err := signed.MarshalBinary()
	if err != nil {
		return fmt.Errorf("txmgr: encode signed tx: %w", err)
	}
	data := signed.Data()
	if data == nil {
		data = []byte{} // self-sends have no calldata; the column is NOT NULL
	}
	var seq int
	if err := tx.QueryRowContext(ctx, `SELECT COALESCE(MAX(seq) + 1, 0) FROM tx_attempts WHERE nonce = ?`, s.Nonce).Scan(&seq); err != nil {
		return err
	}
	now := m.clock.Now().UnixNano()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO tx_attempts (hash, nonce, seq, kind, raw, to_addr, value, data, gas_limit, max_fee, tip, status, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'signed', ?)`,
		signed.Hash().Hex(), s.Nonce, seq, kind, raw, signed.To().Hex(), signed.Value().String(), data,
		signed.Gas(), signed.GasFeeCap().String(), signed.GasTipCap().String(), now); err != nil {
		return fmt.Errorf("txmgr: persist attempt: %w", err)
	}
	if cur.State == StateReserved {
		if _, err := tx.ExecContext(ctx, `UPDATE nonce_slots SET state = 'pending', updated_at = ? WHERE nonce = ?`, now, s.Nonce); err != nil {
			return err
		}
	}
	return nil
}
