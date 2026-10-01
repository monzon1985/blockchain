# SPDX-License-Identifier: MIT
"""Generate test/fixtures/vectors.json: exact reference values for the hook's fee math.

Usage (from the project root):
    uv run --project sim python sim/gen_vectors.py          # (re)write the fixture
    uv run --project sim python sim/gen_vectors.py --check  # fail if the committed fixture is stale

Every expected value is exact (integer / rational arithmetic, or mpmath at 120 digits with a guarded floor). For
the round-down quantities the fixture also carries an analytic error bound, so the Solidity test checks both the
rounding DIRECTION (never above the exact value) and the MAGNITUDE (never further below than the bound).
"""

from __future__ import annotations

import argparse
import sys
from fractions import Fraction

from volfee_model import (
    FIXTURES,
    MAX_FEE_PIPS,
    MAX_TICK_DELTA,
    MIN_FEE_PIPS,
    PIPS,
    WAD,
    Sha256Rng,
    decay_error_bound,
    decay_exact,
    dump_json,
    ewma_error_bound,
    ewma_update_exact,
    floor_of,
    lp_fee,
    pro_rated_surcharge_exact,
    surcharge_amount,
    surcharge_rate,
    write_or_check,
)

SEED = "v4-volatility-fee-hook/vectors/v1"
PRO_RATED_SEED = "v4-volatility-fee-hook/vectors/pro-rated/v1"
Q96 = 2**96
MIN_SQRT_PRICE = 4_295_128_739
MAX_SQRT_PRICE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342
SEQUENCE_LENGTH = 50
MAX_EWMA = MAX_TICK_DELTA * WAD

ALPHAS = [
    1,
    10**15,
    10**16,
    5 * 10**16,
    10**17,
    25 * 10**16,
    5 * 10**17,
    9 * 10**17,
    WAD - 1,
    WAD,
]


def decay_vectors(rng: Sha256Rng) -> list[dict]:
    exponents = [0, 1, 2, 3, 5, 8, 13, 17, 18, 19, 64, 100, 255, 256, 1000, 4096, 20_000, 2**40 - 1]
    out = []
    for alpha in ALPHAS:
        ks = [*exponents, rng.randint(2, 50), rng.randint(51, 5_000), rng.randint(20_001, 10**6)]
        for k in ks:
            exact = decay_exact(alpha, k)
            out.append(
                {
                    "alphaWad": alpha,
                    "floorExact": floor_of(exact),
                    "k": k,
                    "maxError": decay_error_bound(k) if k > 0 else 0,
                }
            )
    return out


def ewma_vectors(rng: Sha256Rng) -> list[dict]:
    out = []
    edge_ewmas = [0, 1, WAD - 1, WAD, 3 * WAD, MAX_EWMA]
    edge_samples = [0, 1, 3, 60, MAX_TICK_DELTA]
    edge_blocks = [1, 2, 3, 12, 300, 7_200]
    for alpha in ALPHAS:
        for _ in range(12):
            ewma = rng.randint(0, MAX_EWMA) if rng.randint(0, 1) else rng.randint(0, 50 * WAD)
            sample = rng.randint(0, MAX_TICK_DELTA) if rng.randint(0, 3) == 0 else rng.randint(0, 200)
            blocks = rng.randint(1, 3) if rng.randint(0, 1) else rng.randint(1, 20_000)
            out.append(_ewma_vector(alpha, ewma, sample, blocks))
        for ewma in edge_ewmas:
            sample = edge_samples[rng.randint(0, len(edge_samples) - 1)]
            blocks = edge_blocks[rng.randint(0, len(edge_blocks) - 1)]
            out.append(_ewma_vector(alpha, ewma, sample, blocks))
    return out


def _ewma_vector(alpha: int, ewma: int, sample: int, blocks: int) -> dict:
    exact = ewma_update_exact(ewma, sample, blocks, alpha)
    return {
        "alphaWad": alpha,
        "blocks": blocks,
        "ewma": ewma,
        "floorExact": floor_of(exact),
        "maxError": ewma_error_bound(ewma, sample, blocks, alpha),
        "sample": sample,
    }


