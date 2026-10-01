// SPDX-License-Identifier: MIT
/**
 * x402 v2 wire types (https://github.com/coinbase/x402, specs/x402-specification-v2.md) as zod schemas, plus the
 * three schemes this project implements:
 *
 * - `exact`        standard x402 EVM scheme (EIP-3009 `transferWithAuthorization`), with one extension field:
 *                  `resourceSalt`, which opens the resource commitment embedded in the nonce.
 * - `budget-exec`  extension scheme for ERC-7579 agent accounts: a session-key EIP-712 `PaymentIntent` executed by
 *                  the on-chain BudgetExecutor module.
 * - `escrow`       extension scheme for delayed fulfilment: EIP-3009 `receiveWithAuthorization` into PaymentEscrow,
 *                  released when the server posts a delivery hash, refunded after the deadline.
 */
import { getAddress, type Address, type Hex } from 'viem';
import { z } from 'zod';

export const X402_VERSION = 2 as const;
export const LOCAL_CHAIN_ID = 31337 as const;
export const LOCAL_NETWORK = `eip155:${LOCAL_CHAIN_ID}` as const;

export const SCHEMES = ['exact', 'budget-exec', 'escrow'] as const;
export type Scheme = (typeof SCHEMES)[number];

/** Checksummed EVM address. */
export const addressSchema = z
  .string()
  .regex(/^0x[0-9a-fA-F]{40}$/, 'expected a 20-byte hex address')
  .transform((value): Address => getAddress(value));

/** 32-byte hex value. */
export const bytes32Schema = z
  .string()
  .regex(/^0x[0-9a-fA-F]{64}$/, 'expected 32 bytes of hex')
  .transform((value) => value.toLowerCase() as Hex);

/** Arbitrary-length hex blob (signatures). */
export const hexSchema = z
  .string()
  .regex(/^0x([0-9a-fA-F]{2})*$/, 'expected even-length hex')
  .max(8192)
  .transform((value) => value as Hex);

/** Unsigned 256-bit integer as a decimal string (x402 encodes amounts and timestamps this way). */
export const uintStringSchema = z
  .string()
  .regex(/^(0|[1-9][0-9]{0,77})$/, 'expected a decimal uint256 string')
  .refine((value) => BigInt(value) < 2n ** 256n, 'value exceeds uint256');

export const resourceInfoSchema = z.object({
  url: z.url(),
  description: z.string().max(512).optional(),
  mimeType: z.string().max(128).optional(),
});
export type ResourceInfo = z.infer<typeof resourceInfoSchema>;

export const paymentRequirementsSchema = z.object({
  scheme: z.string().min(1).max(64),
  network: z.string().min(1).max(64),
  amount: uintStringSchema,
  asset: addressSchema,
  payTo: addressSchema,
  maxTimeoutSeconds: z.number().int().positive().max(86_400),
  extra: z.record(z.string(), z.unknown()).optional(),
});
export type PaymentRequirements = z.infer<typeof paymentRequirementsSchema>;

export const paymentRequiredSchema = z.object({
  x402Version: z.literal(X402_VERSION),
  error: z.string().max(256).optional(),
  resource: resourceInfoSchema,
  accepts: z.array(paymentRequirementsSchema).min(1).max(8),
  extensions: z.record(z.string(), z.unknown()).optional(),
});
export type PaymentRequired = z.infer<typeof paymentRequiredSchema>;

export const paymentPayloadSchema = z.object({
  x402Version: z.literal(X402_VERSION),
  resource: resourceInfoSchema.optional(),
  accepted: paymentRequirementsSchema,
  payload: z.record(z.string(), z.unknown()),
  extensions: z.record(z.string(), z.unknown()).optional(),
});
export type PaymentPayload = z.infer<typeof paymentPayloadSchema>;

export const verifyResponseSchema = z.object({
  isValid: z.boolean(),
  invalidReason: z.string().max(256).optional(),
  payer: addressSchema.optional(),
});
export type VerifyResponse = z.infer<typeof verifyResponseSchema>;

