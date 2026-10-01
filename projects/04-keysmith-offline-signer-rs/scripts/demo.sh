#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The README's "Local demo", end to end, against a throw-away anvil node:
#
#   prepare (keysmith-relay, online) -> sign (keysmith, offline) -> broadcast (keysmith-relay)
#
# for an EIP-1559 transfer under a policy file, then an EIP-7702 self-executed delegation.
# Every command is the one the README shows; the only difference is `--yes`, which stands in for
# the operator typing "yes" at the confirmation prompt (CI has no terminal).
#
# Usage:  bash scripts/demo.sh          (from anywhere; needs cargo, anvil and cast on PATH)
#
# anvil binds a free port chosen by the OS (--port 0) and is killed by PID on exit. All files are
# written to a fresh temporary directory, never into the repository.
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== building keysmith and keysmith-relay (release)"
cargo build --quiet --locked --release --manifest-path "$PROJECT/Cargo.toml" \
  --bin keysmith --bin keysmith-relay
export PATH="$PROJECT/target/release:$PATH"

WORK="$(mktemp -d)"
ANVIL_PID=""
cleanup() {
  if [[ -n "$ANVIL_PID" ]]; then
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
cd "$WORK"

fail() {
  echo "DEMO FAILED: $*" >&2
  exit 1
}

# --- anvil on a free port ----------------------------------------------------------------------
anvil --hardfork osaka --port 0 --host 127.0.0.1 >anvil.log 2>&1 &
ANVIL_PID=$!
RPC=""
for _ in $(seq 1 120); do
  if address=$(grep -m1 -o 'Listening on [0-9.:]*' anvil.log 2>/dev/null); then
    RPC="http://${address#Listening on }"
    break
  fi
  kill -0 "$ANVIL_PID" 2>/dev/null || fail "anvil exited: $(cat anvil.log)"
  sleep 0.5
done
[[ -n "$RPC" ]] || fail "anvil did not report its address within 60 s"
echo "== anvil (pid $ANVIL_PID) at $RPC"

FROM=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
TO=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
DELEGATE=0x5FbDB2315678afecb367f032d93F642f64180aa3

# --- the README demo, verbatim apart from --yes ------------------------------------------------
echo "test test test test test test test test test test test junk" > mnemonic.txt
echo '{"allowedChainIds":[31337],"maxValueWei":"2000000000000000000"}' > policy.json

echo "== online: prepare an EIP-1559 transfer of 1 ether"
keysmith-relay --rpc-url "$RPC" prepare --type eip1559 \
  --from "$FROM" \
  --to "$TO" --value 1ether --out unsigned.json

echo "== offline: review and sign under the policy"
keysmith sign --envelope unsigned.json --mnemonic-file mnemonic.txt --policy policy.json --out signed.json --yes
keysmith decode --file signed.json

echo "== online: verify and broadcast"
keysmith-relay --rpc-url "$RPC" broadcast --envelope signed.json --wait

balance=$(cast balance "$TO" --rpc-url "$RPC")
[[ "$balance" == "10001000000000000000000" ]] || fail "recipient balance is $balance, expected 10001 ether"
echo "ok   recipient received 1 ether ($balance wei)"

echo "== EIP-7702: delegate the sender's own account (authorization nonce = tx nonce + 1)"
keysmith-relay --rpc-url "$RPC" prepare --type eip7702 \
  --from "$FROM" --to "$FROM" \
  --gas-limit 100000 --self-auth "31337:$DELEGATE" --out u7702.json
keysmith sign --envelope u7702.json --mnemonic-file mnemonic.txt --out s7702.json --yes
keysmith-relay --rpc-url "$RPC" broadcast --envelope s7702.json --wait

code=$(cast code "$FROM" --rpc-url "$RPC")
expected="0xef0100$(echo "${DELEGATE#0x}" | tr '[:upper:]' '[:lower:]')"
[[ "$(echo "$code" | tr '[:upper:]' '[:lower:]')" == "$expected" ]] \
  || fail "code at $FROM is $code, expected $expected"
echo "ok   $FROM is delegated: $code"

# --- refusals: the policy and the confirmation gate -------------------------------------------
echo "== a transfer above maxValueWei is refused with exit code 3 and writes nothing"
keysmith-relay --rpc-url "$RPC" prepare --type eip1559 \
  --from "$FROM" --to "$TO" --value 3ether --out big.json
set +e
keysmith sign --envelope big.json --mnemonic-file mnemonic.txt --policy policy.json --out never.json --yes
status=$?
set -e
[[ $status -eq 3 && ! -e never.json ]] || fail "expected exit 3 and no output, got $status"
echo "ok   refused (exit 3), nothing written"

echo "== without --yes and without a terminal, keysmith prints the review and does not sign"
set +e
keysmith sign --envelope unsigned.json --mnemonic-file mnemonic.txt --out unattended.json </dev/null
status=$?
set -e
[[ $status -ne 0 && ! -e unattended.json ]] || fail "signed without confirmation (exit $status)"
echo "ok   not signed (exit $status)"

echo "== demo passed"
