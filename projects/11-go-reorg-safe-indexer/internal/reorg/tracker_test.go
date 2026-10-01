// SPDX-License-Identifier: MIT

package reorg

import (
	"context"
	"encoding/binary"
	"errors"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
)

// model is a ground-truth chain: the canonical headers plus every header ever produced (so the
// tracker can walk orphaned or new forks by hash, as it would on a real node).
type model struct {
	canon  []chain.Header
	byHash map[common.Hash]chain.Header
	fork   uint64
}

func newModel() *model {
	m := &model{byHash: map[common.Hash]chain.Header{}}
	m.push()
	return m
}

func (m *model) push() chain.Header {
	var parent common.Hash
	n := uint64(len(m.canon))
	if n > 0 {
		parent = m.canon[n-1].Hash
	}
	seed := binary.BigEndian.AppendUint64(append(parent[:0:0], parent[:]...), n)
	seed = binary.BigEndian.AppendUint64(seed, m.fork)
	h := chain.Header{Number: n, Hash: crypto.Keccak256Hash(seed), ParentHash: parent}
	m.canon = append(m.canon, h)
	m.byHash[h.Hash] = h
	return h
}

// reorg replaces the last depth blocks with replacement new ones (genesis is kept).
func (m *model) reorg(depth, replacement int) {
	depth = min(depth, len(m.canon)-1)
	m.canon = m.canon[:len(m.canon)-depth]
	m.fork++
	for range replacement {
		m.push()
	}
}

func (m *model) head() chain.Header { return m.canon[len(m.canon)-1] }

func (m *model) byHashFn(_ context.Context, h common.Hash) (chain.Header, error) {
	if hd, ok := m.byHash[h]; ok {
		return hd, nil
	}
	return chain.Header{}, chain.ErrNotFound
}

// sync drives the tracker to the model's head exactly like the engine does: classify the head,
// roll back forks, append canonical headers in chunks whose first header is checked. It returns
// false when a fork was (correctly) found beyond the window, which halts the engine.
func (m *model) sync(t testing.TB, tr *Tracker, chunk int) bool {
	t.Helper()
	for steps := 0; steps < 4*len(m.canon)+100; steps++ {
		head := m.head()
		switch tr.Check(head) {
		case Known, Untracked:
			return true
		case Forked:
			if !m.rollback(t, tr, head) {
				return false
			}
			continue
		}
		from := tr.Next()
		to := min(head.Number, from+uint64(chunk)-1)
		seg := m.canon[from : to+1]
		if tr.Check(seg[0]) == Forked {
			if !m.rollback(t, tr, seg[0]) {
				return false
			}
			continue
		}
		if err := tr.Append(seg); err != nil {
			t.Fatalf("append %d..%d: %v", from, to, err)
		}
	}
	t.Fatal("sync did not converge")
	return false
}

