// SPDX-License-Identifier: MIT
/**
 * x402 resource server (Hono) selling three deterministic services.
 *
 * Unpaid requests get `402` with a base64 `PAYMENT-REQUIRED` header. Paid requests are verified and settled through
 * the facilitator, then the settlement is confirmed independently from the transaction receipt (the facilitator is
 * not trusted), the receipt is marked as consumed (one payment buys one call), and only then is the work done.
 * The escrow route answers `202` and delivers later by posting the result hash to `PaymentEscrow`.
 *
 * A payment that settled but was never served (a lost facilitator response, a transient RPC error, a crash) is
 * recoverable: the client retries with the same `PAYMENT-SIGNATURE`, the idempotent `/settle` answers from the
 * chain, and the call is served if that settlement is this payment's, is not consumed yet and is recent enough (the
 * claim window). Consumed-receipt, work and job records expire with that window or the escrow deadline, so the
 * in-memory state is bounded by traffic over a window, not by all traffic ever.
 */
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { Hono, type Context } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { parseEventLogs, type Address, type Chain, type Hex, type PublicClient, type Transport } from 'viem';
import type { z } from 'zod';
import { paymentEscrowAbi, settlementLogAbi, validationRegistryAbi } from '../chain/abis.js';
import { TOKEN_DOMAIN, type Deployment } from '../chain/deployment.js';
import { EscrowStatus } from '../chain/ids.js';
import type { RelayerClient } from '../chain/reader.js';
import { confirmSettlementWithRetry } from '../chain/settlement.js';
import type { FacilitatorClient } from '../facilitator/facilitator.js';
import { preparePayment, requirementsMatch } from '../facilitator/verify.js';
import { createLogger, type Logger } from '../logging.js';
import {
  MAX_ACCESS_SIGNATURE_TTL_SECONDS,
  VALIDATOR_EXPIRES_HEADER,
  VALIDATOR_SIGNATURE_HEADER,
  validationAccessMessage,
} from '../validator/access.js';
import {
  PAYMENT_REQUIRED_HEADER,
  PAYMENT_RESPONSE_HEADER,
  PAYMENT_SIGNATURE_HEADER,
  X402CodecError,
  decodePaymentPayload,
  encodePaymentRequired,
  encodeSettlementResponse,
} from '../x402/codec.js';
import { resourceHash } from '../x402/resource.js';
import {
  LOCAL_NETWORK,
  X402_VERSION,
  type FacilitatorRequest,
  type PaymentRequired,
  type PaymentRequirements,
  type Scheme,
  type SettlementResponse,
  type VerifyResponse,
} from '../x402/types.js';
import {
  SERVICE_PATHS,
  canonicalJson,
  keywords,
  keywordsInputSchema,
  merkleReport,
  reportInputSchema,
  resultHash,
  sentiment,
  sentimentInputSchema,
  type ServiceId,
} from './services.js';

export interface RouteConfig {
  readonly service: ServiceId;
  readonly path: string;
  readonly description: string;
  readonly price: bigint;
  readonly schemes: readonly Scheme[];
  readonly inputSchema: z.ZodType;
  readonly execute: (input: never) => unknown;
}

export const ROUTES: readonly RouteConfig[] = [
  {
    service: 'sentiment',
    path: SERVICE_PATHS.sentiment,
    description: 'Lexicon sentiment score of a text',
    price: 10_000n, // 0.01 tUSD
    schemes: ['exact', 'budget-exec'],
    inputSchema: sentimentInputSchema,
    execute: sentiment,
  },
  {
    service: 'keywords',
    path: SERVICE_PATHS.keywords,
    description: 'Top-k term-frequency keywords of a text',
    price: 25_000n, // 0.025 tUSD
    schemes: ['exact', 'budget-exec'],
    inputSchema: keywordsInputSchema,
    execute: keywords,
  },
  {
    service: 'merkle-report',
    path: SERVICE_PATHS['merkle-report'],
    description:
      'Merkle root report over a list of items, delivered asynchronously against an escrowed payment',
    price: 100_000n, // 0.10 tUSD
    schemes: ['escrow'],
    inputSchema: reportInputSchema,
    execute: merkleReport,
  },
];

