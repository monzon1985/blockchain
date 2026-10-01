// SPDX-License-Identifier: MIT
/**
 * Full-stack e2e: anvil on a random port, contracts deployed with `forge script`, facilitator and resource server
 * served in-process on random ports, and the scripted agent demo run against them.
 */
import { keccak256, zeroHash, type Hex, type LocalAccount } from 'viem';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { Agent, BudgetExhaustedError, PaymentRefusedError } from '../src/agent/agent.js';
import { discoverServices, type DiscoveredService } from '../src/agent/discovery.js';
import { budgetExecutorAbi, reputationRegistryAbi, settlementLogAbi, testUsdAbi } from '../src/chain/abis.js';
import { EscrowStatus, ReceiptScheme } from '../src/chain/ids.js';
import { runAgentDemo, type DemoSummary } from '../src/demo/scenario.js';
import { startStack, type Stack } from '../src/demo/stack.js';
import { sentiment } from '../src/server/services.js';
import {
  VALIDATOR_EXPIRES_HEADER,
  VALIDATOR_SIGNATURE_HEADER,
  validationAccessMessage,
} from '../src/validator/access.js';
import { Validator } from '../src/validator/validator.js';
import { PAYMENT_REQUIRED_HEADER, decodePaymentRequired } from '../src/x402/codec.js';

let stack: Stack;
let summary: DemoSummary;
const logs: string[] = [];

beforeAll(async () => {
  stack = await startStack({ logSink: (line) => logs.push(line) });
  summary = await runAgentDemo(stack, (line) => logs.push(line));
});

afterAll(async () => {
  await stack.stop();
});

const balanceOf = (address: Hex): Promise<bigint> =>
  stack.publicClient.readContract({
    address: stack.deployment.testUSD,
    abi: testUsdAbi,
    functionName: 'balanceOf',
    args: [address],
  });

describe('HTTP 402 challenge', () => {
  it('answers an unpaid request with 402 and a base64 PAYMENT-REQUIRED header', async () => {
    const url = `${stack.serverUrl}/api/v1/sentiment`;
    const response = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ text: 'hello' }),
    });
    expect(response.status).toBe(402);
    const challenge = decodePaymentRequired(response.headers.get(PAYMENT_REQUIRED_HEADER));
    expect(challenge.x402Version).toBe(2);
    expect(challenge.resource.url).toBe(url);
    expect(challenge.accepts.map((a) => a.scheme)).toEqual(['exact', 'budget-exec']);
    for (const requirement of challenge.accepts) {
      expect(requirement).toMatchObject({
        network: 'eip155:31337',
        asset: stack.deployment.testUSD,
        amount: '10000',
        payTo: stack.server.payTo,
        maxTimeoutSeconds: 120,
      });
    }
  });

  it('rejects invalid input with 400 before asking for money', async () => {
    const response = await fetch(`${stack.serverUrl}/api/v1/sentiment`, {
      method: 'POST',
      body: JSON.stringify({ text: '' }),
    });
    expect(response.status).toBe(400);
    expect(response.headers.get(PAYMENT_REQUIRED_HEADER)).toBeNull();
  });

  it('rejects a malformed PAYMENT-SIGNATURE header with 400', async () => {
    const response = await fetch(`${stack.serverUrl}/api/v1/sentiment`, {
      method: 'POST',
      headers: { 'PAYMENT-SIGNATURE': 'not base64!' },
      body: JSON.stringify({ text: 'hello' }),
    });
    expect(response.status).toBe(400);
  });
});

