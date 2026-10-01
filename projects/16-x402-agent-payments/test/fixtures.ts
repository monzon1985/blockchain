// SPDX-License-Identifier: MIT
/** Shared fixtures for the unit suite: a fake deployment and an in-memory chain. */
import {
  getAddress,
  isAddressEqual,
  recoverAddress,
  size,
  type Address,
  type Hex,
  type LocalAccount,
} from 'viem';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';
import type { Deployment } from '../src/chain/deployment.js';
import type { BudgetPolicy, ChainReader, SettlementCall, SimulationResult } from '../src/chain/reader.js';
import type { PaymentContext } from '../src/agent/payments.js';
import { resourceHash } from '../src/x402/resource.js';
import { LOCAL_NETWORK, type PaymentRequirements } from '../src/x402/types.js';

const addr = (n: number): Address => getAddress(`0x${n.toString(16).padStart(40, '0')}`);

export const deployment: Deployment = {
  chainId: 31337,
  deployer: addr(1),
  testUSD: addr(0x1001),
  settlementLog: addr(0x1002),
  budgetExecutor: addr(0x1003),
  paymentEscrow: addr(0x1004),
  accountFactory: addr(0x1005),
  identityRegistry: addr(0x1006),
  reputationRegistry: addr(0x1007),
  validationRegistry: addr(0x1008),
};

export const NOW = 1_800_000_000n;
export const PRICE = 10_000n;
export const payTo: Address = addr(0xbeef);
export const smartAccount: Address = addr(0xacc0);
export const REQUEST = {
  method: 'POST',
  url: 'http://127.0.0.1:4021/api/v1/sentiment',
  body: '{"text":"good"}',
};
export const RESOURCE_HASH: Hex = resourceHash(REQUEST);

export function newAccount(): LocalAccount {
  return privateKeyToAccount(generatePrivateKey());
}

export function requirements(
  scheme: 'exact' | 'budget-exec' | 'escrow',
  rHash: Hex = RESOURCE_HASH,
): PaymentRequirements {
  const base = {
    scheme,
    network: LOCAL_NETWORK,
    amount: PRICE.toString(),
    asset: deployment.testUSD,
    payTo,
    maxTimeoutSeconds: 120,
  };
  switch (scheme) {
    case 'exact':
      return {
        ...base,
        extra: {
          assetTransferMethod: 'eip3009',
          name: 'TestUSD (local only)',
          version: '1',
          settlementLog: deployment.settlementLog,
          resourceHash: rHash,
        },
      };
    case 'budget-exec':
      return { ...base, extra: { budgetExecutor: deployment.budgetExecutor, resourceHash: rHash } };
    case 'escrow':
      return {
        ...base,
        extra: {
          assetTransferMethod: 'eip3009-receive',
          name: 'TestUSD (local only)',
          version: '1',
          escrow: deployment.paymentEscrow,
          resourceHash: rHash,
          deliveryWindowSeconds: 600,
        },
      };
  }
}

export function context(req: PaymentRequirements, now: bigint = NOW): PaymentContext {
  return { deployment, requirements: req, resource: { url: REQUEST.url }, now };
}

/** In-memory ChainReader with real ECDSA recovery and scriptable state. */
export class FakeChain implements ChainReader {
  timestamp = NOW;
  balances = new Map<string, bigint>();
  usedAuthorizations = new Set<string>();
  usedIntentNonces = new Set<string>();
  policies = new Map<string, BudgetPolicy>();
  remaining = new Map<string, bigint>();
  allowedPayees = new Set<string>();
  contractSigners = new Map<string, Address>(); // contract address -> EOA whose raw signatures it accepts
  simulation: SimulationResult = { ok: true };
  simulated: SettlementCall[] = [];

  now(): Promise<bigint> {
    return Promise.resolve(this.timestamp);
  }

  async isValidSignature(signer: Address, digest: Hex, signature: Hex): Promise<boolean> {
    const delegate = this.contractSigners.get(signer.toLowerCase());
    const expected = delegate ?? signer;
    if (size(signature) !== 65) return false;
    try {
      return isAddressEqual(await recoverAddress({ hash: digest, signature }), expected);
    } catch {
      return false;
    }
  }

  tokenBalance(owner: Address): Promise<bigint> {
    return Promise.resolve(this.balances.get(owner.toLowerCase()) ?? 0n);
  }

  authorizationUsed(authorizer: Address, nonce: Hex): Promise<boolean> {
    return Promise.resolve(this.usedAuthorizations.has(`${authorizer.toLowerCase()}:${nonce}`));
  }

  budgetPolicy(account: Address): Promise<BudgetPolicy> {
    return Promise.resolve(
      this.policies.get(account.toLowerCase()) ?? {
        sessionKey: '0x0000000000000000000000000000000000000000',
        validUntil: 0n,
        perCallCap: 0n,
        periodBudget: 0n,
      },
    );
  }

  remainingBudget(account: Address): Promise<bigint> {
    return Promise.resolve(this.remaining.get(account.toLowerCase()) ?? 0n);
  }

  isPayeeAllowed(account: Address, payee: Address): Promise<boolean> {
    return Promise.resolve(this.allowedPayees.has(`${account.toLowerCase()}:${payee.toLowerCase()}`));
  }

  intentNonceUsed(account: Address, nonce: Hex): Promise<boolean> {
    return Promise.resolve(this.usedIntentNonces.has(`${account.toLowerCase()}:${nonce}`));
  }

  simulate(call: SettlementCall): Promise<SimulationResult> {
    this.simulated.push(call);
    return Promise.resolve(this.simulation);
  }

  /** Installs a budget policy for `smartAccount` with `session` as session key and `payTo` allowlisted. */
  installPolicy(session: Address, remaining = 1_000_000n): void {
    this.policies.set(smartAccount.toLowerCase(), {
      sessionKey: session,
      validUntil: NOW + 86_400n,
      perCallCap: 50_000n,
      periodBudget: 100_000n,
    });
    this.remaining.set(smartAccount.toLowerCase(), remaining);
    this.allowedPayees.add(`${smartAccount.toLowerCase()}:${payTo.toLowerCase()}`);
    this.balances.set(smartAccount.toLowerCase(), 10_000_000n);
  }
}
