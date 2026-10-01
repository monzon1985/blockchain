#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The project's gates as one command. The CI workflow calls the same stages, so the README's
# commands and CI cannot drift apart.
#
#   bash script/check.sh                   # fixture hygiene unit integration demo (what CI gates)
#   bash script/check.sh unit integration  # selected stages, in the order given
#   bash script/check.sh fuzz              # the 5 native fuzz targets
#   bash script/check.sh coverage          # merged statement coverage, minimum COVERAGE_MIN (90)
#   bash script/check.sh race              # race detector (needs cgo: CI only on this project)
#
# Stages:
#   fixture      forge fmt --check, build, lint and test of fixtures/ (ci profile: fixed fuzz seed)
#   hygiene      go mod tidy -diff, go mod verify, gofmt, go vet with and without the integration
#                tag, and the ignore rules (no Go source ignored, the README's bin/trie ignored)
#   unit         go test ./...: unit, vector, differential, property and CLI golden tests
#   integration  go test -tags integration ./integration/...: anvil, Berlin to Osaka
#   demo         go run ./internal/tools/demo: the README walkthrough, end to end
#   fuzz         FuzzRLPRoundTrip and FuzzTrieOrderIndependence for FUZZTIME_GATE (default 30s),
#                FuzzVerifyProof, FuzzHexPrefix and FuzzDecodeRPC for FUZZTIME_OTHER (default 30s)
#   coverage     script/coverage.sh
#   race         the unit and integration suites under -race
#
# Each stage keeps its full output in <name>.log. The console shows the per-package results and
# test counts and, when a test fails, the output that explains the failure.
set -euo pipefail
cd "$(dirname "$0")/.."
export CGO_ENABLED="${CGO_ENABLED:-0}"

DEFAULT_STAGES=(fixture hygiene unit integration demo)

# gotest LOG ARGS...: runs `go test -v ARGS`, keeping the whole output in LOG.
gotest() {
  local log=$1
  shift
  local rc=0
  go test -v "$@" >"$log" 2>&1 || rc=$?
  grep -E '^(ok|FAIL|panic:)' "$log" || true
  local top sub skipped
  top=$(grep -cE '^--- (PASS|FAIL|SKIP)' "$log" || true)
  sub=$(grep -cE '^[[:space:]]+--- (PASS|FAIL|SKIP)' "$log" || true)
  skipped=$(grep -cE -- '--- SKIP' "$log" || true)
  echo "$log: $top top-level tests, $sub subtests, $skipped skipped"
  if [[ $rc -ne 0 ]]; then
    echo "---- failure details (full output in $log) ----"
    failure_details "$log"
    return "$rc"
  fi
}

# failure_details LOG: with -v, a test's output (testify's Error Trace / Error / Messages, a
# race report) is printed while it runs, under "=== RUN <name>", and its "--- FAIL: <name>"
# line comes later (for subtests, after their siblings). Collect each test's output by name
# and print it next to its FAIL line; also print compiler output of a failed build and
# everything from a panic on. Fall back to the log's tail if nothing matched.
failure_details() {
  local details
  details=$(awk '
    panicked { print; next }
    /^panic:/ { panicked = 1; print; next }
    /^=== (RUN|CONT|NAME|PAUSE) / { cur = $3; next }
    /^# / { cur = "#build" }
    /\[(build|setup) failed\]/ { printf "%s", out["#build"]; print; out["#build"] = ""; next }
    /^(PASS|FAIL|ok)([[:space:]]|$)/ { cur = ""; next }
    /^[[:space:]]*--- FAIL: / { printf "%s", out[$3]; print; next }
    { out[cur] = out[cur] $0 "\n" }
  ' "$1")
  if [[ -n $details ]]; then
    printf '%s\n' "$details"
  else
    tail -n 200 "$1"
  fi
}

build_fixture() {
  (cd fixtures && forge build >/dev/null)
}

stage_fixture() {
  (
    cd fixtures
    export FOUNDRY_PROFILE=ci
    forge fmt --check
    forge build
    forge lint
    forge test -vv
  )
}

stage_hygiene() {
  go mod tidy -diff
  go mod verify
  local unformatted
  unformatted=$(gofmt -l .)
  if [[ -n $unformatted ]]; then
    printf 'gofmt -l lists unformatted files:\n%s\n' "$unformatted"
    return 1
  fi
  go vet ./...
  go vet -tags integration ./...
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # A .gitignore rule once matched the trie/ package: every Go source must be committable.
    local hidden
    hidden=$(git ls-files --others --ignored --exclude-standard -- '*.go' 'go.mod' 'go.sum')
    if [[ -n $hidden ]]; then
      printf 'ignored by .gitignore, so missing from a fresh clone:\n%s\n' "$hidden"
      return 1
    fi
    # The README builds bin/trie (13 MB): it must never be committable.
    if ! git check-ignore -q --no-index bin/trie; then
      echo "bin/trie, the README's build output, is not ignored"
      return 1
    fi
    echo "ignore rules: no Go source ignored, bin/ ignored"
  else
    echo "ignore rules: not a git work tree, skipped"
  fi
}

stage_unit() {
  build_fixture
  gotest unit.log -count=1 -p 4 ./...
}

stage_integration() {
  build_fixture
  gotest integration.log -count=1 -tags integration ./integration/...
}

stage_demo() {
  build_fixture
  go run ./internal/tools/demo 2>&1 | tee demo.log
}

fuzz_one() {
  local pkg=$1 target=$2 time=$3
  echo "== $target ($time)"
  go test "./$pkg" -run '^$' -fuzz="^$target\$" -fuzztime="$time" 2>&1 | tee "fuzz-$target.log"
}

stage_fuzz() {
  local gate=${FUZZTIME_GATE:-30s} other=${FUZZTIME_OTHER:-30s}
  fuzz_one rlp FuzzRLPRoundTrip "$gate"
  fuzz_one trie FuzzTrieOrderIndependence "$gate"
  fuzz_one trie FuzzVerifyProof "$other"
  fuzz_one trie FuzzHexPrefix "$other"
  fuzz_one ethrpc FuzzDecodeRPC "$other"
}

stage_coverage() {
  build_fixture
  COVERAGE_MIN="${COVERAGE_MIN:-90}" bash script/coverage.sh 2>&1 | tee coverage.log
}

stage_race() {
  build_fixture
  (
    export CGO_ENABLED=1
    gotest race.log -race -count=1 -p 4 ./...
    gotest race-integration.log -race -count=1 -tags integration ./integration/...
  )
}

stages=("$@")
if [[ ${#stages[@]} -eq 0 ]]; then
  stages=("${DEFAULT_STAGES[@]}")
fi
for s in "${stages[@]}"; do
  if ! declare -F "stage_$s" >/dev/null; then
    echo "unknown stage $s (fixture hygiene unit integration demo fuzz coverage race)" >&2
    exit 2
  fi
done
for s in "${stages[@]}"; do
  echo "==== $s"
  "stage_$s"
done
echo "==== passed: ${stages[*]}"
