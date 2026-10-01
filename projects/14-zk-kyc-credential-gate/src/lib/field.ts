// SPDX-License-Identifier: MIT
import { encodeAbiParameters, getAddress, keccak256, stringToHex, type Address, type Hex } from "viem";

/** BN254 (alt_bn128) scalar field modulus `r`. All circuit values live in Z_r. */
export const FIELD_MODULUS =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

/** Normalise a signed bigint into the canonical `[0, r)` representative. */
export function mod(value: bigint): bigint {
  const m = value % FIELD_MODULUS;
  return m < 0n ? m + FIELD_MODULUS : m;
}

/** True iff `value` is a canonical field element (`0 <= value < r`). */
export function inField(value: bigint): boolean {
  return value >= 0n && value < FIELD_MODULUS;
}

/** Modular inverse in Z_r (Fermat). Throws on zero. */
export function invMod(value: bigint): bigint {
  const v = mod(value);
  if (v === 0n) throw new Error("no inverse of 0 in Z_r");
  let result = 1n;
  let base = v;
  let e = FIELD_MODULUS - 2n;
  while (e > 0n) {
    if (e & 1n) result = (result * base) % FIELD_MODULUS;
    base = (base * base) % FIELD_MODULUS;
    e >>= 1n;
  }
  return result;
}

/**
 * Derive the per-gate, per-epoch scope scalar.
 *
 * `appScope = keccak256(abi.encode(uint256 chainId, address gate, bytes32 actionId, uint256 epoch)) mod r`
 *
 * This MUST match `ZkGate.scopeForEpoch` exactly. Binding the gate's own
 * address means a clone deployed elsewhere (even with the same actionId) has a
 * different scope, so proofs collected there cannot be replayed at the real
 * gate. Binding the epoch makes registrations expire: a holder re-proves each
 * epoch, so revocation, expiry and sanctions changes take effect within one
 * epoch (see README "Invariants").
 */
export function computeAppScope(chainId: bigint, gate: Address, actionId: Hex, epoch: bigint): bigint {
  const encoded = encodeAbiParameters(
    [{ type: "uint256" }, { type: "address" }, { type: "bytes32" }, { type: "uint256" }],
    [chainId, getAddress(gate), actionId, epoch],
  );
  return mod(BigInt(keccak256(encoded)));
}

/** Convenience: derive a bytes32 `actionId` from a human-readable string. */
export function actionIdFromString(domain: string): Hex {
  return keccak256(stringToHex(domain));
}

/** The `recipient` public input for an address: `uint256(uint160(addr))`. */
export function addressToField(addr: Address): bigint {
  return BigInt(getAddress(addr));
}

/** Serialise a bigint map to the decimal-string JSON snarkjs expects. */
export function stringifyInputs(
  input: Record<string, bigint | bigint[]>,
): Record<string, string | string[]> {
  const out: Record<string, string | string[]> = {};
  for (const [key, value] of Object.entries(input)) {
    out[key] = Array.isArray(value) ? value.map((v) => v.toString()) : value.toString();
  }
  return out;
}
