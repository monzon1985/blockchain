// SPDX-License-Identifier: MIT
/**
 * ERC-8004 validator by re-execution.
 *
 * For each request addressed to it, the validator fetches the work document from the requesting agent's own x402
 * endpoint, ties it to an on-chain payment and re-runs the deterministic service on the paid request body. It posts a
 * 0..100 score: 100 when the recorded output is byte-identical (canonical JSON) to the re-execution, the share of
 * agreeing top-level fields (capped at 99) otherwise, and 0 when the document cannot be tied to a real payment to
 * that agent for exactly that request.
 *
 * Requests are untrusted input (anyone can register an agent and name any validator), so each one is handled in
 * isolation: a bad request is skipped or retried with backoff and never blocks the others; documents are fetched only
 * from the agent's registered endpoint origin, without redirects, with a timeout and a size cap; and the event scan
 * resumes from a stored block cursor instead of block 0.
 */
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import {
  keccak256,
  toBytes,
  zeroAddress,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type Transport,
} from 'viem';
import { z } from 'zod';
import { decodeAgentUri } from '../agent/discovery.js';
import { identityRegistryAbi, settlementLogAbi, validationRegistryAbi } from '../chain/abis.js';
import type { Deployment } from '../chain/deployment.js';
import type { RelayerClient } from '../chain/reader.js';
import { createLogger, type Logger } from '../logging.js';
import { SERVICE_PATHS, canonicalJson, executeService, resultHash } from '../server/services.js';
import { resourceHash } from '../x402/resource.js';
import { VALIDATOR_EXPIRES_HEADER, VALIDATOR_SIGNATURE_HEADER, validationAccessMessage } from './access.js';

/** The document a resource server publishes for a paid call. `body` is the raw request body that was paid for. */
export const workDocumentSchema = z.strictObject({
  service: z.enum(['sentiment', 'keywords', 'merkle-report']),
  resource: z.url(),
  body: z.string(),
  receiptId: z
    .string()
    .regex(/^0x[0-9a-fA-F]{64}$/)
    .transform((value) => value.toLowerCase() as Hex),
  output: z.unknown(),
});
export type WorkDocument = z.infer<typeof workDocumentSchema>;

/** Scores a recorded output against a fresh re-execution. */
export function scoreOutputs(recorded: unknown, reexecuted: unknown): number {
  if (canonicalJson(recorded) === canonicalJson(reexecuted)) return 100;
  if (
    recorded === null ||
    reexecuted === null ||
    typeof recorded !== 'object' ||
    typeof reexecuted !== 'object' ||
    Array.isArray(recorded) ||
    Array.isArray(reexecuted)
  ) {
    return 0;
  }
  const expected = reexecuted as Record<string, unknown>;
  const actual = recorded as Record<string, unknown>;
  const keys = Object.keys(expected);
  if (keys.length === 0) return 0;
  const agreeing = keys.filter((k) => canonicalJson(actual[k]) === canonicalJson(expected[k])).length;
  return Math.min(99, Math.floor((agreeing * 100) / keys.length));
}

/** What the validator reads from the chain to tie a work document to a payment. */
export interface ValidationChainView {
  receiptOf(
    receiptId: Hex,
  ): Promise<{ payer: Address; payee: Address; settledAt: bigint; resourceHash: Hex }>;
  wasAgentWalletAt(agentId: bigint, wallet: Address, timestamp: bigint): Promise<boolean>;
}

export interface Verdict {
  readonly score: number;
  readonly reason: string;
  readonly service?: string;
  readonly expectedHash?: Hex;
}

/**
 * Scores a fetched work document. Every check is made against the chain, never against the server's word:
 *   1. the bytes hash to the on-chain `requestHash`;
 *   2. the resource is the claimed service's path on the agent's own registered endpoint origin;
 *   3. the receipt exists, paid the agent's wallet (as it stood at settlement), for exactly this URL and body;
 *   4. re-executing the service on the paid body reproduces the recorded output.
 * A failed check among 1-3 scores 0 with a reason.
 */
