#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Hand-written mutation check (fixed fuzz seed, so the result is deterministic). Each mutant removes one defense from
# src/; the test suite named next to it must then FAIL. A mutant counts as killed only if it compiles and the suite
# reports a failing test: a mutant that stops compiling (for example after a refactor changes the replaced text)
# aborts the check instead of passing as "killed". Every touched file is restored on exit, whatever happens. Exits
# non-zero if a mutant survives or does not compile.
set -euo pipefail
cd "$(dirname "$0")/.."

FILES=(src/AllocatorVault.sol src/libraries/VaultMath.sol)
BACKUP_DIR=$(mktemp -d)
for f in "${FILES[@]}"; do cp "${f}" "${BACKUP_DIR}/$(basename "${f}")"; done
restore() { for f in "${FILES[@]}"; do cp "${BACKUP_DIR}/$(basename "${f}")" "${f}"; done; }
trap 'restore; rm -rf "${BACKUP_DIR}"' EXIT

V=src/AllocatorVault.sol
M=src/libraries/VaultMath.sol
# name | file | exact text to replace (must occur once) | replacement | test contract that must fail
MUTANTS=(
    "withdraw burns shares rounded down|${V}|shares = _toShares(assets, a.totalSupply, a.totalAssets, Math.Rounding.Ceil);|shares = _toShares(assets, a.totalSupply, a.totalAssets, Math.Rounding.Floor);|VaultFuzz18DecimalsTest"
    "performance fee doubled|${V}|highWaterMark, supply, c.performanceFee);|highWaterMark, supply, 2 * c.performanceFee);|PerformanceFeeTest"
    "profit not locked (instant)|${V}|a.lockedProfit = locked;|a.lockedProfit = locked = 0;|HarvestSandwichTest"
    "loss hidden until a later accrual|${V}|a.totalAssets = a.grossAssets - locked;|a.totalAssets = (a.loss != 0 ? last : a.grossAssets) - locked;|FirstMoverLossTest"
    "no virtual shares (offset 0)|${V}|uint8 public constant DECIMALS_OFFSET = 6;|uint8 public constant DECIMALS_OFFSET = 0;|DonationAttackTest"
    "deposit mints shares rounded up|${V}|shares = _toShares(assets, a.totalSupply, a.totalAssets, Math.Rounding.Floor);|shares = _toShares(assets, a.totalSupply, a.totalAssets, Math.Rounding.Ceil);|OneWeiRoundingLoopTest"
    "new profit shortens the unlock (weighted end)|${M}|newUnlockEnd = t + period;|newUnlockEnd = t + period * profit / newLocked + 1;|HarvestSandwichTest"
    "pending removal counted in full|${V}|return _pendingRemovals != 0 && _config[strategy].removableAt != 0;|return _pendingRemovals == type(uint96).max;|StrategyRemovalTest"
    "no forced deallocation when a removal is announced|${V}|        _redeemRedeemable(strategy);|        // (mutant: nothing redeemed)|StrategyRemovalTest"
    "deposits allowed while impaired|${V}|if (address(a.impairedStrategy) != address(0)) revert DepositsPausedWhileImpaired(a.impairedStrategy);|{}|ImpairmentTest"
    "impairment booked as a loss|${V}|if (!impaired) lastTotalAssets = a.grossAssets;|lastTotalAssets = a.grossAssets;|ImpairmentTest"
    "out of gas counted as a failing strategy|${V}|if (gasleft() <= gasBefore / 4) revert StrategyCallOutOfGas(strategy);|gasBefore;|ImpairmentGasGuardTest"
    "rate limiter re-anchored at the ceiling|${V}|} else if (a.sharePrice < ceiling) {|} else {|RateLimiterTest"
    "rate limiter clock runs while impaired|${V}|if (impaired) checkpoint.updatedAt +=|if (false) checkpoint.updatedAt +=|ImpairmentTest"
    "totalAssets readable mid-call|${V}|function totalAssets() public view override(ERC4626, IERC4626) nonReentrantView returns|function totalAssets() public view override(ERC4626, IERC4626) returns|ReentrancyTest"
)

LOG=$(mktemp)
survivors=0
for entry in "${MUTANTS[@]}"; do
    # Split on unescaped "|" only ("\|" stands for a literal "|" inside a pattern).
    IFS=$'\x1f' read -r name file from to suite <<<"$(printf '%s' "${entry}" | sed 's/\\|/\x1e/g; s/|/\x1f/g; s/\x1e/|/g')"
    restore
    count=$(grep -cF -- "${from}" "${file}" || true)
    if [ "${count}" != "1" ]; then
        echo "mutant '${name}': pattern found ${count} times in ${file} (expected 1)"; exit 2
    fi
    FROM="${from}" TO="${to}" perl -0pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/' "${file}"
    if ! forge build >"${LOG}" 2>&1; then
        echo "mutant '${name}' did not compile:"; tail -n 20 "${LOG}"; exit 2
    fi
    if forge test --match-contract "${suite}" --fuzz-seed 0x09 >"${LOG}" 2>&1; then
        echo "SURVIVED  ${name}  (${suite} still passes)"
        survivors=$((survivors + 1))
    elif grep -qE "Suite result: FAILED|Failing tests:" "${LOG}"; then
        echo "killed    ${name}  (by ${suite})"
    else
        echo "mutant '${name}': ${suite} exited non-zero without a failing test:"; tail -n 20 "${LOG}"; exit 2
    fi
done
rm -f "${LOG}"
restore
echo "${survivors} of ${#MUTANTS[@]} mutants survived"
[ "${survivors}" -eq 0 ]