// rollback resolves a fork and checks the result against ground truth. It returns false when
// the fork is (correctly) beyond the window.
func (m *model) rollback(t testing.TB, tr *Tracker, h chain.Header) bool {
	t.Helper()
	tip, _ := tr.Tip()
	// Ground truth: the highest tracked block that is still canonical or, when none is, the
	// parent of the oldest tracked block if it is canonical (that block stores its hash, so a
	// fork exactly as deep as the window is still provable).
	var want *Block
	for _, b := range tr.Blocks() {
		if b.Number < uint64(len(m.canon)) && m.canon[b.Number].Hash == b.Hash {
			bb := b
			want = &bb
		}
	}
	belowWindow := false
	if oldest, ok := tr.Oldest(); ok && want == nil && oldest.Number > tr.Start() &&
		oldest.Number-1 < uint64(len(m.canon)) && m.canon[oldest.Number-1].Hash == oldest.Parent {
		b := FromHeader(m.canon[oldest.Number-1])
		want, belowWindow = &b, true
	}
	rb, err := tr.FindAncestor(context.Background(), h, m.byHashFn)
	if errors.Is(err, ErrBeyondWindow) {
		if want != nil || !tr.Pruned() {
			t.Fatalf("ErrBeyondWindow although ancestor %v is provable (pruned=%v)", want, tr.Pruned())
		}
		return false
	}
	if err != nil {
		t.Fatalf("FindAncestor: %v", err)
	}
	switch {
	case want == nil && rb.Ancestor != nil:
		t.Fatalf("ancestor %d found, ground truth has none", rb.Ancestor.Number)
	case want != nil && (rb.Ancestor == nil || *rb.Ancestor != *want):
		t.Fatalf("ancestor %+v, want %+v", rb.Ancestor, *want)
	case rb.OldTip != tip:
		t.Fatalf("old tip %+v, want %+v", rb.OldTip, tip)
	}
	if want != nil && (rb.From != want.Number+1 || rb.Depth != tip.Number-want.Number) {
		t.Fatalf("rollback from %d depth %d, want from %d depth %d", rb.From, rb.Depth, want.Number+1, tip.Number-want.Number)
	}
	if want == nil && (rb.From != tr.Start() || rb.Depth != tip.Number-tr.Start()+1) {
		t.Fatalf("full rollback from %d depth %d", rb.From, rb.Depth)
	}
	if (rb.AncestorHeader != nil) != belowWindow || (belowWindow && FromHeader(*rb.AncestorHeader) != *want) {
		t.Fatalf("ancestor header %+v, want one exactly when the ancestor is below the window (%v)", rb.AncestorHeader, belowWindow)
	}
	tr.Undo(rb)
	if want != nil {
		if got, ok := tr.Tip(); !ok || got != *want {
			t.Fatalf("tip after the rollback %+v, want the ancestor %+v", got, *want)
		}
	}
	return true
}

// checkInvariants verifies the tracker against the model after a sync.
func (m *model) checkInvariants(t testing.TB, tr *Tracker, window int) {
	t.Helper()
	blocks := tr.Blocks()
	if len(blocks) > window {
		t.Fatalf("tracker holds %d blocks, window %d", len(blocks), window)
	}
	for i := 1; i < len(blocks); i++ {
		if blocks[i].Number != blocks[i-1].Number+1 || blocks[i].Parent != blocks[i-1].Hash {
			t.Fatalf("tracked blocks %d and %d are not linked", blocks[i-1].Number, blocks[i].Number)
		}
	}
	head := m.head()
	tip, ok := tr.Tip()
	if !ok {
		if head.Number >= tr.Start() {
			t.Fatalf("empty tracker with head %d >= start %d", head.Number, tr.Start())
		}
		return
	}
	if head.Number >= tip.Number {
		if tip.Hash != head.Hash {
			t.Fatalf("tip %d/%x is not the head %d/%x", tip.Number, tip.Hash[:4], head.Number, head.Hash[:4])
		}
	}
	for _, b := range blocks {
		if b.Number <= head.Number && m.canon[b.Number].Hash != b.Hash {
			t.Fatalf("tracked block %d is not canonical", b.Number)
		}
	}
}

