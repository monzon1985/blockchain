// SPDX-License-Identifier: MIT

package txmgr

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/fees"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/signer"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

// Slot states.
const (
	StateReserved = "reserved" // nonce allocated, nothing signed yet
	StatePending  = "pending"  // at least one signed attempt, none included
	StateIncluded = "included" // an attempt is in a canonical block, below confirmation depth
	StateFinal    = "final"    // an attempt reached confirmation depth; the nonce is consumed
)

// Attempt kinds and statuses.
const (
	KindOriginal = "original"
	KindBump     = "bump"
	KindCancel   = "cancel"

	AttemptSigned   = "signed"   // persisted, never accepted by a node
	AttemptSent     = "sent"     // accepted by a node at least once
	AttemptRejected = "rejected" // refused as underpriced; superseded by a bump
)

// Meta keys owned by the transaction manager.
const (
	metaNonceFloor = "nonce_floor"
	MetaTrackerNum = "tracker_head_number"
	MetaTrackerHex = "tracker_head_hash"
)

// Slot is one hot-wallet nonce and what it is used for.
type Slot struct {
	Nonce             uint64
	Purpose           signer.Purpose
	RefID             string
	State             string
	IncludedHash      common.Hash
	IncludedBlock     uint64
	IncludedBlockHash common.Hash
	InclusionRef      string
	InclusionEpoch    int64
	LastBroadcastHead uint64
	CancelRequested   bool
}

// Attempt is one signed transaction for a slot.
type Attempt struct {
	Hash     common.Hash
	Nonce    uint64
	Seq      int
	Kind     string
	Raw      []byte
	To       common.Address
	Value    *big.Int
	Data     []byte
	GasLimit uint64
	Fees     fees.Fees
	Status   string
}

// Tx decodes the raw signed transaction.
func (a Attempt) Tx() (*types.Transaction, error) {
	tx := new(types.Transaction)
	if err := tx.UnmarshalBinary(a.Raw); err != nil {
		return nil, fmt.Errorf("txmgr: decode attempt %s: %w", a.Hash, err)
	}
	return tx, nil
}

const slotColumns = `nonce, purpose, ref_id, state, COALESCE(included_hash, ''), COALESCE(included_block, 0),
	COALESCE(included_block_hash, ''), COALESCE(inclusion_ref, ''), inclusion_epoch, last_broadcast_head, cancel_requested`

func scanSlot(row interface{ Scan(...any) error }) (Slot, error) {
	var s Slot
	var purpose, incHash, incBlockHash string
	var cancel int
	if err := row.Scan(&s.Nonce, &purpose, &s.RefID, &s.State, &incHash, &s.IncludedBlock, &incBlockHash,
		&s.InclusionRef, &s.InclusionEpoch, &s.LastBroadcastHead, &cancel); err != nil {
		return Slot{}, err
	}
	s.Purpose = signer.Purpose(purpose)
	if incHash != "" {
		s.IncludedHash = common.HexToHash(incHash)
	}
	if incBlockHash != "" {
		s.IncludedBlockHash = common.HexToHash(incBlockHash)
	}
	s.CancelRequested = cancel != 0
	return s, nil
}

// LoadSlot reads the slot at nonce.
func LoadSlot(ctx context.Context, q store.Querier, nonce uint64) (Slot, error) {
	s, err := scanSlot(q.QueryRowContext(ctx, `SELECT `+slotColumns+` FROM nonce_slots WHERE nonce = ?`, nonce))
	if errors.Is(err, sql.ErrNoRows) {
		return Slot{}, store.ErrNotFound
	}
	return s, err
}

// SlotFor returns the slot owned by (purpose, ref).
func SlotFor(ctx context.Context, q store.Querier, purpose signer.Purpose, ref string) (Slot, error) {
	s, err := scanSlot(q.QueryRowContext(ctx, `SELECT `+slotColumns+` FROM nonce_slots WHERE purpose = ? AND ref_id = ?`, string(purpose), ref))
	if errors.Is(err, sql.ErrNoRows) {
		return Slot{}, store.ErrNotFound
	}
	return s, err
}

