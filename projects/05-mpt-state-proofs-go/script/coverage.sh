#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Line coverage of the production packages, merged across the unit and integration suites.
#
#   bash script/coverage.sh            # run both suites and print the per-package summary
#   COVERAGE_MIN=90 bash script/coverage.sh   # also fail below 90 %
#
# Production code is everything a user of the module or of the trie command runs. Test
# infrastructure (internal/devnet, internal/rpcreplay, internal/tools, internal/archtest) and
# the three-line main of cmd/trie are excluded from the denominator.
set -euo pipefail
cd "$(dirname "$0")/.."

MODULE=github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go
PKGS=(keccak rlp trie block stateproof ethrpc inspect internal/cli)
COVERPKG=$(printf "${MODULE}/%s," "${PKGS[@]}")
COVERPKG=${COVERPKG%,}
# The integration suite runs the CLI as a subprocess, so internal/cli is not loaded in-process.
INT_COVERPKG=${COVERPKG%,"${MODULE}/internal/cli"}
DIR=${COVERAGE_DIR:-covdata}
rm -rf "$DIR"
mkdir -p "$DIR/unit" "$DIR/integration"
export CGO_ENABLED=0

echo "== unit suite"
go test -count=1 -p 4 -cover -coverpkg="$COVERPKG" ./... -args -test.gocoverdir="$(pwd)/$DIR/unit" >/dev/null
echo "== integration suite (anvil)"
go test -count=1 -cover -coverpkg="$INT_COVERPKG" -tags integration ./integration/... -args -test.gocoverdir="$(pwd)/$DIR/integration" >/dev/null

go tool covdata textfmt -i="$DIR/unit,$DIR/integration" -o "$DIR/merged.out"
go tool covdata percent -i="$DIR/unit,$DIR/integration"
TOTAL=$(go tool cover -func="$DIR/merged.out" | awk '/^total:/ {print $3}')
echo "total (unit + integration): $TOTAL"

if [[ -n "${COVERAGE_MIN:-}" ]]; then
  awk -v t="${TOTAL%\%}" -v m="$COVERAGE_MIN" 'BEGIN { if (t + 0 < m + 0) { printf "coverage %s%% is below %s%%\n", t, m; exit 1 } }'
fi
