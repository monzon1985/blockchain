// SPDX-License-Identifier: MIT
/**
 * Self-hosted x402 facilitator: `GET /supported`, `POST /verify`, `POST /settle`.
 *
 * Settlement is idempotent per authorization nonce: concurrent `/settle` calls for the same payment share one
 * in-flight promise, and a payment that is already on-chain (a repeated call, or one after a facilitator restart) is
 * answered from the chain instead of being re-submitted, provided the on-chain record carries the same terms.
 */
import { Hono } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import type { Deployment } from '../chain/deployment.js';
import { revertReason, type ChainReader } from '../chain/reader.js';
import { SettlementMismatchError, type ChainWriter, type SettlementOutcome } from '../chain/settlement.js';
import { createLogger, type Logger } from '../logging.js';
import {
  LOCAL_NETWORK,
  SCHEMES,
  X402_VERSION,
  facilitatorRequestSchema,
  settlementResponseSchema,
  verifyResponseSchema,
  type FacilitatorRequest,
  type SettlementResponse,
  type SupportedResponse,
  type VerifyResponse,
} from '../x402/types.js';
import { preparePayment, verifyPayment, type PreparedPayment } from './verify.js';

export interface FacilitatorOptions {
  readonly deployment: Deployment;
  readonly reader: ChainReader;
  readonly writer: ChainWriter;
  readonly logger?: Logger;
}

export class Facilitator {
  private readonly inflight = new Map<string, Promise<SettlementResponse>>();
  private readonly logger: Logger;
  private submitted = 0;

  constructor(private readonly options: FacilitatorOptions) {
    this.logger = options.logger ?? createLogger({ component: 'facilitator' });
  }

  /** Number of settlement transactions this instance has sent (idempotent replays do not count). */
  get transactionsSent(): number {
    return this.submitted;
  }

  /** Settlements currently in flight. Finished ones are not kept: the chain answers repeated calls. */
  get pendingSettlements(): number {
    return this.inflight.size;
  }

  supported(): SupportedResponse {
    return {
      kinds: SCHEMES.map((scheme) => ({ x402Version: X402_VERSION, scheme, network: LOCAL_NETWORK })),
      extensions: [],
      signers: { [LOCAL_NETWORK]: [this.options.writer.address] },
    };
  }

  async verify(request: FacilitatorRequest): Promise<VerifyResponse> {
    const result = await verifyPayment(request, this.options.deployment, this.options.reader);
    this.logger.info('verify', {
      scheme: request.paymentRequirements.scheme,
      valid: result.isValid,
      reason: result.isValid ? undefined : result.invalidReason,
    });
    if (result.isValid) return { isValid: true, payer: result.payment.payer };
    return result.payer === undefined
      ? { isValid: false, invalidReason: result.invalidReason }
      : { isValid: false, invalidReason: result.invalidReason, payer: result.payer };
  }

  settle(request: FacilitatorRequest): Promise<SettlementResponse> {
    const prepared = preparePayment(request, this.options.deployment);
    if (!prepared.isValid) return Promise.resolve(this.failure(prepared.invalidReason));
    const key = prepared.payment.idempotencyKey;
    const existing = this.inflight.get(key);
    if (existing !== undefined) return existing;
    const pending = this.settleOnce(request, prepared.payment).catch((error: unknown) =>
      this.failure(`unexpected_settle_error:${revertReason(error)}`, prepared.payment),
    );
    this.inflight.set(key, pending);
    // The entry only deduplicates concurrent calls. Once the attempt is over, a later call is answered from the chain
    // ({@link ChainWriter.findExisting}) if it settled, or retried if it failed, so nothing is kept per payment.
    void pending.finally(() => {
      this.inflight.delete(key);
    });
    return pending;
  }

