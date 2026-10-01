#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Local end-to-end demo on anvil (free port chosen at runtime, anvil stopped by PID on exit):
#   1. deploy scriptable feeds, then the router through the production script (AccessManager + 2-day delay);
#   2. keepers build an hour of TWAP history while the primary moves;
#   3. the primary goes silent            -> soft mode bridges with the TWAP (FALLBACK_USED);
#   4. the secondary disagrees by 10 %    -> conservative side (DEVIATION);
#   5. the sequencer goes down, comes back -> SEQUENCER_DOWN, GRACE_PERIOD, then OK; keepers resume and the ring
#      restarts, so a silent primary right after the outage is not bridged with pre-outage prices (STALE);
#   6. governance schedules a change      -> refused before 2 days, applied after.
# Every step asserts the status it expects (and the price where it is deterministic) and exits non-zero otherwise.
# Uses anvil's unlocked default account; no private key is involved.
set -euo pipefail
cd "$(dirname "$0")/.."

SENDER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 # anvil default account 0, unlocked by anvil itself
STATUS=(OK STALE ZERO NEGATIVE OUT_OF_BOUNDS SEQUENCER_DOWN GRACE_PERIOD DEVIATION FALLBACK_USED)
LOG=$(mktemp)
mkdir -p demo-out

anvil --port 0 >"${LOG}" 2>&1 &
ANVIL_PID=$!
trap 'kill "${ANVIL_PID}" 2>/dev/null || true; rm -f "${LOG}"' EXIT

PORT=""
for _ in $(seq 1 300); do
    PORT=$(grep -oE "Listening on [0-9.]+:[0-9]+" "${LOG}" | grep -oE "[0-9]+$" || true)
    [ -n "${PORT}" ] && break
    sleep 0.1
done
[ -n "${PORT}" ] || { echo "anvil did not start"; cat "${LOG}"; exit 1; }
RPC="http://127.0.0.1:${PORT}"
echo "anvil listening on ${RPC} (pid ${ANVIL_PID})"

send() { cast send --rpc-url "${RPC}" --unlocked --from "${SENDER}" "$@" >/dev/null; }
advance() { cast rpc --rpc-url "${RPC}" evm_increaseTime "$1" >/dev/null; cast rpc --rpc-url "${RPC}" evm_mine >/dev/null; }

# quotes <label> <expected status> [expected collateral price in wei]
# Prints tryGetPrice for both intents and stops the demo (non-zero exit) on any status or price it did not expect,
# so the CI job checks behavior instead of only printing it. Prices that depend on wall-clock drift between blocks
# (the TWAP) are checked through their status only.
quotes() {
    local label=$1 expected=$2 collateral=${3:-} intent out price status name
    echo "-- ${label}"
    for intent in 0 1; do
        out=$(cast call --rpc-url "${RPC}" "${ROUTER}" "tryGetPrice(address,uint8)(uint256,uint8)" "${ASSET}" "${intent}")
        price=$(echo "${out}" | sed -n 1p | awk '{print $1}')
        status=$(echo "${out}" | sed -n 2p | awk '{print $1}')
        name=${STATUS[${status}]}
        printf "%-10s price %28s wei  status %s\n" "$([ "${intent}" = 0 ] && echo collateral || echo debt)" "${price}" \
            "${name}"
        [ "${name}" = "${expected}" ] || { echo "FAILED: expected status ${expected}, got ${name}"; exit 1; }
        if [ "${intent}" = 0 ] && [ -n "${collateral}" ] && [ "${price}" != "${collateral}" ]; then
            echo "FAILED: expected collateral price ${collateral}, got ${price}"
            exit 1
        fi
    done
}

# 1. Feeds, then the router through the production deployment script.
OUT=$(forge script script/LocalDemo.s.sol:DeployDemoFeeds --rpc-url "${RPC}" --broadcast --unlocked \
    --sender "${SENDER}" --non-interactive 2>&1) || { echo "${OUT}"; exit 1; }
eval "$(echo "${OUT}" | grep -E "^\s*(PRIMARY|SECONDARY|SEQUENCER|ASSET)=0x[0-9a-fA-F]{40}$" | tr -d ' ')"
OUT=$(GOVERNANCE="${SENDER}" GUARDIAN="${SENDER}" SEQUENCER_FEED="${SEQUENCER}" ROUTER_CONFIG=demo-out/config.json \
    forge script script/DeployOracleRouter.s.sol --rpc-url "${RPC}" --broadcast --unlocked --sender "${SENDER}" \
    --non-interactive 2>&1) || { echo "${OUT}"; exit 1; }
ROUTER=$(echo "${OUT}" | awk '/OracleRouter:/{print $2}')
MANAGER=$(echo "${OUT}" | awk '/AccessManager:/{print $2}')
echo "router ${ROUTER}  manager ${MANAGER}  primary ${PRIMARY}  secondary ${SECONDARY}"
quotes "healthy: primary 2,000 USD, witness 2,000 USD" OK 2000000000000000000000

