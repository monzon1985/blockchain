// SPDX-License-Identifier: MIT
/**
 * Facilitator-side payment verification for the three schemes.
 *
 * The facilitator is treated as untrusted by everybody else, so nothing here is a security boundary for the payer:
 * the contracts re-check every rule. These checks exist so that a broken or stale payment is refused with a precise
 * reason *before* gas is spent, and so the resource server gets an x402-style `invalidReason`.
 */
import { hashTypedData, isAddressEqual, type Address, type Hex } from 'viem';
import { ReceiptScheme, escrowIdFor, receiptIdFor } from '../chain/ids.js';
import type { ChainReader, SettlementCall } from '../chain/reader.js';
import type { Deployment } from '../chain/deployment.js';
import {
  budgetExecutorDomain,
  paymentIntentTypes,
  receiveWithAuthorizationTypes,
  tokenDomain,
  transferWithAuthorizationTypes,
  type PaymentIntent,
} from '../chain/typedData.js';
import { escrowNonce, exactNonce, hasZeroSequence } from '../x402/resource.js';
import {
  LOCAL_NETWORK,
  budgetExecExtraSchema,
  budgetExecPayloadSchema,
  escrowExtraSchema,
  escrowPayloadSchema,
  exactExtraSchema,
  exactPayloadSchema,
  type FacilitatorRequest,
  type PaymentRequirements,
} from '../x402/types.js';

/** Seconds an authorization must still be valid for when it reaches the facilitator. */
export const MIN_REMAINING_VALIDITY = 5n;
/** Clock skew tolerated between the payer, the facilitator and the chain. */
export const CLOCK_SKEW = 30n;

/** What a verified payment will produce on-chain. */
export interface ExpectedSettlement {
  readonly kind: 'receipt' | 'escrow';
  /** Receipt id (exact, budget-exec) or escrow id (escrow). */
  readonly id: Hex;
  readonly payer: Address;
  readonly payee: Address;
  readonly amount: bigint;
  readonly resourceHash: Hex;
}

/** A syntactically valid payment, not yet checked against signatures or chain state. */
export interface PreparedPayment {
  readonly scheme: 'exact' | 'budget-exec' | 'escrow';
  readonly payer: Address;
  readonly idempotencyKey: string;
  readonly call: SettlementCall;
  readonly expected: ExpectedSettlement;
}

export type Invalid = { readonly isValid: false; readonly invalidReason: string; readonly payer?: Address };
export type Prepared = { readonly isValid: true; readonly payment: PreparedPayment };
export type Verification = { readonly isValid: true; readonly payment: PreparedPayment } | Invalid;

const invalid = (invalidReason: string, payer?: Address): Invalid =>
  payer === undefined ? { isValid: false, invalidReason } : { isValid: false, invalidReason, payer };

function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>).sort(([a], [b]) =>
      a < b ? -1 : a > b ? 1 : 0,
    );
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJson(v)}`).join(',')}}`;
  }
  // Hex strings (addresses, hashes) compare case-insensitively; everything else must match exactly.
  return JSON.stringify(
    typeof value === 'string' && /^0x[0-9a-fA-F]+$/.test(value) ? value.toLowerCase() : value,
  );
}

/** True if what the client accepted is exactly what the server requires (addresses compared case-insensitively). */
export function requirementsMatch(accepted: PaymentRequirements, required: PaymentRequirements): boolean {
  return (
    accepted.scheme === required.scheme &&
    accepted.network === required.network &&
    accepted.amount === required.amount &&
    isAddressEqual(accepted.asset, required.asset) &&
    isAddressEqual(accepted.payTo, required.payTo) &&
    accepted.maxTimeoutSeconds === required.maxTimeoutSeconds &&
    canonicalJson(accepted.extra ?? {}) === canonicalJson(required.extra ?? {})
  );
}

/**
 * Parses a facilitator request into the exact on-chain call it would make, without touching the chain. Rejects
 * anything whose fields contradict the requirements (payee, amount, resource, contract addresses).
 */
