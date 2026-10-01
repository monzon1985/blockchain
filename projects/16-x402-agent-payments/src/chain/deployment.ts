// SPDX-License-Identifier: MIT
/** Address book written by `contracts/script/Deploy.s.sol`. */
import { readFileSync } from 'node:fs';
import { z } from 'zod';
import { addressSchema } from '../x402/types.js';

export const deploymentSchema = z.object({
  chainId: z.number().int().positive(),
  deployer: addressSchema,
  testUSD: addressSchema,
  settlementLog: addressSchema,
  budgetExecutor: addressSchema,
  paymentEscrow: addressSchema,
  accountFactory: addressSchema,
  identityRegistry: addressSchema,
  reputationRegistry: addressSchema,
  validationRegistry: addressSchema,
});
export type Deployment = z.infer<typeof deploymentSchema>;

export function loadDeployment(path: string): Deployment {
  return deploymentSchema.parse(JSON.parse(readFileSync(path, 'utf8')));
}

/** EIP-712 domain constants fixed by the contracts' constructors. */
export const TOKEN_DOMAIN = { name: 'TestUSD (local only)', version: '1' } as const;
export const BUDGET_EXECUTOR_DOMAIN = { name: 'BudgetExecutor', version: '1' } as const;
export const REPUTATION_DOMAIN = { name: 'ReputationRegistry', version: '1' } as const;
export const IDENTITY_DOMAIN = { name: 'IdentityRegistry', version: '1' } as const;