// FuzzReorgStateMachine drives a ground-truth chain through random extensions, reorgs of random
// depth (the new fork shorter, equal or longer), pure rollbacks, tracker restarts from its own
// persisted blocks, and syncs with random chunk sizes. After every sync the tracker must mirror
// the canonical chain, and every rollback must name the true common ancestor and depth, or
// report ErrBeyondWindow exactly when the fork point was pruned.
func FuzzReorgStateMachine(f *testing.F) {
	f.Add([]byte{0x00, 0x00, 0x05, 0x02, 0x09, 0x02, 0x03, 0x02})
	f.Add([]byte{0x02, 0x01, 0x0d, 0x0d, 0x02, 0x1d, 0x02, 0x3d, 0x02, 0x01, 0x02})
	f.Add([]byte{0x0e, 0x03, 0x0c, 0x0c, 0x0c, 0x02, 0x7d, 0x02, 0x03, 0x02, 0xfd, 0x02})
	f.Add([]byte{0x01, 0x00, 0x04, 0x02, 0x25, 0x02, 0x45, 0x02, 0x04, 0x02})
	f.Fuzz(func(t *testing.T, ops []byte) {
		if len(ops) < 2 {
			return
		}
		if len(ops) > 512 {
			ops = ops[:512] // longer inputs add run time, not new behaviour
		}
		window := 2 + int(ops[0]%15)
		start := uint64(ops[1] % 4)
		m := newModel()
		tr, err := NewTracker(start, window, nil, false)
		if err != nil {
			t.Fatal(err)
		}
		for _, b := range ops[2:] {
			switch b % 4 {
			case 0:
				for range 1 + int(b>>2)%4 {
					m.push()
				}
			case 1:
				depth := 1 + int(b>>2)%8
				replacement := max(0, depth-1+int(b>>5)%3)
				m.reorg(depth, replacement)
			case 2:
				chunk := 1 + int(b>>2)%5
				if !m.sync(t, tr, chunk) {
					return // the engine halts on ErrBeyondWindow; rollback() checked it was right
				}
				m.checkInvariants(t, tr, window)
			case 3:
				// Restart: rebuild from what the database would hold.
				blocks := tr.Blocks()
				if tr, err = NewTracker(start, window, blocks, tr.Pruned()); err != nil {
					t.Fatalf("restore: %v", err)
				}
			}
		}
		// Convergence: grow the chain past any stale tip, then sync.
		for range window + 2 {
			m.push()
		}
		if m.sync(t, tr, 3) {
			m.checkInvariants(t, tr, window)
		}
	})
}

func hdr(n uint64, hash, parent byte) chain.Header {
	return chain.Header{Number: n, Hash: common.Hash{hash}, ParentHash: common.Hash{parent}}
}

func TestNewTrackerValidation(t *testing.T) {
	linked := []Block{{Number: 5, Hash: common.Hash{5}, Parent: common.Hash{4}}, {Number: 6, Hash: common.Hash{6}, Parent: common.Hash{5}}}
	cases := []struct {
		name   string
		start  uint64
		window int
		blocks []Block
		pruned bool
		ok     bool
	}{
		{"empty", 0, 8, nil, false, true},
		{"window too small", 0, 1, nil, false, false},
		{"pruned but empty", 0, 8, nil, true, false},
		{"starts at start", 5, 8, linked, false, true},
		{"pruned above start", 1, 8, linked, true, true},
		{"gap below unpruned", 1, 8, linked, false, false},
		{"below start", 6, 8, linked, false, false},
		{"not linked", 5, 8, []Block{linked[0], {Number: 6, Hash: common.Hash{6}, Parent: common.Hash{9}}}, false, false},
		{"not contiguous", 5, 8, []Block{linked[0], {Number: 7, Hash: common.Hash{7}, Parent: common.Hash{5}}}, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := NewTracker(tc.start, tc.window, tc.blocks, tc.pruned)
			if (err == nil) != tc.ok {
				t.Fatalf("err = %v, want ok=%v", err, tc.ok)
			}
		})
	}
}

