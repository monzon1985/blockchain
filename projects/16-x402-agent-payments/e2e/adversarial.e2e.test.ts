// SPDX-License-Identifier: MIT
/**
 * Adversarial e2e: the facilitator is treated as untrusted. A facilitator that alters amount, payee or resource
 * gets reverted by the contracts; one that lies about a settlement is caught by the resource server; replayed,
 * cross-resource and expired payments are refused; a payment that settled but was never served can be claimed by
 * retrying it; the validator survives hostile requests. Plus differential checks of the TypeScript mirrors against
 * the contracts on deterministic (seeded) inputs.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  createWalletClient,
  encodeFunctionData,
  encodePacked,
  getAddress,
  hashTypedData,
  http,
  keccak256,
  parseEther,
  slice,
  toBytes,
  zeroHash,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type Transport,
} from 'viem';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { Agent } from '../src/agent/agent.js';
import { encodeAgentUri, type DiscoveredService } from '../src/agent/discovery.js';
import { buildBudgetPayment, buildEscrowPayment, buildExactPayment } from '../src/agent/payments.js';
import {
  agentAccountAbi,
  budgetExecutorAbi,
  identityRegistryAbi,
  paymentEscrowAbi,
  settlementLogAbi,
  testUsdAbi,
  validationRegistryAbi,
} from '../src/chain/abis.js';
import { budgetExecutorCallAbi, paymentEscrowCallAbi, settlementLogCallAbi } from '../src/chain/callAbis.js';
import { ReceiptScheme, escrowIdFor, receiptIdFor, type ReceiptSchemeId } from '../src/chain/ids.js';
import { createChainReader } from '../src/chain/reader.js';
import { createChainWriter } from '../src/chain/settlement.js';
import {
  budgetExecutorDomain,
  identityDomain,
  paymentIntentTypes,
  setAgentWalletTypes,
  tokenDomain,
  transferWithAuthorizationTypes,
} from '../src/chain/typedData.js';
import { CONTRACTS_DIR } from '../src/demo/localnet.js';
import { startStack, type Stack } from '../src/demo/stack.js';
import { Facilitator, type FacilitatorClient } from '../src/facilitator/facilitator.js';
import { ResourceServer, type ResourceServerOptions } from '../src/server/resourceServer.js';
import { sentiment } from '../src/server/services.js';
import { Validator } from '../src/validator/validator.js';
import {
  PAYMENT_REQUIRED_HEADER,
  PAYMENT_RESPONSE_HEADER,
  decodePaymentRequired,
  decodeSettlementResponse,
  encodePaymentPayload,
} from '../src/x402/codec.js';
import { escrowNonce, exactNonce, randomBytes32 } from '../src/x402/resource.js';
import type {
  BudgetExecPayload,
  EscrowPayload,
  ExactPayload,
  FacilitatorRequest,
  PaymentPayload,
  PaymentRequired,
  PaymentRequirements,
} from '../src/x402/types.js';

let stack: Stack;

beforeAll(async () => {
  stack = await startStack();
});

afterAll(async () => {
  await stack.stop();
});

const balanceOf = (address: Address): Promise<bigint> =>
  stack.publicClient.readContract({
    address: stack.deployment.testUSD,
    abi: testUsdAbi,
    functionName: 'balanceOf',
    args: [address],
  });

const receiptCount = (): Promise<bigint> =>
  stack.publicClient.readContract({
    address: stack.deployment.settlementLog,
    abi: settlementLogAbi,
    functionName: 'receiptCount',
  });

const now = async (): Promise<bigint> => (await stack.publicClient.getBlock()).timestamp;

async function challengeFor(
  base: string,
  path: string,
  input: unknown,
): Promise<{ url: string; body: string; challenge: PaymentRequired }> {
  const url = `${base}${path}`;
  const body = JSON.stringify(input);
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body,
  });
  expect(response.status).toBe(402);
  return { url, body, challenge: decodePaymentRequired(response.headers.get(PAYMENT_REQUIRED_HEADER)) };
}

function pick(challenge: PaymentRequired, scheme: string): PaymentRequirements {
  const found = challenge.accepts.find((r) => r.scheme === scheme);
  if (found === undefined) throw new Error(`no ${scheme} offer`);
  return found;
}

async function exactPayment(input: unknown, path = '/api/v1/sentiment', base = stack.serverUrl) {
  const c = await challengeFor(base, path, input);
  const requirements = pick(c.challenge, 'exact');
  const payload = await buildExactPayment(
    { deployment: stack.deployment, requirements, resource: c.challenge.resource, now: await now() },
    stack.actors.eoaPayer.account,
  );
  return { ...c, requirements, payload };
}

async function sendPaid(url: string, body: string, payload: PaymentPayload): Promise<Response> {
  return fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'PAYMENT-SIGNATURE': encodePaymentPayload(payload) },
    body,
  });
}

function rejectionOf(response: Response): string | undefined {
  expect(response.status).toBe(402);
  return decodePaymentRequired(response.headers.get(PAYMENT_REQUIRED_HEADER)).error;
}

/** A second resource server for the same agent wallet, on its own port, with the given facilitator and options. */
async function serverWith(
  facilitator: FacilitatorClient,
  options: Partial<ResourceServerOptions> = {},
): Promise<{ server: ResourceServer; url: string; close: () => Promise<void> }> {
  const server = new ResourceServer({
    deployment: stack.deployment,
    facilitator,
    publicClient: stack.publicClient,
    treasury: stack.actors.treasury.wallet,
    operator: stack.actors.operator.wallet,
    ...options,
  });
  const { serve } = await import('@hono/node-server');
  return new Promise((resolve) => {
    const http = serve({ fetch: server.app.fetch, port: 0, hostname: '127.0.0.1' }, (info) => {
      const url = `http://127.0.0.1:${info.port}`;
      server.setPublicUrl(url);
      resolve({
        server,
        url,
        close: () =>
          new Promise<void>((done) =>
            http.close(() => {
              done();
            }),
          ),
      });
    });
  });
}

