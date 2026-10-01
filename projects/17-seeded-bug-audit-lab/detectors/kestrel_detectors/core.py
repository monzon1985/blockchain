# SPDX-License-Identifier: MIT
"""Core detection logic for the Kestrel custom Slither detectors.

Each detector takes a :class:`slither.Slither` instance and returns a list of :class:`Hit`.
The logic is decoupled from Slither's CLI plumbing so the pytest precision/recall harness can
call it directly on labelled fixtures, and the plugin wrappers in ``detectors.py`` report the
same hits through ``slither --detect``.

A hit identifies its site as ``<source path>:<Contract>.<function>`` so identically named
contracts in different trees are never confused, plus a ``detail`` naming what triggered it.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from slither.core.cfg.node import NodeType
from slither.core.declarations import Function, SolidityVariableComposed
from slither.core.variables.state_variable import StateVariable
from slither.detectors.statements.divide_before_multiply import detect_divide_before_multiply
from slither.slithir.operations import (
    Condition,
    HighLevelCall,
    InternalCall,
    LibraryCall,
    LowLevelCall,
    SolidityCall,
)

# Calls whose result is a price that a single transaction can move: AMM spot reserves,
# token balances (donations), ERC-4626 share prices.
SPOT_CALLS = {
    "balanceOf",
    "getReserves",
    "spotPrice0In1",
    "spotPrice",
    "totalAssets",
    "convertToAssets",
    "convertToShares",
    "pricePerShare",
}

# A function whose name says it produces a valuation used in risk math.
VALUATION_RE = re.compile(r"(collateral|price|value|health|ltv|quote|borrow)", re.IGNORECASE)

# Modifiers whose name implies caller-based access control (not, e.g., reentrancy guards).
ACCESS_MODIFIER_RE = re.compile(r"(only|auth|owner|admin|role|restrict|permission)", re.IGNORECASE)

# Reads that reflect a historical checkpoint: authorization derived from them is durable.
SNAPSHOT_CALLS = {"getPastVotes", "getPastTotalSupply", "getPriorVotes", "balanceOfAt", "totalSupplyAt"}
# Reads that reflect the current balance: a flash loan can inflate them inside one transaction.
FLASHABLE_CALLS = {"balanceOf", "totalSupply", "getVotes", "getCurrentVotes"}


@dataclass(frozen=True, order=True)
class Hit:
    """One detector finding."""

    path: str
    contract: str
    function: str
    detail: str

    @property
    def fid(self) -> str:
        """``Contract.function``."""
        return f"{self.contract}.{self.function}"

    @property
    def site(self) -> str:
        """``<path>:Contract.function``: unique across trees with identical contract names."""
        return f"{self.path}:{self.fid}"


def _path(function: Function) -> str:
    mapping = function.source_mapping
    if mapping is None or mapping.filename is None:
        return "<unknown>"
    return mapping.filename.relative.replace("\\", "/")


def _hit(function: Function, detail: str) -> Hit:
    return Hit(_path(function), function.contract_declarer.name, function.name, detail)


def _call_name(ir) -> str | None:
    if isinstance(ir, (HighLevelCall, InternalCall, LibraryCall)):
        return getattr(ir.function, "name", None)
    if isinstance(ir, SolidityCall):
        return ir.function.name
    return None


# ---------------------------------------------------------------------------------------------
# Detector 1: collateral / price math derived from a spot or share-price source
# ---------------------------------------------------------------------------------------------


def detect_spot_price_collateral(slither) -> list[Hit]:
    """A valuation function (collateral, price, health, ...) that consumes, through an external
    call, a price which one transaction can move: AMM reserves or spot, ``balanceOf``, or an
    ERC-4626 share price. The AMM's own spot view is a source, not a consumer, so own-state
    reads are not flagged. One hit is reported per (function, source), so a fix that removes
    one source is visible."""
    hits: set[Hit] = set()
    for contract in slither.contracts:
        for function in contract.functions_declared:
            if not VALUATION_RE.search(function.name or ""):
                continue
            for node in function.nodes:
                for ir in node.irs:
                    name = _call_name(ir)
                    if name in SPOT_CALLS and isinstance(ir, HighLevelCall):
                        hits.add(_hit(function, name))
    return sorted(hits)


# ---------------------------------------------------------------------------------------------
# Detector 2: externally callable arbitrary call without a durable authorization
# ---------------------------------------------------------------------------------------------


def _producers(function: Function) -> dict:
    produced: dict = {}
    for node in function.nodes:
        for ir in node.irs:
            lvalue = getattr(ir, "lvalue", None)
            if lvalue is not None:
                produced.setdefault(lvalue, []).append(ir)
    return produced


def _condition_variables(function: Function) -> list:
    """Variables tested by ``require``/``assert``/``if`` in ``function`` and its modifiers."""
    found = []
    functions = [function] + [m for m in function.modifiers if isinstance(m, Function)]
    for fn in functions:
        for node in fn.nodes:
            for ir in node.irs:
                if isinstance(ir, SolidityCall) and ir.function.name.startswith(("require(", "assert(")):
                    if ir.arguments:
                        found.append((fn, ir.arguments[0]))
                elif isinstance(ir, Condition):
                    found.append((fn, ir.value))
    return found


def _classify_guard(fn: Function, variable) -> tuple[bool, bool]:
    """Return (durable, flashable) for one tested variable.

    ``durable``: the condition depends on contract storage, a historical checkpoint, or the
    caller's identity (``msg.sender`` compared directly or passed to a non-balance check).
    ``flashable``: the condition depends on a current balance or supply, which a flash loan can
    inflate within the transaction.
    """
    produced = _producers(fn)
    durable = False
    flashable = False
    seen: set = set()
    stack = [variable]
    while stack:
        var = stack.pop()
        if id(var) in seen:
            continue
        seen.add(id(var))
        if isinstance(var, StateVariable) and not var.is_constant and not var.is_immutable:
            durable = True
        if isinstance(var, SolidityVariableComposed) and var.name == "msg.sender":
            durable = True
        for ir in produced.get(var, []):
            name = _call_name(ir)
            if name in SNAPSHOT_CALLS:
                durable = True
                continue
            if name in FLASHABLE_CALLS:
                flashable = True
                continue  # msg.sender passed to balanceOf is not an identity check
            stack.extend(getattr(ir, "read", []))
    return durable, flashable


def _arbitrary_low_level_call(function: Function) -> bool:
    for node in function.nodes:
        for ir in node.irs:
            if isinstance(ir, LowLevelCall):
                destination = ir.destination
                to_caller = (
                    isinstance(destination, SolidityVariableComposed) and destination.name == "msg.sender"
                )
                if not to_caller:
                    return True
    return False


def detect_unchecked_callback(slither) -> list[Hit]:
    """An externally callable, state-changing function that makes a low-level call to a
    destination other than ``msg.sender`` and is not protected by a durable authorization: no
    access-control modifier, and either no guarding condition depends on storage, checkpoints
    or caller identity, or some guarding condition depends on a flash-loanable balance."""
    hits: set[Hit] = set()
    for contract in slither.contracts:
        for function in contract.functions_declared:
            if function.is_constructor or function.visibility not in ("public", "external"):
                continue
            if function.view or function.pure:
                continue
            if not _arbitrary_low_level_call(function):
                continue
            if any(ACCESS_MODIFIER_RE.search(m.name or "") for m in function.modifiers):
                continue
            durable = False
            flashable = False
            for fn, variable in _condition_variables(function):
                d, f = _classify_guard(fn, variable)
                durable |= d
                flashable |= f
            if flashable:
                hits.add(_hit(function, "authorization from a flash-loanable balance"))
            elif not durable:
                hits.add(_hit(function, "no authorization"))
    return sorted(hits)


# ---------------------------------------------------------------------------------------------
# Detector 3: division before multiplication inside a loop
# ---------------------------------------------------------------------------------------------


def _loop_node_ids(function: Function) -> set[int]:
    ids: set[int] = set()
    for start in [n for n in function.nodes if n.type == NodeType.STARTLOOP]:
        stack = [start]
        seen: set[int] = set()
        while stack:
            node = stack.pop()
            if id(node) in seen:
                continue
            seen.add(id(node))
            ids.add(id(node))
            if node.type == NodeType.ENDLOOP:
                continue
            stack.extend(node.sons)
    return ids


def detect_div_before_mul_in_loop(slither) -> list[Hit]:
    """A division whose result is later multiplied, inside a loop, where the truncation error is
    amplified per iteration."""
    hits: set[Hit] = set()
    for contract in slither.contracts:
        loop_cache: dict[int, set[int]] = {}
        for function, nodes in detect_divide_before_multiply(contract):
            key = id(function)
            if key not in loop_cache:
                loop_cache[key] = _loop_node_ids(function)
            if any(id(n) in loop_cache[key] for n in nodes):
                hits.add(_hit(function, "divide-before-multiply in loop"))
    return sorted(hits)
