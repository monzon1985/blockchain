# SPDX-License-Identifier: MIT
"""Seeded price-path models: geometric Brownian motion and Merton jump-diffusion.

Determinism across platforms matters because the generated fixtures are committed and re-checked in CI on a
different OS. Two choices make the output bit-for-bit reproducible:

* numpy (PCG64) is only used for uniform doubles, which are produced from integer state with exact bit
  manipulation, so they are identical everywhere;
* every transcendental function (ln, sqrt, exp) is evaluated with :mod:`decimal`, whose operations are
  correctly rounded by specification, instead of the platform libm.

Normal draws use Marsaglia's polar method (only ln and sqrt, no trigonometry) and Poisson jump counts use
exact inverse-CDF sampling.
"""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass
from decimal import ROUND_HALF_EVEN, Decimal, localcontext

import numpy as np

WAD = 10**18
SECONDS_PER_YEAR = 365 * 24 * 3600
PRECISION = 50


@dataclass(frozen=True)
class PathSpec:
    """A reproducible price path.

    Numeric parameters are decimal strings so they round-trip exactly through JSON.

    Attributes:
        name: File stem of the fixture.
        model: ``"gbm"`` or ``"merton"``.
        seed: PCG64 seed.
        s0: Initial price in USD.
        mu: Annualised drift of the diffusion part.
        sigma: Annualised volatility of the diffusion part.
        dt_seconds: Step length in seconds.
        steps: Number of steps (the path has ``steps + 1`` prices).
        jump_intensity: Expected jumps per year (Merton only).
        jump_mean: Mean of the log-jump size (Merton only).
        jump_std: Standard deviation of the log-jump size (Merton only).
    """

    name: str
    model: str
    seed: int
    s0: str
    mu: str
    sigma: str
    dt_seconds: int
    steps: int
    jump_intensity: str = "0"
    jump_mean: str = "0"
    jump_std: str = "0"

    def __post_init__(self) -> None:
        if self.model not in ("gbm", "merton"):
            raise ValueError(f"unknown model {self.model!r}")
        if self.steps <= 0 or self.dt_seconds <= 0:
            raise ValueError("steps and dt_seconds must be positive")
        if Decimal(self.s0) <= 0 or Decimal(self.sigma) < 0:
            raise ValueError("s0 must be positive and sigma non-negative")
        if self.model == "gbm" and (Decimal(self.jump_intensity) != 0 or Decimal(self.jump_std) != 0):
            raise ValueError("a gbm path cannot carry jump parameters")
        if Decimal(self.jump_intensity) < 0 or Decimal(self.jump_std) < 0:
            raise ValueError("jump intensity and jump std must be non-negative")

    def params(self) -> dict[str, str | int]:
        """Parameters as written into the fixture."""
        return {
            "s0": self.s0,
            "mu": self.mu,
            "sigma": self.sigma,
            "dtSeconds": self.dt_seconds,
            "steps": self.steps,
            "jumpIntensity": self.jump_intensity,
            "jumpMean": self.jump_mean,
            "jumpStd": self.jump_std,
        }


def _uniform_stream(rng: np.random.Generator) -> Iterator[Decimal]:
    """Exact decimal copies of PCG64 uniform doubles in [0, 1)."""
    while True:
        for x in rng.random(64):
            yield Decimal(float(x))


def polar_normal(uniforms: Iterator[Decimal]) -> Iterator[Decimal]:
    """Standard normal draws via Marsaglia's polar method."""
    while True:
        u = next(uniforms) * 2 - 1
        v = next(uniforms) * 2 - 1
        s = u * u + v * v
        if s == 0 or s >= 1:
            continue
        factor = ((-2 * s.ln()) / s).sqrt()
        yield u * factor
        yield v * factor


def poisson_count(u: Decimal, lam: Decimal) -> int:
    """Inverse-CDF Poisson sample for a uniform ``u`` in [0, 1)."""
    if lam == 0:
        return 0
    k = 0
    p = (-lam).exp()
    cdf = p
    while u >= cdf:
        k += 1
        p = p * lam / k
        cdf += p
        if k > 1_000:  # unreachable for the intensities used here; guards against a pathological lam
            raise ValueError("poisson sampler did not converge")
    return k


def to_wad(price: Decimal) -> int:
    """USD price to an 18-decimal integer, banker's rounding."""
    return int((price * WAD).to_integral_value(rounding=ROUND_HALF_EVEN))


def generate_path(spec: PathSpec) -> list[int]:
    """Generates ``spec.steps + 1`` prices in WAD.

    GBM: ``ln S(t+dt) = ln S(t) + (mu - sigma^2 / 2) dt + sigma sqrt(dt) Z``.
    Merton adds ``N ~ Poisson(lambda dt)`` log-jumps ``J ~ Normal(jump_mean, jump_std)`` per step. The jumps
    are stress scenarios on top of the diffusion drift, so no martingale compensator is applied.
    """
    rng = np.random.Generator(np.random.PCG64(spec.seed))
    uniforms = _uniform_stream(rng)
    normals = polar_normal(uniforms)
    with localcontext() as ctx:
        ctx.prec = PRECISION
        dt = Decimal(spec.dt_seconds) / Decimal(SECONDS_PER_YEAR)
        sigma = Decimal(spec.sigma)
        drift = (Decimal(spec.mu) - sigma * sigma / 2) * dt
        vol = sigma * dt.sqrt()
        lam = Decimal(spec.jump_intensity) * dt
        jump_mean = Decimal(spec.jump_mean)
        jump_std = Decimal(spec.jump_std)

        price = Decimal(spec.s0)
        prices = [to_wad(price)]
        for _ in range(spec.steps):
            increment = drift + vol * next(normals)
            if spec.model == "merton":
                for _ in range(poisson_count(next(uniforms), lam)):
                    increment += jump_mean + jump_std * next(normals)
            price = price * increment.exp()
            prices.append(to_wad(price))
    return prices


def log_returns(prices: list[int]) -> np.ndarray:
    """Per-step log-returns of a WAD price path (float64, for statistics only)."""
    arr = np.array([p / WAD for p in prices], dtype=np.float64)
    return np.diff(np.log(arr))