/** The stack's public client, except that its next `failures` receipt reads fail like a dropped RPC connection. */
function flakyReceipts(failures: number): PublicClient<Transport, Chain> {
  let remaining = failures;
  return new Proxy(stack.publicClient, {
    get(target, property, receiver) {
      if (property === 'getTransactionReceipt' && remaining > 0) {
        return () => {
          remaining -= 1;
          return Promise.reject(new Error('ECONNRESET (simulated)'));
        };
      }
      return Reflect.get(target, property, receiver) as unknown;
    },
  });
}

describe('deployment', () => {
  it('the settlement log is sealed, ownerless and trusts exactly the executor and the escrow', async () => {
    const log = { address: stack.deployment.settlementLog, abi: settlementLogAbi } as const;
    expect(await stack.publicClient.readContract({ ...log, functionName: 'isSealed' })).toBe(true);
    expect(await stack.publicClient.readContract({ ...log, functionName: 'owner' })).toBe(
      '0x0000000000000000000000000000000000000000',
    );
    for (const recorder of [stack.deployment.budgetExecutor, stack.deployment.paymentEscrow]) {
      expect(
        await stack.publicClient.readContract({ ...log, functionName: 'isRecorder', args: [recorder] }),
      ).toBe(true);
    }
    expect(
      await stack.publicClient.readContract({
        ...log,
        functionName: 'isRecorder',
        args: [stack.actors.relayer.account.address],
      }),
    ).toBe(false);
  });
});

describe('differential: TypeScript mirrors equal the contracts', () => {
  // Inputs are derived from a fixed seed, so a failure reproduces exactly.
  const seeded = (label: string, i: number): Hex =>
    keccak256(toBytes(`x402-differential/${label}/${String(i)}`));
  const seededAddress = (label: string, i: number): Address => getAddress(slice(seeded(label, i), 12));

  it('nonce commitments, receipt ids, escrow ids and EIP-712 digests on 24 seeded inputs', async () => {
    const { publicClient, deployment } = stack;
    const recorders: readonly [Address, ReceiptSchemeId][] = [
      [deployment.settlementLog, ReceiptScheme.Exact],
      [deployment.budgetExecutor, ReceiptScheme.BudgetExec],
      [deployment.paymentEscrow, ReceiptScheme.Escrow],
    ];
    for (let i = 0; i < 24; i++) {
      const resource = seeded('resource', i);
      const salt = seeded('salt', i);
      const payee = seededAddress('payee', i);
      const deadline = 1_900_000_000n + BigInt(i) * 3_600n;
      expect(
        await publicClient.readContract({
          address: deployment.settlementLog,
          abi: settlementLogAbi,
          functionName: 'exactNonce',
          args: [resource, salt],
        }),
      ).toBe(exactNonce(resource, salt));
      expect(
        await publicClient.readContract({
          address: deployment.paymentEscrow,
          abi: paymentEscrowAbi,
          functionName: 'escrowNonce',
          args: [payee, resource, deadline, salt],
        }),
      ).toBe(escrowNonce(payee, resource, deadline, salt));
      const [recorder, scheme] = recorders[i % recorders.length] as [Address, ReceiptSchemeId];
      expect(
        await publicClient.readContract({
          address: deployment.settlementLog,
          abi: settlementLogAbi,
          functionName: 'receiptIdFor',
          args: [recorder, scheme, payee, salt],
        }),
      ).toBe(receiptIdFor(recorder, scheme, payee, salt));
      expect(
        await publicClient.readContract({
          address: deployment.paymentEscrow,
          abi: paymentEscrowAbi,
          functionName: 'escrowIdFor',
          args: [payee, salt],
        }),
      ).toBe(escrowIdFor(payee, salt));

      const intent = {
        account: seededAddress('account', i),
        payee,
        amount: BigInt(seeded('amount', i)) % 10n ** 24n,
        resourceHash: resource,
        nonce: salt,
        validAfter: deadline - 600n,
        validBefore: deadline,
      };
      expect(
        await publicClient.readContract({
          address: deployment.budgetExecutor,
          abi: budgetExecutorAbi,
          functionName: 'hashPaymentIntent',
          args: [intent],
        }),
      ).toBe(
        hashTypedData({
          domain: budgetExecutorDomain(deployment),
          types: paymentIntentTypes,
          primaryType: 'PaymentIntent',
          message: intent,
        }),
      );
      const newWallet = seededAddress('wallet', i);
      expect(
        await publicClient.readContract({
          address: deployment.identityRegistry,
          abi: identityRegistryAbi,
          functionName: 'agentWalletDigest',
          args: [stack.agentId, newWallet, deadline],
        }),
      ).toBe(
        hashTypedData({
          domain: identityDomain(deployment),
          types: setAgentWalletTypes,
          primaryType: 'SetAgentWallet',
          message: {
            agentId: stack.agentId,
            newWallet,
            owner: stack.actors.operator.account.address,
            nonce: 0n,
            deadline,
          },
        }),
      );
    }
  });
});