/** Receipt identifiers attached by this facilitator to a successful settlement. */
export const settlementExtensionsSchema = z.object({
  receiptId: bytes32Schema.optional(),
  escrowId: bytes32Schema.optional(),
});

export const settlementResponseSchema = z.object({
  success: z.boolean(),
  errorReason: z.string().max(256).optional(),
  payer: addressSchema.optional(),
  transaction: z.string().max(80),
  network: z.string().max(64),
  amount: uintStringSchema.optional(),
  extensions: settlementExtensionsSchema.optional(),
});
export type SettlementResponse = z.infer<typeof settlementResponseSchema>;

export const facilitatorRequestSchema = z.object({
  x402Version: z.literal(X402_VERSION),
  paymentPayload: paymentPayloadSchema,
  paymentRequirements: paymentRequirementsSchema,
});
export type FacilitatorRequest = z.infer<typeof facilitatorRequestSchema>;

export const supportedResponseSchema = z.object({
  kinds: z.array(
    z.object({
      x402Version: z.literal(X402_VERSION),
      scheme: z.string(),
      network: z.string(),
      extra: z.record(z.string(), z.unknown()).optional(),
    }),
  ),
  extensions: z.array(z.string()),
  signers: z.record(z.string(), z.array(z.string())),
});
export type SupportedResponse = z.infer<typeof supportedResponseSchema>;

// ---------------------------------------------------------------------------------------------------------------
// Scheme-specific `extra` and `payload` shapes
// ---------------------------------------------------------------------------------------------------------------

export const exactExtraSchema = z.object({
  assetTransferMethod: z.literal('eip3009'),
  name: z.string(),
  version: z.string(),
  settlementLog: addressSchema,
  resourceHash: bytes32Schema,
});
export type ExactExtra = z.infer<typeof exactExtraSchema>;

export const budgetExecExtraSchema = z.object({
  budgetExecutor: addressSchema,
  resourceHash: bytes32Schema,
});
export type BudgetExecExtra = z.infer<typeof budgetExecExtraSchema>;

export const escrowExtraSchema = z.object({
  assetTransferMethod: z.literal('eip3009-receive'),
  name: z.string(),
  version: z.string(),
  escrow: addressSchema,
  resourceHash: bytes32Schema,
  deliveryWindowSeconds: z
    .number()
    .int()
    .positive()
    .max(30 * 86_400),
});
export type EscrowExtra = z.infer<typeof escrowExtraSchema>;

export const eip3009AuthorizationSchema = z.object({
  from: addressSchema,
  to: addressSchema,
  value: uintStringSchema,
  validAfter: uintStringSchema,
  validBefore: uintStringSchema,
  nonce: bytes32Schema,
});
export type Eip3009Authorization = z.infer<typeof eip3009AuthorizationSchema>;

export const exactPayloadSchema = z.object({
  signature: hexSchema,
  authorization: eip3009AuthorizationSchema,
  resourceSalt: bytes32Schema,
});
export type ExactPayload = z.infer<typeof exactPayloadSchema>;

export const paymentIntentSchema = z.object({
  account: addressSchema,
  payee: addressSchema,
  amount: uintStringSchema,
  resourceHash: bytes32Schema,
  nonce: bytes32Schema,
  validAfter: uintStringSchema,
  validBefore: uintStringSchema,
});
export type PaymentIntentWire = z.infer<typeof paymentIntentSchema>;

export const budgetExecPayloadSchema = z.object({
  signature: hexSchema,
  intent: paymentIntentSchema,
});
export type BudgetExecPayload = z.infer<typeof budgetExecPayloadSchema>;

export const escrowPayloadSchema = z.object({
  signature: hexSchema,
  authorization: eip3009AuthorizationSchema,
  escrow: z.object({
    payee: addressSchema,
    resourceHash: bytes32Schema,
    deliveryDeadline: uintStringSchema,
    salt: bytes32Schema,
  }),
});
export type EscrowPayload = z.infer<typeof escrowPayloadSchema>;
