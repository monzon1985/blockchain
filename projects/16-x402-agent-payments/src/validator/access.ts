// SPDX-License-Identifier: MIT
/**
 * Access control for validation documents.
 *
 * A work document carries the raw paid request (its body and full URL, which may hold personal data), because a
 * validator needs exactly those bytes to recompute the payment's resource hash. The resource server therefore serves
 * a document only to the validator named in the on-chain request, which proves itself with an EIP-191 signature over
 * the request hash and a short expiry. Both sides build the signed text with {@link validationAccessMessage}.
 */
import type { Hex } from 'viem';

export const VALIDATOR_SIGNATURE_HEADER = 'x-validator-signature';
export const VALIDATOR_EXPIRES_HEADER = 'x-validator-expires';

/** Longest validity a server accepts for an access signature, in seconds. */
export const MAX_ACCESS_SIGNATURE_TTL_SECONDS = 300;

/** Text the validator signs (EIP-191 personal message) to fetch the document committed to by `requestHash`. */
export function validationAccessMessage(requestHash: Hex, expires: number): string {
  return `x402-local validation document\nrequestHash: ${requestHash.toLowerCase()}\nexpires: ${String(expires)}`;
}
