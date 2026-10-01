// SPDX-License-Identifier: MIT
/**
 * The agent's own acceptance rules for a `PAYMENT-REQUIRED` challenge. These run before anything is signed and
 * protect the agent from a malicious or misconfigured *server* (the on-chain BudgetExecutor protects the principal
 * from a malicious or buggy *agent*). A challenge is refused unless every rule holds.
 */
import { isAddressEqual, type Address, type Hex } from 'viem';
import type { Deployment } from '../chain/deployment.js';
import {
  LOCAL_NETWORK,
  budgetExecExtraSchema,
  escrowExtraSchema,
  exactExtraSchema,
  type PaymentRequired,
  type PaymentRequirements,
  type Scheme,
} from '../x402/types.js';

export interface ClientPolicy {
  /** Largest price the agent accepts for a single call, in token base units. */
  readonly maxPricePerCall: bigint;
  /** Schemes the agent can pay with, in order of preference. */
  readonly schemes: readonly Scheme[];
  /**
   * Longest validity the agent gives a signed authorization (the challenge's `maxTimeoutSeconds`). A long window
   * widens the time in which a leaked authorization can be submitted. Default {@link DEFAULT_MAX_AUTHORIZATION_SECONDS}.
   */
  readonly maxAuthorizationSeconds?: number;
  /**
   * Longest escrow delivery window the agent accepts: funds stay locked until then if the server never delivers.
   * Default {@link DEFAULT_MAX_DELIVERY_WINDOW_SECONDS}.
   */
  readonly maxDeliveryWindowSeconds?: number;
}

/** Default bound on `maxTimeoutSeconds`: five minutes. */
export const DEFAULT_MAX_AUTHORIZATION_SECONDS = 300;
/** Default bound on an escrow's `deliveryWindowSeconds`: one hour. */
export const DEFAULT_MAX_DELIVERY_WINDOW_SECONDS = 3_600;

export interface ChallengeContext {
  readonly deployment: Deployment;
  /** Payment address registered for the service in the ERC-8004 identity registry. */
  readonly expectedPayTo: Address;
  /** resourceHash computed by the agent from its own request. */
  readonly expectedResourceHash: Hex;
  /** URL the agent actually requested. */
  readonly requestUrl: string;
}

export type PolicyDecision =
  | { readonly ok: true; readonly requirements: PaymentRequirements }
  | { readonly ok: false; readonly reason: string };

function contractMatches(requirements: PaymentRequirements, deployment: Deployment): boolean {
  switch (requirements.scheme) {
    case 'exact': {
      const extra = exactExtraSchema.safeParse(requirements.extra);
      return extra.success && isAddressEqual(extra.data.settlementLog, deployment.settlementLog);
    }
    case 'budget-exec': {
      const extra = budgetExecExtraSchema.safeParse(requirements.extra);
      return extra.success && isAddressEqual(extra.data.budgetExecutor, deployment.budgetExecutor);
    }
    case 'escrow': {
      const extra = escrowExtraSchema.safeParse(requirements.extra);
      return extra.success && isAddressEqual(extra.data.escrow, deployment.paymentEscrow);
    }
    default:
      return false;
  }
}

function resourceHashOf(requirements: PaymentRequirements): string {
  const value = (requirements.extra as { resourceHash?: unknown } | undefined)?.resourceHash;
  return typeof value === 'string' ? value.toLowerCase() : '';
}

/** Delivery window of an escrow offer, 0 for other schemes. Called after `contractMatches` validated `extra`. */
function deliveryWindowOf(requirements: PaymentRequirements): number {
  if (requirements.scheme !== 'escrow') return 0;
  return escrowExtraSchema.parse(requirements.extra).deliveryWindowSeconds;
}

/** Picks the first acceptable requirement in the agent's scheme preference order, or explains the refusal. */
export function selectRequirements(
  challenge: PaymentRequired,
  policy: ClientPolicy,
  context: ChallengeContext,
): PolicyDecision {
  if (challenge.resource.url !== context.requestUrl) return { ok: false, reason: 'resource_url_mismatch' };
  const maxAuthorization = policy.maxAuthorizationSeconds ?? DEFAULT_MAX_AUTHORIZATION_SECONDS;
  const maxDeliveryWindow = policy.maxDeliveryWindowSeconds ?? DEFAULT_MAX_DELIVERY_WINDOW_SECONDS;
  let lastReason = 'no_supported_scheme';
  for (const scheme of policy.schemes) {
    for (const r of challenge.accepts.filter((candidate) => candidate.scheme === scheme)) {
      if (r.network !== LOCAL_NETWORK) lastReason = 'wrong_network';
      else if (!isAddressEqual(r.asset, context.deployment.testUSD)) lastReason = 'unknown_asset';
      else if (!isAddressEqual(r.payTo, context.expectedPayTo)) lastReason = 'payto_not_registered_wallet';
      else if (BigInt(r.amount) > policy.maxPricePerCall) lastReason = 'price_above_client_cap';
      else if (BigInt(r.amount) === 0n) lastReason = 'zero_price';
      else if (r.maxTimeoutSeconds > maxAuthorization) lastReason = 'authorization_window_too_long';
      else if (!contractMatches(r, context.deployment)) lastReason = 'unknown_settlement_contract';
      else if (deliveryWindowOf(r) > maxDeliveryWindow) lastReason = 'delivery_window_too_long';
      else if (resourceHashOf(r) !== context.expectedResourceHash.toLowerCase())
        lastReason = 'resource_hash_mismatch';
      else return { ok: true, requirements: r };
    }
  }
  return { ok: false, reason: lastReason };
}