/**
 * Stored record of a paid call, served to the named validator at `GET /validation/:hash`. `resource` (full URL) and
 * `body` (raw request body) are exactly what the payment's resource hash commits to, so a validator can tie the
 * document to the on-chain receipt and re-execute the service on the input that was actually paid for.
 */
export interface WorkRecord {
  readonly service: ServiceId;
  readonly resource: string;
  readonly body: string;
  readonly receiptId: Hex;
  readonly output: unknown;
}

interface Job {
  readonly escrowId: Hex;
  readonly input: unknown;
  readonly resource: string;
  readonly body: string;
  readonly deadline: bigint;
  /** sha256 of the access token returned in the 202 response (only its holder may read the result). */
  readonly tokenDigest: Buffer;
  /** Chain time after which the job (and its result) is forgotten. */
  readonly expiresAt: bigint;
  status: 'pending' | 'delivered' | 'failed';
  result?: unknown;
  deliveryHash?: Hex;
  deliveryTransaction?: Hex;
  receiptId?: Hex;
}

interface ValidationDoc {
  readonly document: string;
  /** The only address allowed to fetch the document (the validator named in the on-chain request). */
  readonly validator: Address;
  readonly expiresAt: bigint;
}

export interface ResourceServerOptions {
  readonly deployment: Deployment;
  readonly facilitator: FacilitatorClient;
  readonly publicClient: PublicClient<Transport, Chain>;
  /** Wallet of the `payTo` address (the agent wallet): it signs escrow deliveries. */
  readonly treasury: RelayerClient;
  /** Wallet of the ERC-8004 agent owner: it requests validations. */
  readonly operator: RelayerClient;
  readonly logger?: Logger;
  readonly maxTimeoutSeconds?: number;
  readonly deliveryWindowSeconds?: number;
  readonly deliveryDelayMs?: number;
  /** How long after it settled a payment can still be claimed for its call (retries after a lost response). */
  readonly settlementClaimWindowSeconds?: number;
  /** Receipt reads before a settlement is reported unverified (transient RPC errors). */
  readonly confirmationAttempts?: number;
  /** Backoff before the first receipt re-read; doubles on each further one. */
  readonly confirmationDelayMs?: number;
  /** How long work records, validation documents and delivered results are kept. */
  readonly retentionSeconds?: number;
}

/** Verification failures that may only mean this very payment already settled (a retry after a lost response). */
function mayAlreadyBeSettled(reason: string | undefined): boolean {
  return reason === 'nonce_already_used' || (reason?.endsWith('_valid_before') ?? false);
}

function sha256(value: string): Buffer {
  return createHash('sha256').update(value, 'utf8').digest();
}

export class ResourceServer {
  readonly app: Hono;
  private publicUrl = 'http://127.0.0.1';
  private agentId: bigint | null = null;
  private deliveriesPaused = false;
  /** Receipt id -> chain time after which the payment could no longer be claimed anyway. */
  private readonly consumed = new Map<Hex, bigint>();
  private readonly work = new Map<Hex, { readonly record: WorkRecord; readonly expiresAt: bigint }>();
  private readonly validationDocs = new Map<Hex, ValidationDoc>();
  private readonly jobs = new Map<Hex, Job>();
  private readonly pendingDeliveries = new Set<Promise<void>>();
  private readonly logger: Logger;
  private readonly maxTimeoutSeconds: number;
  private readonly deliveryWindowSeconds: number;
  private readonly deliveryDelayMs: number;
  private readonly claimWindowSeconds: bigint;
  private readonly confirmationAttempts: number;
  private readonly confirmationDelayMs: number;
  private readonly retentionSeconds: bigint;

  constructor(private readonly options: ResourceServerOptions) {
    this.logger = options.logger ?? createLogger({ component: 'server' });
    this.maxTimeoutSeconds = options.maxTimeoutSeconds ?? 120;
    this.deliveryWindowSeconds = options.deliveryWindowSeconds ?? 600;
    this.deliveryDelayMs = options.deliveryDelayMs ?? 50;
    this.claimWindowSeconds = BigInt(options.settlementClaimWindowSeconds ?? 600);
    this.confirmationAttempts = options.confirmationAttempts ?? 4;
    this.confirmationDelayMs = options.confirmationDelayMs ?? 100;
    this.retentionSeconds = BigInt(options.retentionSeconds ?? 86_400);
    this.app = this.buildApp();
  }

