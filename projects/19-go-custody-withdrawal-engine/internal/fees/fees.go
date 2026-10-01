// SPDX-License-Identifier: MIT

// Package fees computes EIP-1559 fees from eth_feeHistory and the replace-by-fee bumps used
// to unstick transactions.
package fees

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"slices"

	"github.com/ethereum/go-ethereum"
)

// MinBumpBps is the smallest bump the engine will ever use: 12.5 % (1 250 basis points).
// geth's default txpool price bump is 10 %; 12.5 % also clears pools configured more strictly
// and matches the maximum per-block base-fee increase, so one bump outpaces one full block.
const MinBumpBps = 1250

// ErrFeeCap is returned when the required fee exceeds the configured ceiling.
var ErrFeeCap = errors.New("fees: required fee exceeds the configured cap")

// Fees is an EIP-1559 fee pair.
type Fees struct {
	MaxFee *big.Int // maxFeePerGas
	Tip    *big.Int // maxPriorityFeePerGas
}

// Clone returns a deep copy.
func (f Fees) Clone() Fees {
	return Fees{MaxFee: new(big.Int).Set(f.MaxFee), Tip: new(big.Int).Set(f.Tip)}
}

// String implements fmt.Stringer.
func (f Fees) String() string { return fmt.Sprintf("maxFee=%s tip=%s", f.MaxFee, f.Tip) }

// Source is the subset of chain.Client the estimator needs.
type Source interface {
	FeeHistory(ctx context.Context, blockCount uint64, lastBlock *big.Int, rewardPercentiles []float64) (*ethereum.FeeHistory, error)
}

// Config parameterises the estimator.
type Config struct {
	HistoryBlocks    uint64   // blocks of history to sample (eth_feeHistory blockCount)
	RewardPercentile float64  // percentile of per-block priority fees to use
	MinTip           *big.Int // floor for the priority fee
	MaxFee           *big.Int // absolute ceiling for maxFeePerGas
	BumpBps          int64    // replacement bump in basis points (>= MinBumpBps)
}

// Estimator suggests fees.
type Estimator struct {
	src Source
	cfg Config
}

// NewEstimator validates cfg and returns an Estimator.
func NewEstimator(src Source, cfg Config) (*Estimator, error) {
	if cfg.HistoryBlocks == 0 {
		return nil, errors.New("fees: history_blocks must be positive")
	}
	if cfg.RewardPercentile < 0 || cfg.RewardPercentile > 100 {
		return nil, errors.New("fees: reward_percentile must be within [0,100]")
	}
	if cfg.MinTip == nil || cfg.MinTip.Sign() < 0 || cfg.MaxFee == nil || cfg.MaxFee.Sign() <= 0 {
		return nil, errors.New("fees: min_tip and max_fee must be set")
	}
	if cfg.MinTip.Cmp(cfg.MaxFee) > 0 {
		return nil, errors.New("fees: min_tip exceeds max_fee")
	}
	if cfg.BumpBps < MinBumpBps {
		return nil, fmt.Errorf("fees: bump must be at least %d bps (12.5%%)", MinBumpBps)
	}
	return &Estimator{src: src, cfg: cfg}, nil
}

// Config returns the estimator configuration.
func (e *Estimator) Config() Config { return e.cfg }

// Suggest returns fees for the next block: tip = the configured percentile of recent priority
// fees (at least MinTip), maxFee = 2 x next base fee + tip, which covers five consecutive
// full blocks of +12.5 % base-fee growth. maxFee is clamped to the cap; Capped reports that.
func (e *Estimator) Suggest(ctx context.Context) (f Fees, capped bool, err error) {
	h, err := e.src.FeeHistory(ctx, e.cfg.HistoryBlocks, nil, []float64{e.cfg.RewardPercentile})
	if err != nil {
		return Fees{}, false, fmt.Errorf("fees: fee history: %w", err)
	}
	if len(h.BaseFee) == 0 {
		return Fees{}, false, errors.New("fees: empty fee history")
	}
	nextBase := h.BaseFee[len(h.BaseFee)-1]
	f, capped = Compute(nextBase, rewards(h), e.cfg.MinTip, e.cfg.MaxFee)
	return f, capped, nil
}

func rewards(h *ethereum.FeeHistory) []*big.Int {
	out := make([]*big.Int, 0, len(h.Reward))
	for _, r := range h.Reward {
		if len(r) > 0 && r[0] != nil {
			out = append(out, r[0])
		}
	}
	return out
}

// Compute is the pure core of Suggest.
func Compute(nextBase *big.Int, recentTips []*big.Int, minTip, maxFee *big.Int) (Fees, bool) {
	tip := median(recentTips)
	if tip.Cmp(minTip) < 0 {
		tip = new(big.Int).Set(minTip)
	}
	fee := new(big.Int).Mul(nextBase, big.NewInt(2))
	fee.Add(fee, tip)
	capped := false
	if fee.Cmp(maxFee) > 0 {
		fee = new(big.Int).Set(maxFee)
		capped = true
	}
	if tip.Cmp(fee) > 0 {
		tip = new(big.Int).Set(fee)
	}
	return Fees{MaxFee: fee, Tip: tip}, capped
}

func median(vs []*big.Int) *big.Int {
	if len(vs) == 0 {
		return new(big.Int)
	}
	s := make([]*big.Int, len(vs))
	copy(s, vs)
	slices.SortFunc(s, func(a, b *big.Int) int { return a.Cmp(b) })
	return new(big.Int).Set(s[len(s)/2])
}

// Bump returns replacement fees: each field is raised by at least bumpBps over prev (rounded
// up, so the replacement rule can never fail on rounding) and to at least the current
// suggestion. It returns ErrFeeCap when that would exceed maxFee: the caller must alert
// rather than send a replacement the pool would reject anyway.
func Bump(prev, suggested Fees, bumpBps int64, maxFee *big.Int) (Fees, error) {
	if bumpBps < MinBumpBps {
		bumpBps = MinBumpBps
	}
	tip := maxBig(bumpUp(prev.Tip, bumpBps), suggested.Tip)
	fee := maxBig(bumpUp(prev.MaxFee, bumpBps), suggested.MaxFee)
	if tip.Cmp(fee) > 0 {
		fee = new(big.Int).Set(tip)
	}
	if fee.Cmp(maxFee) > 0 {
		return Fees{}, fmt.Errorf("%w: need %s, cap %s", ErrFeeCap, fee, maxFee)
	}
	return Fees{MaxFee: fee, Tip: tip}, nil
}

// bumpUp returns ceil(v * (10000 + bps) / 10000), and at least v+1 so a zero tip still moves.
func bumpUp(v *big.Int, bps int64) *big.Int {
	num := new(big.Int).Mul(v, big.NewInt(10_000+bps))
	out, rem := new(big.Int).QuoRem(num, big.NewInt(10_000), new(big.Int))
	if rem.Sign() != 0 {
		out.Add(out, big.NewInt(1))
	}
	if out.Cmp(v) <= 0 {
		out = new(big.Int).Add(v, big.NewInt(1))
	}
	return out
}

func maxBig(a, b *big.Int) *big.Int {
	if a.Cmp(b) >= 0 {
		return new(big.Int).Set(a)
	}
	return new(big.Int).Set(b)
}