def fee_vectors(rng: Sha256Rng) -> list[dict]:
    slopes = [0, 1, 7, 100, 500, 2_500, 10_000]
    out = []
    for slope in slopes:
        ewmas = [0, 1, WAD - 1, WAD, WAD + 1, MAX_EWMA]
        if slope > 0:
            # The clamp engages exactly when MIN + ceil(e * slope / WAD) > MAX.
            threshold = (MAX_FEE_PIPS - MIN_FEE_PIPS) * WAD // slope
            ewmas += [threshold - 1, threshold, threshold + 1]
        ewmas += [rng.randint(0, 100 * WAD) for _ in range(4)]
        for ewma in ewmas:
            out.append({"ewma": ewma, "expected": lp_fee(ewma, slope), "slope": slope})
    return out


def surcharge_rate_vectors(rng: Sha256Rng) -> list[dict]:
    out = []
    for slope in [0, 1, 250, 1_000, 10_000]:
        for cap in [0, 1, 2_500, 5_000, 10_000]:
            ewmas = [0, 1, WAD - 1, WAD, MAX_EWMA, rng.randint(0, 60 * WAD)]
            if slope > 0 and cap > 0:
                threshold = cap * WAD // slope
                ewmas += [threshold - 1, threshold, threshold + 1]
            for ewma in ewmas:
                out.append({"cap": cap, "ewma": ewma, "expected": surcharge_rate(ewma, slope, cap), "slope": slope})
    return out


def surcharge_amount_vectors(rng: Sha256Rng) -> list[dict]:
    out = []
    amounts = [0, 1, 2, 999, PIPS - 1, PIPS, PIPS + 1, 10**18, 2**127 - 1, 2**127]
    rates = [0, 1, 250, 2_925, 5_000, 10_000, PIPS]
    for amount in amounts:
        for rate in rates:
            out.append({"amount": amount, "expected": surcharge_amount(amount, rate), "rate": rate})
    for _ in range(40):
        amount = rng.randint(0, 2**127)
        rate = rng.randint(0, 10_000)
        out.append({"amount": amount, "expected": surcharge_amount(amount, rate), "rate": rate})
    return out


