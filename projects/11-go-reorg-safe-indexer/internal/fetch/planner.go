// SPDX-License-Identifier: MIT

package fetch

import "sync"

// Planner adapts the eth_getLogs block span to what the provider accepts: it halves on "too
// many results" or a timeout and doubles after a success at (or above half) the current span.
// It is shared by concurrent fetch workers and safe for concurrent use.
type Planner struct {
	mu      sync.Mutex
	span    uint64
	maxSpan uint64
}

// NewPlanner starts at initial blocks per query and never exceeds maxSpan.
func NewPlanner(initial, maxSpan uint64) *Planner {
	maxSpan = max(maxSpan, 1)
	return &Planner{span: min(max(initial, 1), maxSpan), maxSpan: maxSpan}
}

// Span returns the current span.
func (p *Planner) Span() uint64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.span
}

// Next returns the end of the next range starting at from, capped at limit (from <= limit).
func (p *Planner) Next(from, limit uint64) uint64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	if limit-from < p.span {
		return limit
	}
	return from + p.span - 1
}

// Succeeded records that a query over span blocks worked. Successes on ranges much smaller
// than the current span (the tail of a range, a split half) carry no information and are
// ignored, so a burst of small queries neither shrinks nor overgrows the span.
func (p *Planner) Succeeded(span uint64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if grown := span * 2; grown > p.span {
		p.span = min(grown, p.maxSpan)
	}
}

// TooLarge records that a query over span blocks was rejected; the span drops to half of it.
func (p *Planner) TooLarge(span uint64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if half := max(span/2, 1); half < p.span {
		p.span = half
	}
}
