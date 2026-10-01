#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Local end-to-end demo: starts anvil on a free port, runs the three phases of script/LocalDemo.s.sol with anvil's
# unlocked default account (no private key involved), advances the chain clock between phases with evm_increaseTime,
# and stops anvil (by PID) on exit.
set -euo pipefail
cd "$(dirname "$0")/.."

SENDER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 # anvil default account 0, unlocked by anvil itself
LOG=$(mktemp)

anvil --port 0 >"${LOG}" 2>&1 &
ANVIL_PID=$!
trap 'kill "${ANVIL_PID}" 2>/dev/null || true; rm -f "${LOG}"' EXIT

PORT=""
for _ in $(seq 1 200); do
    PORT=$(grep -oE "Listening on [0-9.]+:[0-9]+" "${LOG}" | grep -oE "[0-9]+$" || true)
    if [ -n "${PORT}" ]; then break; fi
    sleep 0.1
done
[ -n "${PORT}" ] || { echo "anvil did not start"; cat "${LOG}"; exit 1; }
RPC="http://127.0.0.1:${PORT}"
echo "anvil listening on ${RPC} (pid ${ANVIL_PID})"

run() { forge script script/LocalDemo.s.sol --rpc-url "${RPC}" --broadcast --unlocked --sender "${SENDER}" \
    --slow --non-interactive "$@" 2>&1; }
advance() { cast rpc evm_increaseTime "$1" --rpc-url "${RPC}" >/dev/null; cast rpc evm_mine --rpc-url "${RPC}" >/dev/null; }
addr() { echo "${1}" | awk -v k="$2:" '$1 == k {print $2}'; }

echo "== phase 1: deploy, submit caps (3-day timelock), deposit"
OUT=$(run --sig "deploy()") || { echo "${OUT}"; exit 1; }
echo "${OUT}" | grep -E "Vault:|Liquid:|Lossy:|Illiquid:|Caps submitted" || { echo "${OUT}"; exit 1; }
VAULT=$(addr "${OUT}" Vault); LIQUID=$(addr "${OUT}" Liquid); LOSSY=$(addr "${OUT}" Lossy)
ILLIQUID=$(addr "${OUT}" Illiquid)

echo "== advancing 3 days"
advance 259200
echo "== phase 2: accept caps, allocate, strategy harvests 7,000 mUSD"
OUT=$(run --sig "allocate(address,address,address,address)" "${VAULT}" "${LIQUID}" "${LOSSY}" "${ILLIQUID}") \
    || { echo "${OUT}"; exit 1; }
echo "${OUT}" | grep -E "Strategies|Idle|Locked|Unlock end|totalAssets" || { echo "${OUT}"; exit 1; }

echo "== advancing 3.5 days"
advance 302400
echo "== phase 3: half of the profit is unlocked; redeem 10% (report() reverts unless the outcomes hold)"
OUT=$(run --sig "report(address)" "${VAULT}") || { echo "${OUT}"; exit 1; }
echo "${OUT}" | grep -E "totalAssets|Still locked|price|Redeemed|Fee recipient|High-water" || { echo "${OUT}"; exit 1; }

# Independent on-chain checks with cast, after the redemption was mined.
num() { cast call "${VAULT}" "$1" --rpc-url "${RPC}" | awk '{print $1}'; }
TOTAL=$(num "totalAssets()(uint256)")
PRICE=$(num "sharePrice()(uint256)")
SAFE=$(num "safeSharePrice()(uint256)")
echo "On-chain: totalAssets=${TOTAL} sharePrice=${PRICE} safeSharePrice=${SAFE}"
# 1,000,000 deposited + half of the 7,000 yield, minus the 10 % redemption and fees: between 900,000 and 910,000.
awk -v t="${TOTAL}" 'BEGIN { if (t < 900000e18 || t > 910000e18) { print "FAIL: totalAssets out of range"; exit 1 } }'
awk -v p="${PRICE}" -v s="${SAFE}" 'BEGIN { if (!(s < p)) { print "FAIL: safe price does not lag the share price"; exit 1 } }'
echo "Demo checks passed."
