// SPDX-License-Identifier: MIT
import * as fs from "node:fs";
import { type Eddsa } from "circomlibjs";
import { issuerLeaf } from "./crypto.ts";
import { PoseidonMerkleTree } from "./merkle.ts";
import { RevocationTree } from "./revocation.ts";
import { REVOKED_SENTINEL } from "./issuer.ts";

export const ISSUER_TREE_DEPTH = 8;
export const REVOCATION_TREE_DEPTH = 20;
export const N_SANCTIONED = 16;

/**
 * The PUBLIC state a prover needs besides their own credential: the trusted
 * issuer set (tree leaves, in insertion order), the revoked credential ids,
 * the sanctioned list and the reference date. A governor publishes the roots
 * of this state on-chain; anyone can rebuild the trees from it.
 */
export interface WorldFile {
  issuers: Array<{ ax: string; ay: string }>;
  revoked: string[];
  sanctioned: string[];
  currentDate: string;
}

/** The world with its trees rebuilt. */
export interface World {
  issuerTree: PoseidonMerkleTree;
  issuerLeaves: bigint[];
  revocationTree: RevocationTree;
  revoked: bigint[];
  sanctioned: bigint[];
  currentDate: bigint;
}

/** Rebuild the trees of a world. Always revokes REVOKED_SENTINEL (non-zero SMT root). */
export async function buildWorld(eddsa: Eddsa, file: WorldFile): Promise<World> {
  if (file.sanctioned.length !== N_SANCTIONED) {
    throw new Error(`world must list exactly ${N_SANCTIONED} sanctioned codes, got ${file.sanctioned.length}`);
  }
  const issuerTree = new PoseidonMerkleTree(eddsa, ISSUER_TREE_DEPTH);
  const issuerLeaves: bigint[] = [];
  for (const { ax, ay } of file.issuers) {
    const leaf = issuerLeaf(eddsa, BigInt(ax), BigInt(ay));
    issuerLeaves.push(leaf);
    issuerTree.insert(leaf);
  }
  const revocationTree = await RevocationTree.create(eddsa, REVOCATION_TREE_DEPTH);
  const revoked = [...new Set([REVOKED_SENTINEL, ...file.revoked.map((r) => BigInt(r))])];
  for (const id of revoked) await revocationTree.revoke(id);
  return {
    issuerTree,
    issuerLeaves,
    revocationTree,
    revoked,
    sanctioned: file.sanctioned.map((s) => BigInt(s)),
    currentDate: BigInt(file.currentDate),
  };
}

/** Index of an issuer key in the world's tree (throws if it is not trusted). */
export function issuerIndexOf(eddsa: Eddsa, world: World, ax: bigint, ay: bigint): number {
  const idx = world.issuerLeaves.indexOf(issuerLeaf(eddsa, ax, ay));
  if (idx < 0) throw new Error("issuer key is not in the trusted-issuer tree of this world");
  return idx;
}

/** Read a world JSON file. */
export function readWorldFile(file: string): WorldFile {
  return JSON.parse(fs.readFileSync(file, "utf8")) as WorldFile;
}
