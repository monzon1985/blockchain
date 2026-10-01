// SPDX-License-Identifier: MIT
import { keccak256 } from "viem";
import { describe, expect, it } from "vitest";

import { encodeHeader, encodeVerifiedHeader, quantity } from "../src/header.ts";
import { fixture } from "./fixture.ts";

describe("block header RLP", () => {
  it("reproduces the anvil header byte for byte and its hash", () => {
    const rlp = encodeVerifiedHeader(fixture.header.rpcBlock);
    expect(rlp).toBe(fixture.header.rlp);
    expect(keccak256(rlp)).toBe(fixture.header.hash);
  });

  it("refuses to relay a header that does not hash to the block hash", () => {
    const block = { ...fixture.header.rpcBlock, gasUsed: "0x1" as const };
    expect(() => encodeVerifiedHeader(block)).toThrow(/hashes to/);
  });

  it("stops at the first missing fork field (older headers are shorter)", () => {
    const {
      requestsHash: _r,
      parentBeaconBlockRoot: _p,
      blobGasUsed: _b,
      excessBlobGas: _e,
      ...preCancun
    } = fixture.header.rpcBlock;
    const shorter = encodeHeader(preCancun);
    expect(shorter.length).toBeLessThan(fixture.header.rlp.length);
  });

  it("encodes quantities minimally", () => {
    expect(quantity("0x0")).toBe("0x");
    expect(quantity("0x00")).toBe("0x");
    expect(quantity("0x1")).toBe("0x01");
    expect(quantity("0x1c9c380")).toBe("0x01c9c380");
    expect(quantity("0x0100")).toBe("0x0100");
  });
});