export async function judgeWorkDocument(
  document: Uint8Array,
  requestHash: Hex,
  agentId: bigint,
  endpointOrigin: string,
  chain: ValidationChainView,
): Promise<Verdict> {
  if (keccak256(document) !== requestHash.toLowerCase())
    return { score: 0, reason: 'document_hash_mismatch' };
  let work: WorkDocument;
  try {
    work = workDocumentSchema.parse(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(document)));
  } catch {
    return { score: 0, reason: 'malformed_document' };
  }
  const service = work.service;
  const resource = new URL(work.resource);
  if (resource.origin !== endpointOrigin || resource.pathname !== SERVICE_PATHS[service]) {
    return { score: 0, reason: 'resource_not_agent_service', service };
  }
  const receipt = await chain.receiptOf(work.receiptId);
  if (receipt.payer === zeroAddress) return { score: 0, reason: 'unknown_receipt', service };
  if (!(await chain.wasAgentWalletAt(agentId, receipt.payee, receipt.settledAt))) {
    return { score: 0, reason: 'receipt_not_paid_to_agent', service };
  }
  const paidFor = resourceHash({ method: 'POST', url: work.resource, body: work.body });
  if (receipt.resourceHash.toLowerCase() !== paidFor) {
    return { score: 0, reason: 'receipt_for_another_request', service };
  }
  let reexecuted: unknown;
  try {
    reexecuted = executeService(service, JSON.parse(work.body));
  } catch {
    return { score: 0, reason: 'input_not_executable', service };
  }
  const score = scoreOutputs(work.output, reexecuted);
  return {
    score,
    reason: score === 100 ? 'reproduced' : 'output_differs',
    service,
    expectedHash: resultHash(reexecuted),
  };
}

/** The origin of an http(s) URL, or `null` for anything else. */
export function originOf(url: string): string | null {
  try {
    const parsed = new URL(url);
    return parsed.protocol === 'http:' || parsed.protocol === 'https:' ? parsed.origin : null;
  } catch {
    return null;
  }
}

/** Reads a response body, failing as soon as it exceeds `maxBytes` (declared or actual). */
export async function readBody(response: Response, maxBytes: number): Promise<Uint8Array> {
  if (Number(response.headers.get('content-length') ?? '0') > maxBytes) throw new Error('document_too_large');
  if (response.body === null) return new Uint8Array();
  const reader = (response.body as ReadableStream<Uint8Array>).getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw new Error('document_too_large');
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

/** Where the validator resumes its `ValidationRequest` scan. */
export interface CursorStore {
  load(): Promise<bigint>;
  save(nextBlock: bigint): Promise<void>;
}

/** In-memory cursor (lost on restart: the validator then rescans from `start`, already-answered requests are skipped). */
export function memoryCursor(start = 0n): CursorStore {
  let next = start;
  return {
    load: () => Promise.resolve(next),
    save: (nextBlock) => {
      next = nextBlock;
      return Promise.resolve();
    },
  };
}

const cursorFileSchema = z.object({ nextBlock: z.string().regex(/^[0-9]+$/) });

/** Cursor persisted as `{"nextBlock":"<n>"}`. A missing file starts at block 0; a corrupt one is an error. */
export function fileCursor(path: string): CursorStore {
  return {
    async load() {
      let text: string;
      try {
        text = await readFile(path, 'utf8');
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') return 0n;
        throw error;
      }
      return BigInt(cursorFileSchema.parse(JSON.parse(text)).nextBlock);
    },
    async save(nextBlock) {
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, JSON.stringify({ nextBlock: nextBlock.toString() }));
    },
  };
}

interface OutcomeBase {
  readonly agentId: bigint;
  readonly requestHash: Hex;
}

/** What happened to one `ValidationRequest` in a {@link Validator.processPending} pass. */
export type ValidationOutcome =
  | (OutcomeBase & {
      readonly status: 'posted';
      readonly score: number;
      readonly reason: string;
      readonly transaction: Hex;
    })
  | (OutcomeBase & { readonly status: 'skipped'; readonly reason: string })
  | (OutcomeBase & { readonly status: 'deferred'; readonly reason: string; readonly attempts: number });

