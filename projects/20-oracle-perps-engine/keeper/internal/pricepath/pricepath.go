// SPDX-License-Identifier: MIT

// Package pricepath loads the deterministic price-path fixtures written by the Python generator
// (contracts/test/fixtures/paths/*.json) and maps wall-clock time onto a path step.
package pricepath

import (
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"os"
	"time"
)

// Path is a sequence of WAD prices sampled every Step.
type Path struct {
	Name   string
	Step   time.Duration
	Prices []*big.Int
}

type document struct {
	Name      string   `json:"name"`
	DtSeconds int64    `json:"dtSeconds"`
	Prices    []string `json:"prices"`
}

// maxStepSeconds bounds the step so that step arithmetic cannot overflow time.Duration.
const maxStepSeconds = 365 * 24 * 3600

// ErrInvalidPath is returned for malformed or empty fixtures.
var ErrInvalidPath = errors.New("pricepath: invalid path")

// Load reads a fixture file.
func Load(file string) (*Path, error) {
	raw, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	return Parse(raw)
}

// Parse decodes a fixture document.
func Parse(raw []byte) (*Path, error) {
	var doc document
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidPath, err)
	}
	if doc.DtSeconds <= 0 || doc.DtSeconds > maxStepSeconds || len(doc.Prices) == 0 {
		return nil, fmt.Errorf("%w: needs 0 < dtSeconds <= %d and at least one price", ErrInvalidPath, maxStepSeconds)
	}
	p := &Path{Name: doc.Name, Step: time.Duration(doc.DtSeconds) * time.Second, Prices: make([]*big.Int, len(doc.Prices))}
	for i, s := range doc.Prices {
		v, ok := new(big.Int).SetString(s, 10)
		if !ok || v.Sign() <= 0 {
			return nil, fmt.Errorf("%w: price %d = %q", ErrInvalidPath, i, s)
		}
		p.Prices[i] = v
	}
	return p, nil
}

// WithStep returns a copy of the path replayed at a different speed (e.g. one step per second in demos).
func (p *Path) WithStep(step time.Duration) *Path {
	c := *p
	c.Step = step
	return &c
}

// Index is the step active at time now for a replay started at start, clamped to [0, len-1].
func (p *Path) Index(start, now time.Time) int {
	if !now.After(start) {
		return 0
	}
	i := int(now.Sub(start) / p.Step)
	if i >= len(p.Prices) {
		return len(p.Prices) - 1
	}
	return i
}

// PriceAt is the price active at time now (a copy the caller may modify).
func (p *Path) PriceAt(start, now time.Time) *big.Int {
	return new(big.Int).Set(p.Prices[p.Index(start, now)])
}

// ApplyBps shifts price by bps basis points (may be negative), truncating toward zero.
func ApplyBps(price *big.Int, bps int64) *big.Int {
	delta := new(big.Int).Mul(price, big.NewInt(bps))
	delta.Quo(delta, big.NewInt(10_000))
	return delta.Add(delta, price)
}