func TestTrackerCheckVerdicts(t *testing.T) {
	tr, err := NewTracker(10, 4, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	if v := tr.Check(hdr(12, 1, 0)); v != Ahead {
		t.Fatalf("empty tracker, block above start: %v", v)
	}
	if v := tr.Check(hdr(9, 1, 0)); v != Untracked {
		t.Fatalf("below start: %v", v)
	}
	if v := tr.Check(hdr(10, 10, 99)); v != Extends {
		t.Fatalf("start block on empty tracker: %v", v)
	}
	if err := tr.Append([]chain.Header{hdr(10, 10, 9), hdr(11, 11, 10), hdr(12, 12, 11)}); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		h    chain.Header
		want Verdict
	}{
		{hdr(13, 13, 12), Extends},
		{hdr(13, 13, 77), Forked},
		{hdr(14, 14, 13), Ahead},
		{hdr(12, 12, 11), Known},
		{hdr(11, 99, 10), Forked},
		{hdr(9, 9, 8), Untracked},
	}
	for _, tc := range cases {
		if got := tr.Check(tc.h); got != tc.want {
			t.Errorf("Check(%d/%x) = %v, want %v", tc.h.Number, tc.h.Hash[:1], got, tc.want)
		}
	}
	if err := tr.Append([]chain.Header{hdr(14, 14, 13)}); !errors.Is(err, ErrNotLinked) {
		t.Fatalf("append with a gap: %v", err)
	}
	// Pruning keeps the last `window` blocks and marks the tracker pruned.
	if err := tr.Append([]chain.Header{hdr(13, 13, 12), hdr(14, 14, 13)}); err != nil {
		t.Fatal(err)
	}
	if oldest, _ := tr.Oldest(); oldest.Number != 11 || !tr.Pruned() || tr.Len() != 4 {
		t.Fatalf("oldest %d pruned %v len %d", oldest.Number, tr.Pruned(), tr.Len())
	}
	if v := tr.Check(hdr(10, 10, 9)); v != Untracked {
		t.Fatalf("pruned block: %v", v)
	}
	// Verdicts appear in error messages ("segment 5..9 is ahead relative to the tip").
	names := map[Verdict]string{Extends: "extends", Known: "known", Ahead: "ahead", Forked: "forked", Untracked: "untracked", Verdict(42): "verdict(42)"}
	for v, want := range names {
		if got := v.String(); got != want {
			t.Errorf("Verdict(%d).String() = %q, want %q", int(v), got, want)
		}
	}
}

func TestFindAncestorErrors(t *testing.T) {
	ctx := context.Background()
	empty, _ := NewTracker(0, 4, nil, false)
	if _, err := empty.FindAncestor(ctx, hdr(1, 1, 0), nil); err == nil {
		t.Fatal("FindAncestor on an empty tracker must fail")
	}
	tr, _ := NewTracker(0, 8, nil, false)
	if err := tr.Append([]chain.Header{hdr(0, 1, 0), hdr(1, 2, 1), hdr(2, 3, 2)}); err != nil {
		t.Fatal(err)
	}
	if _, err := tr.FindAncestor(ctx, hdr(9, 9, 8), nil); err == nil {
		t.Fatal("header far above the tip must be rejected")
	}
	failing := func(context.Context, common.Hash) (chain.Header, error) {
		return chain.Header{}, errors.New("rpc down")
	}
	if _, err := tr.FindAncestor(ctx, hdr(3, 40, 30), failing); err == nil {
		t.Fatal("fetch error must propagate")
	}
	lying := func(_ context.Context, h common.Hash) (chain.Header, error) { return hdr(1, 77, 76), nil }
	if _, err := tr.FindAncestor(ctx, hdr(3, 40, 30), lying); err == nil {
		t.Fatal("a node answering with the wrong block must be rejected")
	}
	// A fork at the start block of an unpruned tracker rolls everything back.
	rb, err := tr.FindAncestor(ctx, hdr(0, 50, 0), nil)
	if err != nil || rb.Ancestor != nil || rb.From != 0 || rb.Depth != 3 {
		t.Fatalf("full rollback: %+v %v", rb, err)
	}
	tr.Rewind(rb.From)
	if tr.Len() != 0 || tr.Next() != 0 {
		t.Fatalf("after full rewind: len %d next %d", tr.Len(), tr.Next())
	}
	tr.Rewind(5) // no-op on an empty tracker
}