export interface ValidatorOptions {
  readonly logger?: Logger;
  readonly fetch?: typeof fetch;
  readonly cursor?: CursorStore;
  /** Per-document fetch timeout. Default 5 s. */
  readonly fetchTimeoutMs?: number;
  /** Largest document accepted. Default 256 KiB. */
  readonly maxDocumentBytes?: number;
  /** Failed attempts (fetch or chain errors) before a request is given up. Default 5. */
  readonly maxAttempts?: number;
  /** Backoff after the first failure; doubles after each further one. Default 1 s. */
  readonly retryDelayMs?: number;
  /** Validity of the access signature sent to the resource server. Default 60 s. */
  readonly accessTtlSeconds?: number;
}

export class Validator {
  private readonly logger: Logger;
  private readonly http: typeof fetch;
  private readonly cursor: CursorStore;
  private readonly fetchTimeoutMs: number;
  private readonly maxDocumentBytes: number;
  private readonly maxAttempts: number;
  private readonly retryDelayMs: number;
  private readonly accessTtlSeconds: number;
  private readonly chain: ValidationChainView;
  private readonly retries = new Map<string, { attempts: number; notBefore: number }>();
  private readonly abandoned = new Set<string>();

  constructor(
    private readonly deployment: Deployment,
    private readonly publicClient: PublicClient<Transport, Chain>,
    private readonly wallet: RelayerClient,
    options: ValidatorOptions = {},
  ) {
    this.logger = options.logger ?? createLogger({ component: 'validator' });
    this.http = options.fetch ?? fetch;
    this.cursor = options.cursor ?? memoryCursor();
    this.fetchTimeoutMs = options.fetchTimeoutMs ?? 5_000;
    this.maxDocumentBytes = options.maxDocumentBytes ?? 256 * 1024;
    this.maxAttempts = options.maxAttempts ?? 5;
    this.retryDelayMs = options.retryDelayMs ?? 1_000;
    this.accessTtlSeconds = options.accessTtlSeconds ?? 60;
    this.chain = {
      receiptOf: async (receiptId) => {
        const r = await publicClient.readContract({
          address: deployment.settlementLog,
          abi: settlementLogAbi,
          functionName: 'receiptOf',
          args: [receiptId],
        });
        return { payer: r.payer, payee: r.payee, settledAt: r.settledAt, resourceHash: r.resourceHash };
      },
      wasAgentWalletAt: (agentId, wallet, timestamp) =>
        publicClient.readContract({
          address: deployment.identityRegistry,
          abi: identityRegistryAbi,
          functionName: 'wasAgentWalletAt',
          args: [agentId, wallet, timestamp],
        }),
    };
  }

  get address(): Address {
    return this.wallet.account.address;
  }

  /**
   * Handles every request addressed to this validator since the stored cursor. Never throws because of a single
   * request. The cursor advances past every request that was answered or given up; it stays at the first request
   * that is waiting for a retry.
   */
  async processPending(): Promise<ValidationOutcome[]> {
    // Uncached: a block number cached by the client could predate the latest request and silently delay it.
    const latest = await this.publicClient.getBlockNumber({ cacheTime: 0 });
    const fromBlock = await this.cursor.load();
    if (fromBlock > latest) return [];
    const events = await this.publicClient.getContractEvents({
      address: this.deployment.validationRegistry,
      abi: validationRegistryAbi,
      eventName: 'ValidationRequest',
      args: { validatorAddress: this.address },
      fromBlock,
      toBlock: latest,
    });
    const outcomes: ValidationOutcome[] = [];
    let holdAt: bigint | null = null;
    for (const event of events) {
      const { agentId, requestHash, requestURI } = event.args;
      if (agentId === undefined || requestHash === undefined || requestURI === undefined) continue;
      const outcome = await this.handle(agentId, requestHash, requestURI);
      outcomes.push(outcome);
      if (outcome.status === 'deferred' && holdAt === null) holdAt = event.blockNumber;
    }
    await this.cursor.save(holdAt ?? latest + 1n);
    return outcomes;
  }

