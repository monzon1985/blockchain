// SPDX-License-Identifier: MIT

package sqlstore

import (
	"context"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"strconv"
	"strings"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/model"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store"
)

var _ store.Store = (*Store)(nil)

// Update implements store.Store.
func (s *Store) Update(ctx context.Context, fn func(store.Tx) error) error {
	sqlTx, err := s.db.BeginTx(ctx, &s.dialect.Write)
	if err != nil {
		return fmt.Errorf("sqlstore: begin: %w", err)
	}
	t := &txn{ctx: ctx, tx: sqlTx}
	if err := fn(t); err != nil {
		t.done = true
		_ = sqlTx.Rollback()
		return err
	}
	if err := t.flushSeq(); err != nil {
		t.done = true
		_ = sqlTx.Rollback()
		return err
	}
	t.done = true
	if err := sqlTx.Commit(); err != nil {
		return fmt.Errorf("sqlstore: commit: %w", err)
	}
	return nil
}

// View implements store.Store.
func (s *Store) View(ctx context.Context, fn func(store.Reader) error) error {
	sqlTx, err := s.db.BeginTx(ctx, &s.dialect.Read)
	if err != nil {
		return fmt.Errorf("sqlstore: begin read: %w", err)
	}
	t := &txn{ctx: ctx, tx: sqlTx}
	defer func() {
		t.done = true
		_ = sqlTx.Rollback()
	}()
	return fn(t)
}

// txn implements store.Tx over one *sql.Tx.
type txn struct {
	ctx  context.Context
	tx   *sql.Tx
	done bool

	// The outbox sequence counter lives in the checkpoint row; it is read once, advanced in
	// memory and written back before commit.
	seqLoaded bool
	nextSeq   uint64
	seqDirty  bool
}

var _ store.Tx = (*txn)(nil)

func (t *txn) exec(query string, args ...any) (sql.Result, error) {
	if t.done {
		return nil, ErrClosedTx
	}
	return t.tx.ExecContext(t.ctx, query, args...)
}

func (t *txn) query(query string, args ...any) (*sql.Rows, error) {
	if t.done {
		return nil, ErrClosedTx
	}
	return t.tx.QueryContext(t.ctx, query, args...)
}

func (t *txn) queryRow(query string, args ...any) *sql.Row {
	return t.tx.QueryRowContext(t.ctx, query, args...)
}

// --- encoding helpers -------------------------------------------------------------------------

func hexAddr(a common.Address) string { return "0x" + hex.EncodeToString(a[:]) }
func hexHash(h common.Hash) string    { return "0x" + hex.EncodeToString(h[:]) }

func parseAddr(s string) (common.Address, error) {
	b, err := decodeHex(s, common.AddressLength)
	if err != nil {
		return common.Address{}, err
	}
	return common.BytesToAddress(b), nil
}

func parseHash(s string) (common.Hash, error) {
	b, err := decodeHex(s, common.HashLength)
	if err != nil {
		return common.Hash{}, err
	}
	return common.BytesToHash(b), nil
}

func decodeHex(s string, size int) ([]byte, error) {
	b, err := hex.DecodeString(strings.TrimPrefix(s, "0x"))
	if err != nil {
		return nil, fmt.Errorf("sqlstore: bad hex %q: %w", s, err)
	}
	if size > 0 && len(b) != size {
		return nil, fmt.Errorf("sqlstore: hex %q has %d bytes, want %d", s, len(b), size)
	}
	return b, nil
}

func parseBig(s string) (*big.Int, error) {
	v, ok := new(big.Int).SetString(s, 10)
	if !ok {
		return nil, fmt.Errorf("sqlstore: bad decimal %q", s)
	}
	return v, nil
}

func amount(s string) (*model.Amount, error) {
	v, err := parseBig(s)
	if err != nil {
		return nil, err
	}
	return (*model.Amount)(v), nil
}

func i64(v uint64) (int64, error) {
	if v > 1<<63-1 {
		return 0, fmt.Errorf("sqlstore: value %d exceeds int64", v)
	}
	return int64(v), nil
}

