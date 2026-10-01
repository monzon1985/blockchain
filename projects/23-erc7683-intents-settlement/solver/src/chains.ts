// SPDX-License-Identifier: MIT
// viem clients for the two chains.
import {
  type Account,
  type Chain,
  type Hex,
  type PublicClient,
  type Transport,
  type WalletClient,
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

/** A viem wallet client bound to one chain and one local account. */
export type Wallet = WalletClient<Transport, Chain, Account>;

/** A chain and a public client for it. */
export interface ChainClients {
  chain: Chain;
  public: PublicClient<Transport, Chain>;
}

/** viem chain definition for a chain served at `rpcUrl` (local anvils, or any endpoint). */
export function localChain(id: number, rpcUrl: string): Chain {
  return defineChain({
    id,
    name: `local-${id}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  });
}

/** Public client for chain `id` at `rpcUrl`, polling fast and never caching the block number. */
export function clientsFor(id: number, rpcUrl: string): ChainClients {
  const chain = localChain(id, rpcUrl);
  // Poll fast so receipts are seen promptly, and never serve a cached block number: a stale "latest" would make
  // proofs, cursors and headers refer to a block before the transaction we just waited for.
  return {
    chain,
    public: createPublicClient({ chain, transport: http(rpcUrl), pollingInterval: 100, cacheTime: 0 }),
  };
}

/** Wallet client signing locally with `privateKey` on `clients`' chain. */
export function walletFor(clients: ChainClients, privateKey: Hex): Wallet {
  return createWalletClient({
    account: privateKeyToAccount(privateKey),
    chain: clients.chain,
    transport: http(clients.chain.rpcUrls.default.http[0]),
  });
}

/** Timestamp of the latest block. */
export async function chainTime(clients: ChainClients): Promise<bigint> {
  const block = await clients.public.getBlock({ blockTag: "latest" });
  return block.timestamp;
}
