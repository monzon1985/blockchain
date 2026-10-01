# SPDX-License-Identifier: MIT
"""Exact reference model of the hook's fee math, plus a platform-independent deterministic RNG.

Everything here is computed either with exact integer/rational arithmetic or with mpmath at 120 significant
digits, so the generated fixtures are byte-identical on every OS and CPU. Solidity results are compared against
these exact values in `test/unit/VolatilityMathDifferential.t.sol`.
"""

from __future__ import annotations

import hashlib
import json
from fractions import Fraction
from pathlib import Path

import mpmath

mpmath.mp.dps = 120

WAD = 10**18
PIPS = 10**6
MIN_FEE_PIPS = 500
MAX_FEE_PIPS = 10_000
MAX_TICK_DELTA = 2 * 887_272

# Above this exponent the exact rational (WAD - a)^k / WAD^k gets too large to be worth computing exactly;
# mpmath at 120 digits is used instead, guarded against values that sit too close to an integer.
EXACT_EXPONENT_LIMIT = 20_000

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "test" / "fixtures"


class Sha256Rng:
    """Counter-mode SHA-256 generator: stable across Python versions and platforms (unlike `random`)."""

    def __init__(self, seed: str) -> None:
        self._seed = seed.encode()
        self._counter = 0

    def next_u64(self) -> int:
        digest = hashlib.sha256(self._seed + self._counter.to_bytes(8, "big")).digest()
        self._counter += 1
        return int.from_bytes(digest[:8], "big")

    def randint(self, lo: int, hi: int) -> int:
        """Uniform integer in [lo, hi] (inclusive), by rejection sampling (no modulo bias)."""
        span = hi - lo + 1
        if span <= 0:
            raise ValueError("empty range")
        bits = span.bit_length()
        while True:
            value = 0
            for _ in range((bits + 63) // 64):
                value = (value << 64) | self.next_u64()
            value >>= ((bits + 63) // 64) * 64 - bits
            if value < span:
                return lo + value

    def uniform(self) -> mpmath.mpf:
        """Uniform real in the open interval (0, 1)."""
        return (mpmath.mpf(self.next_u64()) + mpmath.mpf("0.5")) / mpmath.mpf(2**64)

    def normal(self) -> mpmath.mpf:
        """Standard normal variate via Box-Muller (one of the pair)."""
        u1 = self.uniform()
        u2 = self.uniform()
        return mpmath.sqrt(-2 * mpmath.log(u1)) * mpmath.cos(2 * mpmath.pi * u2)


def _floor_guarded(value: mpmath.mpf) -> int:
    """Floor of an mpmath value; refuses values within 1e-60 of an integer (precision would be ambiguous)."""
    floored = int(mpmath.floor(value))
    frac = value - floored
    if frac < mpmath.mpf("1e-60") or 1 - frac < mpmath.mpf("1e-60"):
        raise ArithmeticError("value too close to an integer for guarded floor")
    return floored


def decay_exact(alpha_wad: int, k: int) -> Fraction | mpmath.mpf:
    """WAD * (1 - alpha)^k, exactly when feasible."""
    if k <= EXACT_EXPONENT_LIMIT:
        return Fraction((WAD - alpha_wad) ** k * WAD, WAD**k)
    return mpmath.mpf(WAD) * (1 - mpmath.mpf(alpha_wad) / WAD) ** k


def floor_of(value: Fraction | mpmath.mpf) -> int:
    if isinstance(value, Fraction):
        return value.numerator // value.denominator
    if 0 <= value < mpmath.mpf("0.5"):
        return 0
    return _floor_guarded(value)


def decay_error_bound(k: int) -> int:
    """Worst-case round-down error of square-and-multiply with floor at every step: < 2^bitlen(k) wei.

    Level j of the squaring chain carries at most 2^j - 1 wei of error, and each multiplication into the result adds
    that error plus one floor, so the total over bitlen(k) levels stays below 2^bitlen(k).
    """
    return 1 << k.bit_length()


def ewma_first_stage_exact(ewma_wad: int | Fraction, sample: int, alpha_wad: int) -> Fraction:
    """(1 - a) * e + a * d, in WAD units (exact)."""
    return Fraction((WAD - alpha_wad) * ewma_wad, WAD) + alpha_wad * sample


def ewma_update_exact(ewma_wad: int | Fraction, sample: int, blocks: int, alpha_wad: int):
    """((1 - a) * e + a * d) * (1 - a)^(blocks - 1), exact when feasible."""
    first = ewma_first_stage_exact(ewma_wad, sample, alpha_wad)
    if blocks == 1:
        return first
    decay = decay_exact(alpha_wad, blocks - 1)
    if isinstance(decay, Fraction):
        return first * decay / WAD
    return mpmath.mpf(first.numerator) / first.denominator * decay / WAD


def ewma_error_bound(ewma_wad: int | Fraction, sample: int, blocks: int, alpha_wad: int) -> int:
    """Upper bound on floor(exact) - solidity for one EWMA update.

    For blocks == 1 the Solidity result equals floor(exact). Otherwise the first stage loses < 1 wei, the decay factor
    loses < 2^bitlen(blocks - 1) wei, and the final product loses < 1 wei.
    """
    if blocks == 1:
        return 0
    first = ewma_first_stage_exact(ewma_wad, sample, alpha_wad)
    scaled = first * decay_error_bound(blocks - 1) / WAD
    return 2 + (scaled.numerator + scaled.denominator - 1) // scaled.denominator


def ceil_div(a: int, b: int) -> int:
    return -(-a // b)


def lp_fee(ewma_wad: int, slope_pips: int) -> int:
    return min(MAX_FEE_PIPS, MIN_FEE_PIPS + ceil_div(ewma_wad * slope_pips, WAD))


def surcharge_rate(ewma_wad: int, slope_pips: int, cap_pips: int) -> int:
    return min(cap_pips, ceil_div(ewma_wad * slope_pips, WAD))


def surcharge_amount(amount: int, rate_pips: int) -> int:
    return ceil_div(amount * rate_pips, PIPS)


def pro_rated_surcharge_exact(
    amount: int, rate_pips: int, pre: int, post: int, edge: int, in_currency1: bool
) -> Fraction:
    """Exact surcharge on the part of a swap from `pre` to `post` (sqrt prices) that lies beyond the range `edge`.

    The unspecified amount is pro-rated in the coordinate in which its currency is linear at constant liquidity:
    sqrt(P) for currency1, 1/sqrt(P) for currency0 (share b/T becomes b * pre / (T * edge)).
    """
    whole = Fraction(amount * rate_pips, PIPS)
    if edge == pre:
        return whole
    share = Fraction(abs(post - edge), abs(pre - post))
    if not in_currency1:
        share *= Fraction(pre, edge)
    return whole * share


def dump_json(obj: object) -> str:
    """Canonical JSON: sorted keys, two-space indent, LF line endings, trailing newline."""
    return json.dumps(obj, indent=2, sort_keys=True) + "\n"


def write_or_check(path: Path, content: str, check: bool) -> int:
    """Write `content` to `path`, or (with check=True) verify the committed file matches it byte for byte."""
    if check:
        if not path.exists():
            print(f"MISSING {path.relative_to(ROOT).as_posix()}")
            return 1
        committed = path.read_text(encoding="utf-8").replace("\r\n", "\n")
        if committed != content:
            print(f"STALE   {path.relative_to(ROOT).as_posix()} (re-run without --check and commit the result)")
            return 1
        print(f"OK      {path.relative_to(ROOT).as_posix()} is up to date")
        return 0
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)
    print(f"WROTE   {path.relative_to(ROOT).as_posix()} ({len(content)} bytes)")
    return 0
