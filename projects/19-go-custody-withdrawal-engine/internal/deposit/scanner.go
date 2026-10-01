// SPDX-License-Identifier: MIT

package deposit

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"slices"
	"strconv"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/audit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/chain"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/clock"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/metrics"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

const metaScanCursor = "scan_cursor"

// topicChunk bounds the number of recipient topics per eth_getLogs call.
const topicChunk = 200

// ScannerConfig parameterises the scanner.
type ScannerConfig struct {
	Tokens        map[common.Address]string // token contract -> asset symbol
	Confirmations uint64
	MaxRange      uint64 // blocks per eth_getLogs call
	KeepBlocks    uint64 // recent block hashes remembered for reorg detection
}

// Scanner detects deposits.
type Scanner struct {
	db      *store.DB
	chain   chain.Client
	clock   clock.Clock
	metrics *metrics.Metrics
	log     *slog.Logger
	cfg     ScannerConfig
}

// NewScanner returns a Scanner.
func NewScanner(db *store.DB, c chain.Client, clk clock.Clock, m *metrics.Metrics, log *slog.Logger, cfg ScannerConfig) (*Scanner, error) {
	if cfg.Confirmations == 0 || cfg.MaxRange == 0 {
		return nil, errors.New("deposit: confirmations and max_range must be positive")
	}
	if cfg.KeepBlocks < cfg.Confirmations*2 {
		cfg.KeepBlocks = cfg.Confirmations * 2
	}
	return &Scanner{db: db, chain: c, clock: clk, metrics: m, log: log, cfg: cfg}, nil
}