  private async handle(agentId: bigint, requestHash: Hex, requestURI: string): Promise<ValidationOutcome> {
    const key = `${agentId.toString()}:${requestHash}`;
    const base: OutcomeBase = { agentId, requestHash };
    if (this.abandoned.has(key)) return { ...base, status: 'skipped', reason: 'abandoned' };
    try {
      const status = await this.publicClient.readContract({
        address: this.deployment.validationRegistry,
        abi: validationRegistryAbi,
        functionName: 'getValidationStatus',
        args: [agentId, requestHash],
      });
      if (status[5] !== 0n) return { ...base, status: 'skipped', reason: 'already_answered' };
      const retry = this.retries.get(key);
      if (retry !== undefined && Date.now() < retry.notBefore) {
        return { ...base, status: 'deferred', reason: 'backoff', attempts: retry.attempts };
      }
      // SSRF guard: the only host this validator contacts for an agent is that agent's registered endpoint.
      const endpointOrigin = originOf((await this.agentEndpoint(agentId)) ?? '');
      if (endpointOrigin === null) return this.abandon(key, base, 'agent_has_no_x402_endpoint');
      if (originOf(requestURI) !== endpointOrigin) {
        return this.abandon(key, base, 'request_uri_outside_agent_endpoint');
      }
      let document: Uint8Array;
      try {
        document = await this.fetchDocument(requestURI, requestHash);
      } catch (error) {
        return this.defer(key, base, `fetch_failed:${messageOf(error)}`);
      }
      this.retries.delete(key);
      return await this.post(
        base,
        await judgeWorkDocument(document, requestHash, agentId, endpointOrigin, this.chain),
      );
    } catch (error) {
      return this.defer(key, base, `error:${messageOf(error)}`);
    }
  }

  private abandon(key: string, base: OutcomeBase, reason: string): ValidationOutcome {
    this.abandoned.add(key);
    this.retries.delete(key);
    this.logger.warn('validation.skipped', { requestHash: base.requestHash, reason });
    return { ...base, status: 'skipped', reason };
  }

  private defer(key: string, base: OutcomeBase, reason: string): ValidationOutcome {
    const attempts = (this.retries.get(key)?.attempts ?? 0) + 1;
    if (attempts >= this.maxAttempts) return this.abandon(key, base, `gave_up:${reason}`);
    this.retries.set(key, { attempts, notBefore: Date.now() + this.retryDelayMs * 2 ** (attempts - 1) });
    this.logger.warn('validation.deferred', { requestHash: base.requestHash, reason, attempts });
    return { ...base, status: 'deferred', reason, attempts };
  }

  private async agentEndpoint(agentId: bigint): Promise<string | null> {
    const uri = await this.publicClient.readContract({
      address: this.deployment.identityRegistry,
      abi: identityRegistryAbi,
      functionName: 'tokenURI',
      args: [agentId],
    });
    return decodeAgentUri(uri)?.services.find((s) => s.name === 'x402')?.endpoint ?? null;
  }

  private async fetchDocument(requestURI: string, requestHash: Hex): Promise<Uint8Array> {
    const expires = Math.floor(Date.now() / 1000) + this.accessTtlSeconds;
    const signature = await this.wallet.signMessage({
      account: this.wallet.account,
      message: validationAccessMessage(requestHash, expires),
    });
    const response = await this.http(requestURI, {
      headers: { [VALIDATOR_SIGNATURE_HEADER]: signature, [VALIDATOR_EXPIRES_HEADER]: String(expires) },
      redirect: 'error',
      signal: AbortSignal.timeout(this.fetchTimeoutMs),
    });
    if (!response.ok) throw new Error(`http_${String(response.status)}`);
    return readBody(response, this.maxDocumentBytes);
  }

  private async post(base: OutcomeBase, verdict: Verdict): Promise<ValidationOutcome> {
    const report = canonicalJson(verdict);
    const hash = await this.wallet.writeContract({
      address: this.deployment.validationRegistry,
      abi: validationRegistryAbi,
      functionName: 'validationResponse',
      args: [
        base.agentId,
        base.requestHash,
        verdict.score,
        `data:application/json;base64,${Buffer.from(report).toString('base64')}`,
        keccak256(toBytes(report)),
        're-execution',
      ],
    });
    const receipt = await this.publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error('validation response reverted');
    this.logger.info('validation.posted', {
      requestHash: base.requestHash,
      score: verdict.score,
      reason: verdict.reason,
      transaction: hash,
    });
    return { ...base, status: 'posted', score: verdict.score, reason: verdict.reason, transaction: hash };
  }
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
