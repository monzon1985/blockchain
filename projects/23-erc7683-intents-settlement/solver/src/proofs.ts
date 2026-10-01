// SPDX-License-Identifier: MIT
// eth_getProof plumbing for settlement modes 2 (fraud proofs) and 3 (fill proofs), and HeaderStore lookups.
import type { Address, Hex } from "viem";

import { headerStoreAbi } from "./abi.ts";
import type { ChainClients } from "./chains.ts";
import { fillerSlot } from "./orders.ts";

/** A destination header stored in the origin HeaderStore. */
export interface StoredHeader {
  blockNumber: bigint;
  /** Block timestamp (destination chain seconds). */
  timestamp: bigint;
  blockHash: Hex;
}

/** Every header of `chainId` stored in the HeaderStore, from its HeaderStored events (relayed or imported). */
export async function storedHeaders(
  origin: ChainClients,
  headerStore: Address,
  chainId: bigint,
): Promise<StoredHeader[]> {
  const logs = await origin.public.getContractEvents({
    address: headerStore,
    abi: headerStoreAbi,
    eventName: "HeaderStored",
    args: { chainId },
    fromBlock: 0n,
    toBlock: "latest",
  });
  return logs.map((log) => ({
    blockNumber: log.args.blockNumber ?? 0n,
    timestamp: BigInt(log.args.timestamp ?? 0),
    blockHash: log.args.blockHash ?? "0x",
  }));
}

/**
 * Stored headers of `chainId` at or after `minBlock` whose timestamp is strictly after `afterTimestamp`, NEWEST
 * first. Newest first on purpose: anyone can import old ancestors through `HeaderStore.submitAncestor`, down to
 * blocks where the settler did not exist yet or that a non-archive node no longer has state for, so the oldest
 * matching header is the one an attacker controls. The newest one is recent state every node can prove.
 */
export async function storedHeadersNewestFirst(
  origin: ChainClients,
  headerStore: Address,
  chainId: bigint,
  minBlock = 0n,
  afterTimestamp = -1n,
): Promise<StoredHeader[]> {
  return (await storedHeaders(origin, headerStore, chainId))
    .filter((h) => h.blockNumber >= minBlock && h.timestamp > afterTimestamp)
    .sort((a, b) => (a.blockNumber > b.blockNumber ? -1 : a.blockNumber < b.blockNumber ? 1 : 0));
}

/** Newest stored header of `chainId` at or after `minBlock` with a timestamp after `afterTimestamp`, if any. */
export async function findStoredHeader(
  origin: ChainClients,
  headerStore: Address,
  chainId: bigint,
  minBlock: bigint,
  afterTimestamp = -1n,
): Promise<StoredHeader | undefined> {
  return (await storedHeadersNewestFirst(origin, headerStore, chainId, minBlock, afterTimestamp))[0];
}

/** Account proof and first-record-slot proof of one order, from eth_getProof. */
export interface FillRecordProof {
  accountProof: Hex[];
  slotProof: Hex[];
  slotValue: bigint;
  storageHash: Hex;
}

/** Account and storage proof of `orderId`'s first FillRecord slot at `blockNumber` on the destination chain. */
export async function fillRecordProof(
  dest: ChainClients,
  settler: Address,
  orderId: Hex,
  blockNumber: bigint,
): Promise<FillRecordProof> {
  const proof = await dest.public.getProof({ address: settler, storageKeys: [fillerSlot(orderId)], blockNumber });
  const storage = proof.storageProof[0];
  if (storage === undefined) throw new Error("eth_getProof returned no storage proof");
  return {
    accountProof: proof.accountProof,
    slotProof: storage.proof,
    slotValue: storage.value,
    storageHash: proof.storageHash,
  };
}
