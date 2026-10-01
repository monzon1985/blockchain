// SPDX-License-Identifier: MIT
/**
 * Deterministic, scripted x402 agent (no LLM). It discovers services in the ERC-8004 identity registry, pays per
 * call, retries with `PAYMENT-SIGNATURE`, checks the `PAYMENT-RESPONSE` against the chain, logs PII-filtered
 * receipts, and stops cleanly when its on-chain budget is exhausted.
 */
import {
  zeroHash,
  type Address,
  type Chain,
  type Hex,
  type LocalAccount,
  type PublicClient,
  type Transport,
} from 'viem';
import { hashTypedData as erc7739HashTypedData, wrapTypedDataSignature } from 'viem/experimental/erc7739';
import { budgetExecutorAbi, paymentEscrowAbi, reputationRegistryAbi } from '../chain/abis.js';
import { REPUTATION_DOMAIN, type Deployment } from '../chain/deployment.js';
import type { RelayerClient } from '../chain/reader.js';
import { confirmSettlement, type SettlementOutcome } from '../chain/settlement.js';
import { createLogger, type Logger } from '../logging.js';
import { selectRequirements, type ClientPolicy } from '../policy/clientPolicy.js';
import { onchainString, redactUrl, sanitizePaymentMetadata, type PaymentMetadata } from '../policy/pii.js';
import {
  PAYMENT_REQUIRED_HEADER,
  PAYMENT_RESPONSE_HEADER,
  PAYMENT_SIGNATURE_HEADER,
  decodePaymentRequired,
  decodeSettlementResponse,
  encodePaymentPayload,
} from '../x402/codec.js';
import { resourceHash } from '../x402/resource.js';
import type { PaymentPayload, PaymentRequirements, ResourceInfo, Scheme } from '../x402/types.js';
import type { DiscoveredService } from './discovery.js';
import { buildBudgetPayment, buildEscrowPayment, buildExactPayment } from './payments.js';

/** The agent's paying identity. */
export type Payer =
  | { readonly kind: 'eoa'; readonly account: LocalAccount }
  | {
      readonly kind: 'smart-account';
      /** The ERC-7579 AgentAccount that holds the funds. */
      readonly account: Address;
      /** Session key registered in the BudgetExecutor; the only key the agent process holds. */
      readonly sessionKey: LocalAccount;
      /** Optional EOA used to pay escrowed calls (the escrow scheme is EOA-only in this project). */
      readonly escrowPayer?: LocalAccount;
    };

/** Stops the agent loop: the on-chain budget (or rate limit) no longer covers the next call. */
export class BudgetExhaustedError extends Error {
  constructor(
    readonly remaining: bigint,
    readonly price: bigint,
  ) {
    super(`budget exhausted: ${remaining} remaining, ${price} needed`);
    this.name = 'BudgetExhaustedError';
  }
}

/** The server refused the payment, or the agent refused the challenge. */
export class PaymentRefusedError extends Error {
  constructor(readonly reason: string) {
    super(`payment refused: ${reason}`);
    this.name = 'PaymentRefusedError';
  }
}

export interface ReceiptLogEntry {
  readonly at: string;
  readonly scheme: string;
  readonly amount: string;
  readonly payer: Address;
  readonly payTo: Address;
  readonly transaction: Hex;
  readonly id: Hex;
  readonly metadata: PaymentMetadata;
}

export interface PaidResponse<T = unknown> {
  readonly status: number;
  readonly body: T;
  readonly scheme: Scheme;
  readonly amount: bigint;
  readonly settlement: SettlementOutcome;
}

export interface AgentOptions {
  readonly deployment: Deployment;
  readonly publicClient: PublicClient<Transport, Chain>;
  readonly payer: Payer;
  readonly policy: ClientPolicy;
  readonly logger?: Logger;
  readonly onReceipt?: (entry: ReceiptLogEntry) => void;
  readonly fetch?: typeof fetch;
  /**
   * Extra attempts with the same `PAYMENT-SIGNATURE` when the paid request fails transiently (network error, 5xx,
   * or a 402 saying the facilitator or the settlement check was unavailable). A payment that already settled is
   * then served instead of being lost. Default 2.
   */
  readonly paidRetries?: number;
  /** Delay before the first retry; doubles on each further one. Default 200 ms. */
  readonly paidRetryDelayMs?: number;
}