func joinTopics(topics []common.Hash) string {
	parts := make([]string, len(topics))
	for i, t := range topics {
		parts[i] = hexHash(t)
	}
	return strings.Join(parts, ",")
}

// --- meta, checkpoint, outbox ---------------------------------------------------------------

func (t *txn) Meta(key string) (string, bool, error) {
	var v string
	err := t.queryRow(`SELECT value FROM meta WHERE key = $1`, key).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return v, true, nil
}

func (t *txn) PutMeta(key, value string) error {
	_, err := t.exec(`INSERT INTO meta (key, value) VALUES ($1, $2)
		ON CONFLICT (key) DO UPDATE SET value = excluded.value`, key, value)
	return err
}

func (t *txn) Checkpoint() (model.Checkpoint, error) {
	var (
		number, head, updated int64
		hash                  string
	)
	if err := t.queryRow(`SELECT tip_number, tip_hash, chain_head, updated_at FROM checkpoint WHERE id = 1`).
		Scan(&number, &hash, &head, &updated); err != nil {
		return model.Checkpoint{}, fmt.Errorf("sqlstore: read checkpoint: %w", err)
	}
	cp := model.Checkpoint{ChainHead: uint64(head), UpdatedAt: updated}
	if number >= 0 {
		h, err := parseHash(hash)
		if err != nil {
			return model.Checkpoint{}, err
		}
		cp.Tip = &chain.BlockRef{Number: uint64(number), Hash: h}
	}
	return cp, nil
}

func refColumns(r *chain.BlockRef) (int64, string, error) {
	if r == nil {
		return -1, "", nil
	}
	n, err := i64(r.Number)
	return n, hexHash(r.Hash), err
}

func (t *txn) MoveTip(expected, next *chain.BlockRef, chainHead uint64, now int64) error {
	en, eh, err := refColumns(expected)
	if err != nil {
		return err
	}
	nn, nh, err := refColumns(next)
	if err != nil {
		return err
	}
	head, err := i64(chainHead)
	if err != nil {
		return err
	}
	res, err := t.exec(`UPDATE checkpoint SET tip_number = $1, tip_hash = $2, chain_head = $3, updated_at = $4
		WHERE id = 1 AND tip_number = $5 AND tip_hash = $6`, nn, nh, head, now, en, eh)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n != 1 {
		return store.ErrTipConflict
	}
	return nil
}

func (t *txn) Heartbeat(chainHead uint64, now int64) error {
	head, err := i64(chainHead)
	if err != nil {
		return err
	}
	_, err = t.exec(`UPDATE checkpoint SET chain_head = $1, updated_at = $2 WHERE id = 1`, head, now)
	return err
}

func (t *txn) loadSeq() error {
	if t.seqLoaded {
		return nil
	}
	var next int64
	if err := t.queryRow(`SELECT next_seq FROM checkpoint WHERE id = 1`).Scan(&next); err != nil {
		return fmt.Errorf("sqlstore: read next_seq: %w", err)
	}
	t.nextSeq, t.seqLoaded = uint64(next), true
	return nil
}

func (t *txn) flushSeq() error {
	if !t.seqDirty {
		return nil
	}
	next, err := i64(t.nextSeq)
	if err != nil {
		return err
	}
	_, err = t.exec(`UPDATE checkpoint SET next_seq = $1 WHERE id = 1`, next)
	t.seqDirty = false
	return err
}

func (t *txn) AppendEvent(kind string, block uint64, payload []byte) (uint64, error) {
	if err := t.loadSeq(); err != nil {
		return 0, err
	}
	seq := t.nextSeq
	s, err := i64(seq)
	if err != nil {
		return 0, err
	}
	b, err := i64(block)
	if err != nil {
		return 0, err
	}
	if _, err := t.exec(`INSERT INTO events (seq, kind, block_number, payload) VALUES ($1, $2, $3, $4)`,
		s, kind, b, string(payload)); err != nil {
		return 0, err
	}
	t.nextSeq++
	t.seqDirty = true
	return seq, nil
}