# 2. One hour of history: the primary moves every 10 minutes, keepers record every update and twice more.
for step in 1 2 3 4 5 6; do
    advance 600
    send "${PRIMARY}" "pushAnswer(int256)" "$((200000000000 + step * 1000000000))"
    send "${SECONDARY}" "pushAnswer(int256)" "$((200000000000 + step * 1000000000))0000000000"
    send "${ROUTER}" "recordObservation(address)" "${ASSET}"
done
for _ in 1 2; do
    advance 600
    send "${ROUTER}" "recordObservation(address)" "${ASSET}"
done
quotes "after an hour of keeper observations (spot 2,060 USD)" OK 2060000000000000000000

# 3. The primary stays silent past its 1 h heartbeat: 20 min of keeper records plus 41 min puts its age at 61 min
#    (a full minute of margin over the heartbeat, independent of wall-clock drift between blocks), while the newest
#    observation is only 41 min old, so the 1 h TWAP is still fresh.
advance 2460
quotes "primary silent for 61 min: soft mode serves the 1 h TWAP" FALLBACK_USED

# 4. The witness moves 10 % lower while the primary is silent.
send "${SECONDARY}" "pushAnswer(int256)" "1850000000000000000000"
quotes "witness at 1,850 USD disagrees with the TWAP: conservative side" DEVIATION 1850000000000000000000

# 5. Sequencer outage and grace period (fresh feeds first).
send "${PRIMARY}" "pushAnswer(int256)" 205000000000
send "${SECONDARY}" "pushAnswer(int256)" 2050000000000000000000
quotes "feeds refreshed" OK 2050000000000000000000
send "${SEQUENCER}" "setDown()"
quotes "sequencer down" SEQUENCER_DOWN 0
advance 300
send "${SEQUENCER}" "setUp()"
quotes "sequencer back up: grace period" GRACE_PERIOD 0
advance 3601
send "${PRIMARY}" "pushAnswer(int256)" 205000000000
quotes "grace period over" OK 2050000000000000000000

# 5b. Keepers resume. The last observation predates the outage, so the ring restarts instead of carrying the
#     pre-outage answer forward; 30 min later the primary goes silent and soft mode refuses to bridge (half a window
#     of post-outage history), where it used to serve the pre-outage average.
send "${ROUTER}" "recordObservation(address)" "${ASSET}"
CARDINALITY=$(cast call --rpc-url "${RPC}" "${ROUTER}" "getRingState(address)(uint256,uint256,uint256)" "${ASSET}" \
    | sed -n 2p | awk '{print $1}')
echo "-- keepers resume after the outage: ring restarted (cardinality ${CARDINALITY})"
[ "${CARDINALITY}" = 1 ] || { echo "FAILED: expected the ring to restart"; exit 1; }
advance 1800
send "${ROUTER}" "recordObservation(address)" "${ASSET}"
advance 1801
quotes "primary silent again, only 30 min of post-outage history: no TWAP" STALE 0

# 6. Governance: a configuration change must wait 2 days after it is scheduled.
CALL=$(cast calldata \
    "setAssetConfig(address,((address,uint32,uint192,uint192),(address,uint32,uint192,uint192),uint16,uint32,uint8))" \
    "${ASSET}" \
    "((${PRIMARY},3600,10000000000,10000000000000),(${SECONDARY},86400,100000000000000000000,100000000000000000000000),300,3600,0)")
send "${MANAGER}" "schedule(address,bytes,uint48)" "${ROUTER}" "${CALL}" 0
echo "-- governance scheduled a switch to strict mode"
if ERR=$(cast send --rpc-url "${RPC}" --unlocked --from "${SENDER}" "${ROUTER}" "${CALL}" 2>&1); then
    echo "unexpected: the change was applied before the delay"; exit 1
fi
NOT_READY=$(cast sig "AccessManagerNotReady(bytes32)")
echo "${ERR}" | grep -qiE "${NOT_READY#0x}|AccessManagerNotReady" || { echo "unexpected revert: ${ERR}"; exit 1; }
echo "executing immediately: refused with AccessManagerNotReady (${NOT_READY})"
advance 172800
send "${ROUTER}" "${CALL}"
MODE=$(cast call --rpc-url "${RPC}" "${ROUTER}" \
    "getAssetConfig(address)(((address,uint32,uint8,uint192,uint192),(address,uint32,uint8,uint192,uint192),uint16,uint32,uint8))" \
    "${ASSET}" | grep -oE "[0-9]+\)$" | tr -d ')')
echo "executing after 2 days: applied (mode = $([ "${MODE}" = 0 ] && echo strict || echo soft))"
[ "${MODE}" = 0 ] || { echo "mode did not change"; exit 1; }
echo "demo complete"