  private async settleOnce(
    request: FacilitatorRequest,
    payment: PreparedPayment,
  ): Promise<SettlementResponse> {
    const expected = payment.expected;
    let already: SettlementOutcome | null;
    try {
      already = await this.options.writer.findExisting(expected);
    } catch (error) {
      // Same payer and nonce, other amount, payee or resource: the payer signed two authorizations with one nonce
      // and the other one was settled. Reporting success here would describe a payment that never happened.
      if (error instanceof SettlementMismatchError)
        return this.failure('nonce_already_used_mismatch', payment);
      throw error;
    }
    if (already !== null) {
      this.logger.info('settle.already_on_chain', {
        key: payment.idempotencyKey,
        transaction: already.transaction,
      });
      return this.success(already, payment);
    }
    const verification = await verifyPayment(request, this.options.deployment, this.options.reader);
    if (!verification.isValid) return this.failure(verification.invalidReason, payment);
    try {
      this.submitted += 1;
      const outcome = await this.options.writer.execute(payment.call, expected);
      this.logger.info('settle.confirmed', {
        scheme: payment.scheme,
        transaction: outcome.transaction,
        id: outcome.id,
      });
      return this.success(outcome, payment);
    } catch (error) {
      return this.failure(`settlement_failed:${revertReason(error)}`, payment);
    }
  }

  private success(outcome: SettlementOutcome, payment: PreparedPayment): SettlementResponse {
    return {
      success: true,
      payer: payment.payer,
      transaction: outcome.transaction,
      network: LOCAL_NETWORK,
      amount: payment.expected.amount.toString(),
      extensions: payment.expected.kind === 'receipt' ? { receiptId: outcome.id } : { escrowId: outcome.id },
    };
  }

  private failure(errorReason: string, payment?: PreparedPayment): SettlementResponse {
    this.logger.warn('settle.failed', { reason: errorReason });
    return payment === undefined
      ? { success: false, errorReason, transaction: '', network: LOCAL_NETWORK }
      : { success: false, errorReason, payer: payment.payer, transaction: '', network: LOCAL_NETWORK };
  }
}

const MAX_BODY_BYTES = 64 * 1024;

/** HTTP surface of the facilitator. */
export function createFacilitatorApp(facilitator: Facilitator): Hono {
  const app = new Hono();
  app.use('*', bodyLimit({ maxSize: MAX_BODY_BYTES }));

  const parse = async (body: Promise<unknown>): Promise<FacilitatorRequest | null> => {
    try {
      const parsed = facilitatorRequestSchema.safeParse(await body);
      return parsed.success ? parsed.data : null;
    } catch {
      return null;
    }
  };

  app.get('/healthz', (c) => c.json({ ok: true }));
  app.get('/supported', (c) => c.json(facilitator.supported()));

  app.post('/verify', async (c) => {
    const request = await parse(c.req.json());
    if (request === null)
      return c.json({ isValid: false, invalidReason: 'invalid_payload' } satisfies VerifyResponse, 400);
    return c.json(await facilitator.verify(request));
  });

  app.post('/settle', async (c) => {
    const request = await parse(c.req.json());
    if (request === null) {
      const response: SettlementResponse = {
        success: false,
        errorReason: 'invalid_payload',
        transaction: '',
        network: LOCAL_NETWORK,
      };
      return c.json(response, 400);
    }
    return c.json(await facilitator.settle(request));
  });

  return app;
}

/** Client used by the resource server to talk to a facilitator over HTTP. */
export interface FacilitatorClient {
  verify(request: FacilitatorRequest): Promise<VerifyResponse>;
  settle(request: FacilitatorRequest): Promise<SettlementResponse>;
}

export function httpFacilitatorClient(baseUrl: string): FacilitatorClient {
  const post = async (path: string, body: FacilitatorRequest): Promise<unknown> => {
    const response = await fetch(new URL(path, baseUrl), {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    return response.json();
  };
  return {
    async verify(request) {
      return verifyResponseSchema.parse(await post('/verify', request));
    },
    async settle(request) {
      return settlementResponseSchema.parse(await post('/settle', request));
    },
  };
}
