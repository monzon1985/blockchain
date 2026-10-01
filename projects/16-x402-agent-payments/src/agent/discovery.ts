// SPDX-License-Identifier: MIT
/**
 * Service discovery through the ERC-8004 identity registry: enumerate agents, decode their registration files
 * (`data:` URIs on the local stack), keep those that advertise an x402 endpoint, and pair each with its on-chain
 * verified payment address (`agentWallet`). The agent later refuses to pay any `payTo` other than that address.
 */
import type { Address, Chain, PublicClient, Transport } from 'viem';
import { z } from 'zod';
import { identityRegistryAbi } from '../chain/abis.js';
import type { Deployment } from '../chain/deployment.js';

export const agentCardSchema = z.object({
  type: z.string(),
  name: z.string().max(128),
  description: z.string().max(1024).optional(),
  services: z
    .array(z.object({ name: z.string(), endpoint: z.string(), version: z.string().optional() }))
    .max(16),
  x402Support: z.boolean().optional(),
  active: z.boolean().optional(),
  supportedTrust: z.array(z.string()).optional(),
});
export type AgentCard = z.infer<typeof agentCardSchema>;

export interface DiscoveredService {
  readonly agentId: bigint;
  readonly owner: Address;
  /** Verified payment address from the registry (zero if unset: such services are skipped). */
  readonly wallet: Address;
  readonly card: AgentCard;
  readonly endpoint: string;
}

const DATA_JSON_PREFIX = 'data:application/json;base64,';

/** Decodes a `data:application/json;base64,` agent URI. Other schemes (ipfs, https) are out of scope offline. */
export function decodeAgentUri(uri: string): AgentCard | null {
  if (!uri.startsWith(DATA_JSON_PREFIX)) return null;
  try {
    const parsed = agentCardSchema.safeParse(
      JSON.parse(Buffer.from(uri.slice(DATA_JSON_PREFIX.length), 'base64').toString('utf8')),
    );
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}

export function encodeAgentUri(card: Record<string, unknown>): string {
  return `${DATA_JSON_PREFIX}${Buffer.from(JSON.stringify(card), 'utf8').toString('base64')}`;
}

export async function discoverServices(
  publicClient: PublicClient<Transport, Chain>,
  deployment: Deployment,
): Promise<DiscoveredService[]> {
  const registry = { address: deployment.identityRegistry, abi: identityRegistryAbi } as const;
  const total = await publicClient.readContract({ ...registry, functionName: 'totalAgents' });
  const services: DiscoveredService[] = [];
  for (let agentId = 1n; agentId <= total; agentId++) {
    const [owner, uri, wallet] = await Promise.all([
      publicClient.readContract({ ...registry, functionName: 'ownerOf', args: [agentId] }),
      publicClient.readContract({ ...registry, functionName: 'tokenURI', args: [agentId] }),
      publicClient.readContract({ ...registry, functionName: 'getAgentWallet', args: [agentId] }),
    ]);
    const card = decodeAgentUri(uri);
    if (card === null || card.x402Support !== true || card.active === false) continue;
    if (wallet === '0x0000000000000000000000000000000000000000') continue;
    const x402 = card.services.find((s) => s.name === 'x402');
    if (x402 === undefined) continue;
    services.push({ agentId, owner, wallet, card, endpoint: x402.endpoint });
  }
  return services;
}
