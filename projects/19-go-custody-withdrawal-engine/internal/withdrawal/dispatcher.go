// SPDX-License-Identifier: MIT

package withdrawal

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/chain"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/failpoint"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/signer"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/txmgr"
)

type outboxItem struct {
	Seq      int64
	Kind     string
	RefID    string
	Attempts int
}

// maxBackoff caps the retry delay of a failing intent.
const maxBackoff = 30 * time.Second

func backoff(attempts int) time.Duration {
	d := 200 * time.Millisecond
	for i := 0; i < attempts && d < maxBackoff; i++ {
		d *= 2
	}
	return min(d, maxBackoff)
}

// DispatchOnce executes every due outbox intent in commit order and returns how many ran.
// A failing intent is retried with exponential backoff; it does not block later intents.
func (s *Service) DispatchOnce(ctx context.Context) (int, error) {
	now := s.clock.Now()
	rows, err := s.db.QueryContext(ctx,
		`SELECT seq, kind, ref_id, attempts FROM outbox WHERE done_at IS NULL AND not_before <= ? ORDER BY seq LIMIT 100`, now.UnixNano())
	if err != nil {
		return 0, err
	}
	var items []outboxItem
	for rows.Next() {
		var it outboxItem
		if err := rows.Scan(&it.Seq, &it.Kind, &it.RefID, &it.Attempts); err != nil {
			rows.Close()
			return 0, err
		}
		items = append(items, it)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}
	for _, it := range items {
		var err error
		switch it.Kind {
		case IntentEvaluate:
			err = s.evaluate(ctx, it)
		case IntentSign:
			err = s.sign(ctx, it)
		default:
			err = fmt.Errorf("withdrawal: unknown outbox kind %q", it.Kind)
		}
		if err != nil {
			if ctx.Err() != nil {
				return 0, ctx.Err()
			}
			s.log.Warn("outbox intent failed; will retry", "seq", it.Seq, "kind", it.Kind, "ref", it.RefID, "attempts", it.Attempts+1, "err", err)
			next := s.clock.Now().Add(backoff(it.Attempts))
			if _, uerr := s.db.ExecContext(ctx, `UPDATE outbox SET attempts = attempts + 1, last_error = ?, not_before = ? WHERE seq = ?`,
				err.Error(), next.UnixNano(), it.Seq); uerr != nil {
				return 0, uerr
			}
		}
	}
	var pending int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM outbox WHERE done_at IS NULL`).Scan(&pending); err == nil {
		s.metrics.OutboxPending.Set(float64(pending))
	}
	return len(items), nil
}

func (s *Service) markDone(ctx context.Context, tx *store.Tx, seq int64) error {
	_, err := tx.ExecContext(ctx, `UPDATE outbox SET done_at = ? WHERE seq = ? AND done_at IS NULL`, s.clock.Now().UnixNano(), seq)
	return err
}

// evaluate moves a requested withdrawal to approved once enough approvals are recorded.
func (s *Service) evaluate(ctx context.Context, it outboxItem) error {
	approved := false
	err := s.db.WithTx(ctx, func(tx *store.Tx) error {
		w, err := Load(ctx, tx, it.RefID)
		if err != nil {
			return err
		}
		if w.Status == Requested {
			var n int
			if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM approvals WHERE withdrawal_id = ? AND decision = 'approve'`, w.ID).Scan(&n); err != nil {
				return err
			}
			if n >= w.ApprovalsRequired {
				reason := "below approval threshold"
				if w.ApprovalsRequired > 0 {
					reason = fmt.Sprintf("%d of %d approvals", n, w.ApprovalsRequired)
				}
				if err := transition(ctx, tx, s.metrics, s.clock.Now(), &w, Approved, "engine", reason); err != nil {
					return err
				}
				if err := enqueue(ctx, tx, s.clock.Now(), IntentSign, w.ID); err != nil {
					return err
				}
				approved = true
			}
		}
		return s.markDone(ctx, tx, it.Seq)
	})
	if err != nil {
		return err
	}
	if approved {
		s.fp.Hit(failpoint.AfterApprove)
	}
	return nil
}

