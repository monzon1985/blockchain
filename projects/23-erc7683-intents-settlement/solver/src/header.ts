// SPDX-License-Identifier: MIT
// RLP encoding of an execution-layer block header from eth_getBlockByNumber, checked against the block hash.
// Field order follows the Yellow Paper plus fork additions (London .. Prague); OpenZeppelin's BlockHeader parses
// the same layout on-chain.
import { type Hex, keccak256, toRlp } from "viem";

/** The raw JSON-RPC block object (hex quantities as returned by the node). */
export interface RpcBlock {
  hash: Hex;
  parentHash: Hex;
  sha3Uncles: Hex;
  miner: Hex;
  stateRoot: Hex;
  transactionsRoot: Hex;
  receiptsRoot: Hex;
  logsBloom: Hex;
  difficulty: Hex;
  number: Hex;
  gasLimit: Hex;
  gasUsed: Hex;
  timestamp: Hex;
  extraData: Hex;
  mixHash: Hex;
  nonce: Hex;
  baseFeePerGas?: Hex;
  withdrawalsRoot?: Hex;
  blobGasUsed?: Hex;
  excessBlobGas?: Hex;
  parentBeaconBlockRoot?: Hex;
  requestsHash?: Hex;
}

/** Minimal big-endian bytes of a quantity: 0 is the empty string, never a leading zero byte. */
export function quantity(value: Hex): Hex {
  const n = BigInt(value);
  if (n === 0n) return "0x";
  const hex = n.toString(16);
  return `0x${hex.length % 2 === 1 ? `0${hex}` : hex}`;
}

/** Fork-dependent trailing fields, in order; each fork only appends. */
const OPTIONAL: readonly [keyof RpcBlock, "quantity" | "bytes"][] = [
  ["baseFeePerGas", "quantity"], // London
  ["withdrawalsRoot", "bytes"], // Shanghai
  ["blobGasUsed", "quantity"], // Cancun
  ["excessBlobGas", "quantity"], // Cancun
  ["parentBeaconBlockRoot", "bytes"], // Cancun
  ["requestsHash", "bytes"], // Prague
];

/** RLP of the execution-layer header `block`, fork fields included up to the last one the node returned. */
export function encodeHeader(block: RpcBlock): Hex {
  const fields: Hex[] = [
    block.parentHash,
    block.sha3Uncles,
    block.miner,
    block.stateRoot,
    block.transactionsRoot,
    block.receiptsRoot,
    block.logsBloom,
    quantity(block.difficulty),
    quantity(block.number),
    quantity(block.gasLimit),
    quantity(block.gasUsed),
    quantity(block.timestamp),
    block.extraData,
    block.mixHash,
    block.nonce, // 8 bytes, kept as-is
  ];
  for (const [key, kind] of OPTIONAL) {
    const value = block[key];
    if (value === undefined) break;
    fields.push(kind === "quantity" ? quantity(value) : value);
  }
  return toRlp(fields);
}

/** Encodes and checks keccak256(rlp) == block.hash, so a malformed header is never relayed. */
export function encodeVerifiedHeader(block: RpcBlock): Hex {
  const rlp = encodeHeader(block);
  const hash = keccak256(rlp);
  if (hash !== block.hash) throw new Error(`header RLP hashes to ${hash}, block hash is ${block.hash}`);
  return rlp;
}
