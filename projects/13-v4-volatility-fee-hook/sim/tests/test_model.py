# SPDX-License-Identifier: MIT
"""Property tests of the reference model and of the analytic error bounds used by the Solidity differential tests.

`emulate_*` re-implement the Solidity integer algorithms line by line. They are used here only to confirm, on many
random inputs, that the analytic bounds written into vectors.json hold for that algorithm; the Solidity code itself
is checked against the exact values in test/unit/VolatilityMathDifferential.t.sol.
"""

from fractions import Fraction

import pytest

from volfee_model import (
    MAX_FEE_PIPS,
    MAX_TICK_DELTA,
    MIN_FEE_PIPS,
    WAD,
    Sha256Rng,
    decay_error_bound,
    decay_exact,
    ewma_error_bound,
    ewma_update_exact,
    floor_of,
    lp_fee,
    pro_rated_surcharge_exact,
    surcharge_amount,
    surcharge_rate,
)


def emulate_decay(alpha_wad: int, k: int) -> int:
    base = WAD - alpha_wad
    result = WAD
    while True:
        if k & 1:
            result = result * base // WAD
        k >>= 1
        if k == 0 or result == 0:
            return result
        base = base * base // WAD


def emulate_update(ewma: int, sample: int, blocks: int, alpha_wad: int) -> int:
    nxt = (WAD - alpha_wad) * ewma // WAD + alpha_wad * sample
    if blocks > 1 and nxt != 0:
        nxt = nxt * emulate_decay(alpha_wad, blocks - 1) // WAD
    return nxt


def emulate_pro_rated(amount: int, rate: int, pre: int, post: int, edge: int, in_currency1: bool) -> int:
    full = -(-(amount * rate) // 10**6)
    if edge == pre:
        return full
    total = abs(pre - post)
    beyond = abs(post - edge)
    share = -(-(amount * rate * beyond) // total)
    if not in_currency1:
        share = -(-(share * pre) // edge)
    return min(-(-share // 10**6), full)


def test_rng_is_deterministic_and_in_range():
    a = Sha256Rng("seed")
    b = Sha256Rng("seed")
    draws = [a.randint(3, 9) for _ in range(500)]
    assert draws == [b.randint(3, 9) for _ in range(500)]
    assert min(draws) == 3 and max(draws) == 9
    assert all(0 < Sha256Rng("u").uniform() < 1 for _ in range(10))


@pytest.mark.parametrize("alpha", [1, 10**15, 10**17, 5 * 10**17, WAD - 1, WAD])
def test_decay_bound_holds(alpha):
    rng = Sha256Rng(f"decay-{alpha}")
    for _ in range(300):
        k = rng.randint(0, 2000)
        exact = floor_of(decay_exact(alpha, k))
        got = emulate_decay(alpha, k)
        assert got <= exact
        assert exact - got <= (decay_error_bound(k) if k else 0)


@pytest.mark.parametrize("alpha", [10**15, 10**17, 5 * 10**17, WAD])
def test_ewma_bound_holds(alpha):
    rng = Sha256Rng(f"ewma-{alpha}")
    for _ in range(200):
        ewma = rng.randint(0, MAX_TICK_DELTA * WAD)
        sample = rng.randint(0, MAX_TICK_DELTA)
        blocks = rng.randint(1, 3) if rng.randint(0, 1) else rng.randint(4, 600)
        exact = floor_of(ewma_update_exact(ewma, sample, blocks, alpha))
        got = emulate_update(ewma, sample, blocks, alpha)
        assert got <= exact
        assert exact - got <= ewma_error_bound(ewma, sample, blocks, alpha)


def test_repeated_updates_do_not_amplify_error():
    """50 steps from an exact real start: the gap to the exact EWMA stays below the sum of per-step bounds."""
    rng = Sha256Rng("sequence")
    alpha = 10**17
    exact = Fraction(0)
    got = 0
    budget = 0
    for _ in range(50):
        sample = rng.randint(0, 200)
        blocks = rng.randint(1, 4)
        budget += ewma_error_bound(exact, sample, blocks, alpha) if blocks > 1 else 1
        exact = ewma_update_exact(exact, sample, blocks, alpha)
        got = emulate_update(got, sample, blocks, alpha)
        assert got <= floor_of(exact)
        assert floor_of(exact) - got <= budget


def test_fee_and_surcharge_bounds():
    for ewma in [0, 1, WAD, 19 * WAD, 10**30]:
        fee = lp_fee(ewma, 500)
        assert MIN_FEE_PIPS <= fee <= MAX_FEE_PIPS
        assert surcharge_rate(ewma, 250, 5_000) <= 5_000
    assert lp_fee(1, 500) == MIN_FEE_PIPS + 1  # rounds up
    assert surcharge_amount(1, 1) == 1  # rounds up
    assert surcharge_amount(10**18, 10**6) == 10**18


def test_pro_rated_bounds_hold():
    """ceil(exact) <= emulated Solidity result <= min(whole-swap charge, ceil(exact) + 1) for pre / edge <= 1000."""
    rng = Sha256Rng("pro-rated")
    for _ in range(2_000):
        lo = rng.randint(4_295_128_739, 2**150)
        hi = rng.randint(lo + 2, lo * 1_000)
        edge = rng.randint(lo + 1, hi - 1)
        pre, post = (hi, lo) if rng.randint(0, 1) else (lo, hi)
        amount = rng.randint(0, 2**127)
        rate = rng.randint(0, 10**6)
        for in_currency1 in (True, False):
            exact = pro_rated_surcharge_exact(amount, rate, pre, post, edge, in_currency1)
            ceil_exact = -(-exact.numerator // exact.denominator)
            got = emulate_pro_rated(amount, rate, pre, post, edge, in_currency1)
            assert ceil_exact <= got <= min(surcharge_amount(amount, rate), ceil_exact + 1)


def exact_charge(liquidity: int, rate: int, pre: int, post: int, edge: int, in_currency1: bool) -> Fraction:
    """Exact range-extension charge of a swap at constant liquidity: amount1 = L * d sqrt(P), amount0 = L * d(1/sqrt(P))
    (kept as exact rationals, so the amount need not be an integer)."""
    delta = abs(pre - post)
    amount = Fraction(liquidity * delta) if in_currency1 else Fraction(liquidity * delta, pre * post)
    return pro_rated_surcharge_exact(1, rate, pre, post, edge, in_currency1) * amount


def test_pro_rated_exact_is_additive_at_constant_liquidity():
    """With amounts linear in the currency's coordinate, the exact charge of a split swap equals the whole swap's."""
    rng = Sha256Rng("pro-rated-additive")
    for _ in range(500):
        post = rng.randint(2**90, 2**96)
        pre = rng.randint(post + 3, post + 2**80)
        edge = rng.randint(post + 1, pre)
        split = rng.randint(post + 1, pre - 1)
        liquidity = rng.randint(1, 2**40)
        rate = rng.randint(1, 10_000)
        for c1 in (True, False):
            whole = exact_charge(liquidity, rate, pre, post, edge, c1)
            if split >= edge:
                legs = exact_charge(liquidity, rate, split, post, edge, c1)
            else:
                legs = exact_charge(liquidity, rate, pre, split, edge, c1) + exact_charge(
                    liquidity, rate, split, post, split, c1
                )
            assert legs == whole
