// SPDX-License-Identifier: MIT
// Watchtower for settlement mode 2: the "one honest watcher" the optimistic module relies on. It compares every
// pending claim with the destination FillRecord and, on a mismatch, disputes it with a storage proof (inclusion of
// a different record, exclusion of the slot, or exclusion of the settler account itself), taking the claimant's bond.
import { type Address, type Hex, encodeAbiParameters, encodeFunctionData, keccak256, zeroAddress } from "viem";

import { destinationSettlerAbi, optimisticSettlementModuleAbi, originSettlerAbi } from "./abi.ts";
import type { ChainClients, Wallet } from "./chains.ts";
import { chainTime } from "./chains.ts";
import type { Logger } from "./log.ts";
import { fillRecordProof, storedHeadersNewestFirst } from "./proofs.ts";
import { sendAndWait } from "./tx.ts";

/** Chains, key and addresses the watchtower works with. */
export interface WatchtowerDeps {
  origin: ChainClients;
  dest: ChainClients;
  /** Origin-chain wallet that sends challenges and receives the bonds. */
  wallet: Wallet;
  originSettler: Address;
  optimisticModule: Address;
  headerStore: Address;
  destinationSettler: Address;
  log: Logger;
  /** How many of the newest usable headers to try before giving up on a claim for this tick. Default 3. */
  maxHeaderAttempts?: number;
}

/** Outcome of checking one pending claim. `failed`: an error prevented the check; it is retried next tick. */
export type Verdict = "honest" | "waiting-for-header" | "challenged" | "failed";

/** A claim, by its key in the optimistic module. */
export interface ClaimKey {
  orderId: Hex;
  filler: Address;
  filledAt: bigint;
}

/** Id of the claim (`orderId`, `filler`, `filledAt`), as OptimisticSettlementModule.claimIdOf computes it. */
export function claimIdOf(orderId: Hex, filler: Address, filledAt: bigint): Hex {
  return keccak256(
    encodeAbiParameters([{ type: "bytes32" }, { type: "address" }, { type: "uint64" }], [orderId, filler, filledAt]),
  );
}

/**
 * Watches the optimistic module. Every tick it picks up new Claimed events, checks every claim still pending and
 * inside its window against the destination FillRecord, and challenges the ones that disagree. Each claim is checked
 * on its own, so an error on one claim (a proof the node cannot serve, a reverted challenge) never stops the others.
 */
export class Watchtower {
  private readonly claims = new Map<Hex, ClaimKey>();
  private nextBlock = 0n;
  private readonly deps: WatchtowerDeps;

  constructor(deps: WatchtowerDeps) {
    this.deps = deps;
  }

  /** Checks every pending claim. Returns the verdict per claim id (see `claimIdOf`). */
  async tick(): Promise<Map<Hex, Verdict>> {
    const { origin, optimisticModule, log } = this.deps;
    const latest = await origin.public.getBlockNumber();
    if (this.nextBlock <= latest) {
      const events = await origin.public.getContractEvents({
        address: optimisticModule,
        abi: optimisticSettlementModuleAbi,
        eventName: "Claimed",
        fromBlock: this.nextBlock,
        toBlock: latest,
      });
      for (const e of events) {
        const { orderId, filler, filledAt } = e.args;
        if (orderId === undefined || filler === undefined || filledAt === undefined) continue;
        this.claims.set(claimIdOf(orderId, filler, filledAt), { orderId, filler, filledAt });
      }
      this.nextBlock = latest + 1n;
    }

    const verdicts = new Map<Hex, Verdict>();
    const now = await chainTime(origin);
    for (const [id, claim] of this.claims) {
      try {
        const pending = await origin.public.readContract({
          address: optimisticModule,
          abi: optimisticSettlementModuleAbi,
          functionName: "claimOf",
          args: [claim.orderId, claim.filler, claim.filledAt],
        });
        // Resolved (challenged, finalized or voided), or too late to challenge either way.
        if (pending.claimant === zeroAddress || now > pending.challengeDeadline) {
          this.claims.delete(id);
          continue;
        }
        verdicts.set(id, await this.check(claim));
      } catch (error) {
        log.warn("claim check failed; will retry next tick", { claimId: id, orderId: claim.orderId, error });
        verdicts.set(id, "failed");
      }
    }
    return verdicts;
  }

  /** Compares one claim with the record and challenges it if it is false, trying the newest headers first. */
  private async check(claim: ClaimKey): Promise<Verdict> {
    const { origin, dest, wallet, originSettler, optimisticModule, headerStore, destinationSettler, log } = this.deps;
    const record = await dest.public.readContract({
      address: destinationSettler,
      abi: destinationSettlerAbi,
      functionName: "fillRecord",
      args: [claim.orderId],
    });
    if (record.filler.toLowerCase() === claim.filler.toLowerCase() && record.filledAt === claim.filledAt) {
      return "honest";
    }

    const escrow = await origin.public.readContract({
      address: originSettler,
      abi: originSettlerAbi,
      functionName: "escrowOf",
      args: [claim.orderId],
    });
    // Fill records are write-once, so any header after the claimed fill time settles the dispute; the newest one
    // is the one every node has state for (see storedHeadersNewestFirst).
    const headers = await storedHeadersNewestFirst(origin, headerStore, escrow.destinationChainId, 0n, claim.filledAt);
    if (headers.length === 0) return "waiting-for-header";
    let lastError: unknown;
    for (const header of headers.slice(0, this.deps.maxHeaderAttempts ?? 3)) {
      try {
        const proof = await fillRecordProof(dest, destinationSettler, claim.orderId, header.blockNumber);
        const args = [
          claim.orderId,
          claim.filler,
          claim.filledAt,
          header.blockNumber,
          proof.accountProof,
          proof.slotProof,
        ] as const;
        // Simulate first, so a header whose proof does not verify costs no gas and the next one is tried.
        await origin.public.simulateContract({
          account: wallet.account,
          address: optimisticModule,
          abi: optimisticSettlementModuleAbi,
          functionName: "challenge",
          args,
        });
        await sendAndWait(origin, wallet, {
          to: optimisticModule,
          data: encodeFunctionData({ abi: optimisticSettlementModuleAbi, functionName: "challenge", args }),
        });
        log.info("challenged fraudulent claim", {
          orderId: claim.orderId,
          claimedFiller: claim.filler,
          provenFiller: record.filler,
          header: header.blockNumber,
        });
        return "challenged";
      } catch (error) {
        lastError = error;
        log.warn("challenge with this header failed; trying an older one", {
          orderId: claim.orderId,
          header: header.blockNumber,
          error,
        });
      }
    }
    throw lastError;
  }
}