// sign assigns the nonce, signs through the firewall and persists the transaction. Nothing is
// broadcast here: the tracker sends persisted attempts. The transfer is estimated by Submit
// before a nonce is reserved; while the hot wallet cannot cover it, the intent fails, holds no
// nonce, and is retried with backoff (a sweep or a top-up restores the liquidity).
func (s *Service) sign(ctx context.Context, it outboxItem) error {
	w, err := Load(ctx, s.db, it.RefID)
	if err != nil {
		return err
	}
	if w.Status != Approved {
		return s.db.WithTx(ctx, func(tx *store.Tx) error { return s.markDone(ctx, tx, it.Seq) })
	}
	token := s.cfg.Tokens[w.Asset]
	data := chain.EncodeTransfer(w.Destination, w.Amount)
	err = s.txm.Submit(ctx, signer.PurposeWithdrawal, w.ID, txmgr.Payload{To: token, Data: data}, txmgr.SubmitHooks{
		Persisted: func(ctx context.Context, tx *store.Tx, slot txmgr.Slot, hash common.Hash) error {
			cur, err := Load(ctx, tx, w.ID)
			if err != nil {
				return err
			}
			if cur.Status != Approved {
				return txmgr.ErrAbort
			}
			if _, err := tx.ExecContext(ctx, `UPDATE withdrawals SET nonce = ? WHERE id = ?`, slot.Nonce, w.ID); err != nil {
				return err
			}
			if err := transition(ctx, tx, s.metrics, s.clock.Now(), &cur, Signed, "engine", fmt.Sprintf("nonce %d, tx %s", slot.Nonce, hash.Hex())); err != nil {
				return err
			}
			return s.markDone(ctx, tx, it.Seq)
		},
		Refused: func(ctx context.Context, tx *store.Tx, reason error) error {
			cur, err := Load(ctx, tx, w.ID)
			if err != nil {
				return err
			}
			if cur.Status == Approved {
				if err := transition(ctx, tx, s.metrics, s.clock.Now(), &cur, Failed, "engine", "signing refused: "+reason.Error()); err != nil {
					return err
				}
				if err := s.setFailure(ctx, tx, w.ID, "signing_refused"); err != nil {
					return err
				}
				if err := refund(ctx, tx, s.clock.Now(), cur); err != nil {
					return err
				}
			}
			return s.markDone(ctx, tx, it.Seq)
		},
	})
	switch {
	case err == nil, errors.Is(err, txmgr.ErrRefused):
		return nil
	case errors.Is(err, txmgr.ErrAbort):
		// The signature was discarded. Either the withdrawal left approved while it was being
		// signed (cancelled: the intent is done), or its nonce reservation was reclaimed under
		// it (still approved: sign again on the next attempt, with a fresh reservation).
		retry := false
		if err := s.db.WithTx(ctx, func(tx *store.Tx) error {
			cur, err := Load(ctx, tx, w.ID)
			if err != nil {
				return err
			}
			if cur.Status == Approved {
				retry = true
				return nil
			}
			return s.markDone(ctx, tx, it.Seq)
		}); err != nil {
			return err
		}
		if retry {
			return fmt.Errorf("withdrawal %s: signature discarded because its nonce reservation was reclaimed; retrying", w.ID)
		}
		return nil
	default:
		return err
	}
}

// Owner returns the transaction-manager owner for withdrawal slots.
func (s *Service) Owner() txmgr.Owner { return owner{s} }

type owner struct{ s *Service }

func (o owner) SignRequest(ctx context.Context, q store.Querier, slot txmgr.Slot) (signer.Request, error) {
	w, err := Load(ctx, q, slot.RefID)
	if err != nil {
		return signer.Request{}, err
	}
	return signer.Request{Purpose: signer.PurposeWithdrawal, AccountID: w.AccountID, Asset: w.Asset}, nil
}

