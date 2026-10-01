// SPDX-License-Identifier: MIT
// User and adversary actions against a Localnet, shared by the e2e suite and capture-proofs.
import { type Address, type Hex, encodeFunctionData, erc20Abi, keccak256, maxUint256, toHex, zeroAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import {
  destinationSettlerAbi,
  headerStoreAbi,
  mockErc20Abi,
  optimisticSettlementModuleAbi,
  originSettlerAbi,
} from "../src/abi.ts";
import { chainTime, walletFor } from "../src/chains.ts";
import {
  type GaslessCrossChainOrder,
  INTENT_ORDER_DATA_TYPEHASH,
  type IntentOrderData,
  encodeOrderData,
  encodeOriginData,
  gaslessIntent,
  onchainIntent,
  orderIdOf,
  permit2TypedData,
} from "../src/orders.ts";
import { type RpcBlock, encodeVerifiedHeader } from "../src/header.ts";
import { fillRecordProof, storedHeaders } from "../src/proofs.ts";
import { sendAndWait } from "../src/tx.ts";
import type { Actor, Localnet } from "./localnet.ts";

export type Mode = "mailbox" | "optimistic" | "proof";

export interface OrderTerms {
  mode: Mode;
  inputAmount: bigint;
  outputStart: bigint;
  outputEnd: bigint;
  recipient: Address;
  /** Seconds from now until the fill deadline. */
  fillWindow: bigint;
  /** Seconds from now until exclusivity ends and the decay starts. */
  exclusivityWindow?: bigint;
  exclusiveFiller?: Address;
}

export function moduleFor(net: Localnet, mode: Mode): Address {
  const o = net.deployment.origin;
  return mode === "mailbox" ? o.mailboxModule : mode === "optimistic" ? o.optimisticModule : o.proofModule;
}

export async function orderData(net: Localnet, terms: OrderTerms): Promise<{ data: IntentOrderData; fillDeadline: number }> {
  const now = await chainTime(net.origin);
  return {
    data: {
      inputToken: net.inputToken,
      inputAmount: terms.inputAmount,
      outputToken: net.outputToken,
      outputStartAmount: terms.outputStart,
      outputEndAmount: terms.outputEnd,
      recipient: terms.recipient,
      destinationChainId: BigInt(net.deployment.destination.chainId),
      destinationSettler: net.deployment.destination.destinationSettler,
      exclusiveFiller: terms.exclusiveFiller ?? zeroAddress,
      exclusivityDeadline: Number(now + (terms.exclusivityWindow ?? 0n)),
      settlementModule: moduleFor(net, terms.mode),
    },
    fillDeadline: Number(now + terms.fillWindow),
  };
}

export async function mint(net: Localnet, chain: "origin" | "dest", token: Address, to: Address, amount: bigint) {
  const clients = chain === "origin" ? net.origin : net.dest;
  await sendAndWait(clients, walletFor(clients, net.admin.key), {
    to: token,
    data: encodeFunctionData({ abi: mockErc20Abi, functionName: "mint", args: [to, amount] }),
  });
}

export async function approve(net: Localnet, chain: "origin" | "dest", actor: Actor, token: Address, spender: Address) {
  const clients = chain === "origin" ? net.origin : net.dest;
  await sendAndWait(clients, walletFor(clients, actor.key), {
    to: token,
    data: encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [spender, maxUint256] }),
  });
}

/** The user opens an order on-chain (approve + open). Returns its id and originData. */
export async function openOnchain(net: Localnet, user: Actor, terms: OrderTerms): Promise<{ orderId: Hex; originData: Hex }> {
  const { data, fillDeadline } = await orderData(net, terms);
  await mint(net, "origin", net.inputToken, user.address, terms.inputAmount);
  await approve(net, "origin", user, net.inputToken, net.deployment.origin.originSettler);
  const nonce = await net.origin.public.readContract({
    address: net.deployment.origin.originSettler,
    abi: originSettlerAbi,
    functionName: "onchainNonce",
    args: [user.address],
  });
  await sendAndWait(net.origin, walletFor(net.origin, user.key), {
    to: net.deployment.origin.originSettler,
    data: encodeFunctionData({
      abi: originSettlerAbi,
      functionName: "open",
      args: [{ fillDeadline, orderDataType: INTENT_ORDER_DATA_TYPEHASH, orderData: encodeOrderData(data) }],
    }),
  });
  const originData = encodeOriginData(
    onchainIntent(net.deployment.origin.originSettler, BigInt(net.deployment.origin.chainId), user.address, nonce, fillDeadline, data),
  );
  return { orderId: orderIdOf(originData), originData };
}

/** The user signs a gasless order (Permit2 witness); nothing is sent on-chain. */
export async function signGasless(
  net: Localnet,
  user: Actor,
  terms: OrderTerms,
  nonce: bigint,
): Promise<{ order: GaslessCrossChainOrder; signature: Hex; orderId: Hex; originData: Hex }> {
  const { data, fillDeadline } = await orderData(net, terms);
  await mint(net, "origin", net.inputToken, user.address, terms.inputAmount);
  await approve(net, "origin", user, net.inputToken, net.deployment.origin.permit2);
  const now = await chainTime(net.origin);
  const order: GaslessCrossChainOrder = {
    originSettler: net.deployment.origin.originSettler,
    user: user.address,
    nonce,
    originChainId: BigInt(net.deployment.origin.chainId),
    openDeadline: Number(now + 600n),
    fillDeadline,
    orderDataType: INTENT_ORDER_DATA_TYPEHASH,
    orderData: encodeOrderData(data),
  };
  const signature = await privateKeyToAccount(user.key).signTypedData(
    permit2TypedData(order, net.deployment.origin.permit2, BigInt(net.deployment.origin.chainId)),
  );
  const originData = encodeOriginData(gaslessIntent(order));
  return { order, signature, orderId: orderIdOf(originData), originData };
}