describe('a malicious facilitator cannot alter what the payer signed', () => {
  const relayerWrite = (args: Parameters<Stack['actors']['relayer']['wallet']['writeContract']>[0]) =>
    stack.actors.relayer.wallet.writeContract(args);

  it('exact: changed amount, payee or resource all revert on-chain', async () => {
    const { payload, requirements } = await exactPayment({ text: 'honest request' });
    const p = payload.payload as ExactPayload;
    const extra = requirements.extra as { resourceHash: Hex };
    const auth = {
      from: p.authorization.from,
      to: p.authorization.to,
      value: BigInt(p.authorization.value),
      validAfter: BigInt(p.authorization.validAfter),
      validBefore: BigInt(p.authorization.validBefore),
      nonce: p.authorization.nonce,
    };
    const log = {
      address: stack.deployment.settlementLog,
      abi: settlementLogCallAbi,
      functionName: 'settleExact',
    } as const;
    const payerBefore = await balanceOf(auth.from);
    const receiptsBefore = await receiptCount();
    const attempts: [string, readonly unknown[], RegExp][] = [
      [
        'amount',
        [{ ...auth, value: auth.value * 100n }, extra.resourceHash, p.resourceSalt, p.signature],
        /ERC3009InvalidSignature/,
      ],
      [
        'payee',
        [
          { ...auth, to: stack.actors.relayer.account.address },
          extra.resourceHash,
          p.resourceSalt,
          p.signature,
        ],
        /ERC3009InvalidSignature/,
      ],
      ['resource', [auth, randomBytes32(), p.resourceSalt, p.signature], /ResourceBindingMismatch/],
    ];
    for (const [, args, error] of attempts) {
      await expect(
        stack.publicClient.simulateContract({
          ...log,
          account: stack.actors.relayer.account,
          args: args as never,
        }),
      ).rejects.toThrow(error);
      // Also land it on-chain (forced gas) to prove the revert is real, not a simulation artefact.
      const hash = await relayerWrite({ ...log, args: args, gas: 500_000n });
      expect((await stack.publicClient.waitForTransactionReceipt({ hash })).status).toBe('reverted');
    }
    expect(await balanceOf(auth.from)).toBe(payerBefore);
    expect(await receiptCount()).toBe(receiptsBefore);
  });

  it('budget-exec: changed amount, payee or resource all revert with InvalidSessionSignature', async () => {
    // A second allowlisted payee, so that redirecting the payment passes every policy check and only the session
    // signature can stop it (the payee check alone would hide whether the signature binds the payee).
    const otherPayee = stack.actors.validator.account.address;
    const setPayee = async (allowed: boolean): Promise<void> => {
      const hash = await stack.actors.principal.wallet.writeContract({
        address: stack.smartAccount,
        abi: agentAccountAbi,
        functionName: 'execute',
        args: [
          zeroHash,
          encodePacked(
            ['address', 'uint256', 'bytes'],
            [
              stack.deployment.budgetExecutor,
              0n,
              encodeFunctionData({
                abi: budgetExecutorAbi,
                functionName: 'setPayee',
                args: [otherPayee, allowed],
              }),
            ],
          ),
        ],
      });
      await stack.publicClient.waitForTransactionReceipt({ hash });
    };
    await setPayee(true);
    try {
      expect(
        await stack.publicClient.readContract({
          address: stack.deployment.budgetExecutor,
          abi: budgetExecutorAbi,
          functionName: 'isPayeeAllowed',
          args: [stack.smartAccount, otherPayee],
        }),
      ).toBe(true);
      const c = await challengeFor(stack.serverUrl, '/api/v1/sentiment', { text: 'budget request' });
      const requirements = pick(c.challenge, 'budget-exec');
      const payload = await buildBudgetPayment(
        { deployment: stack.deployment, requirements, resource: c.challenge.resource, now: await now() },
        stack.smartAccount,
        stack.actors.session,
      );
      const { intent: wire, signature } = payload.payload as BudgetExecPayload;
      const intent = {
        account: wire.account,
        payee: wire.payee,
        amount: BigInt(wire.amount),
        resourceHash: wire.resourceHash,
        nonce: wire.nonce,
        validAfter: BigInt(wire.validAfter),
        validBefore: BigInt(wire.validBefore),
      };
      expect(intent.amount * 5n).toBeLessThanOrEqual(stack.policy.perCallCap);
      const before = await balanceOf(stack.smartAccount);
      for (const tampered of [
        { ...intent, amount: intent.amount * 5n },
        { ...intent, payee: otherPayee },
        { ...intent, resourceHash: randomBytes32() },
      ]) {
        await expect(
          stack.publicClient.simulateContract({
            account: stack.actors.relayer.account,
            address: stack.deployment.budgetExecutor,
            abi: budgetExecutorCallAbi,
            functionName: 'pay',
            args: [tampered, signature],
          }),
        ).rejects.toThrow(/InvalidSessionSignature/);
      }
      expect(await balanceOf(stack.smartAccount)).toBe(before);
    } finally {
      await setPayee(false);
    }
  });

  it('escrow: changed payee, deadline, amount, resource or escrow contract all revert', async () => {
    const c = await challengeFor(stack.serverUrl, '/api/v1/reports', { items: ['a', 'b'] });
    const requirements = pick(c.challenge, 'escrow');
    const payload = await buildEscrowPayment(
      { deployment: stack.deployment, requirements, resource: c.challenge.resource, now: await now() },
      stack.actors.eoaPayer.account,
    );
    const p = payload.payload as EscrowPayload;
    const request = {
      from: p.authorization.from,
      value: BigInt(p.authorization.value),
      validAfter: BigInt(p.authorization.validAfter),
      validBefore: BigInt(p.authorization.validBefore),
      nonce: p.authorization.nonce,
      payee: p.escrow.payee,
      resourceHash: p.escrow.resourceHash,
      deliveryDeadline: BigInt(p.escrow.deliveryDeadline),
      salt: p.escrow.salt,
    };
    const open = (r: typeof request, escrow: Address = stack.deployment.paymentEscrow) =>
      stack.publicClient.simulateContract({
        account: stack.actors.relayer.account,
        address: escrow,
        abi: paymentEscrowCallAbi,
        functionName: 'open',
        args: [r, p.signature],
      });
    await expect(open({ ...request, payee: stack.actors.relayer.account.address })).rejects.toThrow(
      /TermsBindingMismatch/,
    );
    await expect(open({ ...request, deliveryDeadline: request.deliveryDeadline + 86_400n })).rejects.toThrow(
      /TermsBindingMismatch/,
    );
    await expect(open({ ...request, resourceHash: randomBytes32() })).rejects.toThrow(/TermsBindingMismatch/);
    await expect(open({ ...request, value: request.value * 2n })).rejects.toThrow(/ERC3009InvalidSignature/);

    // Another PaymentEscrow (same code, same asset) cannot take the funds: the payer signed `to` = the real escrow.
    const artifact = JSON.parse(
      readFileSync(join(CONTRACTS_DIR, 'out', 'PaymentEscrow.sol', 'PaymentEscrow.json'), 'utf8'),
    ) as { bytecode: { object: Hex } };
    const deployHash = await stack.actors.relayer.wallet.deployContract({
      abi: paymentEscrowAbi,
      bytecode: artifact.bytecode.object,
      args: [stack.deployment.settlementLog],
    });
    const { contractAddress } = await stack.publicClient.waitForTransactionReceipt({ hash: deployHash });
    if (contractAddress === null || contractAddress === undefined)
      throw new Error('escrow copy not deployed');
    await expect(open(request, contractAddress)).rejects.toThrow(/ERC3009InvalidSignature/);

    // And the authorization cannot be redirected by calling the token directly: only the escrow may receive it.
    await expect(
      stack.publicClient.simulateContract({
        account: stack.actors.relayer.account,
        address: stack.deployment.testUSD,
        abi: testUsdAbi,
        functionName: 'receiveWithAuthorization',
        args: [
          request.from,
          stack.deployment.paymentEscrow,
          request.value,
          request.validAfter,
          request.validBefore,
          request.nonce,
          p.signature,
        ],
      }),
    ).rejects.toThrow(/ERC20InvalidReceiver/);
    // The untampered request does open on the real escrow.
    await expect(open(request)).resolves.toBeDefined();
  });
});

