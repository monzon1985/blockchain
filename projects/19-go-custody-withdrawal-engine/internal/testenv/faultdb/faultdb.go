// SPDX-License-Identifier: MIT

// Package faultdb injects storage failures into the engine's SQLite connection for tests.
//
// An Injector wraps the physical database/sql driver connection (see store.Options.WrapConn)
// and numbers every operation that reaches the database while it is counting: BEGIN, each
// statement (exec or query), and COMMIT. A test first records how many operations a workload
// performs, then replays the workload once per operation index with exactly that operation
// failing, and checks that the engine converges to a correct state anyway. This is the same
// idea as SQLite's own I/O-error tests, applied one layer up.
//
// Two failure modes exist:
//
//   - Fail: the operation is not applied and returns ErrInjected. A failed COMMIT rolls the
//     transaction back first, so nothing it wrote survives.
//   - AmbiguousCommit (commits only): the transaction commits durably and the caller is still
//     told it failed. This is the "outcome unknown" case every client of a database has to
//     survive: the work is done, but the code that asked for it believes it is not.
package faultdb

import (
	"context"
	"database/sql/driver"
	"errors"
	"fmt"
	"sync"
)

// ErrInjected is returned by every injected failure.
var ErrInjected = errors.New("faultdb: injected storage failure")

// Mode selects how the chosen operation fails.
type Mode int

// Failure modes.
const (
	// Fail makes the operation fail without being applied.
	Fail Mode = iota
	// AmbiguousCommit makes a COMMIT succeed but report ErrInjected.
	AmbiguousCommit
)

func (m Mode) String() string {
	if m == AmbiguousCommit {
		return "ambiguous-commit"
	}
	return "fail"
}

// Operation kinds.
const (
	KindBegin  = "begin"
	KindExec   = "exec"
	KindQuery  = "query"
	KindCommit = "commit"
)

// Op is one counted database operation.
type Op struct {
	Index int    // 1-based position in the counted sequence
	Kind  string // KindBegin, KindExec, KindQuery or KindCommit
	Query string // the SQL text for exec and query operations
}

func (o Op) String() string {
	if o.Query == "" {
		return fmt.Sprintf("#%d %s", o.Index, o.Kind)
	}
	return fmt.Sprintf("#%d %s %.90q", o.Index, o.Kind, o.Query)
}

// Injector counts operations and fails the chosen one. The zero value counts nothing until
// Start is called. It is safe for concurrent use.
type Injector struct {
	mu       sync.Mutex
	counting bool
	n        int
	target   int
	mode     Mode
	fired    *Op
	ops      []Op
}

// FailAt arms the injector to fail the k-th counted operation (1-based) in mode m. k = 0
// disarms it. With AmbiguousCommit, an operation at index k that is not a COMMIT is left alone.
func (in *Injector) FailAt(k int, m Mode) {
	in.mu.Lock()
	defer in.mu.Unlock()
	in.target, in.mode = k, m
}

// Start begins (or resumes) counting operations.
func (in *Injector) Start() {
	in.mu.Lock()
	defer in.mu.Unlock()
	in.counting = true
}

// Stop stops counting; no further operation can fail.
func (in *Injector) Stop() {
	in.mu.Lock()
	defer in.mu.Unlock()
	in.counting = false
}

// Ops returns the operations counted so far.
func (in *Injector) Ops() []Op {
	in.mu.Lock()
	defer in.mu.Unlock()
	return append([]Op(nil), in.ops...)
}

// Fired returns the operation that was failed, if any.
func (in *Injector) Fired() (Op, bool) {
	in.mu.Lock()
	defer in.mu.Unlock()
	if in.fired == nil {
		return Op{}, false
	}
	return *in.fired, true
}

