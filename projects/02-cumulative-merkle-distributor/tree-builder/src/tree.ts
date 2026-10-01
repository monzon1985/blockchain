// SPDX-License-Identifier: MIT
/**
 * The distributor's leaf encoding and a tree whose `dump()` is byte-identical to
 * `StandardMerkleTree.of(values, ["address", "address", "uint256"]).dump()` from @openzeppelin/merkle-tree.
 */
import { encodeAbiParameters, getAddress, keccak256, type Address, type Hex } from 'viem';
import {
  MerkleError,
  compareHashes,
  getMultiProof,
  getProof,
  isValidTree,
  makeTree,
  processMultiProof,
  processProof,
} from './merkle.ts';

export const LEAF_ENCODING = ['address', 'address', 'uint256'] as const;
const LEAF_PARAMS = LEAF_ENCODING.map((type) => ({ type }));

/** One (account, token) allocation. `cumulativeAmount` is the total ever allocated, in token base units. */
export interface Allocation {
  readonly account: Address;
  readonly token: Address;
  readonly cumulativeAmount: bigint;
}

/** A leaf value as stored in a StandardMerkleTree dump: checksummed addresses and a decimal string. */
export type LeafValue = readonly [account: Address, token: Address, cumulativeAmount: string];

export interface StandardTreeDump {
  readonly format: 'standard-v1';
  readonly leafEncoding: readonly string[];
  readonly tree: readonly Hex[];
  readonly values: readonly { readonly value: LeafValue; readonly treeIndex: number }[];
}

/** `keccak256(bytes.concat(keccak256(abi.encode(account, token, cumulativeAmount))))`, as the contract computes it. */
export function leafHash(account: Address, token: Address, cumulativeAmount: bigint): Hex {
  return keccak256(keccak256(encodeAbiParameters(LEAF_PARAMS, [account, token, cumulativeAmount])));
}

export function toLeafValue(a: Allocation): LeafValue {
  return [getAddress(a.account), getAddress(a.token), a.cumulativeAmount.toString(10)];
}

export function fromLeafValue(v: LeafValue): Allocation {
  if (!/^(0|[1-9][0-9]*)$/.test(v[2])) throw new MerkleError(`amount is not a canonical decimal: ${v[2]}`);
  return { account: getAddress(v[0]), token: getAddress(v[1]), cumulativeAmount: BigInt(v[2]) };
}

export interface ValueMultiProof {
  /** Leaf values in the order `claimMany` expects them. */
  readonly values: readonly LeafValue[];
  readonly proof: readonly Hex[];
  readonly proofFlags: readonly boolean[];
}

export class CumulativeMerkleTree {
  readonly tree: readonly Hex[];
  readonly values: readonly { readonly value: LeafValue; readonly treeIndex: number }[];
  private readonly hashToValueIndex: ReadonlyMap<Hex, number>;

  private constructor(
    tree: readonly Hex[],
    values: readonly { readonly value: LeafValue; readonly treeIndex: number }[],
  ) {
    this.tree = tree;
    this.values = values;
    this.hashToValueIndex = new Map(values.map(({ treeIndex }, i) => [tree[treeIndex] as Hex, i]));
  }

  /**
   * Builds the tree. Values keep the given order; leaves are sorted by hash (StandardMerkleTree's default
   * `sortLeaves: true`), so the root only depends on the set of allocations.
   */
  static of(allocations: readonly Allocation[]): CumulativeMerkleTree {
    const hashed = allocations.map((a, valueIndex) => ({
      valueIndex,
      hash: leafHash(a.account, a.token, a.cumulativeAmount),
    }));
    hashed.sort((a, b) => compareHashes(a.hash, b.hash));
    const tree = makeTree(hashed.map((h) => h.hash));
    const values = allocations.map((a) => ({ value: toLeafValue(a), treeIndex: 0 }));
    hashed.forEach(({ valueIndex }, leafIndex) => {
      const slot = values[valueIndex];
      if (slot !== undefined) slot.treeIndex = tree.length - 1 - leafIndex;
    });
    return new CumulativeMerkleTree(tree, values);
  }

  /** Loads a `standard-v1` dump and validates every node and every leaf value. */
  static load(dump: StandardTreeDump): CumulativeMerkleTree {
    // `dump` usually comes from JSON.parse: check what the type system cannot.
    const format: string = dump.format;
    if (format !== 'standard-v1') throw new MerkleError(`unknown tree format: ${format}`);
    if (JSON.stringify(dump.leafEncoding) !== JSON.stringify(LEAF_ENCODING)) {
      throw new MerkleError(`unexpected leaf encoding: ${JSON.stringify(dump.leafEncoding)}`);
    }
    if (!isValidTree(dump.tree)) throw new MerkleError('tree nodes are inconsistent');
    const t = new CumulativeMerkleTree(dump.tree, dump.values);
    t.values.forEach((_, i) => {
      t.checkValue(i);
    });
    if (t.values.length !== (t.tree.length + 1) / 2 || t.hashToValueIndex.size !== t.values.length) {
      throw new MerkleError('every leaf must hold exactly one value');
    }
    return t;
  }

  get root(): Hex {
    return this.tree[0] as Hex;
  }

  get length(): number {
    return this.values.length;
  }

  allocationAt(valueIndex: number): Allocation {
    return fromLeafValue(this.valueAt(valueIndex).value);
  }

  leafHashAt(valueIndex: number): Hex {
    return this.tree[this.valueAt(valueIndex).treeIndex] as Hex;
  }

  getProof(valueIndex: number): Hex[] {
    const proof = getProof(this.tree, this.valueAt(valueIndex).treeIndex);
    if (processProof(this.leafHashAt(valueIndex), proof) !== this.root) throw new MerkleError('unable to prove value');
    return proof;
  }

  getMultiProof(valueIndices: readonly number[]): ValueMultiProof {
    const mp = getMultiProof(
      this.tree,
      valueIndices.map((i) => this.valueAt(i).treeIndex),
    );
    if (processMultiProof(mp) !== this.root) throw new MerkleError('unable to prove values');
    return {
      values: mp.leaves.map((h) => this.valueAt(this.hashToValueIndex.get(h) ?? -1).value),
      proof: mp.proof,
      proofFlags: mp.proofFlags,
    };
  }

  /** True if `allocation` with `proof` reaches this tree's root. */
  verify(allocation: Allocation, proof: readonly Hex[]): boolean {
    return (
      processProof(leafHash(allocation.account, allocation.token, allocation.cumulativeAmount), proof) === this.root
    );
  }

  dump(): StandardTreeDump {
    return { format: 'standard-v1', leafEncoding: [...LEAF_ENCODING], tree: this.tree, values: this.values };
  }

  private valueAt(valueIndex: number): { readonly value: LeafValue; readonly treeIndex: number } {
    const v = this.values[valueIndex];
    if (v === undefined) throw new MerkleError(`value index ${valueIndex} out of bounds`);
    return v;
  }

  private checkValue(valueIndex: number): void {
    const { value, treeIndex } = this.valueAt(valueIndex);
    const a = fromLeafValue(value);
    if (this.tree[treeIndex] !== leafHash(a.account, a.token, a.cumulativeAmount)) {
      throw new MerkleError(`value ${valueIndex} does not match its leaf`);
    }
    if (2 * treeIndex + 1 < this.tree.length) throw new MerkleError(`value ${valueIndex} is not stored at a leaf`);
  }
}
