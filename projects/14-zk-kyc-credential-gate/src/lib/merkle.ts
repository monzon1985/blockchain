// SPDX-License-Identifier: MIT
import { type Eddsa } from "circomlibjs";
import { poseidon } from "./crypto.ts";

/** An inclusion proof for a leaf in a fixed-depth binary Poseidon Merkle tree. */
export interface MerkleProof {
  root: bigint;
  leaf: bigint;
  pathElements: bigint[];
  pathIndices: bigint[];
}

/**
 * A fixed-depth binary Merkle tree using `Poseidon(left, right)` for internal
 * nodes and a fixed zero-leaf padding, matching `MerkleInclusionProof` in the
 * circuit. Empty slots hash up from leaf value 0.
 */
export class PoseidonMerkleTree {
  readonly depth: number;
  private readonly eddsa: Eddsa;
  private readonly leaves: bigint[];
  private readonly zeros: bigint[];

  constructor(eddsa: Eddsa, depth: number) {
    this.eddsa = eddsa;
    this.depth = depth;
    this.leaves = [];
    // zeros[i] is the root of an all-zero subtree of height i.
    this.zeros = [0n];
    for (let i = 1; i <= depth; i++) {
      const prev = this.zeros[i - 1] as bigint;
      this.zeros.push(poseidon(eddsa, [prev, prev]));
    }
  }

  /** Append a leaf, returning its index. */
  insert(leaf: bigint): number {
    this.leaves.push(leaf);
    return this.leaves.length - 1;
  }

  private hash(left: bigint, right: bigint): bigint {
    return poseidon(this.eddsa, [left, right]);
  }

  /** Current tree root. */
  root(): bigint {
    let level = this.leaves.slice();
    if (level.length === 0) {
      return this.zeros[this.depth] as bigint;
    }
    for (let d = 0; d < this.depth; d++) {
      const next: bigint[] = [];
      const zero = this.zeros[d] as bigint;
      for (let i = 0; i < level.length; i += 2) {
        const left = level[i] as bigint;
        const right = i + 1 < level.length ? (level[i + 1] as bigint) : zero;
        next.push(this.hash(left, right));
      }
      level = next;
    }
    return level[0] as bigint;
  }

  /** Produce an inclusion proof for the leaf at `index`. */
  proof(index: number): MerkleProof {
    if (index < 0 || index >= this.leaves.length) {
      throw new Error(`leaf index ${index} out of range`);
    }
    const pathElements: bigint[] = [];
    const pathIndices: bigint[] = [];
    let level = this.leaves.slice();
    let idx = index;
    for (let d = 0; d < this.depth; d++) {
      const zero = this.zeros[d] as bigint;
      const isRight = idx % 2 === 1;
      const siblingIdx = isRight ? idx - 1 : idx + 1;
      const sibling = siblingIdx < level.length ? (level[siblingIdx] as bigint) : zero;
      pathElements.push(sibling);
      pathIndices.push(isRight ? 1n : 0n);

      const next: bigint[] = [];
      for (let i = 0; i < level.length; i += 2) {
        const left = level[i] as bigint;
        const right = i + 1 < level.length ? (level[i + 1] as bigint) : zero;
        next.push(this.hash(left, right));
      }
      level = next;
      idx = Math.floor(idx / 2);
    }
    return {
      root: this.root(),
      leaf: this.leaves[index] as bigint,
      pathElements,
      pathIndices,
    };
  }
}
