#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Go statement coverage of the production packages (internal/* except the generated bindings
# and the test-support packages, plus cmd/), measured across both halves of the suite and
# merged with `go tool covdata`:
#   unit         unit, property, scenario, concurrency, simulation and storage-fault tests
#   integration  the anvil and chaos tests (-tags integration; needs anvil and a forge build)
#   merge        merges whatever halves exist and fails below COVERAGE_MIN percent
# CI runs the halves in separate jobs and the merge in a third; with no argument this script
# runs all three in sequence.
#
# Usage: bash script/coverage.sh [unit|integration|merge|all]
# Env:   COVERAGE_DIR (default .coverage), COVERAGE_MIN (default 90)
set -euo pipefail

cd "$(dirname "$0")/.."
DIR="$(pwd)/${COVERAGE_DIR:-.coverage}"
MIN="${COVERAGE_MIN:-90}"
export CGO_ENABLED=0
# Native paths for the go tool when running under MSYS/Git Bash on Windows.
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
PKGS=$(go list ./internal/... ./cmd/... | grep -vE 'internal/(bindings|chainsim|testenv|tools)' | paste -sd, -)

unit() {
  rm -rf "$DIR/unit" && mkdir -p "$DIR/unit"
  go test -count=1 -p 4 -cover -coverpkg="$PKGS" ./... -args -test.gocoverdir="$(native "$DIR/unit")"
}

integration() {
  rm -rf "$DIR/integration" && mkdir -p "$DIR/integration"
  go test -count=1 -tags integration -timeout 20m -v -cover -coverpkg="$PKGS" ./integration/... \
    -args -test.gocoverdir="$(native "$DIR/integration")"
}

merge() {
  local inputs=() d
  for d in unit integration; do
    if [[ -d "$DIR/$d" ]] && compgen -G "$DIR/$d/covcounters.*" >/dev/null; then inputs+=("$(native "$DIR/$d")"); fi
  done
  if [[ ${#inputs[@]} -eq 0 ]]; then
    echo "coverage: no coverage data under $DIR" >&2
    return 1
  fi
  local joined
  joined=$(IFS=,; printf '%s' "${inputs[*]}")
  go tool covdata percent -i="$joined" -pkg="$PKGS"
  go tool covdata textfmt -i="$joined" -pkg="$PKGS" -o "$(native "$DIR/merged.out")"
  local total
  total=$(go tool cover -func="$(native "$DIR/merged.out")" | awk '/^total:/ {sub("%", "", $3); print $3}')
  echo "Go statement coverage over ${#inputs[@]} suite(s) (${joined}): ${total}% (minimum ${MIN}%)"
  awk -v t="$total" -v m="$MIN" 'BEGIN { exit !(t + 0 >= m + 0) }' || {
    echo "coverage: ${total}% is below the ${MIN}% minimum" >&2
    return 1
  }
}

case "${1:-all}" in
unit) unit ;;
integration) integration ;;
merge) merge ;;
all) unit && integration && merge ;;
*)
  echo "usage: $0 [unit|integration|merge|all]" >&2
  exit 2
  ;;
esac