export function preparePayment(request: FacilitatorRequest, deployment: Deployment): Prepared | Invalid {
  const { paymentPayload, paymentRequirements: req } = request;
  if (!requirementsMatch(paymentPayload.accepted, req)) return invalid('invalid_payment_requirements');
  if (req.network !== LOCAL_NETWORK) return invalid('invalid_network');
  if (!isAddressEqual(req.asset, deployment.testUSD)) return invalid('invalid_payment_requirements');
  const amount = BigInt(req.amount);
  if (amount === 0n) return invalid('invalid_payment_requirements');

  switch (req.scheme) {
    case 'exact': {
      const extra = exactExtraSchema.safeParse(req.extra);
      if (!extra.success || !isAddressEqual(extra.data.settlementLog, deployment.settlementLog)) {
        return invalid('invalid_payment_requirements');
      }
      const parsed = exactPayloadSchema.safeParse(paymentPayload.payload);
      if (!parsed.success) return invalid('invalid_payload');
      const { authorization: a, resourceSalt, signature } = parsed.data;
      if (!isAddressEqual(a.to, req.payTo))
        return invalid('invalid_exact_evm_payload_recipient_mismatch', a.from);
      if (BigInt(a.value) !== amount)
        return invalid('invalid_exact_evm_payload_authorization_value_mismatch', a.from);
      if (!hasZeroSequence(a.nonce) || exactNonce(extra.data.resourceHash, resourceSalt) !== a.nonce) {
        return invalid('invalid_resource_binding', a.from);
      }
      const auth = {
        from: a.from,
        to: a.to,
        value: amount,
        validAfter: BigInt(a.validAfter),
        validBefore: BigInt(a.validBefore),
        nonce: a.nonce,
      };
      return {
        isValid: true,
        payment: {
          scheme: 'exact',
          payer: a.from,
          idempotencyKey: `exact:${a.from.toLowerCase()}:${a.nonce}`,
          call: {
            kind: 'exact',
            args: { auth, resourceHash: extra.data.resourceHash, resourceSalt, signature },
          },
          expected: {
            kind: 'receipt',
            id: receiptIdFor(deployment.settlementLog, ReceiptScheme.Exact, a.from, a.nonce),
            payer: a.from,
            payee: a.to,
            amount,
            resourceHash: extra.data.resourceHash,
          },
        },
      };
    }
    case 'budget-exec': {
      const extra = budgetExecExtraSchema.safeParse(req.extra);
      if (!extra.success || !isAddressEqual(extra.data.budgetExecutor, deployment.budgetExecutor)) {
        return invalid('invalid_payment_requirements');
      }
      const parsed = budgetExecPayloadSchema.safeParse(paymentPayload.payload);
      if (!parsed.success) return invalid('invalid_payload');
      const { intent: i, signature } = parsed.data;
      if (!isAddressEqual(i.payee, req.payTo))
        return invalid('invalid_budget_exec_payee_mismatch', i.account);
      if (BigInt(i.amount) !== amount) return invalid('invalid_budget_exec_amount_mismatch', i.account);
      if (i.resourceHash !== extra.data.resourceHash) return invalid('invalid_resource_binding', i.account);
      const intent: PaymentIntent = {
        account: i.account,
        payee: i.payee,
        amount,
        resourceHash: i.resourceHash,
        nonce: i.nonce,
        validAfter: BigInt(i.validAfter),
        validBefore: BigInt(i.validBefore),
      };
      return {
        isValid: true,
        payment: {
          scheme: 'budget-exec',
          payer: i.account,
          idempotencyKey: `budget-exec:${i.account.toLowerCase()}:${i.nonce}`,
          call: { kind: 'budget-exec', intent, signature },
          expected: {
            kind: 'receipt',
            id: receiptIdFor(deployment.budgetExecutor, ReceiptScheme.BudgetExec, i.account, i.nonce),
            payer: i.account,
            payee: i.payee,
            amount,
            resourceHash: i.resourceHash,
          },
        },
      };
    }
    case 'escrow': {
      const extra = escrowExtraSchema.safeParse(req.extra);
      if (!extra.success || !isAddressEqual(extra.data.escrow, deployment.paymentEscrow)) {
        return invalid('invalid_payment_requirements');
      }
      const parsed = escrowPayloadSchema.safeParse(paymentPayload.payload);
      if (!parsed.success) return invalid('invalid_payload');
      const { authorization: a, escrow: terms, signature } = parsed.data;
      if (!isAddressEqual(a.to, deployment.paymentEscrow)) return invalid('invalid_escrow_contract', a.from);
      if (!isAddressEqual(terms.payee, req.payTo)) return invalid('invalid_escrow_payee_mismatch', a.from);
      if (BigInt(a.value) !== amount) return invalid('invalid_escrow_value_mismatch', a.from);
      if (terms.resourceHash !== extra.data.resourceHash) return invalid('invalid_resource_binding', a.from);
      const deadline = BigInt(terms.deliveryDeadline);
      if (
        !hasZeroSequence(a.nonce) ||
        escrowNonce(terms.payee, terms.resourceHash, deadline, terms.salt) !== a.nonce
      ) {
        return invalid('invalid_resource_binding', a.from);
      }
      return {
        isValid: true,
        payment: {
          scheme: 'escrow',
          payer: a.from,
          idempotencyKey: `escrow:${a.from.toLowerCase()}:${a.nonce}`,
          call: {
            kind: 'escrow',
            args: {
              request: {
                from: a.from,
                value: amount,
                validAfter: BigInt(a.validAfter),
                validBefore: BigInt(a.validBefore),
                nonce: a.nonce,
                payee: terms.payee,
                resourceHash: terms.resourceHash,
                deliveryDeadline: deadline,
                salt: terms.salt,
              },
              signature,
            },
          },
          expected: {
            kind: 'escrow',
            id: escrowIdFor(a.from, a.nonce),
            payer: a.from,
            payee: terms.payee,
            amount,
            resourceHash: terms.resourceHash,
          },
        },
      };
    }
    default:
      return invalid('unsupported_scheme');
  }
}

