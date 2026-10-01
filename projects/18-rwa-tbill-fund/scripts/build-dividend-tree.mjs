#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Record-date dividend builder for DividendDistributor.
//
// Usage: node scripts/build-dividend-tree.mjs <holders.json> [out.json]
//
// Input:  { "recordDate": <unix seconds>, "totalAmount": "<payout base units>",
//           "holders": [{ "account": "0x...", "balance": "<share base units at the record date>" }] }
// Output: { root, recordDate, requestedAmount, allocatedAmount, undistributedDust, leafEncoding, count,
//           claims: [{ account, amount, proof }] }
//
// Entitlements are floor(totalAmount * balance / totalBalance). The dust left by flooring stays with the
// fund: `allocatedAmount` is what the fund administrator funds on-chain. Leaves use OpenZeppelin's
// StandardMerkleTree encoding (double-hashed abi.encode(address, uint256)), matching the contract.

import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";

export const LEAF_ENCODING = ["address", "uint256"];
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const UINT = /^[0-9]+$/;

function toBigInt(value, field) {
  const text = String(value);
  if (!UINT.test(text)) throw new Error(`${field} must be a non-negative integer, got ${text}`);
  return BigInt(text);
}

/**
 * Pro-rata allocation with floor rounding. Zero balances and zero entitlements are dropped.
 * @param {Array<{account: string, balance: string|number}>} holders
 * @param {bigint} totalAmount
 * @returns {Array<{account: string, amount: bigint}>} sorted by lower-case account
 */
export function allocate(holders, totalAmount) {
  const seen = new Set();
  let totalBalance = 0n;
  const parsed = holders.map((h, i) => {
    if (!ADDRESS.test(h.account)) throw new Error(`holders[${i}].account is not an address: ${h.account}`);
    const key = h.account.toLowerCase();
    if (seen.has(key)) throw new Error(`duplicate holder ${h.account}`);
    seen.add(key);
    const balance = toBigInt(h.balance, `holders[${i}].balance`);
    totalBalance += balance;
    return { account: h.account, balance };
  });
  if (totalBalance === 0n) throw new Error("total balance at the record date is zero");
  return parsed
    .map(({ account, balance }) => ({ account, amount: (totalAmount * balance) / totalBalance }))
    .filter(({ amount }) => amount > 0n)
    .sort((a, b) => (a.account.toLowerCase() < b.account.toLowerCase() ? -1 : 1));
}

/**
 * Builds the distribution artefact (root + proofs) from a holders snapshot.
 * @param {{recordDate: number, totalAmount: string|number, holders: Array<{account: string, balance: string}>}} input
 */
export function buildDistribution(input) {
  const recordDate = Number(input.recordDate);
  if (!Number.isSafeInteger(recordDate) || recordDate <= 0) throw new Error("recordDate must be a unix timestamp");
  const requested = toBigInt(input.totalAmount, "totalAmount");
  if (requested === 0n) throw new Error("totalAmount must be positive");
  if (!Array.isArray(input.holders) || input.holders.length === 0) throw new Error("holders must be a non-empty array");

  const allocations = allocate(input.holders, requested);
  if (allocations.length === 0) throw new Error("no holder is entitled to a non-zero amount");
  const tree = StandardMerkleTree.of(
    allocations.map(({ account, amount }) => [account, amount.toString()]),
    LEAF_ENCODING,
  );
  const allocated = allocations.reduce((sum, { amount }) => sum + amount, 0n);
  const claims = allocations.map(({ account, amount }, index) => ({
    account,
    amount: amount.toString(),
    proof: tree.getProof(index),
  }));
  return {
    root: tree.root,
    recordDate,
    requestedAmount: requested.toString(),
    allocatedAmount: allocated.toString(),
    undistributedDust: (requested - allocated).toString(),
    leafEncoding: LEAF_ENCODING,
    count: claims.length,
    claims,
  };
}

/** Verifies every proof of an artefact against its root with the reference implementation. */
export function verifyDistribution(artefact) {
  return artefact.claims.every(({ account, amount, proof }) =>
    StandardMerkleTree.verify(artefact.root, LEAF_ENCODING, [account, amount], proof),
  );
}

function main() {
  const [inputPath, outputPath] = process.argv.slice(2);
  if (!inputPath) throw new Error("usage: build-dividend-tree.mjs <holders.json> [out.json]");
  const artefact = buildDistribution(JSON.parse(readFileSync(inputPath, "utf8")));
  if (!verifyDistribution(artefact)) throw new Error("internal error: a generated proof does not verify");
  const json = `${JSON.stringify(artefact, null, 2)}\n`;
  if (outputPath) {
    writeFileSync(outputPath, json);
    console.error(`root ${artefact.root}: ${artefact.count} claims, ${artefact.allocatedAmount} allocated`);
  } else {
    process.stdout.write(json);
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    console.error(error.message);
    process.exit(1);
  }
}
