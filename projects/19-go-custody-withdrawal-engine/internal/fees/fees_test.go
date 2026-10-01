// SPDX-License-Identifier: MIT

package fees_test

import (
	"context"
	"errors"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/fees"
)

func g(v int64) *big.Int { return new(big.Int).Mul(big.NewInt(v), big.NewInt(1_000_000_000)) }

type staticHistory struct {
	h   *ethereum.FeeHistory
	err error
}

func (s staticHistory) FeeHistory(context.Context, uint64, *big.Int, []float64) (*ethereum.FeeHistory, error) {
	return s.h, s.err
}

func cfg() fees.Config {
	return fees.Config{HistoryBlocks: 10, RewardPercentile: 50, MinTip: g(1), MaxFee: g(500), BumpBps: fees.MinBumpBps}
}

func TestNewEstimatorValidates(t *testing.T) {
	bad := []func(*fees.Config){
		func(c *fees.Config) { c.HistoryBlocks = 0 },
		func(c *fees.Config) { c.RewardPercentile = 101 },
		func(c *fees.Config) { c.MinTip = nil },
		func(c *fees.Config) { c.MaxFee = big.NewInt(0) },
		func(c *fees.Config) { c.MinTip = g(600) },
		func(c *fees.Config) { c.BumpBps = 1000 },
	}
	for i, mut := range bad {
		c := cfg()
		mut(&c)
		if _, err := fees.NewEstimator(staticHistory{}, c); err == nil {
			t.Errorf("case %d: invalid config accepted", i)
		}
	}
	if _, err := fees.NewEstimator(staticHistory{}, cfg()); err != nil {
		t.Fatal(err)
	}
}

func TestSuggest(t *testing.T) {
	cases := []struct {
		name       string
		baseFees   []*big.Int
		rewards    [][]*big.Int
		wantFee    *big.Int
		wantTip    *big.Int
		wantCapped bool
	}{
		{"median tip above floor", []*big.Int{g(10), g(12)}, [][]*big.Int{{g(2)}, {g(3)}, {g(4)}}, new(big.Int).Add(g(24), g(3)), g(3), false},
		{"empty blocks use the floor", []*big.Int{g(10), g(10)}, [][]*big.Int{{big.NewInt(0)}}, g(21), g(1), false},
		{"clamped to the cap", []*big.Int{g(300), g(400)}, [][]*big.Int{{g(2)}}, g(500), g(2), true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			e, _ := fees.NewEstimator(staticHistory{h: &ethereum.FeeHistory{BaseFee: tc.baseFees, Reward: tc.rewards}}, cfg())
			f, capped, err := e.Suggest(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if f.MaxFee.Cmp(tc.wantFee) != 0 || f.Tip.Cmp(tc.wantTip) != 0 || capped != tc.wantCapped {
				t.Fatalf("got %s capped=%v, want maxFee=%s tip=%s capped=%v", f, capped, tc.wantFee, tc.wantTip, tc.wantCapped)
			}
		})
	}
}

func TestSuggestErrors(t *testing.T) {
	e, _ := fees.NewEstimator(staticHistory{err: errors.New("rpc down")}, cfg())
	if _, _, err := e.Suggest(context.Background()); err == nil {
		t.Fatal("expected error")
	}
	e, _ = fees.NewEstimator(staticHistory{h: &ethereum.FeeHistory{}}, cfg())
	if _, _, err := e.Suggest(context.Background()); err == nil {
		t.Fatal("expected error on empty history")
	}
}

func TestComputeTipNeverExceedsFee(t *testing.T) {
	f, capped := fees.Compute(g(1), []*big.Int{g(900)}, g(1), g(500))
	if !capped || f.Tip.Cmp(f.MaxFee) > 0 {
		t.Fatalf("tip above fee cap: %s", f)
	}
}