  get payTo(): Address {
    return this.options.treasury.account.address;
  }

  /** Base URL clients use; part of every canonical resource. Set once the HTTP listener is bound. */
  setPublicUrl(url: string): void {
    this.publicUrl = url.replace(/\/$/, '');
  }

  setAgentId(agentId: bigint): void {
    this.agentId = agentId;
  }

  /** Simulates an outage of the delivery worker (escrowed jobs then time out and get refunded). */
  pauseDeliveries(paused: boolean): void {
    this.deliveriesPaused = paused;
  }

  /** Resolves when every scheduled escrow delivery has finished. */
  async flushDeliveries(): Promise<void> {
    while (this.pendingDeliveries.size > 0) await Promise.all([...this.pendingDeliveries]);
  }

  /** Paid calls served so far (and not yet expired), by receipt id. */
  workRecord(receiptId: Hex): WorkRecord | undefined {
    return this.work.get(receiptId)?.record;
  }

  /** Sizes of the in-memory maps (for tests of the expiry logic). */
  stateSizes(): { consumed: number; work: number; validationDocs: number; jobs: number } {
    return {
      consumed: this.consumed.size,
      work: this.work.size,
      validationDocs: this.validationDocs.size,
      jobs: this.jobs.size,
    };
  }

  /** ERC-8004 registration file for this service. */
  agentCard(): Record<string, unknown> {
    return {
      type: 'https://eips.ethereum.org/EIPS/eip-8004#registration-v1',
      name: 'local-text-analytics',
      description: 'Deterministic text analytics sold per call over x402 (local demo, TestUSD only).',
      services: [
        { name: 'x402', endpoint: this.publicUrl, version: String(X402_VERSION) },
        { name: 'web', endpoint: `${this.publicUrl}/.well-known/agent-card.json` },
      ],
      x402Support: true,
      active: true,
      registrations:
        this.agentId === null
          ? []
          : [
              {
                agentId: Number(this.agentId),
                agentRegistry: `eip155:${this.options.deployment.chainId}:${this.options.deployment.identityRegistry}`,
              },
            ],
      supportedTrust: ['reputation', 'validation'],
      pricing: ROUTES.map((r) => ({
        path: r.path,
        amount: r.price.toString(),
        asset: this.options.deployment.testUSD,
        schemes: r.schemes,
      })),
    };
  }

  /**
   * Asks `validator` (ERC-8004 validation registry) to re-execute the call paid by `receiptId`. The request hash
   * commits to the canonical work document, which only that validator can fetch from `GET /validation/:hash`.
   */
  async requestValidation(receiptId: Hex, validator: Address): Promise<Hex> {
    const entry = this.work.get(receiptId);
    if (entry === undefined) throw new Error(`no work recorded for receipt ${receiptId}`);
    if (this.agentId === null) throw new Error('agent id not set');
    const document = canonicalJson(entry.record);
    const requestHash = resultHash(entry.record);
    const now = await this.chainNow();
    this.validationDocs.set(requestHash, { document, validator, expiresAt: now + this.retentionSeconds });
    const hash = await this.options.operator.writeContract({
      address: this.options.deployment.validationRegistry,
      abi: validationRegistryAbi,
      functionName: 'validationRequest',
      args: [validator, this.agentId, `${this.publicUrl}/validation/${requestHash}`, requestHash],
    });
    await this.options.publicClient.waitForTransactionReceipt({ hash });
    return requestHash;
  }

  /** Test hook: rewrites a stored call record (to show that validators catch a dishonest server). */
  tamperWorkRecord(receiptId: Hex, patch: Partial<WorkRecord>): void {
    const entry = this.work.get(receiptId);
    if (entry !== undefined) this.work.set(receiptId, { ...entry, record: { ...entry.record, ...patch } });
  }

  private async chainNow(): Promise<bigint> {
    return (await this.options.publicClient.getBlock({ blockTag: 'latest' })).timestamp;
  }

  /** Forgets records whose expiry (in chain time) has passed. */
  private prune(now: bigint): void {
    for (const [id, expiresAt] of this.consumed) if (expiresAt < now) this.consumed.delete(id);
    for (const [id, entry] of this.work) if (entry.expiresAt < now) this.work.delete(id);
    for (const [hash, doc] of this.validationDocs) if (doc.expiresAt < now) this.validationDocs.delete(hash);
    for (const [id, job] of this.jobs) if (job.expiresAt < now) this.jobs.delete(id);
  }

