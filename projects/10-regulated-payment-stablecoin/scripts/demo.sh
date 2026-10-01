#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# End-to-end demo on a throwaway anvil chain, keystore-based from start to finish (no private key and no keystore
# password is ever passed on a command line or stored in the repository):
#
#   1. fresh encrypted keystores for every role (random password, kept in a mode-600 password file that every
#      forge / cast call reads with --password-file), funded with anvil_setBalance
#   2. Deploy.s.sol wires AccessManager + tPD, VerifyRoles.s.sol checks the implementation and the role graph
#   3. the attestor signs an EIP-712 reserve attestation (cast wallet sign --data), a relayer submits it
#   4. master minter configures a minter, the minter mints, the rolling limit refuses the next mint
#   5. alice pays bob with an EIP-3009 authorization relayed by a third party
#   6. compliance freezes bob under a lawful order: bob's transfer reverts, 100 tPD are seized to court custody,
#      the rest is burned
#   7. the v1 -> v2 upgrade goes through the 2-day schedule, then VerifyRoles runs again in v2 mode
#
# Every refusal is checked for its specific custom error, not just for "some revert".
#
# Usage: bash scripts/demo.sh   (from the project root; needs forge, cast, anvil and node on PATH)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=demo-out
KEYS="$OUT/keystores"
PASSWORD_FILE="$KEYS/.password"
rm -rf "$OUT"
mkdir -p "$KEYS"
(
  umask 077
  node -e "process.stdout.write(require('crypto').randomBytes(24).toString('hex'))" >"$PASSWORD_FILE"
)

# --- anvil on a free port, stopped by PID on exit ------------------------------------------------------------------
anvil --port 0 --silent >"$OUT/anvil.log" 2>&1 &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true' EXIT
PORT=""
for _ in $(seq 1 100); do
  PORT=$(sed -n 's/.*Listening on 127\.0\.0\.1:\([0-9]*\).*/\1/p' "$OUT/anvil.log" | head -n 1)
  [ -n "$PORT" ] && break
  sleep 0.1
done
if [ -z "$PORT" ]; then
  # --silent suppresses the banner on some versions; fall back to a verbose restart.
  kill "$ANVIL_PID" 2>/dev/null || true
  anvil --port 0 >"$OUT/anvil.log" 2>&1 &
  ANVIL_PID=$!
  for _ in $(seq 1 100); do
    PORT=$(sed -n 's/.*Listening on 127\.0\.0\.1:\([0-9]*\).*/\1/p' "$OUT/anvil.log" | head -n 1)
    [ -n "$PORT" ] && break
    sleep 0.1
  done
fi
[ -n "$PORT" ] || { echo "anvil did not start"; exit 1; }
export ETH_RPC_URL="http://127.0.0.1:$PORT"
until cast chain-id >/dev/null 2>&1; do sleep 0.1; done
echo "anvil (pid $ANVIL_PID) on port $PORT, chain id $(cast chain-id)"

# --- keystores ------------------------------------------------------------------------------------------------------
declare -A ADDR
for name in deployer governance masterMinter minter pauser blocklister compliance bridge upgrader attestor \
  alice bob custody relayer; do
  # `cast wallet new` has no --password-file; CAST_PASSWORD keeps the password off the command line.
  CAST_PASSWORD="$(cat "$PASSWORD_FILE")" cast wallet new "$KEYS" "$name" >/dev/null 2>&1
  ADDR[$name]=$(cast wallet address --keystore "$KEYS/$name" --password-file "$PASSWORD_FILE")
  cast rpc anvil_setBalance "${ADDR[$name]}" 0x56BC75E2D63100000 >/dev/null # 100 ETH
done
echo "created ${#ADDR[@]} encrypted keystores in $KEYS"