func (o owner) InclusionPostings(ctx context.Context, q store.Querier, slot txmgr.Slot, a txmgr.Attempt, r *types.Receipt) ([]ledger.Posting, error) {
	if a.Kind == txmgr.KindCancel || r.Status != types.ReceiptStatusSuccessful {
		return nil, nil // nothing left the hot wallet but gas
	}
	w, err := Load(ctx, q, slot.RefID)
	if err != nil {
		return nil, err
	}
	token := o.s.cfg.Tokens[w.Asset]
	seen := false
	for _, l := range r.Logs {
		if tl, ok := chain.DecodeTransferLog(l); ok && tl.Token == token && tl.To == w.Destination && tl.Amount.Cmp(w.Amount) == 0 {
			seen = true
		}
	}
	if !seen {
		o.s.log.Error("withdrawal receipt has no matching Transfer log; reconciliation will flag the difference", "id", w.ID, "tx", a.Hash)
	}
	return []ledger.Posting{
		ledger.Debit(ledger.WithdrawalsPending, w.Asset, w.Amount),
		ledger.Credit(ledger.InFlight, w.Asset, w.Amount),
	}, nil
}

func (o owner) OnSent(ctx context.Context, tx *store.Tx, slot txmgr.Slot) error {
	w, err := Load(ctx, tx, slot.RefID)
	if err != nil {
		return err
	}
	if w.Status != Signed {
		return nil
	}
	return transition(ctx, tx, o.s.metrics, o.s.clock.Now(), &w, Broadcast, "engine", "accepted by node")
}

func (o owner) OnIncluded(ctx context.Context, tx *store.Tx, slot txmgr.Slot, a txmgr.Attempt, r *types.Receipt) error {
	w, err := Load(ctx, tx, slot.RefID)
	if err != nil {
		return err
	}
	now := o.s.clock.Now()
	if w.Status == Signed {
		if err := transition(ctx, tx, o.s.metrics, now, &w, Broadcast, "engine", "accepted by node"); err != nil {
			return err
		}
	}
	if w.Status == Broadcast {
		if err := transition(ctx, tx, o.s.metrics, now, &w, Mined, "engine", fmt.Sprintf("%s %s in block %d", a.Kind, a.Hash.Hex(), r.BlockNumber)); err != nil {
			return err
		}
	}
	_, err = tx.ExecContext(ctx, `UPDATE withdrawals SET tx_hash = ? WHERE id = ?`, a.Hash.Hex(), w.ID)
	return err
}

func (o owner) OnReorged(ctx context.Context, tx *store.Tx, slot txmgr.Slot) error {
	w, err := Load(ctx, tx, slot.RefID)
	if err != nil {
		return err
	}
	if w.Status == Mined {
		if err := transition(ctx, tx, o.s.metrics, o.s.clock.Now(), &w, Broadcast, "engine", "inclusion reorged out"); err != nil {
			return err
		}
	}
	_, err = tx.ExecContext(ctx, `UPDATE withdrawals SET tx_hash = NULL WHERE id = ?`, w.ID)
	return err
}

func (o owner) OnFinal(ctx context.Context, tx *store.Tx, slot txmgr.Slot, a txmgr.Attempt, r *types.Receipt, out txmgr.Outcome) error {
	w, err := Load(ctx, tx, slot.RefID)
	if err != nil {
		return err
	}
	now := o.s.clock.Now()
	switch out {
	case txmgr.Succeeded:
		return transition(ctx, tx, o.s.metrics, now, &w, Confirmed, "engine", fmt.Sprintf("%d confirmations", o.s.txm.Config().Confirmations))
	case txmgr.Reverted:
		if err := transition(ctx, tx, o.s.metrics, now, &w, Failed, "engine", "transfer reverted on chain"); err != nil {
			return err
		}
		if err := o.s.setFailure(ctx, tx, w.ID, "reverted_on_chain"); err != nil {
			return err
		}
		return refund(ctx, tx, now, w)
	default:
		if err := transition(ctx, tx, o.s.metrics, now, &w, Replaced, "engine", "cancellation mined at the same nonce"); err != nil {
			return err
		}
		return refund(ctx, tx, now, w)
	}
}
