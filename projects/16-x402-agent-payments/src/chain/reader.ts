// SPDX-License-Identifier: MIT
/**
 * Read-side view of the chain used by the facilitator's verifier. Kept behind an interface so the verification
 * rules can be unit-tested against an in-memory fake, while production (and the e2e suite) uses viem against anvil.
 */
import {
  BaseError,
  ContractFunctionRevertedError,
  isAddressEqual,
  recoverAddress,
  size,
  type Account,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type Transport,
  type WalletClient,
} from 'viem';
import { budgetExecutorAbi, testUsdAbi } from './abis.js';
import { budgetExecutorCallAbi, paymentEscrowCallAbi, settlementLogCallAbi } from './callAbis.js';
import type { Deployment } from './deployment.js';
import type { PaymentIntent } from './typedData.js';

const ERC1271_MAGIC = '0x1626ba7e';
const erc1271Abi = [
  {
    type: 'function',
    name: 'isValidSignature',
    stateMutability: 'view',
    inputs: [
      { name: 'hash', type: 'bytes32' },
      { name: 'signature', type: 'bytes' },
    ],
    outputs: [{ name: '', type: 'bytes4' }],
  },
] as const;

/** Arguments of `SettlementLog.settleExact`. */
export interface ExactSettlementArgs {
  readonly auth: {
    readonly from: Address;
    readonly to: Address;
    readonly value: bigint;
    readonly validAfter: bigint;
    readonly validBefore: bigint;
    readonly nonce: Hex;
  };
  readonly resourceHash: Hex;
  readonly resourceSalt: Hex;
  readonly signature: Hex;
}

/** Arguments of `PaymentEscrow.open`. */
export interface EscrowOpenArgs {
  readonly request: {
    readonly from: Address;
    readonly value: bigint;
    readonly validAfter: bigint;
    readonly validBefore: bigint;
    readonly nonce: Hex;
    readonly payee: Address;
    readonly resourceHash: Hex;
    readonly deliveryDeadline: bigint;
    readonly salt: Hex;
  };
  readonly signature: Hex;
}

/** One on-chain call that settles a verified payment. */
export type SettlementCall =
  | { readonly kind: 'exact'; readonly args: ExactSettlementArgs }
  | { readonly kind: 'budget-exec'; readonly intent: PaymentIntent; readonly signature: Hex }
  | { readonly kind: 'escrow'; readonly args: EscrowOpenArgs };

export type SimulationResult = { readonly ok: true } | { readonly ok: false; readonly reason: string };

export interface BudgetPolicy {
  readonly sessionKey: Address;
  readonly validUntil: bigint;
  readonly perCallCap: bigint;
  readonly periodBudget: bigint;
}

export interface ChainReader {
  /** Timestamp of the latest block (the chain's notion of "now"). */
  now(): Promise<bigint>;
  /** ECDSA recovery for 65-byte signatures, ERC-1271 `isValidSignature` for contract signers. */
  isValidSignature(signer: Address, digest: Hex, signature: Hex): Promise<boolean>;
  tokenBalance(owner: Address): Promise<bigint>;
  authorizationUsed(authorizer: Address, nonce: Hex): Promise<boolean>;
  budgetPolicy(account: Address): Promise<BudgetPolicy>;
  remainingBudget(account: Address): Promise<bigint>;
  isPayeeAllowed(account: Address, payee: Address): Promise<boolean>;
  intentNonceUsed(account: Address, nonce: Hex): Promise<boolean>;
  /** eth_call dry-run of the settlement transaction. */
  simulate(call: SettlementCall): Promise<SimulationResult>;
}

/** Extracts the custom error name (or a short message) from a viem contract error. */
export function revertReason(error: unknown): string {
  if (error instanceof BaseError) {
    const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) {
      return reverted.data?.errorName ?? reverted.reason ?? 'reverted';
    }
    return error.shortMessage;
  }
  return error instanceof Error ? error.message : 'unknown error';
}

export function createChainReader(
  publicClient: PublicClient<Transport, Chain>,
  deployment: Deployment,
  simulationSender: Address,
): ChainReader {
  return {
    async now() {
      return (await publicClient.getBlock({ blockTag: 'latest' })).timestamp;
    },

    async isValidSignature(signer, digest, signature) {
      if (size(signature) === 65) {
        try {
          if (isAddressEqual(await recoverAddress({ hash: digest, signature }), signer)) return true;
        } catch {
          // Malformed ECDSA signature: fall through to ERC-1271.
        }
      }
      const code = await publicClient.getCode({ address: signer });
      if (code === undefined || code === '0x') return false;
      try {
        const magic = await publicClient.readContract({
          address: signer,
          abi: erc1271Abi,
          functionName: 'isValidSignature',
          args: [digest, signature],
        });
        return magic === ERC1271_MAGIC;
      } catch {
        return false;
      }
    },

    tokenBalance(owner) {
      return publicClient.readContract({
        address: deployment.testUSD,
        abi: testUsdAbi,
        functionName: 'balanceOf',
        args: [owner],
      });
    },

    authorizationUsed(authorizer, nonce) {
      return publicClient.readContract({
        address: deployment.testUSD,
        abi: testUsdAbi,
        functionName: 'authorizationState',
        args: [authorizer, nonce],
      });
    },

    async budgetPolicy(account) {
      const policy = await publicClient.readContract({
        address: deployment.budgetExecutor,
        abi: budgetExecutorAbi,
        functionName: 'policyOf',
        args: [account],
      });
      return {
        sessionKey: policy.sessionKey,
        validUntil: BigInt(policy.validUntil),
        perCallCap: policy.perCallCap,
        periodBudget: policy.periodBudget,
      };
    },

    remainingBudget(account) {
      return publicClient.readContract({
        address: deployment.budgetExecutor,
        abi: budgetExecutorAbi,
        functionName: 'remainingBudget',
        args: [account],
      });
    },

    isPayeeAllowed(account, payee) {
      return publicClient.readContract({
        address: deployment.budgetExecutor,
        abi: budgetExecutorAbi,
        functionName: 'isPayeeAllowed',
        args: [account, payee],
      });
    },

    intentNonceUsed(account, nonce) {
      return publicClient.readContract({
        address: deployment.budgetExecutor,
        abi: budgetExecutorAbi,
        functionName: 'isNonceUsed',
        args: [account, nonce],
      });
    },

    async simulate(call) {
      try {
        switch (call.kind) {
          case 'exact':
            await publicClient.simulateContract({
              account: simulationSender,
              address: deployment.settlementLog,
              abi: settlementLogCallAbi,
              functionName: 'settleExact',
              args: [call.args.auth, call.args.resourceHash, call.args.resourceSalt, call.args.signature],
            });
            break;
          case 'budget-exec':
            await publicClient.simulateContract({
              account: simulationSender,
              address: deployment.budgetExecutor,
              abi: budgetExecutorCallAbi,
              functionName: 'pay',
              args: [call.intent, call.signature],
            });
            break;
          case 'escrow':
            await publicClient.simulateContract({
              account: simulationSender,
              address: deployment.paymentEscrow,
              abi: paymentEscrowCallAbi,
              functionName: 'open',
              args: [call.args.request, call.args.signature],
            });
            break;
        }
        return { ok: true };
      } catch (error) {
        return { ok: false, reason: revertReason(error) };
      }
    },
  };
}

/** Wallet client with a local account (the facilitator's relayer key). */
export type RelayerClient = WalletClient<Transport, Chain, Account>;