// next counts an operation and reports whether it must fail, and how.
func (in *Injector) next(kind, query string) (bool, Mode) {
	in.mu.Lock()
	defer in.mu.Unlock()
	if !in.counting {
		return false, Fail
	}
	in.n++
	op := Op{Index: in.n, Kind: kind, Query: query}
	in.ops = append(in.ops, op)
	if in.n != in.target || in.fired != nil {
		return false, Fail
	}
	if in.mode == AmbiguousCommit && kind != KindCommit {
		return false, Fail
	}
	in.fired = &op
	return true, in.mode
}

// Wrap interposes the injector on a driver connection. It is meant for store.Options.WrapConn.
func (in *Injector) Wrap(c driver.Conn) driver.Conn { return &conn{c: c, in: in} }

// conn forwards to the real connection, consulting the injector first. It implements the
// context-aware interfaces database/sql prefers, so every statement goes through it.
type conn struct {
	c  driver.Conn
	in *Injector
}

var (
	_ driver.Conn               = (*conn)(nil)
	_ driver.ConnBeginTx        = (*conn)(nil)
	_ driver.ConnPrepareContext = (*conn)(nil)
	_ driver.ExecerContext      = (*conn)(nil)
	_ driver.QueryerContext     = (*conn)(nil)
	_ driver.Pinger             = (*conn)(nil)
	_ driver.SessionResetter    = (*conn)(nil)
	_ driver.Validator          = (*conn)(nil)
)

func (c *conn) Prepare(query string) (driver.Stmt, error) {
	return c.PrepareContext(context.Background(), query)
}

func (c *conn) PrepareContext(ctx context.Context, query string) (driver.Stmt, error) {
	if p, ok := c.c.(driver.ConnPrepareContext); ok {
		return p.PrepareContext(ctx, query)
	}
	return c.c.Prepare(query)
}

func (c *conn) Close() error { return c.c.Close() }

// Begin is the legacy entry point; database/sql uses BeginTx.
func (c *conn) Begin() (driver.Tx, error) {
	return c.BeginTx(context.Background(), driver.TxOptions{})
}

func (c *conn) BeginTx(ctx context.Context, opts driver.TxOptions) (driver.Tx, error) {
	if fail, _ := c.in.next(KindBegin, ""); fail {
		return nil, ErrInjected
	}
	b, ok := c.c.(driver.ConnBeginTx)
	if !ok {
		return nil, errors.New("faultdb: wrapped connection does not implement ConnBeginTx")
	}
	t, err := b.BeginTx(ctx, opts)
	if err != nil {
		return nil, err
	}
	return &tx{t: t, in: c.in}, nil
}

func (c *conn) ExecContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	if fail, _ := c.in.next(KindExec, query); fail {
		return nil, ErrInjected
	}
	e, ok := c.c.(driver.ExecerContext)
	if !ok {
		return nil, driver.ErrSkip
	}
	return e.ExecContext(ctx, query, args)
}

func (c *conn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	if fail, _ := c.in.next(KindQuery, query); fail {
		return nil, ErrInjected
	}
	q, ok := c.c.(driver.QueryerContext)
	if !ok {
		return nil, driver.ErrSkip
	}
	return q.QueryContext(ctx, query, args)
}

func (c *conn) Ping(ctx context.Context) error {
	if p, ok := c.c.(driver.Pinger); ok {
		return p.Ping(ctx)
	}
	return nil
}

func (c *conn) ResetSession(ctx context.Context) error {
	if r, ok := c.c.(driver.SessionResetter); ok {
		return r.ResetSession(ctx)
	}
	return nil
}

func (c *conn) IsValid() bool {
	if v, ok := c.c.(driver.Validator); ok {
		return v.IsValid()
	}
	return true
}

// tx wraps a driver transaction so COMMIT can fail.
type tx struct {
	t  driver.Tx
	in *Injector
}

func (t *tx) Commit() error {
	fail, mode := t.in.next(KindCommit, "")
	if !fail {
		return t.t.Commit()
	}
	if mode == AmbiguousCommit {
		if err := t.t.Commit(); err != nil {
			return err
		}
		return ErrInjected
	}
	_ = t.t.Rollback()
	return ErrInjected
}

func (t *tx) Rollback() error { return t.t.Rollback() }
