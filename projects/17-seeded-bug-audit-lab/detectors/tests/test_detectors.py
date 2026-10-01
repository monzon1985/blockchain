# SPDX-License-Identifier: MIT
"""Precision/recall of the three custom detectors over labelled fixtures.

Each fixture function is labelled POSITIVE or NEGATIVE in its source comment; the ground truth
per detector is declared below. Fixtures include adversarial negatives that look like the
positives (a TWAP-priced valuation whose name contains "price", a quorum-gated call, a
checkpoint-gated call), so a name-only heuristic would fail these tests.

The fixtures are compiled hermetically: copied to a temporary directory, compiled with
``compile_force_framework="solc"`` and an explicit solc 0.8.37 (via solc-select's
``SOLC_VERSION``), with crytic-compile's working directory pinned to that temporary directory,
so it never walks up to the enclosing Foundry project and never touches its build output.
"""

from __future__ import annotations

import os
import pathlib
import shutil

import pytest
from slither import Slither

from kestrel_detectors.core import (
    Hit,
    detect_div_before_mul_in_loop,
    detect_spot_price_collateral,
    detect_unchecked_callback,
)

FIXTURES = pathlib.Path(__file__).parent / "fixtures"
SOLC_VERSION = "0.8.37"

# Ground-truth positives (Contract.function) per detector.
EXPECTED = {
    "spot": {"SpotPositives.collateralValue", "SpotPositives.priceOfShare"},
    "callback": {
        "CallbackPositives.onFlashLoan",
        "CallbackPositives.distribute",
        "CallbackPositives.balanceGated",
    },
    "loop": {"LoopPositives.rewards", "LoopPositives.shares"},
}

# The source each spot hit must name (one hit per function x source).
EXPECTED_SPOT_DETAILS = {
    ("SpotPositives.collateralValue", "getReserves"),
    ("SpotPositives.collateralValue", "balanceOf"),
    ("SpotPositives.priceOfShare", "convertToAssets"),
}

DETECTORS = {
    "spot": detect_spot_price_collateral,
    "callback": detect_unchecked_callback,
    "loop": detect_div_before_mul_in_loop,
}


@pytest.fixture(scope="module")
def compiled(tmp_path_factory) -> list[Slither]:
    """Compile every fixture with plain solc, from a temporary directory outside any project."""
    os.environ.setdefault("SOLC_VERSION", SOLC_VERSION)
    workdir = tmp_path_factory.mktemp("fixtures")
    previous = pathlib.Path.cwd()
    units = []
    try:
        os.chdir(workdir)
        for sol in sorted(FIXTURES.glob("*.sol")):
            shutil.copy(sol, workdir / sol.name)
            units.append(Slither(sol.name, compile_force_framework="solc", solc="solc"))
    finally:
        os.chdir(previous)
    return units


@pytest.fixture(scope="module")
def hits(compiled) -> dict[str, list[Hit]]:
    found: dict[str, list[Hit]] = {}
    for name, detector in DETECTORS.items():
        found[name] = [hit for unit in compiled for hit in detector(unit)]
    return found


def _precision_recall(flagged: set[str], expected: set[str]) -> tuple[float, float]:
    tp = len(flagged & expected)
    precision = tp / len(flagged) if flagged else 1.0
    recall = tp / len(expected) if expected else 1.0
    return precision, recall


@pytest.mark.parametrize("name", list(EXPECTED))
def test_detector_precision_recall(hits, name):
    flagged = {hit.fid for hit in hits[name]}
    expected = EXPECTED[name]
    precision, recall = _precision_recall(flagged, expected)
    assert precision == 1.0, f"{name}: false positives {sorted(flagged - expected)}"
    assert recall == 1.0, f"{name}: missed {sorted(expected - flagged)}"


def test_spot_hits_name_their_source(hits):
    assert {(hit.fid, hit.detail) for hit in hits["spot"]} == EXPECTED_SPOT_DETAILS


def test_callback_hits_explain_the_gap(hits):
    details = {hit.fid: hit.detail for hit in hits["callback"]}
    assert details["CallbackPositives.balanceGated"] == "authorization from a flash-loanable balance"
    assert details["CallbackPositives.distribute"] == "no authorization"


def test_sites_include_the_source_path(hits):
    for hit in (h for found in hits.values() for h in found):
        assert hit.site.endswith(f"{hit.path.split('/')[-1]}:{hit.fid}")
        assert hit.path.endswith(".sol")


def test_detectors_do_not_cross_fire(hits):
    all_expected = set().union(*EXPECTED.values())
    for name, found in hits.items():
        flagged = {hit.fid for hit in found}
        assert flagged <= all_expected, f"{name} flagged unexpected items: {sorted(flagged - all_expected)}"
