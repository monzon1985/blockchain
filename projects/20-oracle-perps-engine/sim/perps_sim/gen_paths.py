# SPDX-License-Identifier: MIT
"""Writes (or checks) the price-path fixtures consumed by the Foundry replay test and the Go signers.

Usage::

    uv run python -m perps_sim.gen_paths            # regenerate contracts/test/fixtures/paths/*.json
    uv run python -m perps_sim.gen_paths --check    # exit 1 if the committed fixtures differ
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from perps_sim.paths import PathSpec, generate_path

# Six one-day paths at 5-minute resolution around a $3,000 index price.
SPECS: tuple[PathSpec, ...] = (
    PathSpec("gbm_calm", "gbm", 101, "3000", "0", "0.45", 300, 288),
    PathSpec("gbm_volatile", "gbm", 102, "3000", "0", "1.20", 300, 288),
    PathSpec("gbm_rally", "gbm", 103, "3000", "60", "0.70", 300, 288),
    PathSpec("gbm_selloff", "gbm", 104, "3000", "-60", "0.70", 300, 288),
    PathSpec("merton_crash", "merton", 105, "3000", "0", "0.60", 300, 288, "1460", "-0.12", "0.03"),
    PathSpec("merton_squeeze", "merton", 106, "3000", "0", "0.60", 300, 288, "1460", "0.15", "0.03"),
)

DEFAULT_OUT = Path(__file__).resolve().parents[2] / "contracts" / "test" / "fixtures" / "paths"


def fixture(spec: PathSpec) -> dict[str, object]:
    """The JSON document for one path. Prices are decimal strings (WAD) because they exceed 2^53."""
    return {
        "name": spec.name,
        "model": spec.model,
        "seed": spec.seed,
        "params": spec.params(),
        "dtSeconds": spec.dt_seconds,
        "prices": [str(p) for p in generate_path(spec)],
    }


def render(doc: dict[str, object]) -> str:
    return json.dumps(doc, indent=2) + "\n"


def write_all(out: Path, specs: tuple[PathSpec, ...] = SPECS) -> list[Path]:
    out.mkdir(parents=True, exist_ok=True)
    written = []
    for spec in specs:
        path = out / f"{spec.name}.json"
        path.write_text(render(fixture(spec)), encoding="utf-8", newline="\n")
        written.append(path)
    return written


def check_all(out: Path, specs: tuple[PathSpec, ...] = SPECS) -> list[str]:
    """Returns human-readable problems; an empty list means the fixtures are up to date.

    Documents are compared after parsing, so line endings introduced by a checkout do not matter.
    """
    problems: list[str] = []
    expected = {f"{s.name}.json": s for s in specs}
    present = {p.name for p in out.glob("*.json")} if out.is_dir() else set()
    for name in sorted(present - expected.keys()):
        problems.append(f"unexpected fixture {name}")
    for name, spec in sorted(expected.items()):
        path = out / name
        if not path.is_file():
            problems.append(f"missing fixture {name}")
            continue
        committed = json.loads(path.read_text(encoding="utf-8"))
        regenerated = fixture(spec)
        if committed != regenerated:
            diff_keys = [k for k in regenerated if committed.get(k) != regenerated[k]]
            problems.append(f"stale fixture {name} (differs in: {', '.join(diff_keys) or 'extra keys'})")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--check", action="store_true", help="verify the committed fixtures instead of writing"
    )
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="fixture directory")
    args = parser.parse_args(argv)

    if args.check:
        problems = check_all(args.out)
        for p in problems:
            print(f"error: {p}", file=sys.stderr)
        if problems:
            print("run `uv run python -m perps_sim.gen_paths` to regenerate", file=sys.stderr)
            return 1
        print(f"{len(SPECS)} fixtures up to date in {args.out}")
        return 0

    for path in write_all(args.out):
        print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