def pro_rated_vectors(rng: Sha256Rng) -> list[dict]:
    """Range-extension surcharges. Expected: ceil(exact) <= got <= min(whole-swap charge, ceil(exact) + 1).

    The upper bound needs pre / edge < 1e6 - 1 for currency0 (three roundings, one of them scaled by pre / edge);
    every geometry here keeps that ratio at or below 1,000, far beyond any price move within one block.
    """
    geometries: list[tuple[int, int, int]] = [
        (Q96, Q96 - 10**20, Q96),  # starts on the edge (the block's first swap), down
        (Q96, Q96 + 10**20, Q96),  # starts on the edge, up
        (Q96, Q96 - 10**20, Q96 - 10**20 + 1),  # one unit of new ground
        (Q96, Q96 - 10**20, Q96 - 1),  # all but one unit is new ground
        (Q96, Q96 + 10**20, Q96 + 10**20 - 1),
        (Q96, Q96 + 10**20, Q96 + 1),
        (Q96 + 2 * 10**6, Q96, Q96 + 1_999_999),  # double rounding of the currency0 share hits the cap
        (MAX_SQRT_PRICE - 1, MAX_SQRT_PRICE // 2, MAX_SQRT_PRICE // 2 + 10**30),  # top of the price range
        (MIN_SQRT_PRICE, MIN_SQRT_PRICE * 900, MIN_SQRT_PRICE * 3),  # bottom of the price range
    ]
    hand_picked = len(geometries)
    for _ in range(40):
        lo = rng.randint(MIN_SQRT_PRICE, MAX_SQRT_PRICE // 1_000)
        hi = rng.randint(lo + 2, min(lo * 1_000, MAX_SQRT_PRICE))
        mid = rng.randint(lo + 1, hi - 1)
        geometries.append((hi, lo, mid) if rng.randint(0, 1) else (lo, hi, mid))
    cases = [(0, 250), (1, 1), (100, 10_000), (999_999, PIPS), (10**18, 2_925), (2**127, 10_000)]
    out = []
    for index, (pre, post, edge) in enumerate(geometries):
        if not (edge == pre or min(pre, post) < edge < max(pre, post)):
            raise ValueError("edge must be pre or strictly between pre and post")
        if pre > 1_000 * edge:
            raise ValueError("pre / edge too large for the documented bound")
        picks = cases if index < hand_picked else [cases[rng.randint(0, len(cases) - 1)] for _ in range(2)]
        for in_currency1 in (True, False):
            for amount, rate in picks:
                exact = pro_rated_surcharge_exact(amount, rate, pre, post, edge, in_currency1)
                out.append(
                    {
                        "amount": amount,
                        "ceilExact": -(-exact.numerator // exact.denominator),
                        "edge": edge,
                        "full": surcharge_amount(amount, rate),
                        "inCurrency1": in_currency1,
                        "post": post,
                        "pre": pre,
                        "rate": rate,
                    }
                )
    return out


def sequence_vectors(rng: Sha256Rng) -> list[dict]:
    """50-step sequences: the Bunni lesson is that rounding must be checked across repeated operations."""
    out = []
    kinds = ["random", "quiet-decay", "spike-then-quiet", "constant", "alternating", "long-gaps", "max-shocks"]
    for alpha in [10**15, 10**16, 10**17, 3 * 10**17, 5 * 10**17, WAD]:
        for kind in kinds:
            start = rng.randint(0, 40 * WAD)
            samples: list[int] = []
            blocks: list[int] = []
            for i in range(SEQUENCE_LENGTH):
                if kind == "random":
                    samples.append(rng.randint(0, 120))
                    blocks.append(rng.randint(1, 5))
                elif kind == "quiet-decay":
                    samples.append(0)
                    blocks.append(1)
                elif kind == "spike-then-quiet":
                    samples.append(MAX_TICK_DELTA if i == 0 else 0)
                    blocks.append(1)
                elif kind == "constant":
                    samples.append(7)
                    blocks.append(1)
                elif kind == "alternating":
                    samples.append(200 if i % 2 == 0 else 0)
                    blocks.append(1)
                elif kind == "long-gaps":
                    samples.append(rng.randint(0, 40))
                    blocks.append(rng.randint(1, 400))
                else:
                    samples.append(MAX_TICK_DELTA if rng.randint(0, 4) == 0 else rng.randint(0, 5))
                    blocks.append(rng.randint(1, 2))
            out.append(_sequence_vector(alpha, start, samples, blocks))
    return out


def _sequence_vector(alpha: int, start: int, samples: list[int], blocks: list[int]) -> dict:
    exact: Fraction = Fraction(start)
    max_error = 0
    for sample, k in zip(samples, blocks, strict=True):
        # Per-step error bounds add up: each update is a contraction of its input, so earlier errors never grow.
        # Inside a sequence the exact input carries a fractional part, so even a one-block step loses < 1 wei.
        max_error += ewma_error_bound(exact, sample, k, alpha) if k > 1 else 1
        nxt = ewma_update_exact(exact, sample, k, alpha)
        if not isinstance(nxt, Fraction):
            raise ArithmeticError("sequence steps must stay in the exact-rational range")
        exact = nxt
    return {
        "alphaWad": alpha,
        "blocks": blocks,
        "floorExact": floor_of(exact),
        "maxError": max_error,
        "samples": samples,
        "start": start,
    }


def build() -> dict:
    rng = Sha256Rng(SEED)
    return {
        "comment": "Generated by sim/gen_vectors.py; do not edit by hand.",
        "decay": decay_vectors(rng),
        "ewma": ewma_vectors(rng),
        "fee": fee_vectors(rng),
        "proRatedSurcharge": pro_rated_vectors(Sha256Rng(PRO_RATED_SEED)),
        "sequences": sequence_vectors(rng),
        "surchargeAmount": surcharge_amount_vectors(rng),
        "surchargeRate": surcharge_rate_vectors(rng),
        "version": 2,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="verify the committed fixture instead of writing it")
    args = parser.parse_args()
    content = dump_json(build())
    return write_or_check(FIXTURES / "vectors.json", content, args.check)


if __name__ == "__main__":
    sys.exit(main())