// Bootstrap sets the scan cursor on first start: deposits are detected from the block after
// `start` (the current head when start is nil).
func (sc *Scanner) Bootstrap(ctx context.Context, start *uint64) error {
	return sc.db.WithTx(ctx, func(tx *store.Tx) error {
		if _, ok, err := store.GetMeta(ctx, tx, metaScanCursor); err != nil || ok {
			return err
		}
		var from chain.BlockRef
		var err error
		if start != nil {
			from, err = sc.chain.BlockByNumber(ctx, *start)
		} else {
			from, err = sc.chain.Head(ctx)
		}
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT OR REPLACE INTO scanned_blocks (number, hash) VALUES (?, ?)`, from.Number, from.Hash.Hex()); err != nil {
			return err
		}
		return store.SetMeta(ctx, tx, metaScanCursor, strconv.FormatUint(from.Number, 10))
	})
}

func (sc *Scanner) cursor(ctx context.Context, q store.Querier) (uint64, error) {
	v, ok, err := store.GetMeta(ctx, q, metaScanCursor)
	if err != nil {
		return 0, err
	}
	if !ok {
		return 0, errors.New("deposit: scanner not bootstrapped")
	}
	return strconv.ParseUint(v, 10, 64)
}

func (sc *Scanner) storedHash(ctx context.Context, n uint64) (common.Hash, bool, error) {
	var h string
	err := sc.db.QueryRowContext(ctx, `SELECT hash FROM scanned_blocks WHERE number = ?`, n).Scan(&h)
	if errors.Is(err, sql.ErrNoRows) {
		return common.Hash{}, false, nil
	}
	if err != nil {
		return common.Hash{}, false, err
	}
	return common.HexToHash(h), true, nil
}

// ScanOnce runs one round: make sure the cursor sits on a canonical block at or below the head
// (rewinding after a reorg or a head that went backwards), scan new blocks for deposits, and
// credit deposits that reached the confirmation depth.
func (sc *Scanner) ScanOnce(ctx context.Context) error {
	head, err := sc.chain.Head(ctx)
	if err != nil {
		return err
	}
	cursor, err := sc.cursor(ctx, sc.db)
	if err != nil {
		return err
	}
	if cursor, err = sc.reconcileCursor(ctx, cursor, head); err != nil {
		return err
	}
	if cursor < head.Number {
		to := min(head.Number, cursor+sc.cfg.MaxRange)
		if err := sc.scanRange(ctx, cursor+1, to); err != nil {
			return err
		}
	}
	return sc.credit(ctx, head)
}

// reconcileCursor checks that the cursor block is canonical and not above the head. Because
// block hashes chain, a canonical cursor implies that every scanned block below it is canonical
// too, and the cursor's hash is always remembered (every scan range records its end, every
// rewind records its target), so the common case costs one RPC call.
//
// Otherwise (a reorg, a head that moved backwards, or a cursor whose hash is unknown) it walks
// back through the remembered hashes at or below min(cursor, head) to the highest block that is
// still canonical, and rewinds there. Rewinding only to the new head would not be enough: a
// shorter fork can also replace blocks below its head, and a scan range covering several blocks
// only remembers its end and the blocks that held deposits, so a deposit from the abandoned fork
// would stay pending forever while its re-inclusion, in a block the cursor had already passed,
// would never be scanned.
func (sc *Scanner) reconcileCursor(ctx context.Context, cursor uint64, head chain.BlockRef) (uint64, error) {
	if cursor <= head.Number {
		stored, ok, err := sc.storedHash(ctx, cursor)
		if err != nil {
			return cursor, err
		}
		if ok {
			cur, err := sc.chain.BlockByNumber(ctx, cursor)
			if err != nil && !errors.Is(err, chain.ErrNotFound) {
				return cursor, err
			}
			if err == nil && cur.Hash == stored {
				return cursor, nil
			}
		}
	}
	top := min(cursor, head.Number)
	fork, anchor, err := sc.findFork(ctx, top)
	if err != nil {
		return cursor, err
	}
	if cursor > head.Number {
		sc.log.Warn("deposit: the head moved backwards", "cursor", cursor, "head", head.Number, "rewind_to", fork)
	} else {
		sc.log.Warn("deposit: reorg detected", "cursor", cursor, "fork_point", fork)
	}
	return sc.rewind(ctx, fork, anchor)
}

// findFork returns the highest known block at or below top that is still canonical, and its
// hash. Known blocks are the remembered scan hashes (range ends, an anchor below the window)
// and the blocks of recorded deposits, so every credited deposit above the fork point is known
// not to be canonical any more: rewind reports exactly those as a deep reorg. When no known
// block is canonical (a reorg deeper than everything remembered) it returns the block just below
// the oldest one, with its current hash, and logs an error.
func (sc *Scanner) findFork(ctx context.Context, top uint64) (uint64, common.Hash, error) {
	rows, err := sc.db.QueryContext(ctx, `
		SELECT number, hash FROM scanned_blocks WHERE number <= ?
		UNION SELECT block_number, block_hash FROM deposits WHERE block_number <= ?
		ORDER BY 1 DESC LIMIT 1000`, top, top)
	if err != nil {
		return 0, common.Hash{}, err
	}
	type nh struct {
		n uint64
		h common.Hash
	}
	var candidates []nh
	for rows.Next() {
		var n uint64
		var h string
		if err := rows.Scan(&n, &h); err != nil {
			rows.Close()
			return 0, common.Hash{}, err
		}
		candidates = append(candidates, nh{n, common.HexToHash(h)})
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, common.Hash{}, err
	}
	for _, c := range candidates {
		b, err := sc.chain.BlockByNumber(ctx, c.n)
		if errors.Is(err, chain.ErrNotFound) {
			continue
		}
		if err != nil {
			return 0, common.Hash{}, err
		}
		if b.Hash == c.h {
			return c.n, c.h, nil
		}
	}
	fork := top
	if len(candidates) > 0 {
		fork = max(candidates[len(candidates)-1].n, 1) - 1
	}
	sc.log.Error("deposit: reorg deeper than the remembered window", "searched_from", top, "rewind_to", fork)
	b, err := sc.chain.BlockByNumber(ctx, fork)
	if err != nil {
		return 0, common.Hash{}, err
	}
	return fork, b.Hash, nil
}

// rewind drops scanner state above block n and remembers anchor as n's hash, so the next round
// can verify the new cursor. Pending deposits above n are orphaned; a credited deposit there
// means a reorg deeper than the confirmation depth, which the engine cannot undo on its own
// (the customer may already have withdrawn): it is flagged for manual handling.
func (sc *Scanner) rewind(ctx context.Context, n uint64, anchor common.Hash) (uint64, error) {
	err := sc.db.WithTx(ctx, func(tx *store.Tx) error {
		res, err := tx.ExecContext(ctx, `DELETE FROM deposits WHERE block_number > ? AND status = 'pending'`, n)
		if err != nil {
			return err
		}
		orphaned, _ := res.RowsAffected()
		var deep int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM deposits WHERE block_number > ? AND status = 'credited'`, n).Scan(&deep); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM scanned_blocks WHERE number > ?`, n); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT OR REPLACE INTO scanned_blocks (number, hash) VALUES (?, ?)`, n, anchor.Hex()); err != nil {
			return err
		}
		if err := store.SetMeta(ctx, tx, metaScanCursor, strconv.FormatUint(n, 10)); err != nil {
			return err
		}
		tx.OnCommit(func() {
			sc.metrics.DepositsOrphaned.Add(float64(orphaned))
			if deep > 0 {
				sc.metrics.DeepReorgs.Inc()
			}
		})
		data := map[string]any{"fork_point": n, "orphaned_pending": orphaned, "credited_above_fork": deep}
		typ := "deposit.reorg"
		if deep > 0 {
			typ = "deposit.deep_reorg"
			sc.log.Error("deposit: credited deposits were reorged out; manual reconciliation required", "count", deep, "fork_point", n)
		}
		return audit.Record(ctx, tx, sc.clock.Now(), audit.Event{Type: typ, Actor: "engine", Subject: "scanner", Data: data})
	})
	return n, err
}