describe('agent demo', () => {
  it('discovers the service through the ERC-8004 identity registry', () => {
    expect(summary.service.agentId).toBe(stack.agentId);
    expect(summary.service.wallet).toBe(stack.server.payTo);
    expect(summary.service.endpoint).toBe(stack.serverUrl);
    expect(summary.service.card.x402Support).toBe(true);
  });

  it('pays an exact call from an EOA and gets an on-chain receipt', async () => {
    expect(summary.exactCall.status).toBe(200);
    expect(summary.exactCall.scheme).toBe('exact');
    const receipt = await stack.publicClient.readContract({
      address: stack.deployment.settlementLog,
      abi: settlementLogAbi,
      functionName: 'receiptOf',
      args: [summary.exactCall.settlement.id],
    });
    expect(receipt).toMatchObject({
      payer: stack.actors.eoaPayer.account.address,
      payee: stack.server.payTo,
      amount: 25_000n,
      scheme: ReceiptScheme.Exact,
    });
    expect(summary.exactCall.body).toMatchObject({ keywords: expect.any(Array) as unknown });
  });

  it('stops the budget-bounded agent cleanly at the on-chain budget', () => {
    // 0.10 tUSD per hour at 0.01 tUSD per call: exactly ten calls, then a clean stop.
    expect(summary.budgetRun).toEqual({ calls: 10, spent: 100_000n, stoppedBy: 'budget_exhausted' });
    expect(summary.windowSpent).toBe(summary.budgetPolicy.periodBudget);
    expect(summary.budgetRun.spent).toBeLessThanOrEqual(summary.budgetPolicy.periodBudget);
  });

  it('records receipt-backed feedback signed by the smart account (ERC-7739 via ERC-1271)', () => {
    expect(summary.feedback.count).toBe(1n);
    expect(summary.feedback.average).toBe(92n * 10n ** 18n);
  });

  it('validates a paid call by re-execution', () => {
    expect(summary.validation.score).toBe(100);
  });

  it('delivers an escrowed job whose result hash matches the on-chain delivery hash', () => {
    expect(summary.escrowDelivered.status).toBe(EscrowStatus.Released);
    expect(summary.escrowDelivered.resultHashMatchesChain).toBe(true);
  });

  it('serves an escrowed result only to the holder of its access token', async () => {
    const url = `${stack.serverUrl}/api/v1/reports/${summary.escrowDelivered.escrowId}`;
    // The escrow id is public (EscrowOpened is indexed), so knowing it must not be enough.
    expect((await fetch(url)).status).toBe(401);
    expect((await fetch(url, { headers: { authorization: 'Bearer not-the-token' } })).status).toBe(401);
    expect((await fetch(`${stack.serverUrl}/api/v1/reports/0x${'00'.repeat(32)}`)).status).toBe(404);
  });

  it('refunds an escrowed job the server never delivered', () => {
    expect(summary.escrowRefunded.status).toBe(EscrowStatus.Refunded);
    expect(summary.escrowRefunded.payerBalanceRestored).toBe(true);
  });

  it('logs every receipt without leaking PII', () => {
    // 1 exact + 10 budget-exec + 2 escrow openings.
    expect(summary.receiptsLogged).toBe(13);
    const receiptLines = logs.filter((line) => line.includes('"event":"receipt"'));
    expect(receiptLines).toHaveLength(13);
    // The exact call's URL carried an e-mail and a phone number in its query string.
    expect(logs.some((line) => line.includes('customer=[redacted]'))).toBe(true);
    for (const line of logs) {
      expect(line).not.toMatch(/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}/);
      expect(line).not.toContain('jane.doe');
      expect(line).not.toContain('612 345 678');
      expect(line).not.toContain('612%20345%20678');
    }
  });
});

describe('budget window and reputation rules on the live chain', () => {
  let service: DiscoveredService;
  let agent: Agent;

  beforeAll(async () => {
    [service] = (await discoverServices(stack.publicClient, stack.deployment)) as [DiscoveredService];
    agent = new Agent({
      deployment: stack.deployment,
      publicClient: stack.publicClient,
      payer: { kind: 'smart-account', account: stack.smartAccount, sessionKey: stack.actors.session },
      policy: { maxPricePerCall: 50_000n, schemes: ['budget-exec'] },
    });
  });

  it('keeps refusing while the window is full, then renews after the period', async () => {
    await expect(agent.call(service, '/api/v1/sentiment', { text: 'again' })).rejects.toBeInstanceOf(
      BudgetExhaustedError,
    );
    await stack.advanceTime(stack.policy.periodSeconds);
    const paid = await agent.call(service, '/api/v1/sentiment', { text: 'fresh window' });
    expect(paid.status).toBe(200);
    const [spent, count] = await stack.publicClient.readContract({
      address: stack.deployment.budgetExecutor,
      abi: budgetExecutorAbi,
      functionName: 'windowState',
      args: [stack.smartAccount],
    });
    expect({ spent, count }).toEqual({ spent: 10_000n, count: 1n });
  });

  it('refuses to pay a price above the client-side cap, before signing anything', async () => {
    const stingy = new Agent({
      deployment: stack.deployment,
      publicClient: stack.publicClient,
      payer: { kind: 'smart-account', account: stack.smartAccount, sessionKey: stack.actors.session },
      policy: { maxPricePerCall: 20_000n, schemes: ['budget-exec'] },
    });
    const before = await balanceOf(stack.smartAccount);
    await expect(stingy.call(service, '/api/v1/keywords', { text: 'too expensive' })).rejects.toEqual(
      new PaymentRefusedError('price_above_client_cap'),
    );
    expect(await balanceOf(stack.smartAccount)).toBe(before);
  });

  it('rejects feedback from the service owner and feedback without a receipt', async () => {
    const operator = stack.actors.operator;
    const feedback = {
      agentId: stack.agentId,
      value: 100n,
      valueDecimals: 0,
      tag1: '',
      tag2: '',
      endpoint: '',
      feedbackURI: '',
      feedbackHash: zeroHash,
      receiptId: summary.exactCall.settlement.id,
    };
    await expect(
      stack.publicClient.simulateContract({
        account: operator.account,
        address: stack.deployment.reputationRegistry,
        abi: reputationRegistryAbi,
        functionName: 'giveFeedback',
        args: [feedback],
      }),
    ).rejects.toThrow(/SelfFeedback/);
    await expect(
      stack.publicClient.simulateContract({
        account: stack.actors.relayer.account,
        address: stack.deployment.reputationRegistry,
        abi: reputationRegistryAbi,
        functionName: 'giveFeedback',
        args: [{ ...feedback, receiptId: `0x${'ee'.repeat(32)}` }],
      }),
    ).rejects.toThrow(/UnknownReceipt/);
    // The EOA payer's real receipt works exactly once.
    const hash = await stack.actors.eoaPayer.wallet.writeContract({
      address: stack.deployment.reputationRegistry,
      abi: reputationRegistryAbi,
      functionName: 'giveFeedback',
      args: [feedback],
    });
    await stack.publicClient.waitForTransactionReceipt({ hash });
    await expect(
      stack.publicClient.simulateContract({
        account: stack.actors.eoaPayer.account,
        address: stack.deployment.reputationRegistry,
        abi: reputationRegistryAbi,
        functionName: 'giveFeedback',
        args: [feedback],
      }),
    ).rejects.toThrow(/ReceiptAlreadyUsed/);
  });
});

