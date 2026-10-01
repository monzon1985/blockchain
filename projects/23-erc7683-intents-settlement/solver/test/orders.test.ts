// SPDX-License-Identifier: MIT
import { keccak256, toHex, zeroAddress } from "viem";
import { describe, expect, it } from "vitest";

import {
  INTENT_ORDER_DATA_TYPE,
  INTENT_ORDER_DATA_TYPEHASH,
  decodeOrderData,
  decodeOriginData,
  encodeOrderData,
  encodeOriginData,
  fillerSlot,
  orderIdOf,
  unpackFillerSlot,
} from "../src/orders.ts";
import { fixture } from "./fixture.ts";

describe("order encoding agrees with the contracts (anvil vectors)", () => {
  for (const [name, order] of Object.entries(fixture.orders)) {
    it(`derives the on-chain order id and fill-record slot of ${name}`, () => {
      expect(orderIdOf(order.originData)).toBe(order.orderId);
      expect(keccak256(order.originData)).toBe(order.fillHash);
      expect(fillerSlot(order.orderId)).toBe(order.slot);
    });

    it(`round-trips the originData of ${name}`, () => {
      const intent = decodeOriginData(order.originData);
      expect(encodeOriginData(intent)).toBe(order.originData);
      expect(decodeOrderData(encodeOrderData(intent.data))).toEqual(intent.data);
      expect(intent.originSettler.toLowerCase()).toBe(fixture.origin.originSettler.toLowerCase());
    });
  }

  it("unpacks the recorded filler and fill time", () => {
    const value = BigInt(fixture.orders.filledProof.value);
    const { filler, filledAt } = unpackFillerSlot(value);
    expect(filler.toLowerCase()).toBe(fixture.repayment.toLowerCase());
    expect(filledAt).toBeGreaterThan(0n);
    expect(filledAt).toBeLessThanOrEqual(BigInt(fixture.header.timestamp));
    expect(unpackFillerSlot(0n)).toEqual({ filler: zeroAddress, filledAt: 0n });
  });

  it("uses the EIP-712 typehash of IntentOrderData as orderDataType", () => {
    expect(INTENT_ORDER_DATA_TYPEHASH).toBe(keccak256(toHex(INTENT_ORDER_DATA_TYPE)));
  });

  it("changes the order id when any field of the payload changes", () => {
    const intent = decodeOriginData(fixture.orders.filledProof.originData);
    const tampered = encodeOriginData({ ...intent, data: { ...intent.data, outputEndAmount: 1n } });
    expect(orderIdOf(tampered)).not.toBe(fixture.orders.filledProof.orderId);
  });
});