describe('the resource server does not trust the facilitator', () => {
  let honestTx: Hex;

  beforeAll(async () => {
    // A real, successful settlement for a *different* resource, which a lying facilitator will try to reuse.
    const { url, body, payload } = await exactPayment({ text: 'the honest one' });
    const response = await sendPaid(url, body, payload);
    expect(response.status).toBe(200);
    honestTx = decodeSettlementResponse(response.headers.get(PAYMENT_RESPONSE_HEADER)).transaction as Hex;
  });

  it('refuses to serve when the facilitator claims success with an unrelated transaction', async () => {
    const liar: FacilitatorClient = {
      verify: () => Promise.resolve({ isValid: true }),
      settle: () => Promise.resolve({ success: true, transaction: honestTx, network: 'eip155:31337' }),
    };
    const rogue = await serverWith(liar);
    try {
      const { url, body, payload } = await exactPayment(
        { text: 'never paid for' },
        '/api/v1/sentiment',
        rogue.url,
      );
      const before = await balanceOf(stack.actors.eoaPayer.account.address);
      expect(rejectionOf(await sendPaid(url, body, payload))).toBe('settlement_unverified');
      expect(await balanceOf(stack.actors.eoaPayer.account.address)).toBe(before);
    } finally {
      await rogue.close();
    }
  });

  it('serves a replayed payment only once, even if the facilitator re-reports the original settlement', async () => {
    // Skips verification and forwards to the real (idempotent) facilitator, which answers a replay with the
    // original transaction: only the server's consumed-receipt set stops the second call.
    const permissive: FacilitatorClient = {
      verify: () => Promise.resolve({ isValid: true }),
      settle: (request) => stack.facilitatorClient.settle(request),
    };
    const rogue = await serverWith(permissive);
    try {
      const { url, body, payload } = await exactPayment(
        { text: 'replay me' },
        '/api/v1/sentiment',
        rogue.url,
      );
      expect((await sendPaid(url, body, payload)).status).toBe(200);
      expect(rejectionOf(await sendPaid(url, body, payload))).toBe('payment_already_used');
      expect(rogue.server.stateSizes().consumed).toBe(1);
    } finally {
      await rogue.close();
    }
  });

  it('refuses to serve when the facilitator redirects the payment and reports its reverted transaction', async () => {
    const redirecting: FacilitatorClient = {
      verify: () => Promise.resolve({ isValid: true }),
      settle: async (request: FacilitatorRequest) => {
        const p = request.paymentPayload.payload as ExactPayload;
        const extra = request.paymentRequirements.extra as { resourceHash: Hex };
        const hash = await stack.actors.relayer.wallet.writeContract({
          address: stack.deployment.settlementLog,
          abi: settlementLogAbi,
          functionName: 'settleExact',
          args: [
            {
              from: p.authorization.from,
              to: stack.actors.relayer.account.address, // steal: pay the facilitator instead of the service
              value: BigInt(p.authorization.value),
              validAfter: BigInt(p.authorization.validAfter),
              validBefore: BigInt(p.authorization.validBefore),
              nonce: p.authorization.nonce,
            },
            extra.resourceHash,
            p.resourceSalt,
            p.signature,
          ],
          gas: 500_000n,
        });
        await stack.publicClient.waitForTransactionReceipt({ hash });
        return { success: true, transaction: hash, network: 'eip155:31337' };
      },
    };
    const rogue = await serverWith(redirecting);
    try {
      const { url, body, payload } = await exactPayment(
        { text: 'redirect me' },
        '/api/v1/sentiment',
        rogue.url,
      );
      const relayerBefore = await balanceOf(stack.actors.relayer.account.address);
      expect(rejectionOf(await sendPaid(url, body, payload))).toBe('settlement_unverified');
      expect(await balanceOf(stack.actors.relayer.account.address)).toBe(relayerBefore);
    } finally {
      await rogue.close();
    }
  });

  it('refuses a settlement of the same nonce with other terms, and so does the facilitator', async () => {
    // The payer signs two authorizations with one nonce: 0.01 tUSD (what the server asks) and 1 base unit. The
    // small one is settled directly; the facilitator must not report the large one as settled.
    const c = await exactPayment({ text: 'same nonce, two amounts' });
    const p = c.payload.payload as ExactPayload;
    const extra = c.requirements.extra as { resourceHash: Hex };
    const small = {
      from: p.authorization.from,
      to: p.authorization.to,
      value: 1n,
      validAfter: BigInt(p.authorization.validAfter),
      validBefore: BigInt(p.authorization.validBefore),
      nonce: p.authorization.nonce,
    };
    const smallSignature = await stack.actors.eoaPayer.account.signTypedData({
      domain: tokenDomain(stack.deployment),
      types: transferWithAuthorizationTypes,
      primaryType: 'TransferWithAuthorization',
      message: small,
    });
    const hash = await stack.actors.relayer.wallet.writeContract({
      address: stack.deployment.settlementLog,
      abi: settlementLogAbi,
      functionName: 'settleExact',
      args: [small, extra.resourceHash, p.resourceSalt, smallSignature],
    });
    await stack.publicClient.waitForTransactionReceipt({ hash });

    const response = await stack.facilitatorClient.settle({
      x402Version: 2,
      paymentPayload: c.payload,
      paymentRequirements: c.requirements,
    });
    expect(response).toMatchObject({ success: false, errorReason: 'nonce_already_used_mismatch' });
    expect(rejectionOf(await sendPaid(c.url, c.body, c.payload))).toBe('nonce_already_used_mismatch');
  });
});

