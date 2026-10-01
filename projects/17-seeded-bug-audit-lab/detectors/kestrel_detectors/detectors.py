# SPDX-License-Identifier: MIT
"""Slither ``AbstractDetector`` wrappers around the core logic.

These are what the ``kestrel`` plugin registers, so ``slither .`` run in the detectors
environment reports the custom findings next to the standard ones. Every result carries
``additional_fields.detail`` (what triggered it) and ``additional_fields.site``
(``<path>:Contract.function``) so triage and the scoreboard can key on them.
"""

from __future__ import annotations

from slither.detectors.abstract_detector import AbstractDetector, DetectorClassification

from .core import (
    Hit,
    detect_div_before_mul_in_loop,
    detect_spot_price_collateral,
    detect_unchecked_callback,
)

WIKI = "https://github.com/monzon1985/blockchain/tree/main/projects/17-seeded-bug-audit-lab#detectors"


def _function_of(slither, hit: Hit):
    for contract in slither.contracts:
        if contract.name != hit.contract:
            continue
        for function in contract.functions_declared:
            mapping = function.source_mapping
            path = mapping.filename.relative.replace("\\", "/") if mapping and mapping.filename else ""
            if function.name == hit.function and path == hit.path:
                return function
    return None


def _results(detector: AbstractDetector, hits: list[Hit], message: str) -> list:
    results = []
    for hit in hits:
        function = _function_of(detector.slither, hit)
        if function is None:
            continue
        info = [function, message.format(detail=hit.detail), "\n"]
        results.append(
            detector.generate_result(info, additional_fields={"detail": hit.detail, "site": hit.site})
        )
    return results


class SpotPriceCollateral(AbstractDetector):
    """Valuation math that consumes a price one transaction can move."""

    ARGUMENT = "kestrel-spot-price-collateral"
    HELP = "Collateral/price math derived from a manipulable spot or share-price source"
    IMPACT = DetectorClassification.HIGH
    CONFIDENCE = DetectorClassification.MEDIUM
    WIKI = WIKI
    WIKI_TITLE = "Spot-priced collateral"
    WIKI_DESCRIPTION = (
        "A valuation function derives a price from AMM reserves, balanceOf, totalAssets or an "
        "ERC-4626 share price, all of which can be moved within a single transaction."
    )
    WIKI_EXPLOIT_SCENARIO = (
        "collateralValue() reads pool.spotPrice0In1(); an attacker swaps to move the spot and "
        "borrows against the inflated collateral (SC03)."
    )
    WIKI_RECOMMENDATION = "Price collateral from a TWAP or an external manipulation-resistant oracle."

    def _detect(self):
        return _results(
            self,
            detect_spot_price_collateral(self.slither),
            " values collateral/prices from `{detail}`, which one transaction can move",
        )


class UncheckedCallback(AbstractDetector):
    """Arbitrary external call without a durable authorization."""

    ARGUMENT = "kestrel-unchecked-callback"
    HELP = "Arbitrary call gated by nothing durable (no authorization, or a flash-loanable balance)"
    IMPACT = DetectorClassification.HIGH
    CONFIDENCE = DetectorClassification.MEDIUM
    WIKI = WIKI
    WIKI_TITLE = "Unchecked external callback"
    WIKI_DESCRIPTION = (
        "A public/external state-changing function performs a low-level call to a non-msg.sender "
        "destination, and its authorization is either missing or derived from a current balance "
        "that a flash loan can inflate."
    )
    WIKI_EXPLOIT_SCENARIO = (
        "emergencyExecute(target, data) checks token.balanceOf(msg.sender) against a quorum; an "
        "attacker flash-mints the token and executes an arbitrary call (SC04)."
    )
    WIKI_RECOMMENDATION = (
        "Gate arbitrary calls on caller identity, stored state or historical checkpoints "
        "(getPastVotes), never on current balances."
    )

    def _detect(self):
        return _results(
            self,
            detect_unchecked_callback(self.slither),
            " makes an arbitrary low-level call with {detail}",
        )


class DivBeforeMulInLoop(AbstractDetector):
    """Division before multiplication inside a loop."""

    ARGUMENT = "kestrel-div-before-mul-loop"
    HELP = "Division before multiplication inside a loop (amplified precision loss)"
    IMPACT = DetectorClassification.MEDIUM
    CONFIDENCE = DetectorClassification.MEDIUM
    WIKI = WIKI
    WIKI_TITLE = "Divide-before-multiply in a loop"
    WIKI_DESCRIPTION = (
        "A division whose result is later multiplied, occurring inside a loop, so the "
        "per-iteration truncation error accumulates."
    )
    WIKI_EXPLOIT_SCENARIO = (
        "A reward or rounding loop computes (a / b) * c each iteration; the truncation "
        "compounds into an extractable error (SC07 amplification)."
    )
    WIKI_RECOMMENDATION = "Reorder to multiply before dividing, or accumulate in higher precision."

    def _detect(self):
        return _results(
            self,
            detect_div_before_mul_in_loop(self.slither),
            " divides before multiplying inside a loop",
        )