func TestBump(t *testing.T) {
	prev := fees.Fees{MaxFee: g(100), Tip: g(2)}
	// Market unchanged: exactly +12.5 % on both fields.
	got, err := fees.Bump(prev, fees.Fees{MaxFee: g(10), Tip: g(1)}, fees.MinBumpBps, g(1000))
	if err != nil {
		t.Fatal(err)
	}
	if got.MaxFee.Cmp(big.NewInt(112_500_000_000)) != 0 || got.Tip.Cmp(big.NewInt(2_250_000_000)) != 0 {
		t.Fatalf("got %s", got)
	}
	// Market moved above +12.5 %: follow the market.
	got, _ = fees.Bump(prev, fees.Fees{MaxFee: g(300), Tip: g(5)}, fees.MinBumpBps, g(1000))
	if got.MaxFee.Cmp(g(300)) != 0 || got.Tip.Cmp(g(5)) != 0 {
		t.Fatalf("got %s", got)
	}
	// Cap reached.
	if _, err := fees.Bump(prev, prev, fees.MinBumpBps, g(110)); !errors.Is(err, fees.ErrFeeCap) {
		t.Fatalf("expected ErrFeeCap, got %v", err)
	}
	// A bump below the minimum is raised to 12.5 %.
	got, _ = fees.Bump(prev, prev, 100, g(1000))
	if got.MaxFee.Cmp(big.NewInt(112_500_000_000)) != 0 {
		t.Fatalf("bps floor not applied: %s", got)
	}
	// Zero tips still move.
	got, _ = fees.Bump(fees.Fees{MaxFee: big.NewInt(1), Tip: big.NewInt(0)}, fees.Fees{MaxFee: big.NewInt(0), Tip: big.NewInt(0)}, fees.MinBumpBps, g(1))
	if got.Tip.Sign() <= 0 || got.MaxFee.Cmp(big.NewInt(2)) != 0 {
		t.Fatalf("zero values did not move: %s", got)
	}
}

// FuzzBump checks the replacement rule every node enforces: both fields rise by at least
// 12.5 % (rounded up), the tip never exceeds the fee cap, and the result never exceeds the cap.
func FuzzBump(f *testing.F) {
	f.Add(uint64(100), uint64(2), uint64(10), uint64(1), uint64(1000), int64(1250))
	f.Add(uint64(1), uint64(0), uint64(0), uint64(0), uint64(1_000_000), int64(0))
	f.Add(uint64(7), uint64(7), uint64(50), uint64(60), uint64(80), int64(5000))
	f.Add(uint64(9), uint64(9), uint64(0), uint64(0), uint64(1000), int64(1250)) // 9 x 1.125 = 10.125: must become 11, not 10
	f.Fuzz(func(t *testing.T, prevFee, prevTip, suggFee, suggTip, maxFee uint64, bps int64) {
		if prevTip > prevFee {
			prevTip = prevFee
		}
		if bps > 100_000 || bps < -100_000 {
			bps %= 100_000
		}
		prev := fees.Fees{MaxFee: new(big.Int).SetUint64(prevFee), Tip: new(big.Int).SetUint64(prevTip)}
		sugg := fees.Fees{MaxFee: new(big.Int).SetUint64(suggFee), Tip: new(big.Int).SetUint64(suggTip)}
		cap := new(big.Int).SetUint64(maxFee)
		got, err := fees.Bump(prev, sugg, bps, cap)
		if errors.Is(err, fees.ErrFeeCap) {
			return
		}
		if err != nil {
			t.Fatal(err)
		}
		eff := max(bps, fees.MinBumpBps)
		minNew := func(v uint64) *big.Int { // ceil(v * (10000 + bps) / 10000): the rule rounds up
			n := new(big.Int).Mul(new(big.Int).SetUint64(v), big.NewInt(10_000+eff))
			n.Add(n, big.NewInt(9_999))
			return n.Div(n, big.NewInt(10_000))
		}
		if got.MaxFee.Cmp(minNew(prevFee)) < 0 || got.Tip.Cmp(minNew(prevTip)) < 0 {
			t.Fatalf("bump below %d bps: prev %s -> %s", eff, prev, got)
		}
		if got.MaxFee.Cmp(prev.MaxFee) <= 0 || got.Tip.Cmp(prev.Tip) <= 0 {
			t.Fatalf("bump did not strictly increase: prev %s -> %s", prev, got)
		}
		if got.Tip.Cmp(got.MaxFee) > 0 || got.MaxFee.Cmp(cap) > 0 {
			t.Fatalf("invalid result %s (cap %s)", got, cap)
		}
		if got.MaxFee.Cmp(sugg.MaxFee) < 0 || got.Tip.Cmp(sugg.Tip) < 0 {
			t.Fatalf("result below the market suggestion: %s < %s", got, sugg)
		}
	})
}

func TestFeesCloneAndString(t *testing.T) {
	f := fees.Fees{MaxFee: big.NewInt(3), Tip: big.NewInt(1)}
	c := f.Clone()
	c.MaxFee.SetInt64(9)
	if f.MaxFee.Int64() != 3 || f.String() != "maxFee=3 tip=1" {
		t.Fatalf("clone aliases or string wrong: %s", f)
	}
	e, _ := fees.NewEstimator(staticHistory{}, cfg())
	if e.Config().BumpBps != fees.MinBumpBps {
		t.Fatal("config accessor")
	}
}
