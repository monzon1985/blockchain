// SPDX-License-Identifier: MIT

package pricepath

import (
	"errors"
	"math/big"
	"path/filepath"
	"testing"
	"time"
)

func TestLoadCommittedFixtures(t *testing.T) {
	files, err := filepath.Glob(filepath.Join("..", "..", "..", "contracts", "test", "fixtures", "paths", "*.json"))
	if err != nil || len(files) != 6 {
		t.Fatalf("expected 6 fixtures, got %d (%v)", len(files), err)
	}
	for _, f := range files {
		p, err := Load(f)
		if err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		if p.Step != 300*time.Second || len(p.Prices) != 289 {
			t.Fatalf("%s: step %s, %d prices", f, p.Step, len(p.Prices))
		}
		if p.Prices[0].Cmp(new(big.Int).Mul(big.NewInt(3000), big.NewInt(1e18))) != 0 {
			t.Fatalf("%s: unexpected first price %s", f, p.Prices[0])
		}
	}
}

func TestIndexAndPriceAt(t *testing.T) {
	p, err := Parse([]byte(`{"name":"t","dtSeconds":10,"prices":["100","200","300"]}`))
	if err != nil {
		t.Fatal(err)
	}
	start := time.Unix(1_000, 0)
	tests := []struct {
		name  string
		now   time.Time
		index int
	}{
		{"before start", start.Add(-time.Hour), 0},
		{"at start", start, 0},
		{"first step", start.Add(9 * time.Second), 0},
		{"second step", start.Add(10 * time.Second), 1},
		{"last step", start.Add(25 * time.Second), 2},
		{"clamped after end", start.Add(time.Hour), 2},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := p.Index(start, tc.now); got != tc.index {
				t.Fatalf("index %d want %d", got, tc.index)
			}
			price := p.PriceAt(start, tc.now)
			price.SetInt64(0) // callers get a copy
			if p.Prices[tc.index].Sign() == 0 {
				t.Fatal("PriceAt leaked internal storage")
			}
		})
	}
	fast := p.WithStep(time.Second)
	if fast.Index(start, start.Add(2*time.Second)) != 2 || p.Step != 10*time.Second {
		t.Fatal("WithStep must copy")
	}
}

func TestParseRejectsInvalid(t *testing.T) {
	for _, raw := range []string{
		`not json`,
		`{"dtSeconds":0,"prices":["1"]}`,
		`{"dtSeconds":1,"prices":[]}`,
		`{"dtSeconds":1,"prices":["-1"]}`,
		`{"dtSeconds":1,"prices":["0x10"]}`,
	} {
		if _, err := Parse([]byte(raw)); !errors.Is(err, ErrInvalidPath) {
			t.Fatalf("%s accepted: %v", raw, err)
		}
	}
}

func TestApplyBps(t *testing.T) {
	tests := []struct{ price, bps, want int64 }{
		{10_000, 0, 10_000},
		{10_000, 5, 10_005},
		{10_000, -5, 9_995},
		{3, 1, 3},
	}
	for _, tc := range tests {
		if got := ApplyBps(big.NewInt(tc.price), tc.bps); got.Int64() != tc.want {
			t.Fatalf("ApplyBps(%d,%d)=%s want %d", tc.price, tc.bps, got, tc.want)
		}
	}
}

func FuzzParse(f *testing.F) {
	f.Add([]byte(`{"name":"t","dtSeconds":10,"prices":["100","200"]}`))
	f.Add([]byte(`{"dtSeconds":-1}`))
	f.Fuzz(func(t *testing.T, raw []byte) {
		p, err := Parse(raw)
		if err != nil {
			return
		}
		start := time.Unix(0, 0)
		for _, off := range []time.Duration{0, p.Step, 3 * p.Step} {
			if p.PriceAt(start, start.Add(off)).Sign() <= 0 {
				t.Fatal("non-positive price from a parsed path")
			}
		}
	})
}
