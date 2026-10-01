// SPDX-License-Identifier: MIT
/**
 * Boots the whole local marketplace in one process: anvil, contracts (forge script), facilitator and resource
 * server (both Hono apps on OS-assigned ports), the service's ERC-8004 identity, and funded actors. Every private
 * key is generated at start-up and lives only in memory; no fixed dev keys are used.
 */
import type { AddressInfo } from 'node:net';
import { serve } from '@hono/node-server';
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  encodeAbiParameters,
  http,
  parseEther,
  zeroHash,
  type Address,
  type Chain,
  type Hex,
  type LocalAccount,
  type PublicClient,
  type TestClient,
  type Transport,
} from 'viem';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';
import { anvil as anvilChain } from 'viem/chains';
import { agentAccountFactoryAbi, identityRegistryAbi, testUsdAbi } from '../chain/abis.js';
import type { Deployment } from '../chain/deployment.js';
import { createChainReader, type RelayerClient } from '../chain/reader.js';
import { createChainWriter } from '../chain/settlement.js';
import { identityDomain, setAgentWalletTypes } from '../chain/typedData.js';
import {
  Facilitator,
  createFacilitatorApp,
  httpFacilitatorClient,
  type FacilitatorClient,
} from '../facilitator/facilitator.js';
import { createLogger, type LogSink } from '../logging.js';
import { ResourceServer } from '../server/resourceServer.js';
import { encodeAgentUri } from '../agent/discovery.js';
import { deployContracts, startAnvil, type Anvil } from './localnet.js';

/** Budget policy installed on the agent's smart account (tUSD has 6 decimals). */
export interface BudgetPolicyConfig {
  readonly perCallCap: bigint;
  readonly periodBudget: bigint;
  readonly periodSeconds: number;
  readonly maxPaymentsPerPeriod: number;
  readonly sessionLifetimeSeconds: number;
}

export const DEFAULT_POLICY: BudgetPolicyConfig = {
  perCallCap: 50_000n, // 0.05 tUSD
  periodBudget: 100_000n, // 0.10 tUSD per hour
  periodSeconds: 3_600,
  maxPaymentsPerPeriod: 16,
  sessionLifetimeSeconds: 7 * 86_400,
};

export interface Actor {
  readonly account: LocalAccount;
  readonly wallet: RelayerClient;
}

export interface Stack {
  readonly anvil: Anvil;
  readonly deployment: Deployment;
  readonly publicClient: PublicClient<Transport, Chain>;
  readonly testClient: TestClient;
  readonly facilitator: Facilitator;
  readonly facilitatorUrl: string;
  readonly facilitatorClient: FacilitatorClient;
  readonly server: ResourceServer;
  readonly serverUrl: string;
  readonly agentId: bigint;
  readonly actors: {
    readonly relayer: Actor;
    readonly operator: Actor;
    readonly treasury: Actor;
    readonly validator: Actor;
    readonly principal: Actor;
    readonly eoaPayer: Actor;
    readonly session: LocalAccount;
  };
  readonly smartAccount: Address;
  readonly policy: BudgetPolicyConfig;
  /** Mints tUSD from the (unlocked) deployer. */
  mint(to: Address, amount: bigint): Promise<void>;
  /** Advances chain time and mines a block. */
  advanceTime(seconds: number): Promise<void>;
  stop(): Promise<void>;
}

export interface StackOptions {
  readonly policy?: BudgetPolicyConfig;
  readonly logSink?: LogSink;
  /** Initial tUSD of the EOA payer and of the smart account. */
  readonly funding?: bigint;
  readonly deploymentName?: string;
  readonly deliveryDelayMs?: number;
}

function listen(
  fetchHandler: (request: Request) => Response | Promise<Response>,
): Promise<{ url: string; close: () => Promise<void> }> {
  return new Promise((resolve) => {
    const server = serve({ fetch: fetchHandler, port: 0, hostname: '127.0.0.1' }, (info: AddressInfo) => {
      resolve({
        url: `http://127.0.0.1:${info.port}`,
        close: () =>
          new Promise<void>((done) => {
            server.close(() => {
              done();
            });
          }),
      });
    });
  });
}