describe('a payment that settled but was not served can be claimed by retrying it', () => {
  const payer = (): Address => stack.actors.eoaPayer.account.address;

  it('after the settlement check failed past its retries: the same PAYMENT-SIGNATURE is then served once', async () => {
    const rogue = await serverWith(stack.facilitatorClient, {
      publicClient: flakyReceipts(2),
      confirmationAttempts: 2,
      confirmationDelayMs: 1,
    });
    try {
      const { url, body, payload } = await exactPayment(
        { text: 'settled, not served' },
        '/api/v1/sentiment',
        rogue.url,
      );
      const before = await balanceOf(payer());
      const sent = stack.facilitator.transactionsSent;
      expect(rejectionOf(await sendPaid(url, body, payload))).toBe('settlement_unverified');
      expect(await balanceOf(payer())).toBe(before - 10_000n);
      const retry = await sendPaid(url, body, payload);
      expect(retry.status).toBe(200);
      expect(await retry.json()).toEqual(sentiment({ text: 'settled, not served' }));
      expect(rejectionOf(await sendPaid(url, body, payload))).toBe('payment_already_used');
      expect(stack.facilitator.transactionsSent).toBe(sent + 1);
      expect(await balanceOf(payer())).toBe(before - 10_000n);
    } finally {
      await rogue.close();
    }
  });

  it('absorbs a transient receipt-read failure with backoff, without the client noticing', async () => {
    const rogue = await serverWith(stack.facilitatorClient, {
      publicClient: flakyReceipts(1),
      confirmationDelayMs: 1,
    });
    try {
      const { url, body, payload } = await exactPayment(
        { text: 'one hiccup' },
        '/api/v1/sentiment',
        rogue.url,
      );
      expect((await sendPaid(url, body, payload)).status).toBe(200);
    } finally {
      await rogue.close();
    }
  });

  it('after the facilitator response was lost', async () => {
    let lose = true;
    const lossy: FacilitatorClient = {
      verify: (request) => stack.facilitatorClient.verify(request),
      settle: async (request) => {
        const response = await stack.facilitatorClient.settle(request);
        if (lose) {
          lose = false;
          throw new Error('socket hang up (simulated)');
        }
        return response;
      },
    };
    const rogue = await serverWith(lossy);
    try {
      const { url, body, payload } = await exactPayment(
        { text: 'lost response' },
        '/api/v1/sentiment',
        rogue.url,
      );
      const before = await balanceOf(payer());
      expect(rejectionOf(await sendPaid(url, body, payload))).toBe('facilitator_unavailable');
      expect(await balanceOf(payer())).toBe(before - 10_000n);
      expect((await sendPaid(url, body, payload)).status).toBe(200);
    } finally {
      await rogue.close();
    }
  });

  it('even after the authorization window closed, as long as the settlement is within the claim window', async () => {
    const rogue = await serverWith(stack.facilitatorClient, {
      publicClient: flakyReceipts(2),
      confirmationAttempts: 2,
      confirmationDelayMs: 1,
    });
    try {
      const { url, body, payload } = await exactPayment(
        { text: 'late claim' },
        '/api/v1/sentiment',
        rogue.url,
      );
      expect(rejectionOf(await sendPaid(url, body, payload))).toBe('settlement_unverified');
      await stack.advanceTime(200); // past validBefore (120 s), inside the 600 s claim window
      expect((await sendPaid(url, body, payload)).status).toBe(200);
    } finally {
      await rogue.close();
    }
  });

  it('but not once the claim window has passed', async () => {
    const rogue = await serverWith(stack.facilitatorClient, {
      publicClient: flakyReceipts(2),
      confirmationAttempts: 2,
      confirmationDelayMs: 1,
      settlementClaimWindowSeconds: 30,
    });
    try {
      const { url, body, payload } = await exactPayment({ text: 'too late' }, '/api/v1/sentiment', rogue.url);
      expect(rejectionOf(await sendPaid(url, body, payload))).toBe('settlement_unverified');
      await stack.advanceTime(60);
      expect(rejectionOf(await sendPaid(url, body, payload))).toBe('settlement_expired');
    } finally {
      await rogue.close();
    }
  });

  it('the agent retries by itself and gets the call it paid for', async () => {
    const rogue = await serverWith(stack.facilitatorClient, {
      publicClient: flakyReceipts(2),
      confirmationAttempts: 2,
      confirmationDelayMs: 1,
    });
    try {
      const service: DiscoveredService = {
        agentId: stack.agentId,
        owner: stack.actors.operator.account.address,
        wallet: stack.server.payTo,
        card: { type: 'local', name: 'flaky', services: [{ name: 'x402', endpoint: rogue.url }] },
        endpoint: rogue.url,
      };
      const agent = new Agent({
        deployment: stack.deployment,
        publicClient: stack.publicClient,
        payer: { kind: 'eoa', account: stack.actors.eoaPayer.account },
        policy: { maxPricePerCall: 50_000n, schemes: ['exact'] },
        paidRetryDelayMs: 1,
      });
      const paid = await agent.call(service, '/api/v1/sentiment', { text: 'agent retries' });
      expect(paid.status).toBe(200);
      expect(agent.receipts).toHaveLength(1);
    } finally {
      await rogue.close();
    }
  });
});

