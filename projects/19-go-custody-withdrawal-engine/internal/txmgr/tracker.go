// SPDX-License-Identifier: MIT

package txmgr

import (
	"context"
	"errors"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/audit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/chain"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/failpoint"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/fees"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/signer"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

func ethereumCall(from, to common.Address, data []byte) ethereum.CallMsg {
	return ethereum.CallMsg{From: from, To: &to, Data: data}
}

// Round is the result of one tracker pass.
type Round struct {
	Head chain.BlockRef
	// Complete is true when every live slot was processed without error; only then is the
	// ledger guaranteed to reflect every inclusion at or below Head.
	Complete bool
	Live     int
}

// roundView is what one tracker round knows about the chain, fetched at most once.
type roundView struct {
	head       chain.BlockRef
	chainNonce uint64 // nonce of the hot wallet at head: the next nonce the chain will accept
	sugg       *fees.Fees
}

// suggestion returns the round's fee suggestion, fetching it on first use.
func (m *Manager) suggestion(ctx context.Context, rv *roundView) (fees.Fees, error) {
	if rv.sugg == nil {
		f, _, err := m.fees.Suggest(ctx)
		if err != nil {
			return fees.Fees{}, err
		}
		rv.sugg = &f
	}
	return *rv.sugg, nil
}

// Track runs one tracker round: send unsent attempts, observe inclusions and reorgs, finalize
// at depth, rebroadcast dropped transactions, bump stuck ones, send cancellations and fill
// nonce gaps.
func (m *Manager) Track(ctx context.Context) (Round, error) {
	head, err := m.chain.Head(ctx)
	if err != nil {
		return Round{}, fmt.Errorf("txmgr: head: %w", err)
	}
	chainNonce, err := m.chain.NonceAt(ctx, m.From())
	if err != nil {
		return Round{Head: head}, fmt.Errorf("txmgr: nonce: %w", err)
	}
	rv := &roundView{head: head, chainNonce: chainNonce}
	slots, err := LiveSlots(ctx, m.db)
	if err != nil {
		return Round{Head: head}, err
	}
	round := Round{Head: head, Complete: true, Live: len(slots)}
	for _, s := range slots {
		if err := m.trackSlot(ctx, rv, s); err != nil {
			round.Complete = false
			if ctx.Err() != nil {
				return round, ctx.Err()
			}
			m.log.Warn("tracker: slot round failed", "nonce", s.Nonce, "purpose", s.Purpose, "ref", s.RefID, "err", err)
		}
	}
	if err := m.fillGaps(ctx, head, chainNonce); err != nil {
		m.log.Warn("tracker: gap check failed", "err", err)
	}
	if err := m.db.WithTx(ctx, func(tx *store.Tx) error {
		if err := store.SetMeta(ctx, tx, MetaTrackerNum, fmt.Sprint(head.Number)); err != nil {
			return err
		}
		return store.SetMeta(ctx, tx, MetaTrackerHex, head.Hash.Hex())
	}); err != nil {
		return round, err
	}
	m.metrics.TrackerHead.Set(float64(head.Number))
	return round, nil
}

func (m *Manager) trackSlot(ctx context.Context, rv *roundView, s Slot) error {
	head := rv.head
	atts, err := Attempts(ctx, m.db, s.Nonce)
	if err != nil {
		return err
	}
	if len(atts) == 0 {
		return fmt.Errorf("txmgr: live slot %d has no attempts", s.Nonce)
	}
	// 1. Send attempts that were persisted but never accepted (crash after_sign, or the first
	//    round after the dispatcher signed).
	// A failed send must not stop inclusion detection: another attempt at this nonce may
	// already be mined (for example a replacement the hot wallet can no longer afford to send).
	sentNow := false
	var sendErr error
	for _, a := range atts {
		if a.Status == AttemptSigned {
			if _, err := m.send(ctx, head, s, a, false); err != nil {
				sendErr = errors.Join(sendErr, err)
				continue
			}
			sentNow = true
		}
	}
	if sentNow {
		// send updated the attempt statuses and the bump timer; work from fresh rows.
		if s, err = LoadSlot(ctx, m.db, s.Nonce); err != nil {
			return err
		}
		if atts, err = Attempts(ctx, m.db, s.Nonce); err != nil {
			return err
		}
	}
	// 2. Look for a canonical inclusion of any attempt.
	incAtt, rcpt, err := m.findInclusion(ctx, head, atts)
	if err != nil {
		return err
	}
	if rcpt != nil {
		if s.State != StateIncluded || s.IncludedHash != incAtt.Hash || s.IncludedBlockHash != rcpt.BlockHash {
			if s, err = m.applyInclusion(ctx, s, incAtt, rcpt); err != nil {
				return err
			}
		}
		if head.Number+1 >= rcpt.BlockNumber.Uint64()+m.cfg.Confirmations {
			m.hit(s.Purpose, failpoint.BeforeConfirm)
			return m.finalize(ctx, s, incAtt, rcpt)
		}
		return nil
	}
	// 3. Not included. If it was, the block is gone: undo the inclusion.
	if s.State == StateIncluded {
		if s, err = m.revertInclusion(ctx, s); err != nil {
			return err
		}
	}
	if sendErr != nil {
		return sendErr // retry the send next round before deciding anything else
	}
	if s.CancelRequested && !hasKind(atts, KindCancel) {
		return m.replace(ctx, rv, s, atts, true)
	}
	known := false
	for _, a := range atts {
		if a.Status != AttemptSent {
			continue
		}
		k, err := m.chain.TransactionKnown(ctx, a.Hash)
		if err != nil {
			return err
		}
		known = known || k
	}
	if !known {
		// Dropped from the pool (eviction, restart, reorg): re-send the newest accepted attempt.
		latest := latestSent(atts)
		if latest == nil {
			return m.replace(ctx, rv, s, atts, lastKind(atts) == KindCancel)
		}
		outcome, err := m.send(ctx, head, s, *latest, true)
		if err != nil {
			return err
		}
		if outcome == chain.Underpriced {
			return m.replace(ctx, rv, s, atts, latest.Kind == KindCancel)
		}
		return nil
	}
	if head.Number < s.LastBroadcastHead+m.cfg.BumpAfterBlocks {
		return nil
	}
	// A transaction queued behind a lower, unmined nonce cannot be mined whatever its fee, so
	// it is only bumped when it is next in line or priced below the current market. Without
	// this rule a single stuck nonce would escalate the fees of every transaction queued
	// behind it by 12.5 % per bump until they all hit the cap.
	if s.Nonce != rv.chainNonce {
		sugg, err := m.suggestion(ctx, rv)
		if err != nil {
			return err
		}
		if lf := atts[len(atts)-1].Fees; lf.MaxFee.Cmp(sugg.MaxFee) >= 0 && lf.Tip.Cmp(sugg.Tip) >= 0 {
			return nil
		}
	}
	return m.replace(ctx, rv, s, atts, lastKind(atts) == KindCancel)
}

func hasKind(atts []Attempt, kind string) bool {
	for _, a := range atts {
		if a.Kind == kind {
			return true
		}
	}
	return false
}

func lastKind(atts []Attempt) string { return atts[len(atts)-1].Kind }

func latestSent(atts []Attempt) *Attempt {
	for i := len(atts) - 1; i >= 0; i-- {
		if atts[i].Status == AttemptSent {
			return &atts[i]
		}
	}
	return nil
}

// findInclusion returns the attempt whose receipt is in a canonical block at or below head.
func (m *Manager) findInclusion(ctx context.Context, head chain.BlockRef, atts []Attempt) (Attempt, *types.Receipt, error) {
	for _, a := range atts {
		r, err := m.chain.TransactionReceipt(ctx, a.Hash)
		if errors.Is(err, chain.ErrNotFound) {
			continue
		}
		if err != nil {
			return Attempt{}, nil, fmt.Errorf("txmgr: receipt %s: %w", a.Hash, err)
		}
		n := r.BlockNumber.Uint64()
		if n > head.Number {
			continue // mined after this round's head: next round
		}
		blk, err := m.chain.BlockByNumber(ctx, n)
		if errors.Is(err, chain.ErrNotFound) {
			continue
		}
		if err != nil {
			return Attempt{}, nil, err
		}
		if blk.Hash != r.BlockHash {
			continue // stale receipt from a block that was just reorged out
		}
		return a, r, nil
	}
	return Attempt{}, nil, nil
}

// send broadcasts a persisted attempt and records the classified result.
func (m *Manager) send(ctx context.Context, head chain.BlockRef, s Slot, a Attempt, rebroadcast bool) (chain.SendOutcome, error) {
	tx, err := a.Tx()
	if err != nil {
		return chain.Transient, err
	}
	sendErr := m.chain.SendTransaction(ctx, tx)
	outcome := chain.ClassifySendError(sendErr)
	m.metrics.TxSendResults.WithLabelValues(outcome.String()).Inc()
	switch outcome {
	case chain.Accepted, chain.AlreadyKnown:
		if rebroadcast {
			m.metrics.Rebroadcasts.Inc()
		}
		if a.Kind == KindOriginal {
			m.hit(s.Purpose, failpoint.AfterBroadcast)
		} else {
			m.hit(s.Purpose, failpoint.AfterBumpBroadcast)
		}
		return outcome, m.markSent(ctx, head, s, a)
	case chain.Underpriced:
		m.log.Info("tracker: attempt underpriced", "nonce", s.Nonce, "hash", a.Hash, "err", sendErr)
		_, err := m.db.ExecContext(ctx, `UPDATE tx_attempts SET status = 'rejected' WHERE hash = ? AND status = 'signed'`, a.Hash.Hex())
		return outcome, err
	case chain.NonceTooLow:
		// The nonce is consumed. If it was by one of our attempts the receipt shows up in the
		// inclusion check; if not, the key was used outside the engine (reported by fillGaps).
		m.log.Warn("tracker: nonce already used on chain", "nonce", s.Nonce, "hash", a.Hash)
		return outcome, nil
	default:
		return outcome, fmt.Errorf("txmgr: send %s (%s): %w", a.Hash, outcome, sendErr)
	}
}

func (m *Manager) markSent(ctx context.Context, head chain.BlockRef, s Slot, a Attempt) error {
	o, err := m.owner(s.Purpose)
	if err != nil {
		return err
	}
	return m.db.WithTx(ctx, func(tx *store.Tx) error {
		now := m.clock.Now().UnixNano()
		if _, err := tx.ExecContext(ctx, `UPDATE tx_attempts SET status = 'sent', sent_at = COALESCE(sent_at, ?) WHERE hash = ?`, now, a.Hash.Hex()); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE nonce_slots SET last_broadcast_head = ?, updated_at = ? WHERE nonce = ?`, head.Number, now, s.Nonce); err != nil {
			return err
		}
		return o.OnSent(ctx, tx, s)
	})
}

// replace signs, persists and sends a replacement at the same nonce: a fee bump of the payload,
// or a zero-value self-send when cancel is true. If the firewall no longer accepts the payload
// (for example the destination left the allowlist), the replacement becomes a cancellation.
func (m *Manager) replace(ctx context.Context, rv *roundView, s Slot, atts []Attempt, cancel bool) error {
	head := rv.head
	prev := atts[len(atts)-1].Fees
	sugg, err := m.suggestion(ctx, rv)
	if err != nil {
		return err
	}
	cfg := m.fees.Config()
	nf, err := fees.Bump(prev, sugg, cfg.BumpBps, cfg.MaxFee)
	if errors.Is(err, fees.ErrFeeCap) {
		m.metrics.FeeCapReached.Inc()
		m.log.Error("tracker: cannot bump, fee cap reached; operator action needed", "nonce", s.Nonce, "err", err)
		return nil
	}
	if err != nil {
		return err
	}
	o, err := m.owner(s.Purpose)
	if err != nil {
		return err
	}
	var signed *types.Transaction
	kind := KindBump
	if !cancel {
		orig := atts[0]
		req, err := o.SignRequest(ctx, m.db, s)
		if err != nil {
			return err
		}
		req.Tx = m.dynamicTx(s.Nonce, nf, orig.GasLimit, orig.To, orig.Data)
		signed, err = m.fw.Sign(ctx, req)
		if errors.Is(err, signer.ErrPolicy) {
			m.log.Warn("tracker: payload no longer passes policy, cancelling instead", "nonce", s.Nonce, "err", err)
			cancel = true
		} else if err != nil {
			return err
		}
	}
	if cancel {
		kind = KindCancel
		p := signer.PurposeCancel
		if s.Purpose == signer.PurposeFiller {
			p = signer.PurposeFiller
		}
		signed, err = m.fw.Sign(ctx, signer.Request{Purpose: p, Tx: m.dynamicTx(s.Nonce, nf, signer.SelfSendGas, m.From(), nil)})
		if err != nil {
			return err
		}
	}
	if err := m.db.WithTx(ctx, func(tx *store.Tx) error {
		if err := m.persistAttempt(ctx, tx, s, signed, kind); err != nil {
			return err
		}
		if kind == KindCancel {
			if _, err := tx.ExecContext(ctx, `UPDATE nonce_slots SET cancel_requested = 1 WHERE nonce = ?`, s.Nonce); err != nil {
				return err
			}
		}
		return audit.Record(ctx, tx, m.clock.Now(), audit.Event{
			Type: "tx.replacement", Actor: "engine", Subject: fmt.Sprintf("nonce:%d", s.Nonce),
			Data: map[string]any{"kind": kind, "hash": signed.Hash().Hex(), "max_fee": nf.MaxFee.String(), "tip": nf.Tip.String(),
				"prev_max_fee": prev.MaxFee.String(), "prev_tip": prev.Tip.String(), "purpose": string(s.Purpose), "ref": s.RefID},
		})
	}); err != nil {
		if errors.Is(err, ErrAbort) {
			return nil
		}
		return err
	}
	m.metrics.FeeBumps.Inc()
	m.metrics.TxSigned.WithLabelValues(string(s.Purpose), kind).Inc()
	a, err := AttemptByHash(ctx, m.db, signed.Hash())
	if err != nil {
		return err
	}
	_, err = m.send(ctx, head, s, a, false)
	return err
}

func (m *Manager) dynamicTx(nonce uint64, f fees.Fees, gas uint64, to common.Address, data []byte) *types.Transaction {
	return types.NewTx(&types.DynamicFeeTx{
		ChainID: m.fw.ChainID(), Nonce: nonce, GasTipCap: f.Tip, GasFeeCap: f.MaxFee,
		Gas: gas, To: &to, Value: new(big.Int), Data: data,
	})
}

// gasPostings books the gas an included attempt consumed: fees up, in-flight hot-wallet outflow.
func (m *Manager) gasPostings(r *types.Receipt) []ledger.Posting {
	if r.EffectiveGasPrice == nil {
		return nil
	}
	fee := new(big.Int).Mul(new(big.Int).SetUint64(r.GasUsed), r.EffectiveGasPrice)
	if fee.Sign() == 0 {
		return nil
	}
	return []ledger.Posting{
		ledger.Debit(ledger.Fees, m.cfg.NativeAsset, fee),
		ledger.Credit(ledger.InFlight, m.cfg.NativeAsset, fee),
	}
}

// applyInclusion records that attempt a is in a canonical block. If the slot was already
// included elsewhere (same nonce, different block or different attempt), that inclusion is
// reversed first, all in one transaction.
func (m *Manager) applyInclusion(ctx context.Context, s Slot, a Attempt, r *types.Receipt) (Slot, error) {
	o, err := m.owner(s.Purpose)
	if err != nil {
		return s, err
	}
	var out Slot
	err = m.db.WithTx(ctx, func(tx *store.Tx) error {
		cur, err := LoadSlot(ctx, tx, s.Nonce)
		if err != nil {
			return err
		}
		now := m.clock.Now()
		if cur.State == StateIncluded {
			if err := m.undoInclusion(ctx, tx, o, cur); err != nil {
				return err
			}
		}
		postings := m.gasPostings(r)
		value, err := o.InclusionPostings(ctx, tx, cur, a, r)
		if err != nil {
			return err
		}
		postings = append(postings, value...)
		epoch := cur.InclusionEpoch + 1
		ref := ""
		if len(postings) > 0 {
			ref = fmt.Sprintf("incl:%d:%d", cur.Nonce, epoch)
			if _, err := ledger.Post(ctx, tx, ledger.Entry{Ref: ref, Kind: "inclusion", Postings: postings}, now); err != nil {
				return err
			}
		}
		if _, err := tx.ExecContext(ctx, `
			UPDATE nonce_slots SET state = 'included', included_hash = ?, included_block = ?, included_block_hash = ?,
				inclusion_ref = ?, inclusion_epoch = ?, updated_at = ? WHERE nonce = ?`,
			a.Hash.Hex(), r.BlockNumber.Uint64(), r.BlockHash.Hex(), nullable(ref), epoch, now.UnixNano(), cur.Nonce); err != nil {
			return err
		}
		if out, err = LoadSlot(ctx, tx, cur.Nonce); err != nil {
			return err
		}
		if err := o.OnIncluded(ctx, tx, out, a, r); err != nil {
			return err
		}
		return audit.Record(ctx, tx, now, audit.Event{
			Type: "tx.included", Actor: "engine", Subject: fmt.Sprintf("nonce:%d", cur.Nonce),
			Data: map[string]any{"hash": a.Hash.Hex(), "kind": a.Kind, "block": r.BlockNumber.Uint64(), "block_hash": r.BlockHash.Hex(),
				"status": r.Status, "purpose": string(cur.Purpose), "ref": cur.RefID},
		})
	})
	return out, err
}

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// undoInclusion reverses the current inclusion entry and notifies the owner (inside tx).
func (m *Manager) undoInclusion(ctx context.Context, tx *store.Tx, o Owner, cur Slot) error {
	if cur.InclusionRef != "" {
		if _, err := ledger.Reverse(ctx, tx, cur.InclusionRef, "rev:"+cur.InclusionRef, m.clock.Now()); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE nonce_slots SET state = 'pending', included_hash = NULL, included_block = NULL, included_block_hash = NULL,
			inclusion_ref = NULL, updated_at = ? WHERE nonce = ?`, m.clock.Now().UnixNano(), cur.Nonce); err != nil {
		return err
	}
	cur.State = StatePending
	if err := o.OnReorged(ctx, tx, cur); err != nil {
		return err
	}
	tx.OnCommit(func() { m.metrics.InclusionReorgs.Inc() })
	return audit.Record(ctx, tx, m.clock.Now(), audit.Event{
		Type: "tx.reorged", Actor: "engine", Subject: fmt.Sprintf("nonce:%d", cur.Nonce),
		Data: map[string]any{"hash": cur.IncludedHash.Hex(), "block": cur.IncludedBlock, "block_hash": cur.IncludedBlockHash.Hex()},
	})
}

func (m *Manager) revertInclusion(ctx context.Context, s Slot) (Slot, error) {
	o, err := m.owner(s.Purpose)
	if err != nil {
		return s, err
	}
	var out Slot
	err = m.db.WithTx(ctx, func(tx *store.Tx) error {
		cur, err := LoadSlot(ctx, tx, s.Nonce)
		if err != nil {
			return err
		}
		if cur.State == StateIncluded {
			if err := m.undoInclusion(ctx, tx, o, cur); err != nil {
				return err
			}
		}
		out, err = LoadSlot(ctx, tx, s.Nonce)
		return err
	})
	return out, err
}

// finalize moves the slot's in-flight effect into hot_wallet and hands the outcome to the owner.
func (m *Manager) finalize(ctx context.Context, s Slot, a Attempt, r *types.Receipt) error {
	o, err := m.owner(s.Purpose)
	if err != nil {
		return err
	}
	return m.db.WithTx(ctx, func(tx *store.Tx) error {
		cur, err := LoadSlot(ctx, tx, s.Nonce)
		if err != nil {
			return err
		}
		if cur.State != StateIncluded || cur.IncludedHash != a.Hash || cur.IncludedBlockHash != r.BlockHash {
			return nil // raced with a reorg; next round decides again
		}
		now := m.clock.Now()
		if cur.InclusionRef != "" {
			incl, err := ledger.EntryPostings(ctx, tx, cur.InclusionRef)
			if err != nil {
				return err
			}
			sums := map[string]*big.Int{}
			var order []string
			for _, p := range incl {
				if p.Account != ledger.InFlight {
					continue
				}
				if sums[p.Asset] == nil {
					sums[p.Asset] = new(big.Int)
					order = append(order, p.Asset)
				}
				sums[p.Asset].Add(sums[p.Asset], p.Amount)
			}
			var postings []ledger.Posting
			for _, asset := range order {
				v := sums[asset]
				if v.Sign() == 0 {
					continue
				}
				postings = append(postings,
					ledger.Posting{Account: ledger.InFlight, Asset: asset, Amount: new(big.Int).Neg(v)},
					ledger.Posting{Account: ledger.HotWallet, Asset: asset, Amount: new(big.Int).Set(v)})
			}
			if len(postings) > 0 {
				if _, err := ledger.Post(ctx, tx, ledger.Entry{Ref: fmt.Sprintf("final:%d", cur.Nonce), Kind: "finality", Postings: postings}, now); err != nil {
					return err
				}
			}
		}
		if _, err := tx.ExecContext(ctx, `UPDATE nonce_slots SET state = 'final', updated_at = ? WHERE nonce = ?`, now.UnixNano(), cur.Nonce); err != nil {
			return err
		}
		outcome := Succeeded
		switch {
		case a.Kind == KindCancel:
			outcome = Cancelled
		case r.Status != types.ReceiptStatusSuccessful:
			outcome = Reverted
		}
		cur.State = StateFinal
		if err := o.OnFinal(ctx, tx, cur, a, r, outcome); err != nil {
			return err
		}
		return audit.Record(ctx, tx, now, audit.Event{
			Type: "tx.final", Actor: "engine", Subject: fmt.Sprintf("nonce:%d", cur.Nonce),
			Data: map[string]any{"hash": a.Hash.Hex(), "outcome": outcome.String(), "block": r.BlockNumber.Uint64(),
				"purpose": string(cur.Purpose), "ref": cur.RefID},
		})
	})
}