func (t *txn) EventsAfter(after uint64, limit int) ([]model.Event, error) {
	a, err := i64(after)
	if err != nil {
		return nil, err
	}
	rows, err := t.query(`SELECT seq, kind, block_number, payload FROM events WHERE seq > $1 ORDER BY seq LIMIT $2`, a, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.Event
	for rows.Next() {
		var (
			seq, block int64
			kind, body string
		)
		if err := rows.Scan(&seq, &kind, &block, &body); err != nil {
			return nil, err
		}
		out = append(out, model.Event{Seq: uint64(seq), Kind: kind, BlockNumber: uint64(block), Payload: []byte(body)})
	}
	return out, rows.Err()
}

func (t *txn) EventBounds() (uint64, uint64, error) {
	var oldest sql.NullInt64
	if err := t.queryRow(`SELECT MIN(seq) FROM events`).Scan(&oldest); err != nil {
		return 0, 0, err
	}
	if err := t.loadSeq(); err != nil {
		return 0, 0, err
	}
	newest := t.nextSeq - 1
	if !oldest.Valid {
		// Empty outbox: everything up to newest was pruned (or nothing was ever written).
		return newest + 1, newest, nil
	}
	return uint64(oldest.Int64), newest, nil
}

func (t *txn) PruneEventsBelow(n uint64) error {
	v, err := i64(n)
	if err != nil {
		return err
	}
	_, err = t.exec(`DELETE FROM events WHERE seq < $1`, v)
	return err
}

// --- blocks -----------------------------------------------------------------------------------

func (t *txn) InsertBlock(h chain.Header) error {
	n, err := i64(h.Number)
	if err != nil {
		return err
	}
	ts, err := i64(h.Time)
	if err != nil {
		return err
	}
	_, err = t.exec(`INSERT INTO blocks (number, hash, parent_hash, block_time) VALUES ($1, $2, $3, $4)`,
		n, hexHash(h.Hash), hexHash(h.ParentHash), ts)
	return err
}

func (t *txn) RecentBlocks(limit int) ([]chain.Header, error) {
	rows, err := t.query(`SELECT number, hash, parent_hash, block_time FROM blocks ORDER BY number DESC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []chain.Header
	for rows.Next() {
		var (
			n, ts        int64
			hash, parent string
		)
		if err := rows.Scan(&n, &hash, &parent, &ts); err != nil {
			return nil, err
		}
		h, err := parseHash(hash)
		if err != nil {
			return nil, err
		}
		p, err := parseHash(parent)
		if err != nil {
			return nil, err
		}
		out = append(out, chain.Header{Number: uint64(n), Hash: h, ParentHash: p, Time: uint64(ts)})
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out, nil
}

func (t *txn) BlockCount() (int64, error) {
	var n int64
	err := t.queryRow(`SELECT COUNT(*) FROM blocks`).Scan(&n)
	return n, err
}

func (t *txn) PruneBlocksBelow(n uint64) error {
	v, err := i64(n)
	if err != nil {
		return err
	}
	_, err = t.exec(`DELETE FROM blocks WHERE number < $1`, v)
	return err
}

// --- logs and derived rows -------------------------------------------------------------------

func inserted(res sql.Result, err error) (bool, error) {
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return n == 1, nil
}

func (t *txn) InsertLog(l model.Log) (bool, error) {
	n, err := i64(l.Block.Number)
	if err != nil {
		return false, err
	}
	return inserted(t.exec(`INSERT INTO logs (block_hash, log_index, block_number, tx_hash, tx_index, address, topics, data)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT (block_hash, log_index) DO NOTHING`,
		hexHash(l.Block.Hash), int64(l.LogIndex), n, hexHash(l.TxHash), int64(l.TxIndex),
		hexAddr(l.Address), joinTopics(l.Topics), "0x"+hex.EncodeToString(l.Data)))
}

func (t *txn) InsertTransfer(tr model.Transfer) (bool, error) {
	n, err := i64(tr.Block.Number)
	if err != nil {
		return false, err
	}
	return inserted(t.exec(`INSERT INTO transfers (block_hash, log_index, block_number, block_time, tx_hash, token, from_addr, to_addr, value)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) ON CONFLICT (block_hash, log_index) DO NOTHING`,
		hexHash(tr.Block.Hash), int64(tr.LogIndex), n, int64(tr.BlockTime), hexHash(tr.TxHash),
		hexAddr(tr.Token), hexAddr(tr.From), hexAddr(tr.To), tr.Value.String()))
}

func (t *txn) InsertVaultEvent(v model.VaultEvent) (bool, error) {
	n, err := i64(v.Block.Number)
	if err != nil {
		return false, err
	}
	return inserted(t.exec(`INSERT INTO vault_events (block_hash, log_index, block_number, block_time, tx_hash, vault, kind, sender, owner, receiver, assets, shares)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12) ON CONFLICT (block_hash, log_index) DO NOTHING`,
		hexHash(v.Block.Hash), int64(v.LogIndex), n, int64(v.BlockTime), hexHash(v.TxHash), hexAddr(v.Vault),
		v.Kind, hexAddr(v.Sender), hexAddr(v.Owner), hexAddr(v.Receiver), v.Assets.String(), v.Shares.String()))
}

func (t *txn) InsertSharePrice(p model.SharePrice) error {
	n, err := i64(p.Block.Number)
	if err != nil {
		return err
	}
	var price sql.NullString
	if p.PriceWad != nil {
		price = sql.NullString{String: p.PriceWad.String(), Valid: true}
	}
	_, err = t.exec(`INSERT INTO share_prices (block_hash, vault, block_number, block_time, total_assets, total_supply, price_wad)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (block_hash, vault) DO UPDATE SET total_assets = excluded.total_assets,
			total_supply = excluded.total_supply, price_wad = excluded.price_wad`,
		hexHash(p.Block.Hash), hexAddr(p.Vault), n, int64(p.BlockTime), p.TotalAssets.String(), p.TotalSupply.String(), price)
	return err
}

func (t *txn) Balance(token, holder common.Address) (*big.Int, error) {
	var v string
	err := t.queryRow(`SELECT balance FROM balances WHERE token = $1 AND holder = $2`, hexAddr(token), hexAddr(holder)).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return new(big.Int), nil
	}
	if err != nil {
		return nil, err
	}
	return parseBig(v)
}

func (t *txn) SetBalance(token, holder common.Address, v *big.Int) error {
	if v.Sign() == 0 {
		_, err := t.exec(`DELETE FROM balances WHERE token = $1 AND holder = $2`, hexAddr(token), hexAddr(holder))
		return err
	}
	_, err := t.exec(`INSERT INTO balances (token, holder, balance) VALUES ($1, $2, $3)
		ON CONFLICT (token, holder) DO UPDATE SET balance = excluded.balance`, hexAddr(token), hexAddr(holder), v.String())
	return err
}

func (t *txn) Supply(token common.Address) (*big.Int, error) {
	var v string
	err := t.queryRow(`SELECT supply FROM supplies WHERE token = $1`, hexAddr(token)).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return new(big.Int), nil
	}
	if err != nil {
		return nil, err
	}
	return parseBig(v)
}

func (t *txn) SetSupply(token common.Address, v *big.Int) error {
	if v.Sign() == 0 {
		_, err := t.exec(`DELETE FROM supplies WHERE token = $1`, hexAddr(token))
		return err
	}
	_, err := t.exec(`INSERT INTO supplies (token, supply) VALUES ($1, $2)
		ON CONFLICT (token) DO UPDATE SET supply = excluded.supply`, hexAddr(token), v.String())
	return err
}

func (t *txn) DeleteFrom(from uint64) (store.Deleted, error) {
	f, err := i64(from)
	if err != nil {
		return store.Deleted{}, err
	}
	var d store.Deleted
	for _, step := range []struct {
		query string
		count *int64
	}{
		{`DELETE FROM blocks WHERE number >= $1`, &d.Blocks},
		{`DELETE FROM logs WHERE block_number >= $1`, &d.Logs},
		{`DELETE FROM transfers WHERE block_number >= $1`, &d.Transfers},
		{`DELETE FROM vault_events WHERE block_number >= $1`, &d.VaultEvents},
		{`DELETE FROM share_prices WHERE block_number >= $1`, &d.SharePrices},
	} {
		res, err := t.exec(step.query, f)
		if err != nil {
			return store.Deleted{}, err
		}
		if *step.count, err = res.RowsAffected(); err != nil {
			return store.Deleted{}, err
		}
	}
	return d, nil
}

func (t *txn) InsertReorg(r model.Reorg) error {
	var id int64
	if err := t.queryRow(`SELECT COALESCE(MAX(id), 0) + 1 FROM reorgs`).Scan(&id); err != nil {
		return err
	}
	ancN, ancH, err := refColumns(r.Ancestor)
	if err != nil {
		return err
	}
	oldN, err := i64(r.OldTip.Number)
	if err != nil {
		return err
	}
	newN, err := i64(r.NewHead.Number)
	if err != nil {
		return err
	}
	depth, err := i64(r.Depth)
	if err != nil {
		return err
	}
	_, err = t.exec(`INSERT INTO reorgs (id, detected_at, old_tip_number, old_tip_hash, ancestor_number, ancestor_hash, new_head_number, new_head_hash, depth)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
		id, r.DetectedAt, oldN, hexHash(r.OldTip.Hash), ancN, ancH, newN, hexHash(r.NewHead.Hash), depth)
	return err
}

