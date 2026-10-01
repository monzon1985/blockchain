// SPDX-License-Identifier: MIT
/**
 * The scripted end-to-end demo: discovery, an `exact` call from an EOA, a budget-bounded agent that runs until its
 * on-chain budget is exhausted, receipt-backed feedback signed by the smart account (ERC-7739 / ERC-1271), a
 * validation by re-execution, an escrowed job that is delivered, and an escrowed job that is refunded after an
 * outage. Used by `npm run demo` and asserted step by step in the e2e suite.
 */
import type { Address, Hex } from 'viem';
import {
  budgetExecutorAbi,
  paymentEscrowAbi,
  reputationRegistryAbi,
  testUsdAbi,
  validationRegistryAbi,
} from '../chain/abis.js';
import { EscrowStatus } from '../chain/ids.js';
import { Agent, type PaidResponse } from '../agent/agent.js';
import { discoverServices, type DiscoveredService } from '../agent/discovery.js';
import type { LogSink } from '../logging.js';
import { createLogger } from '../logging.js';
import { resultHash } from '../server/services.js';
import { Validator } from '../validator/validator.js';
import type { Stack } from './stack.js';

export const SENTIMENT_INPUTS: readonly { text: string }[] = [
  'Settlement was fast and the receipts are clear.',
  'The docs are confusing and the API is slow.',
  'Reliable, secure and cheap: not bad at all.',
  'Support never answered; the checkout is broken.',
  'Great latency, stable throughput, helpful errors.',
  'It works, I guess.',
  'Elegant design but the SDK is buggy.',
  'Best settlement flow I have used, safe and smooth.',
  'Useless dashboard, wrong totals, lost my session.',
  'Accurate numbers and robust retries.',
  'Not good, not terrible.',
  'Efficient batching, love the idempotency.',
  'Expensive gas but a clear audit trail.',
  'Fragile under load, then it failed.',
  'Happy with the budget limits.',
  'A clear win for agents.',
].map((text) => ({ text }));

/** Personal data deliberately placed in a paid request to prove the logs never contain it. */
export const DEMO_PII = { email: 'jane.doe@example.com', phone: '+34 612 345 678' } as const;

export interface DemoSummary {
  readonly service: DiscoveredService;
  readonly exactCall: PaidResponse;
  readonly budgetRun: { readonly calls: number; readonly spent: bigint; readonly stoppedBy: string };
  readonly budgetPolicy: { readonly periodBudget: bigint; readonly perCallCap: bigint };
  readonly windowSpent: bigint;
  readonly feedback: { readonly transaction: Hex; readonly count: bigint; readonly average: bigint };
  readonly validation: { readonly requestHash: Hex; readonly score: number };
  readonly escrowDelivered: {
    readonly escrowId: Hex;
    readonly resultHashMatchesChain: boolean;
    readonly status: number;
  };
  readonly escrowRefunded: {
    readonly escrowId: Hex;
    readonly status: number;
    readonly payerBalanceRestored: boolean;
  };
  readonly receiptsLogged: number;
}

async function balanceOf(stack: Stack, owner: Address): Promise<bigint> {
  return stack.publicClient.readContract({
    address: stack.deployment.testUSD,
    abi: testUsdAbi,
    functionName: 'balanceOf',
    args: [owner],
  });
}

async function escrowStatus(stack: Stack, escrowId: Hex): Promise<{ status: number; deliveryHash: Hex }> {
  const escrow = await stack.publicClient.readContract({
    address: stack.deployment.paymentEscrow,
    abi: paymentEscrowAbi,
    functionName: 'escrowOf',
    args: [escrowId],
  });
  return { status: escrow.status, deliveryHash: escrow.deliveryHash };
}

