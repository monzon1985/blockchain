// SPDX-License-Identifier: MIT
/** EIP-712 type definitions shared by signers (agent) and verifiers (facilitator). They mirror the contracts. */
import type { Address, TypedDataDomain } from 'viem';
import { BUDGET_EXECUTOR_DOMAIN, IDENTITY_DOMAIN, TOKEN_DOMAIN, type Deployment } from './deployment.js';

export const transferWithAuthorizationTypes = {
  TransferWithAuthorization: [
    { name: 'from', type: 'address' },
    { name: 'to', type: 'address' },
    { name: 'value', type: 'uint256' },
    { name: 'validAfter', type: 'uint256' },
    { name: 'validBefore', type: 'uint256' },
    { name: 'nonce', type: 'bytes32' },
  ],
} as const;

export const receiveWithAuthorizationTypes = {
  ReceiveWithAuthorization: [
    { name: 'from', type: 'address' },
    { name: 'to', type: 'address' },
    { name: 'value', type: 'uint256' },
    { name: 'validAfter', type: 'uint256' },
    { name: 'validBefore', type: 'uint256' },
    { name: 'nonce', type: 'bytes32' },
  ],
} as const;

export const paymentIntentTypes = {
  PaymentIntent: [
    { name: 'account', type: 'address' },
    { name: 'payee', type: 'address' },
    { name: 'amount', type: 'uint256' },
    { name: 'resourceHash', type: 'bytes32' },
    { name: 'nonce', type: 'bytes32' },
    { name: 'validAfter', type: 'uint256' },
    { name: 'validBefore', type: 'uint256' },
  ],
} as const;

export const setAgentWalletTypes = {
  SetAgentWallet: [
    { name: 'agentId', type: 'uint256' },
    { name: 'newWallet', type: 'address' },
    { name: 'owner', type: 'address' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
  ],
} as const;

export function tokenDomain(deployment: Deployment): TypedDataDomain {
  return { ...TOKEN_DOMAIN, chainId: deployment.chainId, verifyingContract: deployment.testUSD };
}

export function budgetExecutorDomain(deployment: Deployment): TypedDataDomain {
  return {
    ...BUDGET_EXECUTOR_DOMAIN,
    chainId: deployment.chainId,
    verifyingContract: deployment.budgetExecutor,
  };
}

export function identityDomain(deployment: Deployment): TypedDataDomain {
  return { ...IDENTITY_DOMAIN, chainId: deployment.chainId, verifyingContract: deployment.identityRegistry };
}

/** Message shape of a budget-exec intent with bigint fields, as signed and as passed to the contract. */
export interface PaymentIntent {
  readonly account: Address;
  readonly payee: Address;
  readonly amount: bigint;
  readonly resourceHash: `0x${string}`;
  readonly nonce: `0x${string}`;
  readonly validAfter: bigint;
  readonly validBefore: bigint;
}
