# SPDX-License-Identifier: MIT
"""Run halmos with CPython's cyclic garbage collector disabled.

Windows-only workaround. On Windows, halmos 0.3.3 can abort with a heap-corruption fault
(0xc0000374): its solver threads never hold z3 objects, but CPython's cyclic GC may run on a solver
thread and free z3 objects created by the main thread (Z3_dec_ref) while the main thread is inside z3
(Z3_solver_pop). With the cyclic GC off, z3 objects are only freed by reference counting on the thread
that drops them. Nothing else changes: this imports and runs halmos's own entry point with the same
arguments. CI (Linux) runs the plain `halmos` command.

Usage (from the project root, with the halmos uv tool's interpreter):
    FOUNDRY_PROFILE=halmos "$(uv tool dir)/halmos/Scripts/python.exe" scripts/halmos_nogc.py \
        --match-contract Equivalence
"""

import gc
import sys

gc.disable()

from halmos.__main__ import main  # noqa: E402  (import after disabling the GC on purpose)

sys.exit(main())
