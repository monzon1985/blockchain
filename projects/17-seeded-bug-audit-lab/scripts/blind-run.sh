#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Blind run: execute every analysis tool on BOTH builds from a clean state (each profile's build
# directory, persisted fuzz counterexamples and Medusa corpus removed first) and write normalized
# evidence to scoreboard/evidence/. scripts/scoreboard.mjs derives the detection table from it.
#
#   scripts/blind-run.sh                  # all tools (Medusa included), then rewrite the scoreboard
#   scripts/blind-run.sh --deterministic  # skip Medusa (CI re-runs this and diffs the evidence)
#
# Environment: MEDUSA_TIMEOUT (default 180 s), RAW_DIR (raw tool output; default a temp dir).
# Requires forge 1.8.3, medusa 1.5.1 (+ crytic-compile 0.4.2), halmos 0.3.3, uv and node 24.

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-all}"
MEDUSA_TIMEOUT="${MEDUSA_TIMEOUT:-180}"
MEDUSA_WORKERS=4
RAW="${RAW_DIR:-$(mktemp -d)}"
EV=scoreboard/evidence
mkdir -p "$EV" "$RAW"
echo "blind-run: raw tool output in $RAW"

# Record bare semantic versions, so evidence written on Linux and on Windows is identical.
semver() { grep -oE '[0-9]+[.][0-9]+[.][0-9]+' | head -n 1; }
forge_version="forge $(forge --version | semver)"
halmos_version="halmos $(halmos --version 2>/dev/null | semver)"
slither_version="slither $(uv run --project detectors --locked slither --version 2>/dev/null | semver)"
if [ "$MODE" != "--deterministic" ]; then medusa_version="medusa $(medusa --version | semver)"; fi

for tree in vulnerable fixed; do
  export FOUNDRY_PROFILE="$tree"
  echo "=== $tree ==="
  # Clean, isolated state: no cached bytecode, no persisted counterexamples, no corpus.
  rm -rf "out/$tree" "cache/$tree" "medusa-corpus/$tree"

  if [ "$MODE" != "--deterministic" ]; then
    medusa fuzz --config medusa.json --timeout "$MEDUSA_TIMEOUT" --workers "$MEDUSA_WORKERS" \
      --corpus-dir "medusa-corpus/$tree" > "$RAW/medusa-$tree.log" 2>&1 || true
    node scripts/evidence.mjs medusa "$RAW/medusa-$tree.log" "$EV/medusa-$tree.json" --tree "$tree" \
      --command "FOUNDRY_PROFILE=$tree medusa fuzz --config medusa.json --timeout $MEDUSA_TIMEOUT --workers $MEDUSA_WORKERS" \
      --version "$medusa_version" \
      --budget "{\"timeout\":$MEDUSA_TIMEOUT,\"workers\":$MEDUSA_WORKERS,\"callSequenceLength\":100,\"seed\":\"none (Medusa 1.5.1 has no seed option)\"}"
  fi

  forge test --color never --match-path 'test/exploits/*' > "$RAW/exploits-$tree.txt" 2>&1 || true
  node scripts/evidence.mjs forge "$RAW/exploits-$tree.txt" "$EV/exploits-$tree.json" --tree "$tree" \
    --command "FOUNDRY_PROFILE=$tree forge test --match-path 'test/exploits/*'" --version "$forge_version"

  forge test --color never --match-path 'test/regression/*' > "$RAW/regressions-$tree.txt" 2>&1 || true
  node scripts/evidence.mjs forge "$RAW/regressions-$tree.txt" "$EV/regressions-$tree.json" --tree "$tree" \
    --command "FOUNDRY_PROFILE=$tree forge test --match-path 'test/regression/*'" --version "$forge_version"

  budget="$(forge config --json | node -e '
    const c = JSON.parse(require("fs").readFileSync(0, "utf8"));
    process.stdout.write(JSON.stringify({ runs: c.invariant.runs, depth: c.invariant.depth,
      workers: c.invariant.workers, seed: c.fuzz.seed }));')"
  forge test --color never --match-path 'test/invariant/*' > "$RAW/invariants-$tree.txt" 2>&1 || true
  node scripts/evidence.mjs forge "$RAW/invariants-$tree.txt" "$EV/foundry-invariants-$tree.json" --tree "$tree" \
    --command "FOUNDRY_PROFILE=$tree forge test --match-path 'test/invariant/*'" --version "$forge_version" \
    --budget "$budget"

  halmos --match-contract FixedProperties --forge-build-out "out/$tree" \
    --json-output "$RAW/halmos-$tree.json" > "$RAW/halmos-$tree.txt" 2>&1 || true
  node scripts/evidence.mjs halmos "$RAW/halmos-$tree.json" "$EV/halmos-$tree.json" --tree "$tree" \
    --command "FOUNDRY_PROFILE=$tree halmos --match-contract FixedProperties --forge-build-out out/$tree" \
    --version "$halmos_version"

  uv run --project detectors --locked slither . --config-file slither.config.json --json - \
    > "$RAW/slither-$tree.json" 2> "$RAW/slither-$tree.log" || true
  node scripts/evidence.mjs slither "$RAW/slither-$tree.json" "$EV/slither-$tree.json" --tree "$tree" \
    --command "FOUNDRY_PROFILE=$tree uv run --project detectors slither . --config-file slither.config.json --json -" \
    --version "$slither_version"
done
unset FOUNDRY_PROFILE

node scripts/scoreboard.mjs
echo "blind-run: evidence written to $EV"
