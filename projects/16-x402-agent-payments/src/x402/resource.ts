// SPDX-License-Identifier: MIT
/**
 * Canonical resource identifiers and the nonce commitments that bind payments to them.
 *
 * A payment is bound to `resourceHash = keccak256(canonicalResource)`, where the canonical form covers the method,
 * the public URL (origin, path, sorted query) and the SHA-256 of the request body. Paying for `POST /sentiment`
 * with body A therefore cannot be replayed for body B, for another path, or against another server.
 *
 * The binding helpers mirror `contracts/src/settlement/ResourceBinding.sol` bit for bit (checked against the
 * contracts in the e2e differential tests).
 */
import { createHash, randomBytes } from 'node:crypto';
import { encodeAbiParameters, keccak256, toBytes, toHex, type Address, type Hex } from 'viem';

export interface ResourceRequest {
  readonly method: string;
  readonly url: string;
  readonly body?: string | Uint8Array | undefined;
}

/** Builds the canonical resource string: `METHOD origin/path?sorted-query#sha256=<hex>`. */
export function canonicalResource(request: ResourceRequest): string {
  const url = new URL(request.url);
  const params = [...url.searchParams.entries()].sort(([a, av], [b, bv]) =>
    a === b ? (av < bv ? -1 : av > bv ? 1 : 0) : a < b ? -1 : 1,
  );
  const query = params.length === 0 ? '' : `?${new URLSearchParams(params).toString()}`;
  const body = request.body ?? '';
  const bodyHash = createHash('sha256')
    .update(typeof body === 'string' ? Buffer.from(body, 'utf8') : body)
    .digest('hex');
  return `${request.method.toUpperCase()} ${url.origin}${url.pathname}${query}#sha256=${bodyHash}`;
}

/** keccak256 of the canonical resource string. */
export function resourceHash(request: ResourceRequest): Hex {
  return keccak256(toBytes(canonicalResource(request)));
}

export const EXACT_BINDING_TAG = keccak256(toBytes('x402-local/exact/resource-binding/v1'));
export const ESCROW_BINDING_TAG = keccak256(toBytes('x402-local/escrow/terms-binding/v1'));

/** Clears the low 64 bits (the EIP-3009 keyed-nonce sequence) and keeps the 192-bit key. */
const KEY_MASK = ((1n << 256n) - 1n) ^ ((1n << 64n) - 1n);

function keyOnly(hash: Hex): Hex {
  return toHex(BigInt(hash) & KEY_MASK, { size: 32 });
}

/** Mirrors `ResourceBinding.exactNonce`. */
export function exactNonce(resource: Hex, salt: Hex): Hex {
  return keyOnly(
    keccak256(
      encodeAbiParameters(
        [{ type: 'bytes32' }, { type: 'bytes32' }, { type: 'bytes32' }],
        [EXACT_BINDING_TAG, resource, salt],
      ),
    ),
  );
}

/** Mirrors `ResourceBinding.escrowNonce`. */
export function escrowNonce(payee: Address, resource: Hex, deliveryDeadline: bigint, salt: Hex): Hex {
  return keyOnly(
    keccak256(
      encodeAbiParameters(
        [
          { type: 'bytes32' },
          { type: 'address' },
          { type: 'bytes32' },
          { type: 'uint256' },
          { type: 'bytes32' },
        ],
        [ESCROW_BINDING_TAG, payee, resource, deliveryDeadline, salt],
      ),
    ),
  );
}

/** True if the nonce has a zero 64-bit sequence, as OpenZeppelin's keyed EIP-3009 requires for a fresh key. */
export function hasZeroSequence(nonce: Hex): boolean {
  return (BigInt(nonce) & ((1n << 64n) - 1n)) === 0n;
}

/** 32 cryptographically random bytes. */
export function randomBytes32(): Hex {
  return toHex(randomBytes(32));
}