describe('the resource server state is bounded', () => {
  it('forgets consumed receipts, work records, validation documents and jobs once they expire', async () => {
    const rogue = await serverWith(stack.facilitatorClient, {
      settlementClaimWindowSeconds: 30,
      retentionSeconds: 30,
      deliveryWindowSeconds: 30,
      deliveryDelayMs: 1,
    });
    rogue.server.setAgentId(stack.agentId);
    try {
      const paidCall = async (text: string): Promise<Hex> => {
        const { url, body, payload } = await exactPayment({ text }, '/api/v1/sentiment', rogue.url);
        const response = await sendPaid(url, body, payload);
        expect(response.status).toBe(200);
        const id = decodeSettlementResponse(response.headers.get(PAYMENT_RESPONSE_HEADER)).extensions
          ?.receiptId;
        if (id === undefined) throw new Error('no receipt id');
        return id;
      };
      const first = await paidCall('expires soon');
      await rogue.server.requestValidation(first, stack.actors.validator.account.address);
      const c = await challengeFor(rogue.url, '/api/v1/reports', { items: ['x'] });
      const escrowPayload = await buildEscrowPayment(
        {
          deployment: stack.deployment,
          requirements: pick(c.challenge, 'escrow'),
          resource: c.challenge.resource,
          now: await now(),
        },
        stack.actors.eoaPayer.account,
      );
      expect((await sendPaid(c.url, c.body, escrowPayload)).status).toBe(202);
      await rogue.server.flushDeliveries();
      // 2 work records: the paid call and the delivered escrow.
      expect(rogue.server.stateSizes()).toEqual({ consumed: 1, work: 2, validationDocs: 1, jobs: 1 });

      await stack.advanceTime(3_600);
      await paidCall('after the window');
      expect(rogue.server.stateSizes()).toEqual({ consumed: 1, work: 1, validationDocs: 0, jobs: 0 });
      expect(rogue.server.workRecord(first)).toBeUndefined();
    } finally {
      await rogue.close();
    }
  });
});