  private requirements(scheme: Scheme, route: RouteConfig, rHash: Hex): PaymentRequirements {
    const { deployment } = this.options;
    const base = {
      scheme,
      network: LOCAL_NETWORK,
      amount: route.price.toString(),
      asset: deployment.testUSD,
      payTo: this.payTo,
      maxTimeoutSeconds: this.maxTimeoutSeconds,
    };
    switch (scheme) {
      case 'exact':
        return {
          ...base,
          extra: {
            assetTransferMethod: 'eip3009',
            name: TOKEN_DOMAIN.name,
            version: TOKEN_DOMAIN.version,
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
            name: TOKEN_DOMAIN.name,
            version: TOKEN_DOMAIN.version,
            escrow: deployment.paymentEscrow,
            resourceHash: rHash,
            deliveryWindowSeconds: this.deliveryWindowSeconds,
          },
        };
    }
  }

  private paymentRequired(c: Context, required: PaymentRequired): Response {
    c.header(PAYMENT_REQUIRED_HEADER, encodePaymentRequired(required));
    return c.json({ error: required.error ?? 'payment_required' }, 402);
  }

  /** Verifies, and settles unless verification proves the payment unusable. `null` means the facilitator failed. */
  private async verifyAndSettle(
    request: FacilitatorRequest,
  ): Promise<{ verification: VerifyResponse; settlement?: SettlementResponse } | null> {
    try {
      const verification = await this.options.facilitator.verify(request);
      // A consumed nonce (or a passed validity window) may just mean this payment already settled and its response
      // was lost: the idempotent /settle then answers from the chain, and the checks after it decide.
      if (!verification.isValid && !mayAlreadyBeSettled(verification.invalidReason)) return { verification };
      return { verification, settlement: await this.options.facilitator.settle(request) };
    } catch (error) {
      this.logger.warn('facilitator.unavailable', { reason: String(error) });
      return null;
    }
  }