/** 402 reasons that do not mean the payment was refused, only that the server could not finish checking it. */
const TRANSIENT_PAYMENT_ERRORS = new Set(['facilitator_unavailable', 'settlement_unverified']);

/** True for a response worth resending with the same payment. */
function isTransient(response: Response): boolean {
  if (response.status >= 500) return true;
  if (response.status !== 402) return false;
  try {
    const reason = decodePaymentRequired(response.headers.get(PAYMENT_REQUIRED_HEADER)).error;
    return reason !== undefined && TRANSIENT_PAYMENT_ERRORS.has(reason);
  } catch {
    return false;
  }
}

/**
 * Receipt metadata for the log. Never throws: the payment has already settled when this runs, so an oversized or
 * odd URL must not make the paid call fail; it falls back to the redacted URL alone.
 */
export function receiptMetadata(url: string, description: string | undefined): PaymentMetadata {
  try {
    return sanitizePaymentMetadata(
      description === undefined ? { resource: url } : { resource: url, description },
    );
  } catch {
    return { resource: redactUrl(url).slice(0, 2048) };
  }
}

export class Agent {
  private readonly logger: Logger;
  private readonly http: typeof fetch;
  private readonly paidRetries: number;
  private readonly paidRetryDelayMs: number;
  readonly receipts: ReceiptLogEntry[] = [];

  constructor(private readonly options: AgentOptions) {
    this.logger = options.logger ?? createLogger({ component: 'agent' });
    this.http = options.fetch ?? fetch;
    this.paidRetries = options.paidRetries ?? 2;
    this.paidRetryDelayMs = options.paidRetryDelayMs ?? 200;
  }

  /** Address whose balance pays for calls (smart account or EOA). */
  get payerAddress(): Address {
    return this.options.payer.kind === 'eoa'
      ? this.options.payer.account.address
      : this.options.payer.account;
  }

  /** Remaining rolling-window budget of the smart account (`undefined` for EOA payers). */
  async remainingBudget(): Promise<bigint | undefined> {
    if (this.options.payer.kind !== 'smart-account') return undefined;
    return this.options.publicClient.readContract({
      address: this.options.deployment.budgetExecutor,
      abi: budgetExecutorAbi,
      functionName: 'remainingBudget',
      args: [this.options.payer.account],
    });
  }

  /**
   * Calls a priced endpoint: request, read the 402 challenge, pay, retry, confirm the settlement on-chain.
   * Throws {@link BudgetExhaustedError} when the budget cannot cover the price, {@link PaymentRefusedError} otherwise.
   */
  async call<T = unknown>(
    service: DiscoveredService,
    path: string,
    input: unknown,
  ): Promise<PaidResponse<T>> {
    const url = `${service.endpoint.replace(/\/$/, '')}${path}`;
    const body = JSON.stringify(input);
    const first = await this.post(url, body);
    if (first.status !== 402) {
      throw new PaymentRefusedError(`expected 402 challenge, got ${first.status}`);
    }
    const challenge = decodePaymentRequired(first.headers.get(PAYMENT_REQUIRED_HEADER));
    const rHash = resourceHash({ method: 'POST', url, body });
    const decision = selectRequirements(challenge, this.options.policy, {
      deployment: this.options.deployment,
      expectedPayTo: service.wallet,
      expectedResourceHash: rHash,
      requestUrl: url,
    });
    if (!decision.ok) throw new PaymentRefusedError(decision.reason);
    const requirements = decision.requirements;
    const price = BigInt(requirements.amount);

    if (requirements.scheme === 'budget-exec') {
      const remaining = (await this.remainingBudget()) ?? 0n;
      if (remaining < price) {
        this.logger.info('budget.exhausted', { remaining, price });
        throw new BudgetExhaustedError(remaining, price);
      }
    }

    const payload = await this.buildPayment(requirements, challenge.resource);
    const second = await this.postPaid(url, body, encodePaymentPayload(payload));
    if (second.status === 402) {
      const reason =
        decodePaymentRequired(second.headers.get(PAYMENT_REQUIRED_HEADER)).error ?? 'payment_rejected';
      if (reason === 'budget_exhausted') throw new BudgetExhaustedError(0n, price);
      throw new PaymentRefusedError(reason);
    }
    if (second.status !== 200 && second.status !== 202) {
      throw new PaymentRefusedError(`unexpected status ${second.status}`);
    }

    // Never take the server's (or facilitator's) word for it: read the settlement from the chain.
    const settlementHeader = decodeSettlementResponse(second.headers.get(PAYMENT_RESPONSE_HEADER));
    const escrowed = requirements.scheme === 'escrow';
    const settlement = await confirmSettlement(
      this.options.publicClient,
      this.options.deployment,
      settlementHeader.transaction as Hex,
      {
        kind: escrowed ? 'escrow' : 'receipt',
        payer: this.payerFor(requirements.scheme as Scheme),
        payee: requirements.payTo,
        amount: price,
        resourceHash: rHash,
      },
    );
    this.logReceipt(requirements, settlement, url, challenge.resource.description);
    return {
      status: second.status,
      body: (await second.json()) as T,
      scheme: requirements.scheme as Scheme,
      amount: price,
      settlement,
    };
  }