func (sc *Scanner) scanRange(ctx context.Context, from, to uint64) error {
	addrs, err := Addresses(ctx, sc.db)
	if err != nil {
		return err
	}
	// The range end is read before the logs and again after them: if the chain changed in
	// between, the logs may come from another fork and the range is scanned again next round.
	end, err := sc.chain.BlockByNumber(ctx, to)
	if err != nil {
		return err
	}
	var found []depositLog
	if len(addrs) > 0 && len(sc.cfg.Tokens) > 0 {
		tokens := make([]common.Address, 0, len(sc.cfg.Tokens))
		for t := range sc.cfg.Tokens {
			tokens = append(tokens, t)
		}
		slices.SortFunc(tokens, func(a, b common.Address) int { return a.Cmp(b) })
		recipients := make([]common.Hash, 0, len(addrs))
		for a := range addrs {
			recipients = append(recipients, common.BytesToHash(a.Bytes()))
		}
		slices.SortFunc(recipients, func(a, b common.Hash) int { return a.Cmp(b) })
		for i := 0; i < len(recipients); i += topicChunk {
			chunk := recipients[i:min(i+topicChunk, len(recipients))]
			logs, err := sc.chain.FilterLogs(ctx, ethereum.FilterQuery{
				FromBlock: new(big.Int).SetUint64(from),
				ToBlock:   new(big.Int).SetUint64(to),
				Addresses: tokens,
				Topics:    [][]common.Hash{{chain.TransferTopic}, nil, chunk},
			})
			if err != nil {
				return fmt.Errorf("deposit: get logs %d-%d: %w", from, to, err)
			}
			for i := range logs {
				l := &logs[i]
				tl, ok := chain.DecodeTransferLog(l)
				if !ok || l.Removed || tl.Amount.Sign() == 0 {
					continue
				}
				a, ok := addrs[tl.To]
				if !ok {
					continue
				}
				found = append(found, depositLog{log: tl, account: a.AccountID, txHash: l.TxHash, index: l.Index,
					block: l.BlockNumber, blockHash: l.BlockHash})
			}
		}
	}
	// Remember the hash of every block that holds a deposit and of the range end, and make sure
	// they are all still canonical, so a reorg racing this scan cannot slip stale logs in.
	hashes := map[uint64]common.Hash{}
	if after, err := sc.chain.BlockByNumber(ctx, to); err != nil {
		return err
	} else if after.Hash != end.Hash {
		return fmt.Errorf("deposit: block %d changed during the scan; retrying", to)
	}
	hashes[to] = end.Hash
	for _, d := range found {
		if h, ok := hashes[d.block]; ok {
			if h != d.blockHash {
				return fmt.Errorf("deposit: logs of block %d span two forks; retrying", d.block)
			}
			continue
		}
		b, err := sc.chain.BlockByNumber(ctx, d.block)
		if err != nil {
			return err
		}
		if b.Hash != d.blockHash {
			return fmt.Errorf("deposit: block %d was reorged during the scan; retrying", d.block)
		}
		hashes[d.block] = b.Hash
	}
	return sc.db.WithTx(ctx, func(tx *store.Tx) error {
		now := sc.clock.Now()
		seen := 0
		for _, d := range found {
			res, err := tx.ExecContext(ctx, `
				INSERT INTO deposits (tx_hash, log_index, block_number, block_hash, account_id, forwarder, asset, sender, amount, status, seen_at)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?) ON CONFLICT (tx_hash, log_index) DO NOTHING`,
				d.txHash.Hex(), d.index, d.block, d.blockHash.Hex(), d.account, d.log.To.Hex(), sc.cfg.Tokens[d.log.Token],
				d.log.From.Hex(), d.log.Amount.String(), now.UnixNano())
			if err != nil {
				return err
			}
			if n, _ := res.RowsAffected(); n == 1 {
				seen++
			}
		}
		for n, h := range hashes {
			if _, err := tx.ExecContext(ctx, `INSERT OR REPLACE INTO scanned_blocks (number, hash) VALUES (?, ?)`, n, h.Hex()); err != nil {
				return err
			}
		}
		if to > sc.cfg.KeepBlocks {
			// Forget old hashes, but keep the newest one at or below the window: it anchors the
			// fork search, so a reorg shallower than the confirmation depth always finds a
			// canonical block to rewind to, however many blocks one scan range covered.
			if _, err := tx.ExecContext(ctx, `DELETE FROM scanned_blocks WHERE number < (SELECT MAX(number) FROM scanned_blocks WHERE number <= ?)`,
				to-sc.cfg.KeepBlocks); err != nil {
				return err
			}
		}
		tx.OnCommit(func() { sc.metrics.DepositsSeen.Add(float64(seen)) })
		return store.SetMeta(ctx, tx, metaScanCursor, strconv.FormatUint(to, 10))
	})
}

