#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Local end-to-end demo of the custody engine:
#   1. anvil on an OS-assigned port with 1-second blocks,
#   2. TestToken + ForwarderFactory deployed from anvil's *unlocked* dev account (no private
#      keys handled by this script),
#   3. a freshly generated, scrypt-encrypted hot-wallet keystore and random API tokens,
#   4. custodyd started on a free port,
#   5. one customer deposit to a counterfactual CREATE2 address and one withdrawal, driven with
#      curl through the HTTP API, followed by reconciliation and audit-log verification.
# Every step is checked: the script exits non-zero on the first thing that does not hold, which
# is what makes it usable as CI's end-to-end smoke test.
#
# Usage: bash script/devnet.sh [--keep]     (--keep leaves anvil and custodyd running)
# Requires: anvil, forge, cast (Foundry 1.8.3), go, curl. Everything is written to ./.devnet.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
WORK="$ROOT/.devnet"
EXE=""
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) EXE=".exe" ;; esac

rm -rf "$WORK"
mkdir -p "$WORK"
ANVIL_PID=""
CUSTODY_PID=""
cleanup() {
  if [[ -n "$CUSTODY_PID" ]]; then kill "$CUSTODY_PID" 2>/dev/null || true; fi
  if [[ -n "$ANVIL_PID" ]]; then kill "$ANVIL_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

step() { printf '\n==> %s\n' "$*"; }
json_field() { grep -o "\"$1\":\"[^\"]*\"" | head -1 | cut -d'"' -f4; }
random_token() { od -An -tx1 -N24 /dev/urandom | tr -d ' \n'; }
wait_until() { # wait_until <seconds> <command...>
  local limit=$1
  shift
  for _ in $(seq 1 $((limit * 5))); do
    if "$@"; then return 0; fi
    sleep 0.2
  done
  echo "timed out waiting for: $*" >&2
  return 1
}

step "Starting anvil on a free port"
anvil --port 0 --block-time 1 >"$WORK/anvil.log" 2>&1 &
ANVIL_PID=$!
wait_until 30 grep -q "Listening on" "$WORK/anvil.log"
RPC="http://$(grep -o 'Listening on [0-9.:]*' "$WORK/anvil.log" | head -1 | awk '{print $3}')"
DEV=$(cast rpc --rpc-url "$RPC" eth_accounts | grep -o '0x[0-9a-fA-F]\{40\}' | head -1)
echo "rpc=$RPC  dev account (unlocked)=$DEV"

step "Building custodyd and creating an encrypted hot-wallet keystore"
CGO_ENABLED=0 go build -o "$WORK/custodyd$EXE" ./cmd/custodyd
CUSTODYD="$WORK/custodyd$EXE"
random_token >"$WORK/hot.pass"
HOT=$("$CUSTODYD" keystore-new -out "$WORK/hot.json" -password-file "$WORK/hot.pass" -light)
cast rpc --rpc-url "$RPC" anvil_setBalance "$HOT" 0x56BC75E2D63100000 >/dev/null # 100 ETH for gas
echo "hot wallet=$HOT"

step "Deploying TestToken and ForwarderFactory (destination = owner = hot wallet)"
(cd contracts && forge build >/dev/null)
TOKEN=$(cd contracts && forge create test/mocks/TestToken.sol:TestToken --rpc-url "$RPC" --unlocked --from "$DEV" --broadcast |
  awk '/Deployed to:/ {print $3}')
FACTORY=$(cd contracts && forge create src/ForwarderFactory.sol:ForwarderFactory --rpc-url "$RPC" --unlocked --from "$DEV" \
  --broadcast --constructor-args "$HOT" "$HOT" | awk '/Deployed to:/ {print $3}')
cast send --rpc-url "$RPC" --unlocked --from "$DEV" "$TOKEN" "mint(address,uint256)" "$HOT" 1000000000000 >/dev/null
echo "token=$TOKEN factory=$FACTORY (hot wallet pre-funded with 1,000,000 tUSD of treasury liquidity)"

step "Writing configuration with fresh API tokens"
CLIENT_TOKEN=$(random_token)
APPROVER_TOKENS=("$(random_token)" "$(random_token)" "$(random_token)")
hash_token() { echo "$1" | "$CUSTODYD" hash-token; }
cat >"$WORK/custody.json" <<EOF
{
  "chain": {"rpc_url": "$RPC", "chain_id": 31337, "confirmations": 3, "poll_interval": "250ms"},
  "database": {"path": "custody.db"},
  "http": {"listen": "127.0.0.1:0", "addr_file": "addr.txt"},
  "audit": {"path": "audit.jsonl"},
  "hot_wallet": {"keystore": "hot.json", "password_file": "hot.pass"},
  "fees": {"min_tip_wei": "1000000000", "max_fee_wei": "200000000000"},
  "assets": [{"symbol": "tUSD", "token": "$TOKEN", "max_per_tx": "1000000000000",
              "velocity_24h": "5000000000000", "approval_threshold": "500000000000"}],
  "policy": {"allowlist_cooldown": "0s", "approvals_required": 2, "approvers": [
    {"id": "ops-a", "token_sha256": "$(hash_token "${APPROVER_TOKENS[0]}")"},
    {"id": "ops-b", "token_sha256": "$(hash_token "${APPROVER_TOKENS[1]}")"},
    {"id": "ops-c", "token_sha256": "$(hash_token "${APPROVER_TOKENS[2]}")"}]},
  "clients": [{"id": "gateway", "token_sha256": "$(hash_token "$CLIENT_TOKEN")"}],
  "deposits": {"factory": "$FACTORY", "scan_interval": "500ms", "sweep_interval": "2s"},
  "reconcile": {"every_rounds": 4}
}
EOF
echo "note: the allowlist cool-down is 0s for the demo; production uses 24h"

step "Starting custodyd"
"$CUSTODYD" serve -config "$WORK/custody.json" >"$WORK/custodyd.log" 2>&1 &
CUSTODY_PID=$!
wait_until 60 test -s "$WORK/addr.txt"
API="http://$(cat "$WORK/addr.txt")"
AUTH=(-H "Authorization: Bearer $CLIENT_TOKEN")
echo "api=$API"

step "Customer deposit to a counterfactual CREATE2 address"
DEPOSIT=$(curl -fsS -X POST "${AUTH[@]}" "$API/v1/accounts/alice/deposit-address" | json_field address)
echo "alice deposit address=$DEPOSIT (no contract there yet)"
cast send --rpc-url "$RPC" --unlocked --from "$DEV" "$TOKEN" "mint(address,uint256)" "$DEPOSIT" 250000000 >/dev/null
credited() { curl -fsS "${AUTH[@]}" "$API/v1/accounts/alice/balances" | grep -q '"tUSD":"250000000"'; }
wait_until 60 credited
echo "credited after 3 confirmations: $(curl -fsS "${AUTH[@]}" "$API/v1/accounts/alice/balances")"

step "Withdrawal with an Idempotency-Key (sent twice: the second is a replay)"
DEST=0x000000000000000000000000000000000000dEaD
curl -fsS -X POST "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"address\":\"$DEST\",\"label\":\"demo\"}" "$API/v1/accounts/alice/allowlist" >/dev/null
BODY="{\"account_id\":\"alice\",\"asset\":\"tUSD\",\"amount\":\"100000000\",\"destination\":\"$DEST\"}"
WID=$(curl -fsS -X POST "${AUTH[@]}" -H "Idempotency-Key: demo-1" -d "$BODY" "$API/v1/withdrawals" | json_field id)
test -n "$WID" || { echo "the withdrawal was not created" >&2; exit 1; }
REPLAY=$(curl -fsS -D "$WORK/replay.headers" -X POST "${AUTH[@]}" -H "Idempotency-Key: demo-1" -d "$BODY" "$API/v1/withdrawals")
grep -qi '^idempotent-replayed: true' "$WORK/replay.headers" || { echo "the retry was not replayed" >&2; exit 1; }
test "$(echo "$REPLAY" | json_field id)" = "$WID" || { echo "the retry returned another withdrawal" >&2; exit 1; }
echo "retry with the same key: Idempotent-Replayed: true, same withdrawal $WID"
confirmed() { curl -fsS "${AUTH[@]}" "$API/v1/withdrawals/$WID" | grep -q '"status":"confirmed"'; }
wait_until 90 confirmed
curl -fsS "${AUTH[@]}" "$API/v1/withdrawals/$WID"
echo
echo "destination balance: $(cast call --rpc-url "$RPC" "$TOKEN" 'balanceOf(address)(uint256)' "$DEST")"

step "Reconciliation (on-chain hot wallet == ledger hot_wallet + in_flight, in_flight being the signed, usually negative, effect of mined but not yet final transactions) and audit log"
reconciled() { curl -fsS "${AUTH[@]}" "$API/v1/reconciliation" 2>/dev/null | grep -q '"ok":true'; }
wait_until 60 reconciled
curl -fsS "${AUTH[@]}" "$API/v1/reconciliation"
echo
# The log is shipped every second: wait until it holds exactly the database's events.
audit_complete() { "$CUSTODYD" audit-verify -file "$WORK/audit.jsonl" -db "$WORK/custody.db" >"$WORK/audit-verify.out" 2>&1; }
wait_until 30 audit_complete
cat "$WORK/audit-verify.out"
echo "metrics sample:"
curl -fsS "$API/metrics" | grep -E '^custody_(withdrawal_transitions_total|deposits_credited_total|sweeps_total|reconciliation_runs_total)' | head -12

if [[ "${1:-}" == "--keep" ]]; then
  step "Leaving anvil ($RPC) and custodyd ($API) running; client token: $CLIENT_TOKEN. Ctrl-C to stop."
  wait "$CUSTODY_PID"
fi
step "Demo complete (artifacts in $WORK)"