  private async handlePaid(c: Context, route: RouteConfig): Promise<Response> {
    const bodyText = await c.req.text();
    let json: unknown;
    try {
      json = JSON.parse(bodyText);
    } catch {
      return c.json({ error: 'invalid_json' }, 400);
    }
    const input = route.inputSchema.safeParse(json);
    // Invalid input is rejected before any payment is requested, so nobody pays for a call that cannot succeed.
    if (!input.success) return c.json({ error: 'invalid_input' }, 400);

    const query = new URL(c.req.url).search;
    const url = `${this.publicUrl}${route.path}${query}`;
    const rHash = resourceHash({ method: c.req.method, url, body: bodyText });
    const accepts = route.schemes.map((s) => this.requirements(s, route, rHash));
    const challenge: PaymentRequired = {
      x402Version: X402_VERSION,
      resource: { url, description: route.description, mimeType: 'application/json' },
      accepts,
    };

    const header = c.req.header(PAYMENT_SIGNATURE_HEADER);
    if (header === undefined) {
      return this.paymentRequired(c, { ...challenge, error: 'PAYMENT-SIGNATURE header is required' });
    }
    let payload;
    try {
      payload = decodePaymentPayload(header);
    } catch (error) {
      const code = error instanceof X402CodecError ? error.code : 'unknown';
      return c.json({ error: `invalid_payment_header:${code}` }, 400);
    }
    const matching = accepts.find((r) => requirementsMatch(payload.accepted, r));
    if (matching === undefined)
      return this.paymentRequired(c, { ...challenge, error: 'invalid_payment_requirements' });

    const request: FacilitatorRequest = {
      x402Version: X402_VERSION,
      paymentPayload: payload,
      paymentRequirements: matching,
    };
    // The server derives the receipt (or escrow) id and payer from the signed payload itself, so a facilitator
    // cannot pass off somebody else's settlement as this payment.
    const prepared = preparePayment(request, this.options.deployment);
    if (!prepared.isValid) return this.paymentRequired(c, { ...challenge, error: prepared.invalidReason });
    const expected = prepared.payment.expected;

    const outcome = await this.verifyAndSettle(request);
    if (outcome === null) return this.paymentRequired(c, { ...challenge, error: 'facilitator_unavailable' });
    const { verification, settlement } = outcome;
    if (settlement === undefined) {
      return this.paymentRequired(c, {
        ...challenge,
        error: verification.invalidReason ?? 'invalid_payment',
      });
    }
    if (!settlement.success) {
      return this.paymentRequired(c, { ...challenge, error: settlement.errorReason ?? 'settlement_failed' });
    }

    let confirmed;
    try {
      confirmed = await confirmSettlementWithRetry(
        this.options.publicClient,
        this.options.deployment,
        settlement.transaction as Hex,
        {
          kind: expected.kind,
          payer: expected.payer,
          payee: this.payTo,
          amount: route.price,
          resourceHash: rHash,
          id: expected.id,
        },
        { attempts: this.confirmationAttempts, delayMs: this.confirmationDelayMs },
      );
    } catch (error) {
      this.logger.warn('settlement.unverified', {
        reason: error instanceof Error ? error.message : 'unknown',
      });
      return this.paymentRequired(c, { ...challenge, error: 'settlement_unverified' });
    }

    const now = await this.chainNow();
    this.prune(now);

    if (matching.scheme === 'escrow') {
      const escrow = await this.options.publicClient.readContract({
        address: this.options.deployment.paymentEscrow,
        abi: paymentEscrowAbi,
        functionName: 'escrowOf',
        args: [confirmed.id],
      });
      // The on-chain status is the consumption marker: an escrow is served while Open, once.
      if (this.jobs.has(confirmed.id) || escrow.status !== EscrowStatus.Open) {
        return this.paymentRequired(c, { ...challenge, error: 'payment_already_used' });
      }
      if (escrow.deadline <= now) {
        return this.paymentRequired(c, { ...challenge, error: 'settlement_expired' });
      }
      const accessToken = randomBytes(32).toString('base64url');
      const job: Job = {
        escrowId: confirmed.id,
        input: input.data,
        resource: url,
        body: bodyText,
        deadline: escrow.deadline,
        tokenDigest: sha256(accessToken),
        expiresAt: escrow.deadline + this.retentionSeconds,
        status: 'pending',
      };
      this.jobs.set(confirmed.id, job);
      c.header(PAYMENT_RESPONSE_HEADER, encodeSettlementResponse(settlement));
      this.scheduleDelivery(job, route);
      this.logger.info('escrow.accepted', { escrowId: confirmed.id, resource: url });
      return c.json(
        {
          escrowId: confirmed.id,
          status: 'pending',
          statusUrl: `${route.path}/${confirmed.id}`,
          accessToken,
        },
        202,
      );
    }

    const receipt = await this.options.publicClient.readContract({
      address: this.options.deployment.settlementLog,
      abi: settlementLogAbi,
      functionName: 'receiptOf',
      args: [confirmed.id],
    });
    const claimableUntil = receipt.settledAt + this.claimWindowSeconds;
    // Checked and marked with no await in between, so two concurrent retries cannot both be served.
    if (this.consumed.has(confirmed.id)) {
      return this.paymentRequired(c, { ...challenge, error: 'payment_already_used' });
    }
    if (now > claimableUntil) return this.paymentRequired(c, { ...challenge, error: 'settlement_expired' });
    this.consumed.set(confirmed.id, claimableUntil);
    c.header(PAYMENT_RESPONSE_HEADER, encodeSettlementResponse(settlement));

    const output = route.execute(input.data as never);
    this.work.set(confirmed.id, {
      record: { service: route.service, resource: url, body: bodyText, receiptId: confirmed.id, output },
      expiresAt: now + this.retentionSeconds,
    });
    this.logger.info('call.served', { service: route.service, receiptId: confirmed.id, resource: url });
    return c.json(output as Record<string, unknown>, 200);
  }

