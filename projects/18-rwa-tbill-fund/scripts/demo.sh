#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Local end-to-end demo on anvil: deploy -> onboard -> subscribe -> settle -> claim -> trade -> redeem ->
# lawful-order enforcement -> lost-wallet recovery -> record-date dividend (Node builder fed from chain state).
# Every step asserts its outcome (require in script/DemoLocal.s.sol), so a regression fails the demo.
# Picks a free port at runtime, uses unlocked default anvil accounts (no keys), and stops anvil by PID on exit.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=$(node -e "const s=require('node:net').createServer();s.listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close();})")
RPC="http://127.0.0.1:${PORT}"
OPERATOR=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ALICE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
ALICE_NEW_WALLET=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
BOB=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

anvil --port "$PORT" --silent &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 100); do
  if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then break; fi
  sleep 0.2
done

mkdir -p demo-out

step() {
  echo "==> $1"
  local log
  log=$(mktemp)
  if ! forge script script/DemoLocal.s.sol:DemoLocal --sig "$1()" --rpc-url "$RPC" \
    --broadcast --unlocked --sender "$OPERATOR" --slow >"$log" 2>&1; then
    cat "$log"
    rm -f "$log"
    return 1
  fi
  sed -n '/== Logs ==/,/^$/p' "$log" | sed '1d'
  rm -f "$log"
}

advance() {
  cast rpc --rpc-url "$RPC" evm_increaseTime "$1" >/dev/null
  cast rpc --rpc-url "$RPC" evm_mine >/dev/null
}

step deploy
advance 3600 # the NAV must be observed strictly after the epoch cutoff
step settle
advance 86401 # 1-day lockup on newly issued shares
step trade
advance 3600
step finish
step enforce
advance 172801 # 2-day recovery timelock
step recover

echo "==> record-date snapshot (cast) -> Node dividend builder"
SHARE=$(node -e "console.log(JSON.parse(require('node:fs').readFileSync('demo-out/deployment.json','utf8')).share)")
RECORD_DATE=$(cast block latest --field timestamp --rpc-url "$RPC")
balance() { cast call "$SHARE" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC" | awk '{print $1}'; }
cat >demo-out/holders.json <<EOF
{
  "recordDate": ${RECORD_DATE},
  "totalAmount": "1000000000",
  "holders": [
    { "account": "${ALICE}", "balance": "$(balance "$ALICE")" },
    { "account": "${ALICE_NEW_WALLET}", "balance": "$(balance "$ALICE_NEW_WALLET")" },
    { "account": "${BOB}", "balance": "$(balance "$BOB")" }
  ]
}
EOF
node scripts/build-dividend-tree.mjs demo-out/holders.json demo-out/dividend-tree.json 2>&1 | sed 's/^/  /'
step dividend
echo "demo complete; anvil (port ${PORT}) is stopped on exit"