func TestFindAncestorBeyondPrunedWindow(t *testing.T) {
	tr, _ := NewTracker(0, 2, nil, false)
	if err := tr.Append([]chain.Header{hdr(0, 1, 0), hdr(1, 2, 1), hdr(2, 3, 2)}); err != nil {
		t.Fatal(err)
	}
	// Tracked: 1, 2 (pruned). A fork at block 1 needs block 0, which was pruned.
	fork := map[common.Hash]chain.Header{{0x41}: hdr(1, 0x41, 0x31)}
	byHash := func(_ context.Context, h common.Hash) (chain.Header, error) {
		if hd, ok := fork[h]; ok {
			return hd, nil
		}
		return chain.Header{}, chain.ErrNotFound
	}
	if _, err := tr.FindAncestor(context.Background(), hdr(2, 0x42, 0x41), byHash); !errors.Is(err, ErrBeyondWindow) {
		t.Fatalf("want ErrBeyondWindow, got %v", err)
	}
}

// TestFindAncestorAtTheWindowDepth: with a window of W headers, a fork exactly W blocks deep
// replaces every retained header, and its common ancestor is the parent of the oldest one,
// whose hash that header stores. It is resolved (not reported as beyond the window), the
// ancestor's header is fetched so the caller can store it again, and Undo leaves the tracker
// at the ancestor, ready to extend it. One block deeper is beyond the window.
func TestFindAncestorAtTheWindowDepth(t *testing.T) {
	ctx := context.Background()
	m := newModel()
	for range 20 {
		m.push()
	}
	const window = 4
	tr, err := NewTracker(1, window, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	if err := tr.Append(m.canon[1:]); err != nil {
		t.Fatal(err)
	}
	oldest, _ := tr.Oldest()
	if oldest.Number != 17 || !tr.Pruned() {
		t.Fatalf("tracking from %d (pruned %v), want 17..20", oldest.Number, tr.Pruned())
	}
	ancestor := m.canon[16]
	m.reorg(window, window+1) // replaces 17..20 with 17'..21'
	if v := tr.Check(m.head()); v != Forked {
		t.Fatalf("head verdict %v", v)
	}
	rb, err := tr.FindAncestor(ctx, m.head(), m.byHashFn)
	if err != nil {
		t.Fatalf("a reorg exactly as deep as the window: %v", err)
	}
	if rb.Ancestor == nil || *rb.Ancestor != FromHeader(ancestor) || rb.AncestorHeader == nil || *rb.AncestorHeader != ancestor ||
		rb.From != 17 || rb.Depth != window {
		t.Fatalf("rollback %+v, want ancestor 16, from 17, depth %d", rb, window)
	}
	tr.Undo(rb)
	if tip, _ := tr.Tip(); tr.Len() != 1 || tip != FromHeader(ancestor) || tr.Next() != 17 || !tr.Pruned() {
		t.Fatalf("after Undo: len %d tip %+v next %d pruned %v", tr.Len(), tip, tr.Next(), tr.Pruned())
	}
	if err := tr.Append(m.canon[17:]); err != nil {
		t.Fatalf("extending the ancestor with the new fork: %v", err)
	}
	// What a restart restores from the stored headers resolves the same way.
	if _, err := NewTracker(1, window, tr.Blocks(), tr.Pruned()); err != nil {
		t.Fatal(err)
	}

	// One block deeper: the fork point is the grandparent of the oldest header, which nothing
	// retained identifies.
	tip, _ := tr.Tip()
	m.reorg(window+1, window+2)
	if tip.Number != 21 || tr.Check(m.head()) != Forked {
		t.Fatalf("setup: tip %d, verdict %v", tip.Number, tr.Check(m.head()))
	}
	if _, err := tr.FindAncestor(ctx, m.head(), m.byHashFn); !errors.Is(err, ErrBeyondWindow) {
		t.Fatalf("a reorg one block deeper than the window: %v, want ErrBeyondWindow", err)
	}
}
