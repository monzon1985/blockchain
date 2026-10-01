#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Local end-to-end demo against anvil:
#   1. anvil on a port the OS picks (`--port 0`, the bound address read from its output); the
#      fixture ERC-20 and ERC-4626 deployed and used from anvil's unlocked dev accounts
#      (eth_sendTransaction: no private key appears anywhere);
#   2. `indexer serve` on `--listen 127.0.0.1:0` (the address read from its "http listening"
#      log line), with an SSE client following /v1/stream;
#   3. anvil_reorg orphans the last transfer: the REST view drops it, the stream carries a
#      `retract` event with the exact transfer, /v1/status counts the reorg;
#   4. `indexer verify` diffs the database against a from-scratch reindex.
# Every process the script starts is stopped by PID on exit. No port is chosen before the
# process that binds it: a port probed and released first could be taken by another process.
#
# Usage: bash script/demo.sh        (needs Go, Foundry and curl)
set -euo pipefail

cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

say() { printf '\n== %s\n' "$*"; }
show() { if command -v jq >/dev/null 2>&1; then jq "${2:-.}" <<<"$1"; else printf '%s\n' "$1"; fi; }
wait_for() { for _ in $(seq 1 300); do if eval "$1" >/dev/null 2>&1; then return 0; fi; sleep 0.2; done; echo "timed out: $1" >&2; exit 1; }
# listening_address LOG SED: waits until the sed expression extracts an address from LOG.
listening_address() {
  local addr
  for _ in $(seq 1 300); do
    addr=$(sed -n "$2" "$1" 2>/dev/null | head -n 1 | tr -d '\r')
    if [[ -n "$addr" ]]; then
      printf '%s' "$addr"
      return 0
    fi
    sleep 0.2
  done
  echo "timed out waiting for a listening address in $1:" >&2
  cat "$1" >&2
  return 1
}

# anvil's default dev accounts (public addresses of its well-known test mnemonic).
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ALICE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
BOB=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

say "Building the fixtures and the indexer"
(cd contracts && forge soldeer install >/dev/null && forge build >/dev/null)
BIN="$WORK/indexer$(go env GOEXE)"
CGO_ENABLED=0 go build -o "$BIN" ./cmd/indexer

anvil --port 0 >"$WORK/anvil.log" 2>&1 &
PIDS+=($!)
RPC="http://$(listening_address "$WORK/anvil.log" 's/.*Listening on \([^ ]*\).*/\1/p')"
wait_for "cast chain-id --rpc-url $RPC"
echo "anvil listening on $RPC"

say "Deploying FixtureToken and FixtureVault (unlocked dev account, no keys)"
deploy() {
  forge create --root contracts --rpc-url "$RPC" --unlocked --from "$OWNER" --broadcast "$@" |
    awk '/Deployed to:/ {print $3}'
}
TOKEN=$(deploy src/FixtureToken.sol:FixtureToken --constructor-args "Demo USD" dUSD 6 "$OWNER")
VAULT=$(deploy src/FixtureVault.sol:FixtureVault --constructor-args "$TOKEN" "Demo Vault" dvUSD)
echo "token $TOKEN"
echo "vault $VAULT"

send() { cast send --rpc-url "$RPC" --unlocked --from "$1" "${@:2}" >/dev/null; }
send "$OWNER" "$TOKEN" "mint(address,uint256)" "$ALICE" 1000000000
send "$ALICE" "$TOKEN" "approve(address,uint256)" "$VAULT" 1000000000
send "$ALICE" "$VAULT" "deposit(uint256,address)" 400000000 "$ALICE"
send "$OWNER" "$TOKEN" "mint(address,uint256)" "$VAULT" 40000000   # a donation: the share price rises
send "$ALICE" "$TOKEN" "transfer(address,uint256)" "$BOB" 1000000   # the transfer the reorg will orphan

say "Starting the indexer (serve: index + REST + SSE)"
"$BIN" serve --rpc-url "$RPC" --db "$WORK/demo.db" --token "$TOKEN" --vault "$VAULT" \
  --confirmations 2 --poll-interval 200ms --listen 127.0.0.1:0 --log-format json 2>"$WORK/indexer.log" &
PIDS+=($!)
API="http://$(listening_address "$WORK/indexer.log" 's/.*"msg":"http listening","addr":"\([^"]*\)".*/\1/p')"
echo "indexer listening on $API"
HEAD=$(cast block-number --rpc-url "$RPC")
wait_for "curl -sf '$API/v1/status' | grep -q '\"number\":$HEAD,'"
curl -sN "$API/v1/stream?after=0" >"$WORK/stream.txt" &
PIDS+=($!)

say "GET /v1/status"
show "$(curl -s "$API/v1/status")" '{chainId, tip, safeHead, reorgs, events}'
say "GET /v1/transfers?token=$TOKEN (latest view)"
show "$(curl -s "$API/v1/transfers?token=$TOKEN")" '.data[] | {block: .block.number, from, to, value}'
say "GET /v1/tokens/$TOKEN/balances?view=safe (2 confirmations)"
show "$(curl -s "$API/v1/tokens/$TOKEN/balances?view=safe")" '{safeHead: .meta.safeHead, balances: [.data[] | {holder, balance}]}'
say "GET /v1/vaults/$VAULT/share-prices"
show "$(curl -s "$API/v1/vaults/$VAULT/share-prices")" '.data[] | {block: .block.number, totalAssets, totalSupply, priceWad}'

say "anvil_reorg: replace the last block with an empty one (alice -> bob disappears)"
cast rpc --rpc-url "$RPC" anvil_reorg 1 '[]' >/dev/null
NEWHEAD=$(cast block --rpc-url "$RPC" latest --field hash)
wait_for "curl -sf '$API/v1/status' | grep -q '$NEWHEAD'"
show "$(curl -s "$API/v1/transfers?token=$TOKEN")" '.data[] | {block: .block.number, from, to, value}'
say "SSE events after the reorg (retract carries the exact transfer published before)"
wait_for "grep -q 'event: reorg' '$WORK/stream.txt'"
grep -B1 -A1 -E '^event: (retract|reorg)' "$WORK/stream.txt" | grep -E '^(id|event|data):' | cut -c1-220
say "GET /v1/status"
show "$(curl -s "$API/v1/status")" '{tip, reorgs, lastReorg}'

say "indexer verify (reindex from scratch into a temporary database and diff)"
"$BIN" verify --rpc-url "$RPC" --db "$WORK/demo.db" --log-level error