  private scheduleDelivery(job: Job, route: RouteConfig): void {
    if (this.deliveriesPaused) return;
    const task = (async () => {
      await new Promise((resolve) => setTimeout(resolve, this.deliveryDelayMs));
      if (this.deliveriesPaused) return;
      try {
        const result = route.execute(job.input as never);
        const deliveryHash = resultHash(result);
        const hash = await this.options.treasury.writeContract({
          address: this.options.deployment.paymentEscrow,
          abi: paymentEscrowAbi,
          functionName: 'deliver',
          args: [job.escrowId, deliveryHash],
        });
        const receipt = await this.options.publicClient.waitForTransactionReceipt({ hash });
        const released = parseEventLogs({
          abi: paymentEscrowAbi,
          eventName: 'EscrowReleased',
          logs: receipt.logs,
        });
        const receiptId = released[0]?.args.receiptId;
        if (receipt.status !== 'success' || receiptId === undefined) throw new Error('delivery reverted');
        Object.assign(job, {
          status: 'delivered',
          result,
          deliveryHash,
          deliveryTransaction: hash,
          receiptId,
        });
        this.work.set(receiptId, {
          record: {
            service: route.service,
            resource: job.resource,
            body: job.body,
            receiptId,
            output: result,
          },
          expiresAt: job.expiresAt,
        });
        this.logger.info('escrow.delivered', { escrowId: job.escrowId, transaction: hash });
      } catch (error) {
        job.status = 'failed';
        this.logger.error('escrow.delivery_failed', { escrowId: job.escrowId, reason: String(error) });
      }
    })();
    this.pendingDeliveries.add(task);
    void task.finally(() => this.pendingDeliveries.delete(task));
  }

  /** True if `authorization` is `Bearer <token>` for the token issued with `job`. */
  private static holdsToken(job: Job, authorization: string | undefined): boolean {
    const token = /^Bearer (\S+)$/.exec(authorization ?? '')?.[1];
    return token !== undefined && timingSafeEqual(sha256(token), job.tokenDigest);
  }

  /** True if the request carries a fresh signature of `doc.validator` over the document's request hash. */
  private async isNamedValidator(c: Context, requestHash: Hex, doc: ValidationDoc): Promise<boolean> {
    const signature = c.req.header(VALIDATOR_SIGNATURE_HEADER);
    const expires = Number(c.req.header(VALIDATOR_EXPIRES_HEADER));
    const nowSeconds = Math.floor(Date.now() / 1000);
    if (
      signature === undefined ||
      !/^0x[0-9a-fA-F]+$/.test(signature) ||
      !Number.isSafeInteger(expires) ||
      expires < nowSeconds ||
      expires > nowSeconds + MAX_ACCESS_SIGNATURE_TTL_SECONDS
    ) {
      return false;
    }
    try {
      return await this.options.publicClient.verifyMessage({
        address: doc.validator,
        message: validationAccessMessage(requestHash, expires),
        signature: signature as Hex,
      });
    } catch {
      return false;
    }
  }

  private buildApp(): Hono {
    const app = new Hono();
    app.use('*', bodyLimit({ maxSize: 64 * 1024 }));
    app.get('/healthz', (c) => c.json({ ok: true }));
    app.get('/.well-known/agent-card.json', (c) => c.json(this.agentCard()));

    for (const route of ROUTES) {
      app.post(route.path, (c) => this.handlePaid(c, route));
    }

    // Escrow ids are public (EscrowOpened is an indexed event), so a result is only served to the holder of the
    // access token returned with the 202.
    app.get('/api/v1/reports/:escrowId', (c) => {
      const job = this.jobs.get(c.req.param('escrowId').toLowerCase() as Hex);
      if (job === undefined) return c.json({ error: 'unknown_job' }, 404);
      if (!ResourceServer.holdsToken(job, c.req.header('authorization'))) {
        return c.json({ error: 'unauthorized' }, 401);
      }
      if (job.status === 'delivered') {
        return c.json({
          status: 'delivered',
          result: job.result,
          deliveryHash: job.deliveryHash,
          deliveryTransaction: job.deliveryTransaction,
          receiptId: job.receiptId,
        });
      }
      return c.json(
        { status: job.status, deadline: job.deadline.toString() },
        job.status === 'failed' ? 500 : 202,
      );
    });

    // Work documents hold the raw paid request (possibly personal data), so only the named validator may read one.
    app.get('/validation/:requestHash', async (c) => {
      const requestHash = c.req.param('requestHash').toLowerCase() as Hex;
      const doc = this.validationDocs.get(requestHash);
      if (doc === undefined) return c.json({ error: 'unknown_request' }, 404);
      if (!(await this.isNamedValidator(c, requestHash, doc))) return c.json({ error: 'unauthorized' }, 401);
      return c.body(doc.document, 200, { 'content-type': 'application/json' });
    });
    return app;
  }
}
