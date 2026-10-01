// SPDX-License-Identifier: MIT
/**
 * Client-side construction and signing of x402 payment payloads for the three schemes.
 * Signers are viem `LocalAccount`s: an EOA payer for `exact` / `escrow`, a session key for `budget-exec`.
 */
import type { Address, LocalAccount } from 'viem';
import type { Deployment } from '../chain/deployment.js';
import {
  budgetExecutorDomain,
  paymentIntentTypes,
  receiveWithAuthorizationTypes,
  tokenDomain,
  transferWithAuthorizationTypes,
} from '../chain/typedData.js';
import { escrowNonce, exactNonce, randomBytes32 } from '../x402/resource.js';
import {
  X402_VERSION,
  escrowExtraSchema,
  exactExtraSchema,
  budgetExecExtraSchema,
  type BudgetExecPayload,
  type EscrowPayload,
  type ExactPayload,
  type PaymentPayload,
  type PaymentRequirements,
  type ResourceInfo,
} from '../x402/types.js';

export interface PaymentContext {
  readonly deployment: Deployment;
  readonly requirements: PaymentRequirements;
  readonly resource: ResourceInfo;
  /** Chain time used to derive the validity window. */
  readonly now: bigint;
}

/** `validAfter` is set a little in the past to tolerate clock skew between the agent and the chain. */
const VALID_AFTER_SLACK = 10n;

function payloadOf(
  context: PaymentContext,
  payload: ExactPayload | BudgetExecPayload | EscrowPayload,
): PaymentPayload {
  return {
    x402Version: X402_VERSION,
    resource: context.resource,
    accepted: context.requirements,
    payload: payload,
  };
}

/** `exact`: EIP-3009 TransferWithAuthorization with a resource-bound nonce. */
export async function buildExactPayment(
  context: PaymentContext,
  payer: LocalAccount,
): Promise<PaymentPayload> {
  const extra = exactExtraSchema.parse(context.requirements.extra);
  const resourceSalt = randomBytes32();
  const message = {
    from: payer.address,
    to: context.requirements.payTo,
    value: BigInt(context.requirements.amount),
    validAfter: context.now - VALID_AFTER_SLACK,
    validBefore: context.now + BigInt(context.requirements.maxTimeoutSeconds),
    nonce: exactNonce(extra.resourceHash, resourceSalt),
  };
  const signature = await payer.signTypedData({
    domain: tokenDomain(context.deployment),
    types: transferWithAuthorizationTypes,
    primaryType: 'TransferWithAuthorization',
    message,
  });
  return payloadOf(context, {
    signature,
    resourceSalt,
    authorization: {
      from: message.from,
      to: message.to,
      value: message.value.toString(),
      validAfter: message.validAfter.toString(),
      validBefore: message.validBefore.toString(),
      nonce: message.nonce,
    },
  });
}

/** `budget-exec`: session-key PaymentIntent for the smart account `account`. */
export async function buildBudgetPayment(
  context: PaymentContext,
  account: Address,
  sessionKey: LocalAccount,
): Promise<PaymentPayload> {
  const extra = budgetExecExtraSchema.parse(context.requirements.extra);
  const intent = {
    account,
    payee: context.requirements.payTo,
    amount: BigInt(context.requirements.amount),
    resourceHash: extra.resourceHash,
    nonce: randomBytes32(),
    validAfter: context.now - VALID_AFTER_SLACK,
    validBefore: context.now + BigInt(context.requirements.maxTimeoutSeconds),
  };
  const signature = await sessionKey.signTypedData({
    domain: budgetExecutorDomain(context.deployment),
    types: paymentIntentTypes,
    primaryType: 'PaymentIntent',
    message: intent,
  });
  return payloadOf(context, {
    signature,
    intent: {
      account: intent.account,
      payee: intent.payee,
      amount: intent.amount.toString(),
      resourceHash: intent.resourceHash,
      nonce: intent.nonce,
      validAfter: intent.validAfter.toString(),
      validBefore: intent.validBefore.toString(),
    },
  });
}

/** `escrow`: EIP-3009 ReceiveWithAuthorization into PaymentEscrow, nonce bound to payee, resource and deadline. */
export async function buildEscrowPayment(
  context: PaymentContext,
  payer: LocalAccount,
): Promise<PaymentPayload> {
  const extra = escrowExtraSchema.parse(context.requirements.extra);
  const salt = randomBytes32();
  const deliveryDeadline = context.now + BigInt(extra.deliveryWindowSeconds);
  const payee = context.requirements.payTo;
  const message = {
    from: payer.address,
    to: extra.escrow,
    value: BigInt(context.requirements.amount),
    validAfter: context.now - VALID_AFTER_SLACK,
    validBefore: context.now + BigInt(context.requirements.maxTimeoutSeconds),
    nonce: escrowNonce(payee, extra.resourceHash, deliveryDeadline, salt),
  };
  const signature = await payer.signTypedData({
    domain: tokenDomain(context.deployment),
    types: receiveWithAuthorizationTypes,
    primaryType: 'ReceiveWithAuthorization',
    message,
  });
  return payloadOf(context, {
    signature,
    authorization: {
      from: message.from,
      to: message.to,
      value: message.value.toString(),
      validAfter: message.validAfter.toString(),
      validBefore: message.validBefore.toString(),
      nonce: message.nonce,
    },
    escrow: {
      payee,
      resourceHash: extra.resourceHash,
      deliveryDeadline: deliveryDeadline.toString(),
      salt,
    },
  });
}
