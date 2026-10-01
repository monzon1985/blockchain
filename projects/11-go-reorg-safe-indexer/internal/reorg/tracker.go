// SPDX-License-Identifier: MIT

// Package reorg is the indexer's fork-choice bookkeeping: an in-memory mirror of the most recent
// indexed headers (number, hash, parent hash) that classifies every header the node reports
// and, on a fork, walks the new chain back by parent hash to the common ancestor.
//
// The package is pure: it performs no I/O except through the HeaderByHash callback passed to
// FindAncestor, which is what makes FuzzReorgStateMachine cheap enough to run millions of steps.
package reorg

import (
	"context"
	"errors"
	"fmt"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
)

// ErrBeyondWindow means the fork point lies below the retained headers and below the parent of
// the oldest one (whose hash that header stores), so the indexer cannot prove where the chains
// diverge. With a window of W headers, every reorg up to W blocks deep is resolved; a deeper one
// needs an operator (`indexer verify`, then a reindex) or a larger --reorg-window.
var ErrBeyondWindow = errors.New("reorg: fork point is below the retained header window")

// ErrNotLinked means Append was given headers that do not extend the tracked tip.
var ErrNotLinked = errors.New("reorg: headers do not link to the tracked tip")

// Block is one tracked header link.
type Block struct {
	Number uint64
	Hash   common.Hash
	Parent common.Hash
}

// FromHeader converts a chain header into a tracked block.
func FromHeader(h chain.Header) Block {
	return Block{Number: h.Number, Hash: h.Hash, Parent: h.ParentHash}
}

// Ref returns the block reference.
func (b Block) Ref() chain.BlockRef { return chain.BlockRef{Number: b.Number, Hash: b.Hash} }

// Verdict classifies a canonical header reported by the node against the tracked chain.
type Verdict int

const (
	// Extends means the header is the next block and links to the tracked tip.
	Extends Verdict = iota + 1
	// Known means the header is already tracked with the same hash (in sync, or a lagging node).
	Known
	// Ahead means the header is above the next expected block; fetch from Next() first.
	Ahead
	// Forked means the header proves the tracked chain is no longer canonical.
	Forked
	// Untracked means the header is below the retained window, so it cannot be judged. The
	// indexer treats it like a lagging node and waits.
	Untracked
)

func (v Verdict) String() string {
	switch v {
	case Extends:
		return "extends"
	case Known:
		return "known"
	case Ahead:
		return "ahead"
	case Forked:
		return "forked"
	case Untracked:
		return "untracked"
	default:
		return fmt.Sprintf("verdict(%d)", int(v))
	}
}

// Rollback describes how to undo a fork: drop every indexed block with number >= From. Ancestor
// is the last block both chains share, nil when the fork reaches below the first indexed block.
type Rollback struct {
	Ancestor *Block
	// AncestorHeader is set when the ancestor is the parent of the oldest retained header: the
	// fork is exactly as deep as the window, and the ancestor itself is no longer stored. It is
	// the node's header for it, which the caller stores again so that the rolled-back checkpoint
	// still points at a stored header.
	AncestorHeader *chain.Header
	From           uint64
	Depth          uint64
	OldTip         Block
}

// Tracker mirrors the most recent indexed headers. It is not safe for concurrent use; the
// indexer's single commit loop owns it.
type Tracker struct {
	start  uint64
	window int
	blocks []Block // ascending, contiguous and parent-linked
	pruned bool    // blocks below blocks[0] were indexed and then forgotten
}

// NewTracker restores a tracker. start is the first block the indexer indexes, window the
// number of headers retained, recent the stored headers (ascending, at most window of them),
// and pruned whether indexed blocks exist below recent[0].
func NewTracker(start uint64, window int, recent []Block, pruned bool) (*Tracker, error) {
	if window < 2 {
		return nil, fmt.Errorf("reorg: window %d is too small (minimum 2)", window)
	}
	t := &Tracker{start: start, window: window, pruned: pruned}
	if len(recent) == 0 {
		if pruned {
			return nil, errors.New("reorg: pruned tracker without blocks")
		}
		return t, nil
	}
	if recent[0].Number < start {
		return nil, fmt.Errorf("reorg: stored block %d is below the start block %d", recent[0].Number, start)
	}
	if !pruned && recent[0].Number != start {
		return nil, fmt.Errorf("reorg: first stored block %d is not the start block %d", recent[0].Number, start)
	}
	for i := 1; i < len(recent); i++ {
		if recent[i].Number != recent[i-1].Number+1 || recent[i].Parent != recent[i-1].Hash {
			return nil, fmt.Errorf("reorg: stored blocks %d and %d are not linked", recent[i-1].Number, recent[i].Number)
		}
	}
	t.blocks = append(t.blocks, recent...)
	t.prune()
	return t, nil
}

// Start returns the first block number the indexer indexes.
func (t *Tracker) Start() uint64 { return t.start }

// Len returns the number of tracked blocks.
func (t *Tracker) Len() int { return len(t.blocks) }

// Pruned reports whether indexed blocks exist below the retained window.
func (t *Tracker) Pruned() bool { return t.pruned }

// Blocks returns a copy of the tracked blocks, ascending.
func (t *Tracker) Blocks() []Block { return append([]Block(nil), t.blocks...) }

// Tip returns the last tracked block.
func (t *Tracker) Tip() (Block, bool) {
	if len(t.blocks) == 0 {
		return Block{}, false
	}
	return t.blocks[len(t.blocks)-1], true
}

// Oldest returns the first retained block.
func (t *Tracker) Oldest() (Block, bool) {
	if len(t.blocks) == 0 {
		return Block{}, false
	}
	return t.blocks[0], true
}

