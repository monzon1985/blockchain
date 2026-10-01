#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Mutation check. Every committed mutant (test/mutants/M*.patch, a unified diff against src/) is applied to a scratch
# copy of the project, and the test suite (every suite except the GBM replay and the invariant campaign) must FAIL on
# it. The working tree is never modified. The unmutated copy must pass first.
#
#   bash script/mutants.sh                        # all mutants
#   bash script/mutants.sh M06                    # mutants whose file name starts with M06
#   MEDUSA_TIMEOUT=180 bash script/mutants.sh M15 # also run Medusa (seconds) on each selected mutant
#
# Prints one line per mutant (killed / SURVIVED, number of failing tests, some failing tests; with MEDUSA_TIMEOUT, the
# Medusa properties or assertions that failed) and exits non-zero if a mutant survives, does not apply or does not
# compile.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
FILTER="${1:-M}"
MEDUSA_TIMEOUT="${MEDUSA_TIMEOUT:-}"
TEST_ARGS=(--no-match-contract "GbmReplay|Invariants")

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Scratch copy: sources, tests, scripts and configuration. The (large) dependencies stay where they are and are
# referenced by absolute path; on Windows (Git Bash) forge needs a native path.
cp -R src test script foundry.toml medusa.json "${WORK}/"
DEPS="${ROOT}/dependencies"
if command -v cygpath >/dev/null 2>&1; then DEPS="$(cygpath -m "${DEPS}")"; fi
sed -i -e "s#=dependencies/#=${DEPS}/#g" -e "s#\[\"dependencies\"\]#[\"${DEPS}\"]#g" "${WORK}/foundry.toml"
cp -R "${WORK}/src" "${WORK}/.pristine-src"

run_suite() {
    (cd "${WORK}" && forge test "${TEST_ARGS[@]}" 2>&1)
}

# Medusa verdict for the current mutant: the names of the failed properties / assertions, or "nothing".
run_medusa() {
    local log
    log="$( (cd "${WORK}" && rm -rf medusa-corpus && medusa fuzz --config medusa.json --timeout "${MEDUSA_TIMEOUT}" 2>&1) || true)"
    local failed
    failed="$(echo "${log}" | grep -oE "\[FAILED\] [A-Za-z]+ Test: VolatilityFeeMedusa\.[A-Za-z_]+" |
        sed -E 's/.*VolatilityFeeMedusa\.//' | sort -u | paste -sd, -)"
    echo "${failed:-nothing}"
}

echo "baseline: building and testing the unmutated copy"
if ! (cd "${WORK}" && forge build >/dev/null 2>&1); then
    echo "baseline does not compile"
    (cd "${WORK}" && forge build 2>&1 | tail -20)
    exit 1
fi
if ! BASE="$(run_suite)"; then
    echo "baseline fails; fix the suite before checking mutants"
    echo "${BASE}" | tail -20
    exit 1
fi
echo "baseline: $(echo "${BASE}" | grep -E "tests passed" | tail -1)"

status=0
killed=0
total=0
shopt -s nullglob
for patch in test/mutants/"${FILTER}"*.patch; do
    name="$(basename "${patch}" .patch)"
    total=$((total + 1))
    rm -rf "${WORK}/src"
    cp -R "${WORK}/.pristine-src" "${WORK}/src"
    if ! (cd "${WORK}" && patch -p1 --quiet --no-backup-if-mismatch <"${ROOT}/${patch}"); then
        echo "ERROR     ${name}: patch does not apply to src/ (regenerate it)"
        status=1
        continue
    fi
    if ! (cd "${WORK}" && forge build >/dev/null 2>&1); then
        echo "ERROR     ${name}: mutant does not compile"
        status=1
        continue
    fi
    medusa=""
    if [ -n "${MEDUSA_TIMEOUT}" ]; then medusa="; Medusa (${MEDUSA_TIMEOUT} s) failed: $(run_medusa)"; fi
    if OUT="$(run_suite)"; then
        echo "SURVIVED  ${name}${medusa}"
        status=1
        continue
    fi
    failed="$(echo "${OUT}" | grep -oE "[0-9]+ failed" | tail -1 | grep -oE "[0-9]+")"
    # Test names from the "[FAIL...] name(" lines only (the reason may itself contain brackets).
    first="$(echo "${OUT}" | grep "^\[FAIL" | grep -oE "\] (test|invariant)[A-Za-z0-9_]*\(" | sed -E 's/^\] //; s/\($//' |
        sort -u | head -3 | paste -sd, -)"
    echo "killed    ${name}: ${failed} failing test(s), e.g. ${first}${medusa}"
    killed=$((killed + 1))
done

if [ "${total}" -eq 0 ]; then
    echo "no mutant matches ${FILTER}"
    exit 1
fi
echo "${killed}/${total} mutants killed"
exit "${status}"