  /**
   * Scripted loop: calls `path` with each input in turn until the budget is exhausted or the inputs run out.
   * A budget stop is a normal, clean termination.
   */
  async runUntilBudgetExhausted(
    service: DiscoveredService,
    path: string,
    inputs: readonly unknown[],
  ): Promise<{ calls: PaidResponse[]; stoppedBy: 'budget_exhausted' | 'inputs_done' }> {
    const calls: PaidResponse[] = [];
    for (const input of inputs) {
      try {
        calls.push(await this.call(service, path, input));
      } catch (error) {
        if (error instanceof BudgetExhaustedError) return { calls, stoppedBy: 'budget_exhausted' };
        throw error;
      }
    }
    return { calls, stoppedBy: 'inputs_done' };
  }

  /** Reclaims an escrowed payment after its deadline (the service never delivered). */
  async refundEscrow(escrowId: Hex, relayer: RelayerClient): Promise<Hex> {
    const hash = await relayer.writeContract({
      address: this.options.deployment.paymentEscrow,
      abi: paymentEscrowAbi,
      functionName: 'refund',
      args: [escrowId],
    });
    await this.options.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  /**
   * Leaves receipt-backed feedback through `giveFeedbackBySig`. For a smart-account payer the account owner signs
   * an ERC-7739 nested typed-data signature, verified on-chain via ERC-1271; any relayer can submit it.
   */
  async leaveFeedback(params: {
    readonly agentId: bigint;
    readonly receiptId: Hex;
    readonly score: number;
    readonly tag1: string;
    readonly endpoint: string;
    readonly signer: LocalAccount;
    readonly relayer: RelayerClient;
  }): Promise<Hex> {
    const { deployment, publicClient } = this.options;
    const client = this.payerAddress;
    const nonce = await publicClient.readContract({
      address: deployment.reputationRegistry,
      abi: reputationRegistryAbi,
      functionName: 'nonces',
      args: [client],
    });
    const latest = await publicClient.getBlock();
    const deadline = latest.timestamp + 600n;
    const feedback = {
      agentId: params.agentId,
      value: BigInt(params.score),
      valueDecimals: 0,
      tag1: onchainString(params.tag1, 64),
      tag2: '',
      endpoint: onchainString(params.endpoint, 256),
      feedbackURI: '',
      feedbackHash: zeroHash,
      receiptId: params.receiptId,
    };
    const typed = {
      domain: {
        ...REPUTATION_DOMAIN,
        chainId: deployment.chainId,
        verifyingContract: deployment.reputationRegistry,
      },
      types: FEEDBACK_TYPES,
      primaryType: 'Feedback',
      message: { ...feedback, client, nonce, deadline },
    } as const;

    let signature: Hex;
    if (this.options.payer.kind === 'smart-account') {
      const hash = erc7739HashTypedData({
        ...typed,
        verifierDomain: {
          name: 'AgentAccount',
          version: '1',
          chainId: deployment.chainId,
          verifyingContract: client,
          salt: zeroHash,
        },
      });
      if (params.signer.sign === undefined) throw new Error('signer cannot sign raw hashes');
      signature = wrapTypedDataSignature({ ...typed, signature: await params.signer.sign({ hash }) });
    } else {
      signature = await params.signer.signTypedData(typed);
    }

    const hash = await params.relayer.writeContract({
      address: deployment.reputationRegistry,
      abi: reputationRegistryAbi,
      functionName: 'giveFeedbackBySig',
      args: [{ ...feedback, value: feedback.value }, client, deadline, signature],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error('feedback transaction reverted');
    return hash;
  }

  private payerFor(scheme: Scheme): Address {
    const payer = this.options.payer;
    if (payer.kind === 'eoa') return payer.account.address;
    if (scheme === 'escrow') {
      if (payer.escrowPayer === undefined) throw new PaymentRefusedError('no_escrow_payer');
      return payer.escrowPayer.address;
    }
    return payer.account;
  }

  private async buildPayment(
    requirements: PaymentRequirements,
    resource: ResourceInfo,
  ): Promise<PaymentPayload> {
    const now = (await this.options.publicClient.getBlock()).timestamp;
    const context = { deployment: this.options.deployment, requirements, resource, now };
    const payer = this.options.payer;
    switch (requirements.scheme) {
      case 'exact':
        if (payer.kind !== 'eoa') throw new PaymentRefusedError('exact_requires_eoa');
        return buildExactPayment(context, payer.account);
      case 'budget-exec':
        if (payer.kind !== 'smart-account')
          throw new PaymentRefusedError('budget_exec_requires_smart_account');
        return buildBudgetPayment(context, payer.account, payer.sessionKey);
      case 'escrow': {
        const eoa = payer.kind === 'eoa' ? payer.account : payer.escrowPayer;
        if (eoa === undefined) throw new PaymentRefusedError('no_escrow_payer');
        return buildEscrowPayment(context, eoa);
      }
      default:
        throw new PaymentRefusedError('unsupported_scheme');
    }
  }

  private logReceipt(
    requirements: PaymentRequirements,
    settlement: SettlementOutcome,
    url: string,
    description: string | undefined,
  ): void {
    const entry: ReceiptLogEntry = {
      at: new Date().toISOString(),
      scheme: requirements.scheme,
      amount: requirements.amount,
      payer: settlement.payer,
      payTo: requirements.payTo,
      transaction: settlement.transaction,
      id: settlement.id,
      metadata: receiptMetadata(url, description),
    };
    this.receipts.push(entry);
    this.options.onReceipt?.(entry);
    this.logger.info('receipt', { ...entry });
  }

  private post(url: string, body: string, paymentHeader?: string): Promise<Response> {
    const headers: Record<string, string> = { 'content-type': 'application/json' };
    if (paymentHeader !== undefined) headers[PAYMENT_SIGNATURE_HEADER] = paymentHeader;
    return this.http(url, { method: 'POST', headers, body });
  }

  /**
   * Sends the paid request, retrying with the *same* payment header while the failure is transient. Resending the
   * same signature is safe: the server serves one call per settled payment, and settlement is idempotent.
   */
  private async postPaid(url: string, body: string, paymentHeader: string): Promise<Response> {
    for (let attempt = 0; ; attempt++) {
      let response: Response | null = null;
      try {
        response = await this.post(url, body, paymentHeader);
      } catch (error) {
        if (attempt >= this.paidRetries) throw error;
      }
      if (response !== null && (attempt >= this.paidRetries || !isTransient(response))) return response;
      this.logger.warn('payment.retry', { attempt: attempt + 1, status: response?.status ?? 0 });
      await new Promise((resolve) => setTimeout(resolve, this.paidRetryDelayMs * 2 ** attempt));
    }
  }
}

export const FEEDBACK_TYPES = {
  Feedback: [
    { name: 'agentId', type: 'uint256' },
    { name: 'value', type: 'int128' },
    { name: 'valueDecimals', type: 'uint8' },
    { name: 'tag1', type: 'string' },
    { name: 'tag2', type: 'string' },
    { name: 'endpoint', type: 'string' },
    { name: 'feedbackURI', type: 'string' },
    { name: 'feedbackHash', type: 'bytes32' },
    { name: 'receiptId', type: 'bytes32' },
    { name: 'client', type: 'address' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
  ],
} as const;