describe('replay, cross-resource and expiry protection', () => {
  it('a PAYMENT-SIGNATURE buys exactly one call', async () => {
    const { url, body, payload } = await exactPayment({ text: 'pay once' });
    const sent = stack.facilitator.transactionsSent;
    expect((await sendPaid(url, body, payload)).status).toBe(200);
    const balance = await balanceOf(stack.actors.eoaPayer.account.address);
    // The facilitator answers the replay from the chain (no new transaction); the server sees the receipt consumed.
    expect(rejectionOf(await sendPaid(url, body, payload))).toBe('payment_already_used');
    expect(stack.facilitator.transactionsSent).toBe(sent + 1);
    expect(await balanceOf(stack.actors.eoaPayer.account.address)).toBe(balance);
  });

  it('a payment for one resource is refused for another body, path or server', async () => {
    const { url, payload } = await exactPayment({ text: 'resource A' });
    expect(rejectionOf(await sendPaid(url, JSON.stringify({ text: 'resource B' }), payload))).toBe(
      'invalid_payment_requirements',
    );
    expect(
      rejectionOf(
        await sendPaid(`${stack.serverUrl}/api/v1/keywords`, JSON.stringify({ text: 'resource A' }), payload),
      ),
    ).toBe('invalid_payment_requirements');
    // Same path and body on another server (another origin, same payTo): the resource hash differs.
    const other = await serverWith(stack.facilitatorClient);
    try {
      expect(
        rejectionOf(
          await sendPaid(`${other.url}/api/v1/sentiment`, JSON.stringify({ text: 'resource A' }), payload),
        ),
      ).toBe('invalid_payment_requirements');
    } finally {
      await other.close();
    }
  });

  it('an expired authorization is refused before any gas is spent', async () => {
    const { url, body, payload } = await exactPayment({ text: 'too late to settle' });
    const sent = stack.facilitator.transactionsSent;
    await stack.advanceTime(200);
    expect(rejectionOf(await sendPaid(url, body, payload))).toBe(
      'invalid_exact_evm_payload_authorization_valid_before',
    );
    expect(stack.facilitator.transactionsSent).toBe(sent);
  });

  it('settlement is idempotent per nonce, across concurrent calls and facilitator restarts', async () => {
    const { payload, requirements } = await exactPayment({ text: 'idempotent' });
    const request: FacilitatorRequest = {
      x402Version: 2,
      paymentPayload: payload,
      paymentRequirements: requirements,
    };
    const receiptsBefore = await receiptCount();
    const [a, b] = await Promise.all([
      stack.facilitatorClient.settle(request),
      stack.facilitatorClient.settle(request),
    ]);
    expect(a.success && b.success).toBe(true);
    expect(a.transaction).toBe(b.transaction);
    expect(stack.facilitator.pendingSettlements).toBe(0);
    const restarted = new Facilitator({
      deployment: stack.deployment,
      reader: createChainReader(stack.publicClient, stack.deployment, stack.actors.relayer.account.address),
      writer: createChainWriter(stack.publicClient, stack.actors.relayer.wallet, stack.deployment),
    });
    const c = await restarted.settle(request);
    expect(c.transaction).toBe(a.transaction);
    expect(restarted.transactionsSent).toBe(0);
    expect(await receiptCount()).toBe(receiptsBefore + 1n);
  });

  it('an authorization consumed outside the log leaves no receipt and cannot be settled (documented limitation)', async () => {
    const { url, body, payload, requirements } = await exactPayment({ text: 'front-run' });
    const p = payload.payload as ExactPayload;
    const payTo = requirements.payTo;
    const payeeBefore = await balanceOf(payTo);
    const hash = await stack.actors.relayer.wallet.writeContract({
      address: stack.deployment.testUSD,
      abi: testUsdAbi,
      functionName: 'transferWithAuthorization',
      args: [
        p.authorization.from,
        p.authorization.to,
        BigInt(p.authorization.value),
        BigInt(p.authorization.validAfter),
        BigInt(p.authorization.validBefore),
        p.authorization.nonce,
        p.signature,
      ],
    });
    await stack.publicClient.waitForTransactionReceipt({ hash });
    // The payee still received exactly the signed amount...
    expect(await balanceOf(payTo)).toBe(payeeBefore + BigInt(p.authorization.value));
    // ...but there is no receipt, and neither the facilitator nor the server's recovery path can produce one.
    const response = await stack.facilitatorClient.settle({
      x402Version: 2,
      paymentPayload: payload,
      paymentRequirements: requirements,
    });
    expect(response).toMatchObject({ success: false, errorReason: 'nonce_already_used' });
    expect(rejectionOf(await sendPaid(url, body, payload))).toBe('nonce_already_used');
  });
});

