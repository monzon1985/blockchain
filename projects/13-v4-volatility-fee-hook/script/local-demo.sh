#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Local end-to-end demo: starts anvil on a free port, deploys everything with script/LocalDemo.s.sol using anvil's
# unlocked default account (no private key involved), prints the hook's per-pool oracle state, and stops anvil.
set -euo pipefail
cd "$(dirname "$0")/.."

SENDER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 # anvil default account 0, unlocked by anvil itself
LOG=$(mktemp)

# Port 0: the OS picks a free port and anvil reports it. The PoolManager built with this project's legacy-pipeline
# settings is ~27 KB, above EIP-170's 24 KB, so the demo chain lifts the limit (the canonical build is via-IR).
anvil --port 0 --code-size-limit 60000 >"${LOG}" 2>&1 &
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

# forge script sets each transaction's gas limit to its simulated usage x the multiplier (1.3 by default). A
# notification delivery must hold MODULE_GAS_LIMIT * 64/63 + 15,000 gas (~117k) when the hook checks, far more than a
# cheap module uses, so the demo raises the multiplier (tools based on eth_estimateGas find the right limit by
# themselves).
OUT=$(forge script script/LocalDemo.s.sol --rpc-url "${RPC}" --broadcast --unlocked --sender "${SENDER}" --slow \
    --disable-code-size-limit --gas-estimate-multiplier 300 --non-interactive 2>&1) || { echo "${OUT}"; exit 1; }
echo "${OUT}" | grep -E "PoolManager:|Hook:|Telemetry:|Token0:|Token1:|Mined hook address" || { echo "${OUT}"; exit 1; }
HOOK=$(echo "${OUT}" | awk '/Hook: /{print $2}')
TELEMETRY=$(echo "${OUT}" | awk '/Telemetry: /{print $2}')
POOL_ID=$(echo "${OUT}" | grep -A1 "PoolId:" | tail -1 | tr -d ' ')

echo "Blocks mined: $(cast block-number --rpc-url "${RPC}")"
echo "Pool state (lowSqrtPriceX96, ewmaWad, registered, highSqrtPriceX96, anchorTick, anchorBlock, lpFeePips,"
echo "surchargePips):"
cast call "${HOOK}" "getPoolState(bytes32)((uint160,uint88,bool,uint160,int24,uint40,uint16,uint16))" "${POOL_ID}" \
    --rpc-url "${RPC}"
echo "quoteFees now, in the block of the last swap (stored lpFeePips, surchargePips, low and high edges):"
cast call "${HOOK}" \
    "quoteFees((address,address,uint24,int24,address))(uint24,uint24,uint160,uint160)" \
    "($(echo "${OUT}" | awk '/Token0: /{print $2}'),$(echo "${OUT}" | awk '/Token1: /{print $2}'),8388608,60,${HOOK})" \
    --rpc-url "${RPC}"
echo "Liquidity notifications queued, and the commitment still pending for id 0 (zero = delivered):"
cast call "${HOOK}" "notificationCount()(uint96)" --rpc-url "${RPC}"
cast call "${HOOK}" "pendingNotification(uint256)(bytes32)" 0 --rpc-url "${RPC}"
echo "Telemetry delivered to the module for the pool (additions, removals, netLiquidity):"
cast call "${TELEMETRY}" "telemetry(bytes32)(uint64,uint64,int128)" "${POOL_ID}" --rpc-url "${RPC}"