/** Gives `filler` output inventory and approves the destination settler. */
export async function prepareFiller(net: Localnet, filler: Actor) {
  await mint(net, "dest", net.outputToken, filler.address, 10n ** 30n);
  await approve(net, "dest", filler, net.outputToken, net.deployment.destination.destinationSettler);
}

/** A filler fills directly (no solver logic): funds itself, approves and calls fill. */
export async function fillDirect(net: Localnet, filler: Actor, orderId: Hex, originData: Hex, repayment: Address) {
  await prepareFiller(net, filler);
  return sendAndWait(net.dest, walletFor(net.dest, filler.key), {
    to: net.deployment.destination.destinationSettler,
    data: encodeFunctionData({
      abi: destinationSettlerAbi,
      functionName: "fill",
      args: [orderId, originData, encodeRepayment(repayment)],
    }),
  });
}

export function encodeRepayment(repayment: Address): Hex {
  return `0x${repayment.slice(2).toLowerCase().padStart(64, "0")}`;
}

export async function escrowStatus(net: Localnet, orderId: Hex): Promise<number> {
  const escrow = await net.origin.public.readContract({
    address: net.deployment.origin.originSettler,
    abi: originSettlerAbi,
    functionName: "escrowOf",
    args: [orderId],
  });
  return escrow.status;
}

export async function balanceOf(net: Localnet, chain: "origin" | "dest", token: Address, who: Address) {
  const clients = chain === "origin" ? net.origin : net.dest;
  return clients.public.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [who] });
}

/**
 * An attacker claims an order through the optimistic module, naming itself as the filler (bond minted and
 * approved). Returns the claimed fill time: `filledAt` if given, the origin chain's current time otherwise.
 */
export async function fraudulentClaim(
  net: Localnet,
  attacker: Actor,
  orderId: Hex,
  originData: Hex,
  filledAt?: bigint,
): Promise<bigint> {
  const module = net.deployment.origin.optimisticModule;
  await mint(net, "origin", net.deployment.origin.bondToken, attacker.address, net.bond);
  await approve(net, "origin", attacker, net.deployment.origin.bondToken, module);
  const claimedAt = filledAt ?? (await chainTime(net.origin));
  await sendAndWait(net.origin, walletFor(net.origin, attacker.key), {
    to: module,
    data: encodeFunctionData({
      abi: optimisticSettlementModuleAbi,
      functionName: "claim",
      args: [orderId, attacker.address, claimedAt, keccak256(originData)],
    }),
  });
  return claimedAt;
}

/** Challenges the claim (`orderId`, `filler`, `filledAt`) directly with the proof at destination block `blockNumber`. */
export async function challengeAt(
  net: Localnet,
  challenger: Actor,
  orderId: Hex,
  filler: Address,
  filledAt: bigint,
  blockNumber: bigint,
) {
  const proof = await fillRecordProof(net.dest, net.deployment.destination.destinationSettler, orderId, blockNumber);
  return sendAndWait(net.origin, walletFor(net.origin, challenger.key), {
    to: net.deployment.origin.optimisticModule,
    data: encodeFunctionData({
      abi: optimisticSettlementModuleAbi,
      functionName: "challenge",
      args: [orderId, filler, filledAt, blockNumber, proof.accountProof, proof.slotProof],
    }),
  });
}

/**
 * Anyone can import the ancestors of a stored destination header through `HeaderStore.submitAncestor`. Imports
 * every ancestor of the newest stored header down to block `downTo` and returns the lowest stored block.
 */
export async function importAncestors(net: Localnet, caller: Actor, downTo: bigint): Promise<bigint> {
  const chainId = BigInt(net.deployment.destination.chainId);
  const stored = await storedHeaders(net.origin, net.deployment.origin.headerStore, chainId);
  const numbers = new Set(stored.map((h) => h.blockNumber));
  let child = stored.reduce((max, h) => (h.blockNumber > max ? h.blockNumber : max), 0n);
  const rlpOf = async (n: bigint): Promise<Hex> =>
    encodeVerifiedHeader(
      (await net.dest.public.request({ method: "eth_getBlockByNumber", params: [toHex(n), false] })) as unknown as RpcBlock,
    );
  const wallet = walletFor(net.origin, caller.key);
  while (child > downTo) {
    if (!numbers.has(child - 1n)) {
      await sendAndWait(net.origin, wallet, {
        to: net.deployment.origin.headerStore,
        data: encodeFunctionData({
          abi: headerStoreAbi,
          functionName: "submitAncestor",
          args: [chainId, child, await rlpOf(child), await rlpOf(child - 1n)],
        }),
      });
    }
    child--;
  }
  return child;
}

export async function refund(net: Localnet, caller: Actor, orderId: Hex) {
  return sendAndWait(net.origin, walletFor(net.origin, caller.key), {
    to: net.deployment.origin.originSettler,
    data: encodeFunctionData({ abi: originSettlerAbi, functionName: "refund", args: [orderId] }),
  });
}