export async function runAgentDemo(stack: Stack, logSink?: LogSink): Promise<DemoSummary> {
  const logger = createLogger({ component: 'demo', ...(logSink === undefined ? {} : { sink: logSink }) });
  const { deployment, publicClient, actors } = stack;

  // 1. Discovery through the ERC-8004 identity registry.
  const services = await discoverServices(publicClient, deployment);
  const service = services.find((s) => s.agentId === stack.agentId);
  if (service === undefined) throw new Error('service not discovered');
  logger.info('discovered', { agentId: service.agentId, endpoint: service.endpoint, wallet: service.wallet });

  // 2. An EOA pays one `exact` call. The query string carries personal data on purpose: it is part of the paid
  //    resource (and of its hash) but must never reach a log line in clear text.
  const eoaAgent = new Agent({
    deployment,
    publicClient,
    payer: { kind: 'eoa', account: actors.eoaPayer.account },
    policy: { maxPricePerCall: 200_000n, schemes: ['exact', 'escrow'] },
    logger: logger.child('eoa-agent'),
  });
  const exactCall = await eoaAgent.call(
    service,
    `/api/v1/keywords?customer=${encodeURIComponent(DEMO_PII.email)}&phone=${encodeURIComponent(DEMO_PII.phone)}`,
    {
      text: 'x402 settles agent payments; agents pay per call and settlement receipts back reputation.',
      k: 3,
    },
  );

  // 3. The budget-bounded agent (holds only a session key) runs until the on-chain budget stops it.
  const agent = new Agent({
    deployment,
    publicClient,
    payer: { kind: 'smart-account', account: stack.smartAccount, sessionKey: actors.session },
    policy: { maxPricePerCall: 50_000n, schemes: ['budget-exec'] },
    logger: logger.child('agent'),
  });
  const run = await agent.runUntilBudgetExhausted(service, '/api/v1/sentiment', SENTIMENT_INPUTS);
  const spent = run.calls.reduce((sum, call) => sum + call.amount, 0n);
  const [windowSpent] = await publicClient.readContract({
    address: deployment.budgetExecutor,
    abi: budgetExecutorAbi,
    functionName: 'windowState',
    args: [stack.smartAccount],
  });
  logger.info('budget.run', { calls: run.calls.length, spent, stoppedBy: run.stoppedBy });

  // 4. Receipt-backed feedback: the smart account's owner signs (ERC-7739), a third party relays.
  const firstCall = run.calls[0];
  if (firstCall === undefined) throw new Error('agent made no call');
  const feedbackTx = await agent.leaveFeedback({
    agentId: service.agentId,
    receiptId: firstCall.settlement.id,
    score: 92,
    tag1: 'sentiment',
    endpoint: '/api/v1/sentiment',
    signer: actors.principal.account,
    relayer: actors.relayer.wallet,
  });
  const [count, average] = await publicClient.readContract({
    address: deployment.reputationRegistry,
    abi: reputationRegistryAbi,
    functionName: 'getSummary',
    args: [service.agentId, [stack.smartAccount], '', ''],
  });

  // 5. The service asks an independent validator to re-execute one paid call.
  const requestHash = await stack.server.requestValidation(
    firstCall.settlement.id,
    actors.validator.account.address,
  );
  const validator = new Validator(deployment, publicClient, actors.validator.wallet, {
    logger: logger.child('validator'),
  });
  const outcomes = await validator.processPending();
  const validation = outcomes.find((o) => o.requestHash === requestHash);
  if (validation?.status !== 'posted') throw new Error('validation not processed');
  const [, , score] = await publicClient.readContract({
    address: deployment.validationRegistry,
    abi: validationRegistryAbi,
    functionName: 'getValidationStatus',
    args: [service.agentId, requestHash],
  });

  // 6. Escrowed job, delivered: 202 now, result later; the delivery hash on-chain matches the result.
  const report = await eoaAgent.call<{ escrowId: Hex; accessToken: string }>(service, '/api/v1/reports', {
    items: ['invoice-001', 'invoice-002', 'invoice-003'],
  });
  await stack.server.flushDeliveries();
  // The result is only served to the holder of the access token returned with the 202.
  const jobResponse = await fetch(`${service.endpoint}/api/v1/reports/${report.body.escrowId}`, {
    headers: { authorization: `Bearer ${report.body.accessToken}` },
  });
  const job = (await jobResponse.json()) as { result: unknown };
  const delivered = await escrowStatus(stack, report.body.escrowId);

  // 7. Escrowed job during an outage: nothing is delivered, the payer reclaims the funds after the deadline.
  stack.server.pauseDeliveries(true);
  const before = await balanceOf(stack, actors.eoaPayer.account.address);
  const stalled = await eoaAgent.call<{ escrowId: Hex }>(service, '/api/v1/reports', { items: ['batch-7'] });
  const deadline = (
    await publicClient.readContract({
      address: deployment.paymentEscrow,
      abi: paymentEscrowAbi,
      functionName: 'escrowOf',
      args: [stalled.body.escrowId],
    })
  ).deadline;
  const nowTs = (await publicClient.getBlock()).timestamp;
  await stack.advanceTime(Number(deadline - nowTs) + 1);
  await eoaAgent.refundEscrow(stalled.body.escrowId, actors.eoaPayer.wallet);
  const after = await balanceOf(stack, actors.eoaPayer.account.address);
  const refunded = await escrowStatus(stack, stalled.body.escrowId);
  stack.server.pauseDeliveries(false);

  return {
    service,
    exactCall,
    budgetRun: { calls: run.calls.length, spent, stoppedBy: run.stoppedBy },
    budgetPolicy: { periodBudget: stack.policy.periodBudget, perCallCap: stack.policy.perCallCap },
    windowSpent,
    feedback: { transaction: feedbackTx, count, average },
    validation: { requestHash, score },
    escrowDelivered: {
      escrowId: report.body.escrowId,
      resultHashMatchesChain: resultHash(job.result) === delivered.deliveryHash,
      status: delivered.status,
    },
    escrowRefunded: {
      escrowId: stalled.body.escrowId,
      status: refunded.status,
      payerBalanceRestored: after === before && refunded.status === EscrowStatus.Refunded,
    },
    receiptsLogged: eoaAgent.receipts.length + agent.receipts.length,
  };
}