// Next returns the number of the next block to index.
func (t *Tracker) Next() uint64 {
	if tip, ok := t.Tip(); ok {
		return tip.Number + 1
	}
	return t.start
}

// At returns the tracked block at number n.
func (t *Tracker) At(n uint64) (Block, bool) {
	if len(t.blocks) == 0 || n < t.blocks[0].Number || n > t.blocks[len(t.blocks)-1].Number {
		return Block{}, false
	}
	return t.blocks[n-t.blocks[0].Number], true
}

// Check classifies a canonical header reported by the node.
func (t *Tracker) Check(h chain.Header) Verdict {
	next := t.Next()
	switch {
	case h.Number > next:
		return Ahead
	case h.Number == next:
		tip, ok := t.Tip()
		if !ok || h.ParentHash == tip.Hash {
			return Extends
		}
		return Forked
	case h.Number < t.start:
		// Below the indexed range: nothing to compare against.
		return Untracked
	}
	b, ok := t.At(h.Number)
	if !ok {
		return Untracked
	}
	if b.Hash == h.Hash {
		return Known
	}
	return Forked
}

// HeaderByHash fetches a header on the node's current chain (canonical or side chain).
type HeaderByHash func(ctx context.Context, hash common.Hash) (chain.Header, error)

// FindAncestor walks the new chain back from h, a header for which Check returned Forked,
// following parent hashes (never numbers, which could change under a concurrent reorg) until
// it reaches a tracked block. It does not modify the tracker.
func (t *Tracker) FindAncestor(ctx context.Context, h chain.Header, byHash HeaderByHash) (Rollback, error) {
	tip, ok := t.Tip()
	if !ok {
		return Rollback{}, errors.New("reorg: FindAncestor on an empty tracker")
	}
	if h.Number > tip.Number+1 {
		return Rollback{}, fmt.Errorf("reorg: header %d is above the next block %d", h.Number, tip.Number+1)
	}
	cur := h
	// Every iteration moves one block down, so the loop is bounded by the window.
	for steps := 0; ; steps++ {
		if steps > t.window+1 {
			return Rollback{}, ErrBeyondWindow
		}
		if cur.Number <= t.start {
			// The fork reaches the first indexed block itself.
			if t.pruned {
				return Rollback{}, ErrBeyondWindow
			}
			return Rollback{Ancestor: nil, From: t.start, Depth: tip.Number - t.start + 1, OldTip: tip}, nil
		}
		parent := cur.Number - 1
		if b, tracked := t.At(parent); tracked {
			if b.Hash == cur.ParentHash {
				anc := b
				return Rollback{Ancestor: &anc, From: parent + 1, Depth: tip.Number - parent, OldTip: tip}, nil
			}
		} else if oldest := t.blocks[0]; parent < oldest.Number {
			// Below the retained headers, one block is still provable: the parent of the oldest
			// one, whose hash that header stores. Anything deeper is beyond the window.
			if parent+1 != oldest.Number || cur.ParentHash != oldest.Parent {
				return Rollback{}, ErrBeyondWindow
			}
			h, err := parentOf(ctx, cur, byHash)
			if err != nil {
				return Rollback{}, err
			}
			anc := FromHeader(h)
			return Rollback{Ancestor: &anc, AncestorHeader: &h, From: oldest.Number, Depth: tip.Number - parent, OldTip: tip}, nil
		}
		next, err := parentOf(ctx, cur, byHash)
		if err != nil {
			return Rollback{}, err
		}
		cur = next
	}
}

// parentOf fetches the parent of cur by hash and checks the node answered with that block.
func parentOf(ctx context.Context, cur chain.Header, byHash HeaderByHash) (chain.Header, error) {
	next, err := byHash(ctx, cur.ParentHash)
	if err != nil {
		return chain.Header{}, fmt.Errorf("reorg: fetch parent %s of block %d: %w", cur.ParentHash.TerminalString(), cur.Number, err)
	}
	if next.Hash != cur.ParentHash || next.Number+1 != cur.Number {
		return chain.Header{}, fmt.Errorf("reorg: node returned block %d/%s for parent %s of block %d",
			next.Number, next.Hash.TerminalString(), cur.ParentHash.TerminalString(), cur.Number)
	}
	return next, nil
}

// Undo applies a rollback found by FindAncestor: it drops every tracked block with number >=
// rb.From and, when the ancestor was the parent of the oldest retained block, tracks that
// ancestor as the new tip.
func (t *Tracker) Undo(rb Rollback) {
	t.Rewind(rb.From)
	if len(t.blocks) == 0 && rb.AncestorHeader != nil {
		t.blocks = append(t.blocks, FromHeader(*rb.AncestorHeader))
	}
	if len(t.blocks) > 0 {
		t.pruned = t.blocks[0].Number > t.start
	}
}

// Rewind drops every tracked block with number >= from.
func (t *Tracker) Rewind(from uint64) {
	if len(t.blocks) == 0 || from > t.blocks[len(t.blocks)-1].Number {
		return
	}
	if from <= t.blocks[0].Number {
		t.blocks = t.blocks[:0]
		return
	}
	t.blocks = t.blocks[:from-t.blocks[0].Number]
}

// Append extends the tracked chain with contiguous, linked headers.
func (t *Tracker) Append(headers []chain.Header) error {
	for _, h := range headers {
		if v := t.Check(h); v != Extends {
			return fmt.Errorf("%w: block %d is %s", ErrNotLinked, h.Number, v)
		}
		t.blocks = append(t.blocks, FromHeader(h))
	}
	t.prune()
	return nil
}

func (t *Tracker) prune() {
	if extra := len(t.blocks) - t.window; extra > 0 {
		t.blocks = append(t.blocks[:0], t.blocks[extra:]...)
		t.pruned = true
	}
}
