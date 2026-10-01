// SPDX-License-Identifier: MIT

// Package audit records security-relevant events and ships them to an append-only, hash-chained
// JSONL file.
//
// Events are written to the audit_events table inside the same database transaction as the
// state change they describe (transactional outbox), so the audit trail can never disagree with
// the database: a crash either loses both or neither. A shipper copies committed events to the
// JSONL file in sequence order. Each line carries the SHA-256 of the previous line, so deleting,
// reordering or editing a line breaks the chain, which Verify detects. The chain is not keyed:
// lines cut from the end, or a file rewritten with a recomputed chain, are only detected by
// comparing the file with the database (VerifyAgainst, custodyd audit-verify -db).
package audit

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

// Genesis is the "previous hash" of the first line.
const Genesis = "0000000000000000000000000000000000000000000000000000000000000000"

// Event is one audit record.
type Event struct {
	Type    string         // e.g. withdrawal.transition, approval.recorded, reconciliation.mismatch
	Actor   string         // client id, approver id or "engine"
	Subject string         // the object acted on (withdrawal id, account id, ...)
	Data    map[string]any // event-specific details
}

// Record writes e in the caller's transaction.
func Record(ctx context.Context, tx store.Querier, at time.Time, e Event) error {
	data := e.Data
	if data == nil {
		data = map[string]any{}
	}
	blob, err := json.Marshal(data)
	if err != nil {
		return fmt.Errorf("audit: encode data: %w", err)
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO audit_events (at, type, actor, subject, data) VALUES (?, ?, ?, ?, ?)`,
		at.UnixNano(), e.Type, e.Actor, e.Subject, string(blob))
	if err != nil {
		return fmt.Errorf("audit: insert: %w", err)
	}
	return nil
}

// Line is the JSONL representation. Field order is fixed by the struct, which makes the
// hashed bytes canonical.
type Line struct {
	Seq     int64           `json:"seq"`
	At      string          `json:"at"`
	Type    string          `json:"type"`
	Actor   string          `json:"actor"`
	Subject string          `json:"subject"`
	Data    json.RawMessage `json:"data"`
	Prev    string          `json:"prev"`
	Hash    string          `json:"hash"`
}

// hashLine computes the hash of l with Hash cleared.
func hashLine(l Line) (string, error) {
	l.Hash = ""
	b, err := json.Marshal(l)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:]), nil
}

// Shipper appends committed events to the JSONL file.
type Shipper struct {
	db       *store.DB
	path     string
	log      *slog.Logger
	failures prometheus.Counter

	mu       sync.Mutex
	lastSeq  int64
	lastHash string
	loaded   bool
}

// NewShipper returns a shipper writing to path. failures (optional) counts failed rounds,
// including a shipper refusing to append to a damaged or divergent file.
func NewShipper(db *store.DB, path string, log *slog.Logger, failures prometheus.Counter) *Shipper {
	return &Shipper{db: db, path: path, log: log, failures: failures}
}

// load reads the file to find where shipping stopped, and checks it before anything is appended
// to it. Every complete line must parse and chain from the previous one, and the last one must
// be the database's event with the same sequence number. The only damage repaired is a final
// line without its newline (a crash in the middle of a write): it is truncated away and that
// event, still in the database, is shipped again. Anything else (a corrupt or edited line, a
// broken chain, a file ahead of the database or different from it) is refused on every round
// until an operator restores the file: appending a fresh chain to a damaged log would bury the
// damage, and replacing its history with the database's would erase the evidence.
func (s *Shipper) load(ctx context.Context) error {
	f, err := os.OpenFile(s.path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return fmt.Errorf("audit: open %s: %w", s.path, err)
	}
	defer f.Close()
	content, err := io.ReadAll(f)
	if err != nil {
		return fmt.Errorf("audit: read %s: %w", s.path, err)
	}
	complete := content[:bytes.LastIndexByte(content, '\n')+1]
	res, last, err := verify(bytes.NewReader(complete), nil)
	if err != nil {
		return fmt.Errorf("audit: %s does not verify, refusing to append to it (run custodyd audit-verify): %w", s.path, err)
	}
	if res.Lines > 0 {
		var want Line
		row := s.db.QueryRowContext(ctx, `SELECT seq, at, type, actor, subject, data FROM audit_events WHERE seq = ?`, last.Seq)
		if err := scanEvent(row, &want); errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("audit: %s ends at sequence %d, which the database does not have (restored from an older backup?); refusing to append", s.path, last.Seq)
		} else if err != nil {
			return fmt.Errorf("audit: load: %w", err)
		}
		if !sameEvent(last, want) {
			return fmt.Errorf("audit: the last line of %s (sequence %d) differs from the database's event; refusing to append", s.path, last.Seq)
		}
	}
	if len(complete) != len(content) {
		s.log.Warn("audit: truncating a torn final line", "path", s.path, "bytes", len(content)-len(complete))
		if err := f.Truncate(int64(len(complete))); err != nil {
			return fmt.Errorf("audit: truncate: %w", err)
		}
	}
	s.lastSeq, s.lastHash = res.LastSeq, Genesis
	if res.Lines > 0 {
		s.lastHash = last.Hash
	}
	s.loaded = true
	return nil
}

// scanEvent reads one audit_events row into l (without prev and hash).
func scanEvent(row interface{ Scan(...any) error }, l *Line) error {
	var at int64
	var data string
	if err := row.Scan(&l.Seq, &at, &l.Type, &l.Actor, &l.Subject, &data); err != nil {
		return err
	}
	l.At = time.Unix(0, at).UTC().Format(time.RFC3339Nano)
	l.Data = json.RawMessage(data)
	return nil
}

// sameEvent compares the content of a shipped line with a database event.
func sameEvent(a, b Line) bool {
	if a.Seq != b.Seq || a.At != b.At || a.Type != b.Type || a.Actor != b.Actor || a.Subject != b.Subject {
		return false
	}
	var ca, cb bytes.Buffer
	if json.Compact(&ca, a.Data) != nil || json.Compact(&cb, b.Data) != nil {
		return false
	}
	return bytes.Equal(ca.Bytes(), cb.Bytes())
}

// Ship appends every committed event not yet in the file and fsyncs. It returns the number of
// lines written.
func (s *Shipper) Ship(ctx context.Context) (n int, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	defer func() {
		if err != nil && s.failures != nil && !errors.Is(err, context.Canceled) {
			s.failures.Inc()
		}
	}()
	if !s.loaded {
		if err := s.load(ctx); err != nil {
			return 0, err
		}
	}
	rows, err := s.db.QueryContext(ctx, `SELECT seq, at, type, actor, subject, data FROM audit_events WHERE seq > ? ORDER BY seq LIMIT 1000`, s.lastSeq)
	if err != nil {
		return 0, fmt.Errorf("audit: query: %w", err)
	}
	var lines []Line
	for rows.Next() {
		var l Line
		if err := scanEvent(rows, &l); err != nil {
			rows.Close()
			return 0, err
		}
		lines = append(lines, l)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}
	if len(lines) == 0 {
		return 0, nil
	}
	f, err := os.OpenFile(s.path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return 0, fmt.Errorf("audit: open for append: %w", err)
	}
	defer f.Close()
	w := bufio.NewWriter(f)
	prev := s.lastHash
	for i := range lines {
		lines[i].Prev = prev
		h, err := hashLine(lines[i])
		if err != nil {
			return 0, err
		}
		lines[i].Hash = h
		b, err := json.Marshal(lines[i])
		if err != nil {
			return 0, err
		}
		w.Write(b)
		w.WriteByte('\n')
		prev = h
	}
	if err := w.Flush(); err != nil {
		return 0, fmt.Errorf("audit: write: %w", err)
	}
	if err := f.Sync(); err != nil {
		return 0, fmt.Errorf("audit: fsync: %w", err)
	}
	s.lastSeq, s.lastHash = lines[len(lines)-1].Seq, prev
	return len(lines), nil
}

// Run ships every interval until ctx is cancelled, then ships once more.
func (s *Shipper) Run(ctx context.Context, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			if _, err := s.Ship(context.WithoutCancel(ctx)); err != nil {
				s.log.Error("audit: final ship failed", "err", err)
			}
			return
		case <-t.C:
			if _, err := s.Ship(ctx); err != nil && !errors.Is(err, context.Canceled) {
				s.log.Error("audit: ship failed", "err", err)
			}
		}
	}
}

// VerifyResult summarises a chain verification.
type VerifyResult struct {
	Lines   int
	LastSeq int64
	// DatabaseChecked is set by VerifyAgainst: every line matched the database's event with the
	// same sequence number, and the file holds every event the database has.
	DatabaseChecked bool
}

// Verify re-hashes every line of r and checks the chain and the sequence numbers. It detects an
// edited, deleted, inserted or reordered line, but on its own it cannot detect lines deleted at
// the end of the file, or a file rewritten from scratch with a recomputed chain (the chain is
// not keyed); VerifyAgainst anchors the file to the database for that.
func Verify(r io.Reader) (VerifyResult, error) {
	res, _, err := verify(r, nil)
	return res, err
}

// VerifyAgainst is Verify plus a comparison with the database: the file's lines must be exactly
// the database's audit events, in order, with the same content, and none may be missing at the
// end. Run it with custodyd stopped, or allow for events committed within the last ship
// interval, which are legitimately not in the file yet. It cannot catch an attacker who rewrites
// the database and the file consistently; anchoring periodic checkpoints in a separate trust
// domain (write-once storage, or a signed checkpoint published elsewhere) is the next step.
func VerifyAgainst(ctx context.Context, r io.Reader, q store.Querier) (VerifyResult, error) {
	rows, err := q.QueryContext(ctx, `SELECT seq, at, type, actor, subject, data FROM audit_events ORDER BY seq`)
	if err != nil {
		return VerifyResult{}, fmt.Errorf("audit: read events: %w", err)
	}
	defer rows.Close()
	next := func() (Line, bool, error) {
		if !rows.Next() {
			return Line{}, false, rows.Err()
		}
		var l Line
		err := scanEvent(rows, &l)
		return l, err == nil, err
	}
	res, _, err := verify(r, func(l Line) error {
		want, ok, err := next()
		if err != nil {
			return err
		}
		if !ok {
			return fmt.Errorf("sequence %d is not in the database", l.Seq)
		}
		if want.Seq != l.Seq {
			return fmt.Errorf("the database's next event is %d, the file has %d (lines deleted or inserted)", want.Seq, l.Seq)
		}
		if !sameEvent(l, want) {
			return fmt.Errorf("sequence %d differs from the database's event", l.Seq)
		}
		return nil
	})
	if err != nil {
		return res, err
	}
	extra, ok, err := next()
	if err != nil {
		return res, err
	}
	if ok {
		last := extra.Seq
		for {
			l, more, err := next()
			if err != nil {
				return res, err
			}
			if !more {
				break
			}
			last = l.Seq
		}
		return res, fmt.Errorf("audit: the file ends at sequence %d but the database has events %d to %d (deleted from the file, or not shipped yet)",
			res.LastSeq, extra.Seq, last)
	}
	res.DatabaseChecked = true
	return res, nil
}

// verify checks the chain of r line by line, calls each (when set) for every line, and returns
// the last line.
func verify(r io.Reader, each func(Line) error) (VerifyResult, Line, error) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	prev := Genesis
	var res VerifyResult
	var last Line
	for sc.Scan() {
		raw := strings.TrimSpace(sc.Text())
		if raw == "" {
			continue
		}
		var l Line
		if err := json.Unmarshal([]byte(raw), &l); err != nil {
			return res, last, fmt.Errorf("audit: line %d: %w", res.Lines+1, err)
		}
		if l.Prev != prev {
			return res, last, fmt.Errorf("audit: line %d (seq %d): prev hash does not match the previous line", res.Lines+1, l.Seq)
		}
		h, err := hashLine(l)
		if err != nil {
			return res, last, err
		}
		if h != l.Hash {
			return res, last, fmt.Errorf("audit: line %d (seq %d): content does not match its hash", res.Lines+1, l.Seq)
		}
		if l.Seq <= res.LastSeq {
			return res, last, fmt.Errorf("audit: line %d: sequence %d is not increasing", res.Lines+1, l.Seq)
		}
		if each != nil {
			if err := each(l); err != nil {
				return res, last, fmt.Errorf("audit: line %d: %w", res.Lines+1, err)
			}
		}
		prev = h
		last = l
		res.LastSeq = l.Seq
		res.Lines++
	}
	return res, last, sc.Err()
}
