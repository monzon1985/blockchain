# SPDX-License-Identifier: MIT
from decimal import Decimal, localcontext

import numpy as np
import pytest

from perps_sim.paths import (
    WAD,
    PathSpec,
    generate_path,
    log_returns,
    poisson_count,
    polar_normal,
    to_wad,
)

SECONDS_PER_YEAR = 365 * 24 * 3600


def gbm(seed: int = 7, steps: int = 20_000, mu: str = "0", sigma: str = "0.8", dt: int = 300) -> PathSpec:
    return PathSpec("t", "gbm", seed, "3000", mu, sigma, dt, steps)


def test_path_shape_and_start():
    prices = generate_path(gbm(steps=10))
    assert len(prices) == 11
    assert prices[0] == 3000 * WAD
    assert all(isinstance(p, int) and p > 0 for p in prices)


def test_same_seed_same_path_different_seed_different_path():
    assert generate_path(gbm(seed=1, steps=50)) == generate_path(gbm(seed=1, steps=50))
    assert generate_path(gbm(seed=1, steps=50)) != generate_path(gbm(seed=2, steps=50))


def test_golden_values_are_platform_independent():
    # Golden values generated on Windows (x86-64) and re-checked by CI on Linux: the pipeline uses only exact
    # uniform doubles and correctly rounded decimal arithmetic, so they must match bit for bit everywhere.
    assert generate_path(gbm(seed=42, steps=3, sigma="0.5")) == [
        3000000000000000000000,
        3006866271528479576844,
        3005328625380053649597,
        3008959800563798523582,
    ]
    merton = PathSpec("t", "merton", 42, "3000", "0", "0.5", 300, 3, "100000", "-0.1", "0.02")
    assert generate_path(merton) == [
        3000000000000000000000,
        2459313229158090514635,
        1833632364646184290933,
        1833229431605479419599,
    ]


def test_gbm_log_returns_match_theory():
    spec = gbm()
    r = log_returns(generate_path(spec))
    dt = spec.dt_seconds / SECONDS_PER_YEAR
    sigma = float(spec.sigma)
    expected_mean = (float(spec.mu) - sigma**2 / 2) * dt
    expected_std = sigma * np.sqrt(dt)
    n = len(r)
    # Mean within 4 standard errors, volatility within 3%.
    assert abs(r.mean() - expected_mean) < 4 * expected_std / np.sqrt(n)
    assert r.std(ddof=1) == pytest.approx(expected_std, rel=0.03)


def test_gbm_drift_is_applied():
    up = log_returns(generate_path(gbm(mu="50", sigma="0.2")))
    down = log_returns(generate_path(gbm(mu="-50", sigma="0.2")))
    assert up.mean() > 0 > down.mean()


def test_zero_volatility_is_deterministic_exponential_growth():
    spec = PathSpec("t", "gbm", 1, "100", "1", "0", 3600, 24)
    prices = generate_path(spec)
    with localcontext() as ctx:
        ctx.prec = 50
        expected = Decimal(100) * (Decimal(24 * 3600) / Decimal(SECONDS_PER_YEAR)).exp()
    assert prices[-1] == to_wad(expected)


def test_merton_jumps_have_expected_frequency_and_sign():
    base = dict(model="merton", s0="3000", mu="0", sigma="0.3", dt_seconds=300, steps=20_000)
    crash = PathSpec("c", seed=3, jump_intensity="2000", jump_mean="-0.05", jump_std="0.01", **base)
    r = log_returns(generate_path(crash))
    dt = 300 / SECONDS_PER_YEAR
    expected_jumps = 2000 * dt * len(r)
    # Jumps of about -5% stand out from 0.3-vol diffusion noise (step std ~0.29%).
    detected = int((r < -0.03).sum())
    assert detected == pytest.approx(expected_jumps, rel=0.15)
    # Negative jumps make the distribution left-skewed.
    centred = r - r.mean()
    assert (centred**3).mean() < 0


def test_polar_normal_moments():
    rng = np.random.Generator(np.random.PCG64(9))
    uniforms = (Decimal(float(x)) for x in rng.random(200_000))
    draws = np.array([float(next(polar_normal(uniforms))) for _ in range(20_000)])
    assert abs(draws.mean()) < 0.05
    assert draws.std() == pytest.approx(1.0, rel=0.03)


def test_poisson_count_inverse_cdf():
    lam = Decimal("0.5")
    assert poisson_count(Decimal(0), lam) == 0
    # P(N = 0) = e^-0.5 = 0.6065...; just above it the count is 1.
    assert poisson_count(Decimal("0.6066"), lam) == 1
    assert poisson_count(Decimal("0.9999"), lam) >= 3
    assert poisson_count(Decimal("0.5"), Decimal(0)) == 0


def test_to_wad_rounds_half_even():
    assert to_wad(Decimal("1.0000000000000000005")) == WAD
    assert to_wad(Decimal("1.0000000000000000015")) == WAD + 2


@pytest.mark.parametrize(
    "kwargs",
    [
        dict(model="bogus"),
        dict(steps=0),
        dict(dt_seconds=0),
        dict(s0="0"),
        dict(sigma="-1"),
        dict(jump_intensity="5"),
        dict(model="merton", jump_intensity="-1"),
    ],
)
def test_invalid_specs_rejected(kwargs):
    base = dict(name="x", model="gbm", seed=1, s0="1", mu="0", sigma="0.1", dt_seconds=1, steps=1)
    base.update(kwargs)
    with pytest.raises(ValueError):
        PathSpec(**base)