as() { # as <role> <cast send args...>
  local who=$1
  shift
  cast send --keystore "$KEYS/$who" --password-file "$PASSWORD_FILE" "$@" >/dev/null
}
script_as() { # script_as <role> <script> [--sig ...]
  local who=$1
  shift
  forge script "$@" --rpc-url "$ETH_RPC_URL" --broadcast --keystore "$KEYS/$who" --password-file "$PASSWORD_FILE" \
    --sender "${ADDR[$who]}" --slow -q
}
# refused <custom error signature> <what> <output of the failed call>: the call must have failed with that error,
# matched by name or by selector (cast prints the selector when it cannot decode the error).
refused() {
  local sig=$1 what=$2 out=$3 selector
  selector=$(cast sig "$sig")
  if [[ "$out" == *"${sig%%(*}("* || "${out,,}" == *"${selector#0x}"* ]]; then
    return 0
  fi
  echo "FAILED: $what was refused, but not with ${sig%%(*} ($selector):"
  echo "$out"
  exit 1
}
bal() { cast call "$TOKEN" "balanceOf(address)(uint256)" "$1" | awk '{print $1}'; }
expect_eq() {
  if [ "$1" != "$2" ]; then
    echo "FAILED: $3 (expected $2, got $1)"
    exit 1
  fi
}

export GOVERNANCE=${ADDR[governance]} MASTER_MINTER=${ADDR[masterMinter]} PAUSER=${ADDR[pauser]}
export BLOCKLISTER=${ADDR[blocklister]} COMPLIANCE_OFFICER=${ADDR[compliance]} BRIDGE=${ADDR[bridge]}
export UPGRADER=${ADDR[upgrader]} ATTESTOR=${ADDR[attestor]} MINTERS=${ADDR[minter]}

# --- deploy + verify -------------------------------------------------------------------------------------------------
script_as deployer script/Deploy.s.sol >/dev/null
TOKEN=$(node -e "console.log(require('./$OUT/deployment.json').token)")
MANAGER=$(node -e "console.log(require('./$OUT/deployment.json').manager)")
echo "deployed: tPD proxy $TOKEN, AccessManager $MANAGER"
forge script script/VerifyRoles.s.sol --rpc-url "$ETH_RPC_URL" | sed -n "/== Logs ==/,/^$/p" | sed "s/^/  /"

# --- reserve attestation signed as EIP-712 typed data -------------------------------------------------------------
CHAIN_ID=$(cast chain-id)
AS_OF=$(cast block latest -f timestamp)
RESERVES=5000000000000 # 5,000,000 tPD
REPORT=$(cast keccak "demo attestation report 2026-09")
cat >"$OUT/attestation.json" <<JSON
{
  "types": {
    "EIP712Domain": [
      {"name": "name", "type": "string"}, {"name": "version", "type": "string"},
      {"name": "chainId", "type": "uint256"}, {"name": "verifyingContract", "type": "address"}
    ],
    "ReserveAttestation": [
      {"name": "reserves", "type": "uint256"}, {"name": "asOf", "type": "uint64"}, {"name": "reportHash", "type": "bytes32"}
    ]
  },
  "primaryType": "ReserveAttestation",
  "domain": {"name": "Test Payment Dollar", "version": "1", "chainId": $CHAIN_ID, "verifyingContract": "$TOKEN"},
  "message": {"reserves": "$RESERVES", "asOf": $AS_OF, "reportHash": "$REPORT"}
}
JSON
SIG=$(cast wallet sign --data --from-file "$OUT/attestation.json" --keystore "$KEYS/attestor" --password-file "$PASSWORD_FILE")
as relayer "$TOKEN" "submitReserveAttestation(uint256,uint64,bytes32,bytes)" "$RESERVES" "$AS_OF" "$REPORT" "$SIG"
echo "attestor signed 5,000,000 tPD of reserves; a relayer submitted it"

# --- minting under allowance + rolling limit ----------------------------------------------------------------------
as masterMinter "$TOKEN" "configureMinter(address,uint256,uint208)" "${ADDR[minter]}" 3000000000000 1000000000000
as minter "$TOKEN" "mint(address,uint256)" "${ADDR[alice]}" 1000000000000
expect_eq "$(bal "${ADDR[alice]}")" 1000000000000 "alice balance after mint"
if OUTPUT=$(cast call --from "${ADDR[minter]}" "$TOKEN" "mint(address,uint256)" "${ADDR[alice]}" 1 2>&1); then
  echo "FAILED: a mint above the rolling 24 h limit went through"
  exit 1
fi
refused "MinterRateLimitExceeded(address,uint256,uint256)" "the mint above the rolling limit" "$OUTPUT"
echo "minter minted 1,000,000 tPD to alice; one more unit is refused by the rolling 24 h limit"

