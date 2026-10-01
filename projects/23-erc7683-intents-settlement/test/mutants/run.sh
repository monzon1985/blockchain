#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Mutation smoke test. Each test/mutants/*.patch breaks one security-critical check in src/. For every patch this
# script applies it to a scratch copy of the project, runs `forge test` and expects it to FAIL (the mutant is
# "killed"), then prints which test contracts caught it. It exits non-zero if any mutant survives or a patch no
# longer applies. The project directory itself is never modified.
#
# Usage, from the project root:   bash test/mutants/run.sh [name-filter]
# Gas benchmarks are excluded: a mutant must be caught by a behavioural test, not by a gas number moving.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
filter="${1:-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Everything forge needs, plus the build caches so each mutant only recompiles what it touches.
for item in src test script foundry.toml remappings.txt soldeer.lock dependencies out cache snapshots .gas-snapshot; do
  if [ -e "$root/$item" ]; then cp -R "$root/$item" "$work/"; fi
done

unset FORGE_SNAPSHOT_CHECK
survivors=0
total=0
for patch in "$root"/test/mutants/*.patch; do
  name="$(basename "$patch" .patch)"
  if [ -n "$filter" ] && [[ "$name" != *"$filter"* ]]; then continue; fi
  total=$((total + 1))
  if ! (cd "$work" && patch -p1 --quiet --forward < "$patch"); then
    echo "ERROR    $name: patch does not apply (regenerate it against the current src/)"
    exit 2
  fi
  log="$work/$name.log"
  if (cd "$work" && forge test --no-match-contract GasBench > "$log" 2>&1); then
    echo "SURVIVED $name"
    survivors=$((survivors + 1))
  elif grep -q "Compiler run failed" "$log"; then
    echo "ERROR    $name: the mutant does not compile"
    tail -20 "$log"
    exit 2
  else
    killers="$(grep -E '^Encountered [0-9]+ failing tests? in ' "$log" | sed -E 's/^Encountered ([0-9]+) failing tests? in [^:]*:([A-Za-z0-9_]+)$/\2 (\1)/' | paste -sd ',' - | sed 's/,/, /g')"
    echo "killed   $name by: $killers"
  fi
  (cd "$work" && patch -p1 --quiet --reverse < "$patch")
done

echo "mutants: $total, killed: $((total - survivors)), survived: $survivors"
[ "$survivors" -eq 0 ]