export async function startStack(options: StackOptions = {}): Promise<Stack> {
  const policy = options.policy ?? DEFAULT_POLICY;
  const funding = options.funding ?? 10_000_000n; // 10 tUSD
  const anvil = await startAnvil();
  const closers: (() => Promise<void>)[] = [() => anvil.stop()];
  try {
    const transport = http(anvil.rpcUrl);
    const chain: Chain = { ...anvilChain, rpcUrls: { default: { http: [anvil.rpcUrl] } } };
    const publicClient = createPublicClient({ chain, transport, pollingInterval: 50 });
    const testClient = createTestClient({ chain, transport, mode: 'anvil' });

    const [deployer] = await createWalletClient({ chain, transport }).getAddresses();
    if (deployer === undefined) throw new Error('anvil exposes no unlocked account');
    const deployment = await deployContracts(
      anvil.rpcUrl,
      deployer,
      options.deploymentName ?? `stack-${anvil.port}`,
    );
    const deployerWallet = createWalletClient({ chain, transport, account: deployer });

    const makeActor = async (): Promise<Actor> => {
      const account = privateKeyToAccount(generatePrivateKey());
      await testClient.setBalance({ address: account.address, value: parseEther('100') });
      return { account, wallet: createWalletClient({ chain, transport, account }) };
    };
    const [relayer, operator, treasury, validator, principal, eoaPayer] = (await Promise.all(
      Array.from({ length: 6 }, makeActor),
    )) as [Actor, Actor, Actor, Actor, Actor, Actor];
    const session = privateKeyToAccount(generatePrivateKey());

    const logger = createLogger({
      component: 'stack',
      ...(options.logSink === undefined ? {} : { sink: options.logSink }),
    });

    const mint = async (to: Address, amount: bigint): Promise<void> => {
      const hash = await deployerWallet.writeContract({
        address: deployment.testUSD,
        abi: testUsdAbi,
        functionName: 'mint',
        args: [to, amount],
      });
      await publicClient.waitForTransactionReceipt({ hash });
    };

    // Agent smart account: owner = principal, session key = agent process, payee allowlist = the service wallet.
    const latest = await publicClient.getBlock();
    const policyInit = encodeAbiParameters(
      [
        {
          type: 'tuple',
          components: [
            { name: 'sessionKey', type: 'address' },
            { name: 'validUntil', type: 'uint48' },
            { name: 'period', type: 'uint32' },
            { name: 'maxPaymentsPerPeriod', type: 'uint16' },
            { name: 'perCallCap', type: 'uint128' },
            { name: 'periodBudget', type: 'uint128' },
          ],
        },
        { type: 'address[]' },
      ],
      [
        {
          sessionKey: session.address,
          validUntil: Number(latest.timestamp) + policy.sessionLifetimeSeconds,
          period: policy.periodSeconds,
          maxPaymentsPerPeriod: policy.maxPaymentsPerPeriod,
          perCallCap: policy.perCallCap,
          periodBudget: policy.periodBudget,
        },
        [treasury.account.address],
      ],
    );
    const factory = { address: deployment.accountFactory, abi: agentAccountFactoryAbi } as const;
    const smartAccount = await publicClient.readContract({
      ...factory,
      functionName: 'predictAccount',
      args: [principal.account.address, policyInit, zeroHash],
    });
    const createHash = await principal.wallet.writeContract({
      ...factory,
      functionName: 'createAccount',
      args: [principal.account.address, policyInit, zeroHash],
    });
    await publicClient.waitForTransactionReceipt({ hash: createHash });
    await mint(smartAccount, funding);
    await mint(eoaPayer.account.address, funding);

    // Facilitator (untrusted relayer) and resource server, each on its own OS-assigned port.
    const facilitator = new Facilitator({
      deployment,
      reader: createChainReader(publicClient, deployment, relayer.account.address),
      writer: createChainWriter(publicClient, relayer.wallet, deployment),
      logger: logger.child('facilitator'),
    });
    const facilitatorHttp = await listen(createFacilitatorApp(facilitator).fetch);
    closers.push(facilitatorHttp.close);
    const facilitatorClient = httpFacilitatorClient(facilitatorHttp.url);

    const server = new ResourceServer({
      deployment,
      facilitator: facilitatorClient,
      publicClient,
      treasury: treasury.wallet,
      operator: operator.wallet,
      logger: logger.child('server'),
      ...(options.deliveryDelayMs === undefined ? {} : { deliveryDelayMs: options.deliveryDelayMs }),
    });
    const serverHttp = await listen(server.app.fetch);
    closers.push(async () => {
      await server.flushDeliveries();
      await serverHttp.close();
    });
    server.setPublicUrl(serverHttp.url);

    // ERC-8004 identity: register, prove the treasury wallet, publish the card with its agent id.
    const identity = { address: deployment.identityRegistry, abi: identityRegistryAbi } as const;
    const registerHash = await operator.wallet.writeContract({
      ...identity,
      functionName: 'register',
      args: [''],
    });
    await publicClient.waitForTransactionReceipt({ hash: registerHash });
    const agentId = await publicClient.readContract({ ...identity, functionName: 'totalAgents' });
    server.setAgentId(agentId);
    const walletDeadline = (await publicClient.getBlock()).timestamp + 3_600n;
    const walletNonce = await publicClient.readContract({
      ...identity,
      functionName: 'nonces',
      args: [treasury.account.address],
    });
    const walletSignature: Hex = await treasury.account.signTypedData({
      domain: identityDomain(deployment),
      types: setAgentWalletTypes,
      primaryType: 'SetAgentWallet',
      message: {
        agentId,
        newWallet: treasury.account.address,
        owner: operator.account.address,
        nonce: walletNonce,
        deadline: walletDeadline,
      },
    });
    const walletHash = await operator.wallet.writeContract({
      ...identity,
      functionName: 'setAgentWallet',
      args: [agentId, treasury.account.address, walletDeadline, walletSignature],
    });
    await publicClient.waitForTransactionReceipt({ hash: walletHash });
    const uriHash = await operator.wallet.writeContract({
      ...identity,
      functionName: 'setAgentURI',
      args: [agentId, encodeAgentUri(server.agentCard())],
    });
    await publicClient.waitForTransactionReceipt({ hash: uriHash });

    return {
      anvil,
      deployment,
      publicClient,
      testClient,
      facilitator,
      facilitatorUrl: facilitatorHttp.url,
      facilitatorClient,
      server,
      serverUrl: serverHttp.url,
      agentId,
      actors: { relayer, operator, treasury, validator, principal, eoaPayer, session },
      smartAccount,
      policy,
      mint,
      async advanceTime(seconds) {
        await testClient.increaseTime({ seconds });
        await testClient.mine({ blocks: 1 });
      },
      async stop() {
        for (const close of closers.reverse()) await close();
      },
    };
  } catch (error) {
    for (const close of closers.reverse()) await close();
    throw error;
  }
}