describe('the validator contains hostile validation requests', () => {
  it('skips or defers them, never fetches another host, and still validates the legitimate request', async () => {
    const { publicClient, deployment } = stack;
    const attacker = privateKeyToAccount(generatePrivateKey());
    await stack.testClient.setBalance({ address: attacker.address, value: parseEther('10') });
    const attackerWallet = createWalletClient({
      chain: publicClient.chain,
      transport: http(stack.anvil.rpcUrl),
      account: attacker,
    });
    const write = async (args: Parameters<typeof attackerWallet.writeContract>[0]) => {
      const hash = await attackerWallet.writeContract(args);
      await publicClient.waitForTransactionReceipt({ hash });
    };
    const validatorAddress = stack.actors.validator.account.address;
    const identity = { address: deployment.identityRegistry, abi: identityRegistryAbi } as const;

    // Agent 1 of the attacker: registering is permissionless; its card points at an unreachable endpoint.
    const unreachable = 'http://127.0.0.1:1';
    await write({
      ...identity,
      functionName: 'register',
      args: [
        encodeAgentUri({
          type: 'x',
          name: 'squatter',
          services: [{ name: 'x402', endpoint: unreachable }],
          x402Support: true,
        }),
      ],
    });
    const hostileAgent = await publicClient.readContract({ ...identity, functionName: 'totalAgents' });
    // Agent 2 of the attacker: no card at all.
    await write({ ...identity, functionName: 'register', args: [] });
    const cardlessAgent = await publicClient.readContract({ ...identity, functionName: 'totalAgents' });

    const request = (agentId: bigint, uri: string, requestHash: Hex) =>
      write({
        address: deployment.validationRegistry,
        abi: validationRegistryAbi,
        functionName: 'validationRequest',
        args: [validatorAddress, agentId, uri, requestHash],
      });
    const unreachableHash = randomBytes32();
    const ssrfHash = randomBytes32();
    const cardlessHash = randomBytes32();
    await request(hostileAgent, `${unreachable}/x`, unreachableHash);
    await request(hostileAgent, `${stack.facilitatorUrl}/healthz`, ssrfHash); // another host than the card's
    await request(cardlessAgent, `${stack.serverUrl}/validation/x`, cardlessHash);

    // Then a legitimate request, behind the hostile ones.
    const { url, body, payload } = await exactPayment({ text: 'validate me' });
    const paid = await sendPaid(url, body, payload);
    expect(paid.status).toBe(200);
    const receiptId = decodeSettlementResponse(paid.headers.get(PAYMENT_RESPONSE_HEADER)).extensions
      ?.receiptId;
    if (receiptId === undefined) throw new Error('no receipt id');
    const legitHash = await stack.server.requestValidation(receiptId, validatorAddress);

    const fetched: string[] = [];
    const spy: typeof fetch = (input, init) => {
      fetched.push(input instanceof Request ? input.url : String(input));
      return fetch(input, init);
    };
    const validator = new Validator(deployment, publicClient, stack.actors.validator.wallet, {
      fetch: spy,
      retryDelayMs: 0,
      maxAttempts: 2,
      fetchTimeoutMs: 3_000,
    });
    const byHash = (outcomes: Awaited<ReturnType<Validator['processPending']>>, hash: Hex) =>
      outcomes.find((o) => o.requestHash === hash);

    const first = await validator.processPending();
    expect(byHash(first, unreachableHash)).toMatchObject({ status: 'deferred', attempts: 1 });
    expect(byHash(first, ssrfHash)).toMatchObject({
      status: 'skipped',
      reason: 'request_uri_outside_agent_endpoint',
    });
    expect(byHash(first, cardlessHash)).toMatchObject({
      status: 'skipped',
      reason: 'agent_has_no_x402_endpoint',
    });
    expect(byHash(first, legitHash)).toMatchObject({ status: 'posted', score: 100, reason: 'reproduced' });
    expect(fetched.some((u) => u.startsWith(stack.facilitatorUrl))).toBe(false);

    // The deferred request is retried, then given up; nothing else is fetched or posted again.
    const second = await validator.processPending();
    expect(byHash(second, unreachableHash)).toMatchObject({
      status: 'skipped',
      reason: expect.stringMatching(/^gave_up:fetch_failed/) as unknown,
    });
    expect(byHash(second, legitHash)).toMatchObject({ status: 'skipped', reason: 'already_answered' });
    expect(fetched.filter((u) => u.startsWith(stack.serverUrl))).toHaveLength(1);
    // The cursor moved past every resolved request.
    expect(await validator.processPending()).toEqual([]);
  });
});
