#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Slither gate for the fixed tree: standard detectors plus the kestrel plugin, normalized, then
# every finding must be triaged in slither.triage.json (scripts/slither-triage.mjs).
#
#   scripts/slither-gate.sh [output-dir]     # default output dir: a fresh temp dir
#
# Requires uv (the detectors project pins Slither 0.11.6) and node 24.

set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-$(mktemp -d)}"
mkdir -p "$OUT"
FOUNDRY_PROFILE=fixed uv run --project detectors --locked slither . --config-file slither.config.json \
  --json - > "$OUT/slither-fixed.raw.json" 2> "$OUT/slither-fixed.log" || true
node scripts/evidence.mjs slither "$OUT/slither-fixed.raw.json" "$OUT/slither-fixed.json" \
  --tree fixed --command "scripts/slither-gate.sh"
node scripts/slither-triage.mjs "$OUT/slither-fixed.json"
echo "slither-gate: raw and normalized output in $OUT"
