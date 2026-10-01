# SPDX-License-Identifier: MIT
"""Statistical sanity checks of the committed GBM paths (numpy)."""

import json

import numpy as np
import pytest

from volfee_model import FIXTURES

TICK = np.log(1.0001)


@pytest.fixture(scope="module")
def fixture():
    return json.loads((FIXTURES / "gbm_paths.json").read_text(encoding="utf-8"))


def test_shape(fixture):
    assert fixture["version"] == 1
    for path in fixture["paths"]:
        assert len(path["extTicks"]) == fixture["blocks"]
        assert len(path["noiseAmounts"]) == fixture["blocks"] * fixture["noiseSlots"]
        assert len(path["noiseMaxFeePips"]) == len(path["noiseAmounts"])


@pytest.mark.parametrize("name", ["calm", "normal", "stressed"])
def test_realized_volatility_matches_target(fixture, name):
    path = next(p for p in fixture["paths"] if p["name"] == name)
    ticks = np.asarray([0, *path["extTicks"]], dtype=float)
    log_returns = np.diff(ticks) * TICK
    target = float(path["sigmaBpsPerBlock"][0]) / 1e4
    realized = log_returns.std(ddof=1)
    # 400 samples: the standard error of a sample stdev is ~3.5%; ticks are rounded to integers, which adds
    # variance for the calm regime (sigma = 1.5 ticks), hence the looser upper bound.
    assert 0.85 * target < realized < 1.25 * target


def test_regime_switch_has_a_stressed_middle(fixture):
    path = next(p for p in fixture["paths"] if p["name"] == "regime-switch")
    moves = np.abs(np.diff(np.asarray([0, *path["extTicks"]], dtype=float)))
    assert moves[150:250].mean() > 4 * moves[:150].mean()
    assert moves[150:250].mean() > 4 * moves[250:].mean()


def test_noise_flow(fixture):
    for path in fixture["paths"]:
        amounts = np.asarray(path["noiseAmounts"], dtype=float)
        present = amounts[amounts != 0]
        assert 0.5 < present.size / amounts.size < 0.7  # 60% presence probability
        assert 0.4 < (present > 0).mean() < 0.6  # both directions
        fees = np.asarray(path["noiseMaxFeePips"])[amounts != 0]
        assert fees.min() >= 500 and fees.max() <= 6_000
