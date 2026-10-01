# SPDX-License-Identifier: MIT
"""Kestrel custom Slither detectors (registered as the ``kestrel`` Slither plugin)."""

from __future__ import annotations

from .detectors import DivBeforeMulInLoop, SpotPriceCollateral, UncheckedCallback

__all__ = ["DivBeforeMulInLoop", "SpotPriceCollateral", "UncheckedCallback", "make_plugin"]


def make_plugin():
    """Slither plugin entry point: return (detectors, printers)."""
    return [SpotPriceCollateral, UncheckedCallback, DivBeforeMulInLoop], []