func (t *txn) LastReorg() (*model.Reorg, bool, error) {
	var (
		detected, oldN, ancN, newN, depth int64
		oldH, ancH, newH                  string
	)
	err := t.queryRow(`SELECT detected_at, old_tip_number, old_tip_hash, ancestor_number, ancestor_hash, new_head_number, new_head_hash, depth
		FROM reorgs ORDER BY id DESC LIMIT 1`).Scan(&detected, &oldN, &oldH, &ancN, &ancH, &newN, &newH, &depth)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	r := &model.Reorg{DetectedAt: detected, Depth: uint64(depth)}
	if r.OldTip.Hash, err = parseHash(oldH); err != nil {
		return nil, false, err
	}
	r.OldTip.Number = uint64(oldN)
	if r.NewHead.Hash, err = parseHash(newH); err != nil {
		return nil, false, err
	}
	r.NewHead.Number = uint64(newN)
	if ancN >= 0 {
		h, err := parseHash(ancH)
		if err != nil {
			return nil, false, err
		}
		r.Ancestor = &chain.BlockRef{Number: uint64(ancN), Hash: h}
	}
	return r, true, nil
}

func (t *txn) ReorgCount() (int64, error) {
	var n int64
	err := t.queryRow(`SELECT COUNT(*) FROM reorgs`).Scan(&n)
	return n, err
}