describe('validation is tied to the payment it claims to validate', () => {
  let service: DiscoveredService;
  let eoaAgent: Agent;
  let validator: Validator;

  beforeAll(async () => {
    [service] = (await discoverServices(stack.publicClient, stack.deployment)) as [DiscoveredService];
    eoaAgent = new Agent({
      deployment: stack.deployment,
      publicClient: stack.publicClient,
      payer: { kind: 'eoa', account: stack.actors.eoaPayer.account },
      policy: { maxPricePerCall: 50_000n, schemes: ['exact'] },
    });
    validator = new Validator(stack.deployment, stack.publicClient, stack.actors.validator.wallet);
  });

  const paidCall = (text: string) =>
    eoaAgent.call<Record<string, unknown>>(service, '/api/v1/sentiment', { text });

  async function validate(receiptId: Hex) {
    const requestHash = await stack.server.requestValidation(
      receiptId,
      stack.actors.validator.account.address,
    );
    return (await validator.processPending()).find((o) => o.requestHash === requestHash);
  }

  it('scores a dishonest server below 100 when its recorded output was tampered with', async () => {
    const paid = await paidCall('fast and secure');
    stack.server.tamperWorkRecord(paid.settlement.id, {
      output: { ...paid.body, label: 'negative', scoreBps: -10_000 },
    });
    expect(await validate(paid.settlement.id)).toMatchObject({
      status: 'posted',
      score: 60,
      reason: 'output_differs',
    });
  });

  it('scores 0 when the server fabricates both input and output for a real receipt', async () => {
    const paid = await paidCall('fast and secure');
    const fabricated = { text: 'slow and broken' };
    stack.server.tamperWorkRecord(paid.settlement.id, {
      body: JSON.stringify(fabricated),
      output: sentiment(fabricated),
    });
    expect(await validate(paid.settlement.id)).toMatchObject({
      status: 'posted',
      score: 0,
      reason: 'receipt_for_another_request',
    });
  });

  it('scores 0 for work tied to a receipt that does not exist on-chain', async () => {
    const paid = await paidCall('reliable and clear');
    stack.server.tamperWorkRecord(paid.settlement.id, { receiptId: `0x${'ab'.repeat(32)}` });
    expect(await validate(paid.settlement.id)).toMatchObject({
      status: 'posted',
      score: 0,
      reason: 'unknown_receipt',
    });
  });

  it('serves a work document only to the validator named on-chain', async () => {
    const paid = await paidCall('helpful and stable');
    const requestHash = await stack.server.requestValidation(
      paid.settlement.id,
      stack.actors.validator.account.address,
    );
    const url = `${stack.serverUrl}/validation/${requestHash}`;
    const nowSeconds = Math.floor(Date.now() / 1000);
    const get = async (signer: LocalAccount | null, expires: number) => {
      const headers: Record<string, string> = { [VALIDATOR_EXPIRES_HEADER]: String(expires) };
      if (signer !== null) {
        headers[VALIDATOR_SIGNATURE_HEADER] = await signer.signMessage({
          message: validationAccessMessage(requestHash, expires),
        });
      }
      return fetch(url, { headers });
    };
    expect((await fetch(url)).status).toBe(401);
    expect((await get(null, nowSeconds + 60)).status).toBe(401);
    expect((await get(stack.actors.relayer.account, nowSeconds + 60)).status).toBe(401);
    expect((await get(stack.actors.validator.account, nowSeconds - 1)).status).toBe(401);
    expect((await get(stack.actors.validator.account, nowSeconds + 3_600)).status).toBe(401);
    const ok = await get(stack.actors.validator.account, nowSeconds + 60);
    expect(ok.status).toBe(200);
    expect(keccak256(new Uint8Array(await ok.arrayBuffer()))).toBe(requestHash);
    expect((await fetch(`${stack.serverUrl}/validation/0x${'00'.repeat(32)}`)).status).toBe(404);
    expect((await validator.processPending()).find((o) => o.requestHash === requestHash)).toMatchObject({
      status: 'posted',
      score: 100,
    });
  });
});