function checkWindow(
  validAfter: bigint,
  validBefore: bigint,
  now: bigint,
  maxTimeoutSeconds: number,
  prefix: string,
  payer: Address,
): Invalid | null {
  if (validAfter >= now + CLOCK_SKEW) return invalid(`${prefix}_valid_after`, payer);
  if (validBefore <= now + MIN_REMAINING_VALIDITY) return invalid(`${prefix}_valid_before`, payer);
  if (validBefore > now + BigInt(maxTimeoutSeconds) + CLOCK_SKEW)
    return invalid(`${prefix}_valid_before`, payer);
  return null;
}

/** Full verification: static checks, signature, chain state and an eth_call simulation of the settlement. */
export async function verifyPayment(
  request: FacilitatorRequest,
  deployment: Deployment,
  chain: ChainReader,
): Promise<Verification> {
  const prepared = preparePayment(request, deployment);
  if (!prepared.isValid) return prepared;
  const { payment } = prepared;
  const req = request.paymentRequirements;
  const now = await chain.now();
  const call = payment.call;

  switch (call.kind) {
    case 'exact': {
      const { auth, signature } = call.args;
      const windowError = checkWindow(
        auth.validAfter,
        auth.validBefore,
        now,
        req.maxTimeoutSeconds,
        'invalid_exact_evm_payload_authorization',
        auth.from,
      );
      if (windowError !== null) return windowError;
      const digest = hashTypedData({
        domain: tokenDomain(deployment),
        types: transferWithAuthorizationTypes,
        primaryType: 'TransferWithAuthorization',
        message: auth,
      });
      if (!(await chain.isValidSignature(auth.from, digest, signature))) {
        return invalid('invalid_exact_evm_payload_signature', auth.from);
      }
      if (await chain.authorizationUsed(auth.from, auth.nonce))
        return invalid('nonce_already_used', auth.from);
      if ((await chain.tokenBalance(auth.from)) < auth.value) return invalid('insufficient_funds', auth.from);
      break;
    }
    case 'budget-exec': {
      const { intent, signature } = call;
      const windowError = checkWindow(
        intent.validAfter,
        intent.validBefore,
        now,
        req.maxTimeoutSeconds,
        'invalid_budget_exec_intent',
        intent.account,
      );
      if (windowError !== null) return windowError;
      const policy = await chain.budgetPolicy(intent.account);
      if (policy.sessionKey === '0x0000000000000000000000000000000000000000') {
        return invalid('budget_not_installed', intent.account);
      }
      const digest = hashTypedData({
        domain: budgetExecutorDomain(deployment),
        types: paymentIntentTypes,
        primaryType: 'PaymentIntent',
        message: intent,
      });
      if (!(await chain.isValidSignature(policy.sessionKey, digest, signature))) {
        return invalid('invalid_budget_exec_signature', intent.account);
      }
      if (now > policy.validUntil) return invalid('budget_session_expired', intent.account);
      if (intent.amount > policy.perCallCap) return invalid('budget_per_call_cap_exceeded', intent.account);
      if (!(await chain.isPayeeAllowed(intent.account, intent.payee))) {
        return invalid('budget_payee_not_allowed', intent.account);
      }
      if (await chain.intentNonceUsed(intent.account, intent.nonce)) {
        return invalid('nonce_already_used', intent.account);
      }
      if ((await chain.remainingBudget(intent.account)) < intent.amount) {
        return invalid('budget_exhausted', intent.account);
      }
      if ((await chain.tokenBalance(intent.account)) < intent.amount) {
        return invalid('insufficient_funds', intent.account);
      }
      break;
    }
    case 'escrow': {
      const { request: r, signature } = call.args;
      const windowError = checkWindow(
        r.validAfter,
        r.validBefore,
        now,
        req.maxTimeoutSeconds,
        'invalid_escrow_authorization',
        r.from,
      );
      if (windowError !== null) return windowError;
      const extra = escrowExtraSchema.parse(req.extra);
      if (
        r.deliveryDeadline <= now ||
        r.deliveryDeadline > now + BigInt(extra.deliveryWindowSeconds) + CLOCK_SKEW
      ) {
        return invalid('invalid_escrow_deadline', r.from);
      }
      const digest = hashTypedData({
        domain: tokenDomain(deployment),
        types: receiveWithAuthorizationTypes,
        primaryType: 'ReceiveWithAuthorization',
        message: {
          from: r.from,
          to: deployment.paymentEscrow,
          value: r.value,
          validAfter: r.validAfter,
          validBefore: r.validBefore,
          nonce: r.nonce,
        },
      });
      if (!(await chain.isValidSignature(r.from, digest, signature))) {
        return invalid('invalid_escrow_signature', r.from);
      }
      if (await chain.authorizationUsed(r.from, r.nonce)) return invalid('nonce_already_used', r.from);
      if ((await chain.tokenBalance(r.from)) < r.value) return invalid('insufficient_funds', r.from);
      break;
    }
  }

  const simulation = await chain.simulate(call);
  if (!simulation.ok) return invalid(`simulation_failed:${simulation.reason}`, payment.payer);
  return { isValid: true, payment };
}