// --- row scanners -----------------------------------------------------------------------------

const transferColumns = `block_hash, log_index, block_number, block_time, tx_hash, token, from_addr, to_addr, value`

func scanTransfers(rows *sql.Rows) ([]model.Transfer, error) {
	defer rows.Close()
	var out []model.Transfer
	for rows.Next() {
		var (
			bh, tx, token, from, to, value string
			idx, n, ts                     int64
		)
		if err := rows.Scan(&bh, &idx, &n, &ts, &tx, &token, &from, &to, &value); err != nil {
			return nil, err
		}
		var tr model.Transfer
		var err error
		if tr.Block.Hash, err = parseHash(bh); err != nil {
			return nil, err
		}
		tr.Block.Number, tr.LogIndex, tr.BlockTime = uint64(n), uint64(idx), uint64(ts)
		if tr.TxHash, err = parseHash(tx); err != nil {
			return nil, err
		}
		if tr.Token, err = parseAddr(token); err != nil {
			return nil, err
		}
		if tr.From, err = parseAddr(from); err != nil {
			return nil, err
		}
		if tr.To, err = parseAddr(to); err != nil {
			return nil, err
		}
		if tr.Value, err = amount(value); err != nil {
			return nil, err
		}
		out = append(out, tr)
	}
	return out, rows.Err()
}

