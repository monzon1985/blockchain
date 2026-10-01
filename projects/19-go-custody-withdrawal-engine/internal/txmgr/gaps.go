// SPDX-License-Identifier: MIT

package txmgr

import (
	"context"
	"fmt"
	"slices"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/audit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/chain"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/signer"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

// fillerOwner owns zero-value self-sends that fill nonce gaps. They move no value; their gas
// is booked by the manager like any other transaction.
type fillerOwner struct{}

func (fillerOwner) SignRequest(context.Context, store.Querier, Slot) (signer.Request, error) {
	return signer.Request{Purpose: signer.PurposeFiller}, nil
}

func (fillerOwner) InclusionPostings(context.Context, store.Querier, Slot, Attempt, *types.Receipt) ([]ledger.Posting, error) {
	return nil, nil
}
func (fillerOwner) OnSent(context.Context, *store.Tx, Slot) error    { return nil }
func (fillerOwner) OnReorged(context.Context, *store.Tx, Slot) error { return nil }
func (fillerOwner) OnIncluded(context.Context, *store.Tx, Slot, Attempt, *types.Receipt) error {
	return nil
}
func (fillerOwner) OnFinal(context.Context, *store.Tx, Slot, Attempt, *types.Receipt, Outcome) error {
	return nil
}

// FindGaps returns the unused nonces in [max(floor, chainNonce), highest slot).
func FindGaps(ctx context.Context, q store.Querier, chainNonce uint64) ([]uint64, error) {
	floor, err := nonceFloor(ctx, q)
	if err != nil {
		return nil, err
	}
	start := max(floor, chainNonce)
	rows, err := q.QueryContext(ctx, `SELECT nonce FROM nonce_slots WHERE nonce >= ? ORDER BY nonce`, start)
	if err != nil {
		return nil, fmt.Errorf("txmgr: gap scan: %w", err)
	}
	defer rows.Close()
	var used []uint64
	for rows.Next() {
		var n uint64
		if err := rows.Scan(&n); err != nil {
			return nil, err
		}
		used = append(used, n)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	var gaps []uint64
	next := start
	for _, n := range used {
		for ; next < n; next++ {
			gaps = append(gaps, next)
		}
		next = n + 1
	}
	return gaps, nil
}

// fillGaps detects nonce drift, releases abandoned reservations and fills gaps that outlived
// the grace period with zero-value self-sends, so a nonce released by a failed pre-signing
// step, or reserved by a step that never came back, can never block the queue.
func (m *Manager) fillGaps(ctx context.Context, head chain.BlockRef, chainNonce uint64) error {
	if err := m.checkDrift(ctx, chainNonce); err != nil {
		return err
	}
	if err := m.checkFinalized(ctx, chainNonce); err != nil {
		return err
	}
	if err := m.reclaimReservations(ctx, head); err != nil {
		return err
	}
	gaps, err := FindGaps(ctx, m.db, chainNonce)
	if err != nil {
		return err
	}
	m.mu.Lock()
	for n := range m.gaps {
		if !slices.Contains(gaps, n) {
			delete(m.gaps, n)
		}
	}
	var due []uint64
	for _, n := range gaps {
		first, ok := m.gaps[n]
		if !ok {
			m.gaps[n] = head.Number
			first = head.Number
			m.log.Warn("tracker: nonce gap detected", "nonce", n)
		}
		if head.Number >= first+m.cfg.GapGraceBlocks {
			due = append(due, n)
		}
	}
	m.mu.Unlock()
	for _, n := range due {
		ref := fmt.Sprintf("gap:%d:%d", n, head.Number)
		if err := m.Submit(ctx, signer.PurposeFiller, ref, Payload{To: m.From(), GasLimit: signer.SelfSendGas}, SubmitHooks{
			Persisted: func(ctx context.Context, tx *store.Tx, s Slot, hash common.Hash) error {
				return audit.Record(ctx, tx, m.clock.Now(), audit.Event{
					Type: "nonce.gap_filled", Actor: "engine", Subject: fmt.Sprintf("nonce:%d", s.Nonce),
					Data: map[string]any{"hash": hash.Hex(), "gap": n},
				})
			},
		}); err != nil {
			return err
		}
		m.metrics.NonceGapsFilled.Inc()
		m.mu.Lock()
		delete(m.gaps, n)
		m.mu.Unlock()
	}
	return nil
}

// reclaimReservations releases reservations that never produced a signature and that nothing
// will ever retry. A reserved slot occupies its nonce, so FindGaps does not see it, and every
// later transaction would queue behind it forever.
//
//   - Gap fillers are only submitted from fillGaps, on the tracker's own goroutine, under a
//     reference that is never reused. A filler reservation still unsigned when a round starts
//     was abandoned (a crash, or a failed write between reserving and persisting), so it is
//     released at once; the nonce turns into a gap and is filled again under a fresh reference.
//   - Withdrawal and sweep reservations are released by their owners whenever a retry cannot
//     use them (see Submit). As a safety net, one that stays unsigned for ReservationTTL and
//     across GapGraceBlocks blocks seen by this tracker is released too. Releasing a slot that
//     is being signed at that very moment is safe: persistAttempt finds the slot gone or
//     reassigned and discards the signature, and the owner retries.
func (m *Manager) reclaimReservations(ctx context.Context, head chain.BlockRef) error {
	rows, err := m.db.QueryContext(ctx, `SELECT s.nonce, s.purpose, s.ref_id, s.created_at FROM nonce_slots s
		WHERE s.state = 'reserved' AND NOT EXISTS (SELECT 1 FROM tx_attempts a WHERE a.nonce = s.nonce) ORDER BY s.nonce`)
	if err != nil {
		return fmt.Errorf("txmgr: reservation scan: %w", err)
	}
	type unsigned struct {
		r       reservation
		created time.Time
	}
	var found []unsigned
	for rows.Next() {
		var u unsigned
		var purpose string
		var created int64
		if err := rows.Scan(&u.r.nonce, &purpose, &u.r.ref, &created); err != nil {
			rows.Close()
			return err
		}
		u.r.purpose = signer.Purpose(purpose)
		u.created = time.Unix(0, created)
		found = append(found, u)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	now := m.clock.Now()
	var abandoned []unsigned
	m.mu.Lock()
	present := map[reservation]bool{}
	for _, u := range found {
		present[u.r] = true
		first, ok := m.reserved[u.r]
		if !ok {
			m.reserved[u.r], first = head.Number, head.Number
		}
		stale := head.Number >= first+m.cfg.GapGraceBlocks && now.Sub(u.created) >= ReservationTTL
		if u.r.purpose == signer.PurposeFiller || stale {
			abandoned = append(abandoned, u)
		}
	}
	for r := range m.reserved {
		if !present[r] {
			delete(m.reserved, r)
		}
	}
	m.mu.Unlock()
	for _, u := range abandoned {
		reason := "abandoned gap filler"
		if u.r.purpose != signer.PurposeFiller {
			reason = fmt.Sprintf("unsigned for %s", now.Sub(u.created).Round(time.Second))
		}
		s := Slot{Nonce: u.r.nonce, Purpose: u.r.purpose, RefID: u.r.ref}
		if err := m.db.WithTx(ctx, func(tx *store.Tx) error { return m.release(ctx, tx, s, reason) }); err != nil {
			return err
		}
	}
	return nil
}

// checkDrift raises the nonce floor if the chain has used nonces the engine never assigned
// (the key was used elsewhere, or the database was restored from an old backup). The engine
// must be the only user of the hot-wallet key; drift is reported as a critical event.
func (m *Manager) checkDrift(ctx context.Context, chainNonce uint64) error {
	return m.db.WithTx(ctx, func(tx *store.Tx) error {
		floor, err := nonceFloor(ctx, tx)
		if err != nil {
			return err
		}
		var maxSlot *int64
		if err := tx.QueryRowContext(ctx, `SELECT MAX(nonce) FROM nonce_slots`).Scan(&maxSlot); err != nil {
			return err
		}
		expected := floor
		if maxSlot != nil && uint64(*maxSlot)+1 > expected {
			expected = uint64(*maxSlot) + 1
		}
		if chainNonce <= expected {
			return nil
		}
		m.log.Error("tracker: on-chain nonce is ahead of the engine; raising the nonce floor", "chain", chainNonce, "expected", expected)
		tx.OnCommit(func() { m.metrics.NonceDrift.Inc() })
		if err := store.SetMeta(ctx, tx, metaNonceFloor, fmt.Sprint(chainNonce)); err != nil {
			return err
		}
		return audit.Record(ctx, tx, m.clock.Now(), audit.Event{
			Type: "nonce.drift", Actor: "engine", Subject: m.From().Hex(),
			Data: map[string]any{"chain_nonce": chainNonce, "expected": expected},
		})
	})
}

// checkFinalized raises an alarm when the chain's nonce is at or below a nonce the engine has
// already finalized: a transaction booked as final is no longer on the chain. That takes a reorg
// deeper than the confirmation depth (or a node that far behind). What was booked as final, a
// confirmed withdrawal or a credited sweep, cannot be undone automatically: the customer has
// been told, so the engine reports it once (error log, custody_deep_reorgs_total, audit event)
// and leaves the decision to an operator, exactly as the deposit scanner does for deposits.
func (m *Manager) checkFinalized(ctx context.Context, chainNonce uint64) error {
	var maxFinal *int64
	if err := m.db.QueryRowContext(ctx, `SELECT MAX(nonce) FROM nonce_slots WHERE state = 'final'`).Scan(&maxFinal); err != nil {
		return err
	}
	lost := maxFinal != nil && chainNonce <= uint64(*maxFinal)
	m.mu.Lock()
	reported := m.lostFinal
	if !lost {
		m.lostFinal = false
	}
	m.mu.Unlock()
	if !lost || reported {
		return nil
	}
	m.log.Error("tracker: a finalized transaction is no longer on chain (reorg deeper than the confirmation depth, or a node that far behind); manual reconciliation required",
		"chain_nonce", chainNonce, "highest_final_nonce", *maxFinal)
	return m.db.WithTx(ctx, func(tx *store.Tx) error {
		tx.OnCommit(func() {
			m.metrics.DeepReorgs.Inc()
			m.mu.Lock()
			m.lostFinal = true
			m.mu.Unlock()
		})
		return audit.Record(ctx, tx, m.clock.Now(), audit.Event{
			Type: "tx.deep_reorg", Actor: "engine", Subject: m.From().Hex(),
			Data: map[string]any{"chain_nonce": chainNonce, "highest_final_nonce": *maxFinal},
		})
	})
}