# --- EIP-3009 payment relayed by a third party ---------------------------------------------------------------------
NOW=$(cast block latest -f timestamp)
NONCE=$(cast keccak "$(date +%s%N)-demo-payment")
cat >"$OUT/payment.json" <<JSON
{
  "types": {
    "EIP712Domain": [
      {"name": "name", "type": "string"}, {"name": "version", "type": "string"},
      {"name": "chainId", "type": "uint256"}, {"name": "verifyingContract", "type": "address"}
    ],
    "TransferWithAuthorization": [
      {"name": "from", "type": "address"}, {"name": "to", "type": "address"}, {"name": "value", "type": "uint256"},
      {"name": "validAfter", "type": "uint256"}, {"name": "validBefore", "type": "uint256"}, {"name": "nonce", "type": "bytes32"}
    ]
  },
  "primaryType": "TransferWithAuthorization",
  "domain": {"name": "Test Payment Dollar", "version": "1", "chainId": $CHAIN_ID, "verifyingContract": "$TOKEN"},
  "message": {"from": "${ADDR[alice]}", "to": "${ADDR[bob]}", "value": "250000000",
              "validAfter": "$((NOW - 60))", "validBefore": "$((NOW + 3600))", "nonce": "$NONCE"}
}
JSON
SIG=$(cast wallet sign --data --from-file "$OUT/payment.json" --keystore "$KEYS/alice" --password-file "$PASSWORD_FILE")
as relayer "$TOKEN" "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)" \
  "${ADDR[alice]}" "${ADDR[bob]}" 250000000 "$((NOW - 60))" "$((NOW + 3600))" "$NONCE" "$SIG"
expect_eq "$(bal "${ADDR[bob]}")" 250000000 "bob balance after the EIP-3009 payment"
echo "alice paid bob 250 tPD with an EIP-3009 authorization; she never sent a transaction"

# --- lawful order: freeze, blocked transfer, seize, burn ---------------------------------------------------------
ORDER=$(cast keccak "demo court order #1")
as compliance "$TOKEN" "freeze(address,bytes32)" "${ADDR[bob]}" "$ORDER"
if OUTPUT=$(cast call --from "${ADDR[bob]}" "$TOKEN" "transfer(address,uint256)" "${ADDR[alice]}" 1 2>&1); then
  echo "FAILED: a frozen account could transfer"
  exit 1
fi
refused "AccountFrozen(address)" "bob's transfer" "$OUTPUT"
as compliance "$TOKEN" "seize(address,address,uint256,bytes32)" "${ADDR[bob]}" "${ADDR[custody]}" 100000000 "$ORDER"
as compliance "$TOKEN" "burnFrozen(address,bytes32)" "${ADDR[bob]}" "$ORDER"
expect_eq "$(bal "${ADDR[custody]}")" 100000000 "court custody balance after seizure"
expect_eq "$(bal "${ADDR[bob]}")" 0 "bob balance after burnFrozen"
echo "bob frozen under order $ORDER: transfer refused, 100 tPD seized to custody, 150 tPD burned"

# --- v1 -> v2 through the 2-day schedule ---------------------------------------------------------------------------
script_as upgrader script/UpgradeToV2.s.sol --sig "schedule()" >/dev/null
script_as governance script/UpgradeToV2.s.sol --sig "scheduleWiring()" >/dev/null
if OUTPUT=$(script_as upgrader script/UpgradeToV2.s.sol --sig "execute()" 2>&1); then
  echo "FAILED: the upgrade executed before the 2-day delay"
  exit 1
fi
refused "AccessManagerNotReady(bytes32)" "the early upgrade" "$OUTPUT"
cast rpc evm_increaseTime 172800 >/dev/null
cast rpc evm_mine >/dev/null
script_as upgrader script/UpgradeToV2.s.sol --sig "execute()" >/dev/null
script_as governance script/UpgradeToV2.s.sol --sig "executeWiring()" >/dev/null
expect_eq "$(cast call "$TOKEN" "implementationVersion()(string)")" '"2"' "implementation version after upgrade"
expect_eq "$(cast call "$TOKEN" "version()(string)")" '"1"' "EIP-712 domain version after upgrade"
expect_eq "$(bal "${ADDR[alice]}")" 999750000000 "alice balance preserved across the upgrade"
echo "upgrade to v2 refused before the delay, executed after it; balances preserved"
forge script script/VerifyRoles.s.sol --rpc-url "$ETH_RPC_URL" | sed -n "/== Logs ==/,/^$/p" | sed "s/^/  /"
echo "demo completed"
