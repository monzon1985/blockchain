// SPDX-License-Identifier: MIT
import { newMemEmptyTrie, type Eddsa, type Smt } from "circomlibjs";
import { toBig } from "./crypto.ts";

/** Witness for a revocation-tree non-membership (exclusion) proof. */
export interface NonMembershipProof {
  root: bigint;
  siblings: bigint[];
  oldKey: bigint;
  oldValue: bigint;
  isOld0: bigint;
}

/**
 * A sparse Merkle tree of revoked credential ids, wrapping circomlib's SMT.
 * Keys are credential ids; the value (1) is irrelevant to non-membership.
 */
export class RevocationTree {
  readonly depth: number;
  private readonly eddsa: Eddsa;
  private readonly smt: Smt;

  private constructor(eddsa: Eddsa, smt: Smt, depth: number) {
    this.eddsa = eddsa;
    this.smt = smt;
    this.depth = depth;
  }

  static async create(eddsa: Eddsa, depth: number): Promise<RevocationTree> {
    const smt = await newMemEmptyTrie();
    return new RevocationTree(eddsa, smt, depth);
  }

  /** Mark a credential id as revoked. */
  async revoke(credentialId: bigint): Promise<void> {
    await this.smt.insert(credentialId, 1);
  }

  /** Current root as a bigint. */
  root(): bigint {
    return toBig(this.eddsa, this.smt.root);
  }

  /**
   * Build a non-membership proof for `credentialId`. Throws if the id is in
   * fact revoked (there is no honest exclusion proof for a member).
   */
  async nonMembership(credentialId: bigint): Promise<NonMembershipProof> {
    const res = await this.smt.find(credentialId);
    if (res.found) {
      throw new Error(`credentialId ${credentialId} is revoked; no exclusion proof`);
    }
    const siblings = res.siblings.map((s) => toBig(this.eddsa, s));
    while (siblings.length < this.depth) {
      siblings.push(0n);
    }
    if (siblings.length > this.depth) {
      throw new Error(
        `revocation proof needs depth > ${this.depth}; got ${siblings.length} siblings`,
      );
    }
    return {
      root: this.root(),
      siblings,
      oldKey: res.isOld0 ? 0n : toBig(this.eddsa, res.notFoundKey as Uint8Array),
      oldValue: res.isOld0 ? 0n : toBig(this.eddsa, res.notFoundValue as Uint8Array),
      isOld0: res.isOld0 ? 1n : 0n,
    };
  }

  /**
   * Membership path of a REVOKED id (siblings padded to `depth`) and the value
   * stored under it. This is public data (holders need the tree to build
   * exclusion proofs); the adversarial tests use it to try to forge an
   * exclusion proof for a revoked id.
   */
  async membership(credentialId: bigint): Promise<{ root: bigint; siblings: bigint[]; value: bigint }> {
    const res = await this.smt.find(credentialId);
    if (!res.found || res.foundValue === undefined) {
      throw new Error(`credentialId ${credentialId} is not revoked`);
    }
    const siblings = res.siblings.map((s) => toBig(this.eddsa, s));
    while (siblings.length < this.depth) {
      siblings.push(0n);
    }
    return { root: this.root(), siblings, value: toBig(this.eddsa, res.foundValue) };
  }
}