// LiveSlots returns every slot the tracker must watch, lowest nonce first.
func LiveSlots(ctx context.Context, q store.Querier) ([]Slot, error) {
	rows, err := q.QueryContext(ctx, `SELECT `+slotColumns+` FROM nonce_slots WHERE state IN ('pending', 'included') ORDER BY nonce`)
	if err != nil {
		return nil, fmt.Errorf("txmgr: live slots: %w", err)
	}
	defer rows.Close()
	var out []Slot
	for rows.Next() {
		s, err := scanSlot(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

const attemptColumns = `hash, nonce, seq, kind, raw, to_addr, value, data, gas_limit, max_fee, tip, status`

// Attempts returns the attempts of a nonce in signing order.
func Attempts(ctx context.Context, q store.Querier, nonce uint64) ([]Attempt, error) {
	rows, err := q.QueryContext(ctx, `SELECT `+attemptColumns+` FROM tx_attempts WHERE nonce = ? ORDER BY seq`, nonce)
	if err != nil {
		return nil, fmt.Errorf("txmgr: attempts: %w", err)
	}
	defer rows.Close()
	var out []Attempt
	for rows.Next() {
		var a Attempt
		var hash, to, value, maxFee, tip string
		if err := rows.Scan(&hash, &a.Nonce, &a.Seq, &a.Kind, &a.Raw, &to, &value, &a.Data, &a.GasLimit, &maxFee, &tip, &a.Status); err != nil {
			return nil, err
		}
		a.Hash = common.HexToHash(hash)
		a.To = common.HexToAddress(to)
		a.Value, _ = new(big.Int).SetString(value, 10)
		mf, _ := new(big.Int).SetString(maxFee, 10)
		tp, _ := new(big.Int).SetString(tip, 10)
		a.Fees = fees.Fees{MaxFee: mf, Tip: tp}
		out = append(out, a)
	}
	return out, rows.Err()
}

// AttemptByHash reads one attempt.
func AttemptByHash(ctx context.Context, q store.Querier, hash common.Hash) (Attempt, error) {
	var nonce uint64
	err := q.QueryRowContext(ctx, `SELECT nonce FROM tx_attempts WHERE hash = ?`, hash.Hex()).Scan(&nonce)
	if errors.Is(err, sql.ErrNoRows) {
		return Attempt{}, store.ErrNotFound
	}
	if err != nil {
		return Attempt{}, err
	}
	as, err := Attempts(ctx, q, nonce)
	if err != nil {
		return Attempt{}, err
	}
	for _, a := range as {
		if a.Hash == hash {
			return a, nil
		}
	}
	return Attempt{}, store.ErrNotFound
}

// nonceFloor is the first nonce the engine may use (the account nonce when it was adopted).
func nonceFloor(ctx context.Context, q store.Querier) (uint64, error) {
	v, ok, err := store.GetMeta(ctx, q, metaNonceFloor)
	if err != nil {
		return 0, err
	}
	if !ok {
		return 0, errors.New("txmgr: nonce floor not initialised (bootstrap not run)")
	}
	var n uint64
	if _, err := fmt.Sscan(v, &n); err != nil {
		return 0, fmt.Errorf("txmgr: corrupt nonce floor %q", v)
	}
	return n, nil
}

// Reserve allocates the lowest free nonce at or above the floor for (purpose, ref), or returns
// the nonce already reserved for it. Lowest-free allocation keeps the sequence contiguous:
// a nonce released by a failed pre-signing step is the next one handed out.
func Reserve(ctx context.Context, tx store.Querier, purpose signer.Purpose, ref string, now time.Time) (Slot, error) {
	if s, err := SlotFor(ctx, tx, purpose, ref); err == nil {
		return s, nil
	} else if !errors.Is(err, store.ErrNotFound) {
		return Slot{}, err
	}
	floor, err := nonceFloor(ctx, tx)
	if err != nil {
		return Slot{}, err
	}
	var next uint64
	err = tx.QueryRowContext(ctx, `
		SELECT n FROM (
			SELECT ? AS n
			UNION ALL
			SELECT nonce + 1 FROM nonce_slots WHERE nonce >= ?
		) WHERE n NOT IN (SELECT nonce FROM nonce_slots) ORDER BY n LIMIT 1`, floor, floor).Scan(&next)
	if err != nil {
		return Slot{}, fmt.Errorf("txmgr: allocate nonce: %w", err)
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO nonce_slots (nonce, purpose, ref_id, state, created_at, updated_at) VALUES (?, ?, ?, 'reserved', ?, ?)`,
		next, string(purpose), ref, now.UnixNano(), now.UnixNano()); err != nil {
		return Slot{}, fmt.Errorf("txmgr: reserve nonce %d: %w", next, err)
	}
	return LoadSlot(ctx, tx, next)
}

// Release frees a reservation that never produced a signed transaction. It refuses to release
// anything that has attempts: a signed transaction may already be on the network.
func Release(ctx context.Context, tx store.Querier, purpose signer.Purpose, ref string) (bool, error) {
	res, err := tx.ExecContext(ctx, `
		DELETE FROM nonce_slots WHERE purpose = ? AND ref_id = ? AND state = 'reserved'
		AND NOT EXISTS (SELECT 1 FROM tx_attempts a WHERE a.nonce = nonce_slots.nonce)`, string(purpose), ref)
	if err != nil {
		return false, fmt.Errorf("txmgr: release: %w", err)
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// RequestCancel flags a live slot for cancellation; the tracker sends the zero-value
// self-send replacement on its next round.
func RequestCancel(ctx context.Context, tx store.Querier, nonce uint64, now time.Time) error {
	res, err := tx.ExecContext(ctx, `UPDATE nonce_slots SET cancel_requested = 1, updated_at = ? WHERE nonce = ? AND state IN ('pending', 'included')`,
		now.UnixNano(), nonce)
	if err != nil {
		return fmt.Errorf("txmgr: request cancel: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("txmgr: nonce %d is not live", nonce)
	}
	return nil
}