const vaultEventColumns = `block_hash, log_index, block_number, block_time, tx_hash, vault, kind, sender, owner, receiver, assets, shares`

func scanVaultEvents(rows *sql.Rows) ([]model.VaultEvent, error) {
	defer rows.Close()
	var out []model.VaultEvent
	for rows.Next() {
		var (
			bh, tx, vault, kind, sender, owner, receiver, assets, shares string
			idx, n, ts                                                   int64
		)
		if err := rows.Scan(&bh, &idx, &n, &ts, &tx, &vault, &kind, &sender, &owner, &receiver, &assets, &shares); err != nil {
			return nil, err
		}
		v := model.VaultEvent{Kind: kind, LogIndex: uint64(idx), BlockTime: uint64(ts)}
		v.Block.Number = uint64(n)
		var err error
		for _, f := range []struct {
			dst *common.Hash
			src string
		}{{&v.Block.Hash, bh}, {&v.TxHash, tx}} {
			if *f.dst, err = parseHash(f.src); err != nil {
				return nil, err
			}
		}
		for _, f := range []struct {
			dst *common.Address
			src string
		}{{&v.Vault, vault}, {&v.Sender, sender}, {&v.Owner, owner}, {&v.Receiver, receiver}} {
			if *f.dst, err = parseAddr(f.src); err != nil {
				return nil, err
			}
		}
		if v.Assets, err = amount(assets); err != nil {
			return nil, err
		}
		if v.Shares, err = amount(shares); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

const sharePriceColumns = `block_hash, vault, block_number, block_time, total_assets, total_supply, price_wad`

func scanSharePrices(rows *sql.Rows) ([]model.SharePrice, error) {
	defer rows.Close()
	var out []model.SharePrice
	for rows.Next() {
		var (
			bh, vault, assets, supply string
			price                     sql.NullString
			n, ts                     int64
		)
		if err := rows.Scan(&bh, &vault, &n, &ts, &assets, &supply, &price); err != nil {
			return nil, err
		}
		p := model.SharePrice{BlockTime: uint64(ts)}
		p.Block.Number = uint64(n)
		var err error
		if p.Block.Hash, err = parseHash(bh); err != nil {
			return nil, err
		}
		if p.Vault, err = parseAddr(vault); err != nil {
			return nil, err
		}
		if p.TotalAssets, err = amount(assets); err != nil {
			return nil, err
		}
		if p.TotalSupply, err = amount(supply); err != nil {
			return nil, err
		}
		if price.Valid {
			if p.PriceWad, err = amount(price.String); err != nil {
				return nil, err
			}
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func scanBalances(rows *sql.Rows) ([]model.Balance, error) {
	defer rows.Close()
	var out []model.Balance
	for rows.Next() {
		var token, holder, bal string
		if err := rows.Scan(&token, &holder, &bal); err != nil {
			return nil, err
		}
		var b model.Balance
		var err error
		if b.Token, err = parseAddr(token); err != nil {
			return nil, err
		}
		if b.Holder, err = parseAddr(holder); err != nil {
			return nil, err
		}
		if b.Balance, err = amount(bal); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

func (t *txn) TransfersFrom(from uint64) ([]model.Transfer, error) {
	f, err := i64(from)
	if err != nil {
		return nil, err
	}
	rows, err := t.query(`SELECT `+transferColumns+` FROM transfers WHERE block_number >= $1 ORDER BY block_number, log_index`, f)
	if err != nil {
		return nil, err
	}
	return scanTransfers(rows)
}

func (t *txn) VaultEventsFrom(from uint64) ([]model.VaultEvent, error) {
	f, err := i64(from)
	if err != nil {
		return nil, err
	}
	rows, err := t.query(`SELECT `+vaultEventColumns+` FROM vault_events WHERE block_number >= $1 ORDER BY block_number, log_index`, f)
	if err != nil {
		return nil, err
	}
	return scanVaultEvents(rows)
}

func (t *txn) SharePricesFrom(from uint64) ([]model.SharePrice, error) {
	f, err := i64(from)
	if err != nil {
		return nil, err
	}
	rows, err := t.query(`SELECT `+sharePriceColumns+` FROM share_prices WHERE block_number >= $1 ORDER BY block_number, vault`, f)
	if err != nil {
		return nil, err
	}
	return scanSharePrices(rows)
}

// --- filtered queries ------------------------------------------------------------------------

// where accumulates predicates with sequentially numbered placeholders.
type where struct {
	conds []string
	args  []any
}

// add appends a predicate; every `?` in cond becomes the next placeholder (the same number for
// all `?` of one call, so a value can be referenced twice).
func (w *where) add(cond string, arg any) {
	w.args = append(w.args, arg)
	w.conds = append(w.conds, strings.ReplaceAll(cond, "?", "$"+strconv.Itoa(len(w.args))))
}

// addPosition appends the keyset predicate (block_number, log_index) > (b, i).
func (w *where) addPosition(p store.Position) error {
	b, err := i64(p.Block)
	if err != nil {
		return err
	}
	w.args = append(w.args, b, int64(p.LogIndex))
	bn, in := "$"+strconv.Itoa(len(w.args)-1), "$"+strconv.Itoa(len(w.args))
	w.conds = append(w.conds, "(block_number > "+bn+" OR (block_number = "+bn+" AND log_index > "+in+"))")
	return nil
}

func (w *where) sql() string {
	if len(w.conds) == 0 {
		return ""
	}
	return " WHERE " + strings.Join(w.conds, " AND ")
}

func (w *where) limit(n int) string {
	w.args = append(w.args, n)
	return " LIMIT $" + strconv.Itoa(len(w.args))
}

func blockBounds(w *where, from, to *uint64) error {
	if from != nil {
		v, err := i64(*from)
		if err != nil {
			return err
		}
		w.add("block_number >= ?", v)
	}
	if to != nil {
		v, err := i64(*to)
		if err != nil {
			return err
		}
		w.add("block_number <= ?", v)
	}
	return nil
}

func (t *txn) Transfers(f store.TransferFilter) ([]model.Transfer, error) {
	var w where
	if f.Token != nil {
		w.add("token = ?", hexAddr(*f.Token))
	}
	if f.Address != nil {
		w.add("(from_addr = ? OR to_addr = ?)", hexAddr(*f.Address))
	}
	if f.From != nil {
		w.add("from_addr = ?", hexAddr(*f.From))
	}
	if f.To != nil {
		w.add("to_addr = ?", hexAddr(*f.To))
	}
	if err := blockBounds(&w, f.FromBlock, f.ToBlock); err != nil {
		return nil, err
	}
	if f.After != nil {
		if err := w.addPosition(*f.After); err != nil {
			return nil, err
		}
	}
	q := `SELECT ` + transferColumns + ` FROM transfers` + w.sql() + ` ORDER BY block_number, log_index` + w.limit(f.Limit)
	rows, err := t.query(q, w.args...)
	if err != nil {
		return nil, err
	}
	return scanTransfers(rows)
}

func (t *txn) VaultEvents(f store.VaultEventFilter) ([]model.VaultEvent, error) {
	var w where
	w.add("vault = ?", hexAddr(f.Vault))
	if err := blockBounds(&w, f.FromBlock, f.ToBlock); err != nil {
		return nil, err
	}
	if f.After != nil {
		if err := w.addPosition(*f.After); err != nil {
			return nil, err
		}
	}
	q := `SELECT ` + vaultEventColumns + ` FROM vault_events` + w.sql() + ` ORDER BY block_number, log_index` + w.limit(f.Limit)
	rows, err := t.query(q, w.args...)
	if err != nil {
		return nil, err
	}
	return scanVaultEvents(rows)
}

func (t *txn) SharePrices(f store.SharePriceFilter) ([]model.SharePrice, error) {
	var w where
	w.add("vault = ?", hexAddr(f.Vault))
	if err := blockBounds(&w, f.FromBlock, f.ToBlock); err != nil {
		return nil, err
	}
	if f.After != nil {
		v, err := i64(*f.After)
		if err != nil {
			return nil, err
		}
		w.add("block_number > ?", v)
	}
	q := `SELECT ` + sharePriceColumns + ` FROM share_prices` + w.sql() + ` ORDER BY block_number` + w.limit(f.Limit)
	rows, err := t.query(q, w.args...)
	if err != nil {
		return nil, err
	}
	return scanSharePrices(rows)
}

func (t *txn) Balances(f store.BalanceFilter) ([]model.Balance, error) {
	var w where
	w.add("token = ?", hexAddr(f.Token))
	if f.After != nil {
		w.add("holder > ?", hexAddr(*f.After))
	}
	if len(f.Holders) > 0 {
		marks := make([]string, len(f.Holders))
		for i, h := range f.Holders {
			w.args = append(w.args, hexAddr(h))
			marks[i] = "$" + strconv.Itoa(len(w.args))
		}
		w.conds = append(w.conds, "holder IN ("+strings.Join(marks, ", ")+")")
	}
	q := `SELECT token, holder, balance FROM balances` + w.sql() + ` ORDER BY holder` + w.limit(f.Limit)
	rows, err := t.query(q, w.args...)
	if err != nil {
		return nil, err
	}
	return scanBalances(rows)
}

func (t *txn) HolderBalances(holder common.Address) ([]model.Balance, error) {
	rows, err := t.query(`SELECT token, holder, balance FROM balances WHERE holder = $1 ORDER BY token`, hexAddr(holder))
	if err != nil {
		return nil, err
	}
	return scanBalances(rows)
}

// --- snapshot ---------------------------------------------------------------------------------

func (t *txn) Snapshot() (*store.Snapshot, error) {
	cp, err := t.Checkpoint()
	if err != nil {
		return nil, err
	}
	snap := &store.Snapshot{Tip: cp.Tip, Tables: map[string][]store.Row{}}
	type spec struct {
		table, query string
		ncol         int
		key          func(c []string) string
	}
	pos := func(c []string) string { return pad(c[2], 12) + ":" + c[0] + ":" + pad(c[1], 6) }
	specs := []spec{
		{"logs", `SELECT block_hash, log_index, block_number, tx_hash, tx_index, address, topics, data FROM logs`, 8, pos},
		{"transfers", `SELECT block_hash, log_index, block_number, block_time, tx_hash, token, from_addr, to_addr, value FROM transfers`, 9, pos},
		{"vault_events", `SELECT block_hash, log_index, block_number, block_time, tx_hash, vault, kind, sender, owner, receiver, assets, shares FROM vault_events`, 12, pos},
		{"share_prices", `SELECT block_hash, vault, block_number, block_time, total_assets, total_supply, COALESCE(price_wad, 'null') FROM share_prices`, 7,
			func(c []string) string { return pad(c[2], 12) + ":" + c[0] + ":" + c[1] }},
		{"balances", `SELECT token, holder, balance FROM balances`, 3, func(c []string) string { return c[0] + ":" + c[1] }},
		{"supplies", `SELECT token, supply FROM supplies`, 2, func(c []string) string { return c[0] }},
	}
	for _, sp := range specs {
		rows, err := t.query(sp.query)
		if err != nil {
			return nil, err
		}
		var out []store.Row
		for rows.Next() {
			cols := make([]string, sp.ncol)
			ptrs := make([]any, sp.ncol)
			for i := range cols {
				ptrs[i] = &cols[i]
			}
			if err := rows.Scan(ptrs...); err != nil {
				rows.Close()
				return nil, err
			}
			out = append(out, store.Row{Key: sp.key(cols), Value: strings.Join(cols, "|")})
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return nil, err
		}
		rows.Close()
		store.SortRows(out)
		snap.Tables[sp.table] = out
	}
	return snap, nil
}

// pad left-pads a decimal string with zeros so keys sort numerically.
func pad(s string, width int) string {
	if len(s) >= width {
		return s
	}
	return strings.Repeat("0", width-len(s)) + s
}