type depositLog struct {
	log       chain.TransferLog
	account   string
	txHash    common.Hash
	index     uint
	block     uint64
	blockHash common.Hash
}

// credit books every pending deposit that reached the confirmation depth and is still canonical.
func (sc *Scanner) credit(ctx context.Context, head chain.BlockRef) error {
	if head.Number+1 < sc.cfg.Confirmations {
		return nil
	}
	maxBlock := head.Number + 1 - sc.cfg.Confirmations
	rows, err := sc.db.QueryContext(ctx, `SELECT tx_hash, log_index, block_number, block_hash, account_id, asset, amount FROM deposits
		WHERE status = 'pending' AND block_number <= ? ORDER BY block_number, log_index`, maxBlock)
	if err != nil {
		return err
	}
	type pending struct {
		tx, blockHash, account, asset, amount string
		index                                 int64
		block                                 uint64
	}
	var ps []pending
	for rows.Next() {
		var p pending
		if err := rows.Scan(&p.tx, &p.index, &p.block, &p.blockHash, &p.account, &p.asset, &p.amount); err != nil {
			rows.Close()
			return err
		}
		ps = append(ps, p)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, p := range ps {
		b, err := sc.chain.BlockByNumber(ctx, p.block)
		if err != nil && !errors.Is(err, chain.ErrNotFound) {
			return err
		}
		if err != nil || b.Hash != common.HexToHash(p.blockHash) {
			// A pending deposit at depth whose block is no longer canonical: a reorg the
			// cursor check did not see (or one racing this round). It is never credited, and
			// skipping it is not enough either: its re-inclusion may sit in a block the cursor
			// already passed. Rewind below it so that range is scanned again, and say so.
			sc.metrics.DepositsStale.Inc()
			sc.log.Warn("deposit: pending deposit at depth is in a block that is no longer canonical; rescanning from below it",
				"tx", p.tx, "log_index", p.index, "block", p.block)
			fork, anchor, err := sc.findFork(ctx, max(p.block, 1)-1)
			if err != nil {
				return err
			}
			// Every later row is above the fork point, so the rewind discards it with this one;
			// the rows before it were credited above.
			_, err = sc.rewind(ctx, fork, anchor)
			return err
		}
		amount, ok := new(big.Int).SetString(p.amount, 10)
		if !ok {
			return fmt.Errorf("deposit: corrupt amount %q", p.amount)
		}
		err = sc.db.WithTx(ctx, func(tx *store.Tx) error {
			now := sc.clock.Now()
			res, err := tx.ExecContext(ctx, `UPDATE deposits SET status = 'credited', credited_at = ? WHERE tx_hash = ? AND log_index = ? AND status = 'pending'`,
				now.UnixNano(), p.tx, p.index)
			if err != nil {
				return err
			}
			if n, _ := res.RowsAffected(); n == 0 {
				return nil
			}
			if _, err := ledger.Post(ctx, tx, ledger.Entry{
				Ref:  fmt.Sprintf("dep:%s:%d", p.tx, p.index),
				Kind: "deposit",
				Postings: []ledger.Posting{
					ledger.Debit(ledger.Forwarders, p.asset, amount),
					ledger.Credit(ledger.User(p.account), p.asset, amount),
				},
			}, now); err != nil {
				return err
			}
			tx.OnCommit(func() { sc.metrics.DepositsCredited.Inc() })
			return audit.Record(ctx, tx, now, audit.Event{Type: "deposit.credited", Actor: "engine", Subject: p.account,
				Data: map[string]any{"tx": p.tx, "log_index": p.index, "block": p.block, "asset": p.asset, "amount": p.amount}})
		})
		if err != nil {
			return err
		}
	}
	return nil
}

// Deposit is a detected deposit.
type Deposit struct {
	TxHash      string `json:"tx_hash"`
	LogIndex    int64  `json:"log_index"`
	BlockNumber uint64 `json:"block_number"`
	AccountID   string `json:"account_id"`
	Asset       string `json:"asset"`
	Amount      string `json:"amount"`
	Status      string `json:"status"`
	SweptBy     string `json:"swept_by,omitempty"`
}

// List returns the deposits of an account (all accounts when accountID is empty).
func List(ctx context.Context, q store.Querier, accountID string) ([]Deposit, error) {
	query := `SELECT tx_hash, log_index, block_number, account_id, asset, amount, status, COALESCE(swept_by, '') FROM deposits`
	args := []any{}
	if accountID != "" {
		query += ` WHERE account_id = ?`
		args = append(args, accountID)
	}
	rows, err := q.QueryContext(ctx, query+` ORDER BY block_number, log_index`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Deposit
	for rows.Next() {
		var d Deposit
		if err := rows.Scan(&d.TxHash, &d.LogIndex, &d.BlockNumber, &d.AccountID, &d.Asset, &d.Amount, &d.Status, &d.SweptBy); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}
