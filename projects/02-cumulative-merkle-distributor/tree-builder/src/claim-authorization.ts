// SPDX-License-Identifier: MIT
/**
 * EIP-712 claim authorizations for `CumulativeMerkleDistributor.claimFor`. A wallet signs one of these to let a relayer
 * claim its rewards and pay them to `recipient`.
 */
import { hashDomain, hashTypedData, type Address, type Hex, type TypedDataDomain } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

export const EIP712_NAME = 'CumulativeMerkleDistributor';
export const EIP712_VERSION = '1';

export const CLAIM_AUTHORIZATION_TYPES = {
  ClaimAuthorization: [
    { name: 'account', type: 'address' },
    { name: 'token', type: 'address' },
    { name: 'cumulativeAmount', type: 'uint256' },
    { name: 'recipient', type: 'address' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
  ],
} as const;

export interface ClaimAuthorization {
  readonly account: Address;
  readonly token: Address;
  readonly cumulativeAmount: bigint;
  readonly recipient: Address;
  /** Must equal `nonces(account)` on the distributor when the claim executes. */
  readonly nonce: bigint;
  /** Last valid unix timestamp (inclusive). */
  readonly deadline: bigint;
}

export interface ClaimAuthorizationDomain extends TypedDataDomain {
  readonly name: string;
  readonly version: string;
  readonly chainId: number;
  readonly verifyingContract: Address;
}

export function claimAuthorizationDomain(chainId: number, verifyingContract: Address): ClaimAuthorizationDomain {
  return { name: EIP712_NAME, version: EIP712_VERSION, chainId, verifyingContract };
}

/** EIP-712 domain separator, as returned by the contract's `DOMAIN_SEPARATOR()`. */
export function claimAuthorizationDomainSeparator(domain: ClaimAuthorizationDomain): Hex {
  return hashDomain({
    domain: { ...domain, chainId: BigInt(domain.chainId) },
    types: {
      EIP712Domain: [
        { name: 'name', type: 'string' },
        { name: 'version', type: 'string' },
        { name: 'chainId', type: 'uint256' },
        { name: 'verifyingContract', type: 'address' },
      ],
    },
  });
}

function typedData(domain: TypedDataDomain, message: ClaimAuthorization) {
  return {
    domain,
    types: CLAIM_AUTHORIZATION_TYPES,
    primaryType: 'ClaimAuthorization',
    message: { ...message },
  } as const;
}

/** The digest the distributor checks (`hashClaimAuthorization`). */
export function hashClaimAuthorization(domain: TypedDataDomain, message: ClaimAuthorization): Hex {
  return hashTypedData(typedData(domain, message));
}

/** 65-byte `r || s || v` signature by `privateKey` (EOAs and EIP-7702 accounts). */
export async function signClaimAuthorization(
  privateKey: Hex,
  domain: TypedDataDomain,
  message: ClaimAuthorization,
): Promise<Hex> {
  return privateKeyToAccount(privateKey).signTypedData(typedData(domain, message));
}
