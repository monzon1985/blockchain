// SPDX-License-Identifier: MIT
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { decodeFunctionResult, encodeFunctionData, toHex } from "viem";

import { assertWellFormedSvg, decodeTokenUri } from "../support/metadata.js";
import { DAY, Shape, YEAR, linearParams, milestoneParams, type CreateParams } from "../support/params.js";
import { Rng, runs } from "../support/random.js";
import { MAX_UINT128, STRESS_SYMBOL, createStressStreams } from "../support/stress.js";

/** Budget from the spec: rendering must stay under 3,000,000 gas in `eth_estimateGas`. */
const TOKEN_URI_GAS_BUDGET = 3_000_000n;

/** RawSymbolToken.SymbolMode */
const Mode = { AbiString: 0, BurnGas: 3 } as const;

describe("tokenURI gas budget (eth_estimateGas)", async () => {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;
  const publicClient = await viem.getPublicClient();
  const [sender, recipient] = await viem.getWalletClients();
  assert.ok(sender !== undefined && recipient !== undefined);
  const caller = sender.account.address;

  const renderer = await viem.deployContract("StreamRenderer");
  const vesting = await viem.deployContract("VestingStreams", [renderer.address, sender.account.address]);
  // The exact gas of these two streams is pinned in gas-table.json by `npm run gas:check` (scripts/gas-check.ts).
  const stress = await createStressStreams(connection, vesting.address);

  async function estimateTokenUri(streamId: bigint): Promise<bigint> {
    return publicClient.estimateGas({
      account: caller,
      to: vesting.address,
      data: encodeFunctionData({ abi: vesting.abi, functionName: "tokenURI", args: [streamId] }),
    });
  }

  async function callTokenUriWithBudget(streamId: bigint): Promise<string> {
    const { data } = await publicClient.call({
      account: caller,
      to: vesting.address,
      gas: TOKEN_URI_GAS_BUDGET,
      data: encodeFunctionData({ abi: vesting.abi, functionName: "tokenURI", args: [streamId] }),
    });
    assert.ok(data !== undefined);
    return decodeFunctionResult({ abi: vesting.abi, functionName: "tokenURI", data });
  }

  it("stress case: a canceled 32-tranche stream with 39-digit amounts renders under 3,000,000 gas", async () => {
    const gas = await estimateTokenUri(stress.tranched);
    assert.ok(gas < TOKEN_URI_GAS_BUDGET, `tokenURI used ${gas} gas`);
    const { svg } = decodeTokenUri(await vesting.read.tokenURI([stress.tranched]));
    assertWellFormedSvg(svg);
    // The stress inputs really are in the art: escaped symbol, 39-digit rows, cancel marker and date.
    assert.ok(svg.includes(`${"&quot;".repeat(16)}</text>`), "symbol escaped 16 times");
    assert.ok(svg.includes("REFUNDED") && svg.includes("| CANCELED "), "canceled art");
    assert.ok(/>\d{3}(,\d{3}){12} /.test(svg), "no 39-digit amount row");
  });

  it("stress case: a canceled 16-segment stream with 39-digit amounts renders under 3,000,000 gas", async () => {
    const gas = await estimateTokenUri(stress.segmented);
    assert.ok(gas < TOKEN_URI_GAS_BUDGET, `tokenURI used ${gas} gas`);
  });

  it("the 32-tranche stress stream also renders in an eth_call capped at the budget", async () => {
    const uri = await callTokenUriWithBudget(stress.tranched);
    assert.ok(uri.startsWith("data:application/json;base64,") && uri.length > 1_000);
  });

  it("a token whose symbol() burns all forwarded gas still renders with the budget as the call's gas limit", async () => {
    // eth_estimateGas refuses to estimate here (by design, EDR reports that an inner call runs out of gas no matter
    // the limit), so the budget is enforced directly as the gas limit of the eth_call.
    await stress.token.write.setSymbol(["0x", Mode.BurnGas]);
    try {
      for (const id of [stress.tranched, stress.segmented]) {
        assert.ok(decodeTokenUri(await callTokenUriWithBudget(id)).svg.includes(" UNKNOWN</text>"));
      }
    } finally {
      await stress.token.write.setSymbol([toHex(STRESS_SYMBOL), Mode.AbiString]);
    }
  });

  it(`${runs(24)} seeded random streams (shape, size, amounts, decimals, symbol, withdrawals, cancel) stay under the budget`, async () => {
    const rng = new Rng(0x6a5b);
    const token = await viem.deployContract("RawSymbolToken", ["0x", 18]);
    await token.write.mint([caller, 2n ** 255n]);
    await token.write.approve([vesting.address, 2n ** 255n]);
    const symbolChars = ["<", "&", ">", '"', "'", "A", "z", "9", " "];
    for (let i = 0; i < runs(24); i++) {
      await token.write.setDecimals([rng.pick([0, 0, 2, 6, 8, 17, 18, 24, 36, 77, 255]), false]);
      const symbol = Array.from({ length: rng.int(0, 20) }, () => rng.pick(symbolChars)).join("");
      await token.write.setSymbol([toHex(symbol), Mode.AbiString]);

      const start = (await networkHelpers.time.latest()) + 10;
      const duration = rng.int(2, 4 * YEAR);
      const shape = rng.pick([Shape.LinearCliff, Shape.Tranched, Shape.Segmented]);
      let params: CreateParams;
      if (shape === Shape.LinearCliff) {
        const cliff = rng.int(0, 1) === 0 ? 0 : start + rng.int(1, duration - 1);
        const deposit = 1n + rng.below(MAX_UINT128);
        params = linearParams({ recipient: recipient.account.address, deposit, start, cliff, end: start + duration });
      } else {
        const count = rng.int(1, shape === Shape.Tranched ? 32 : 16);
        const step = Math.max(1, Math.floor(duration / count));
        // Each amount is at most MAX_UINT128 / count, so the deposit always fits in a uint128.
        const milestones = Array.from({ length: count }, (_, k) => ({
          amount: 1n + rng.below(MAX_UINT128 / BigInt(count)),
          timestamp: start + step * (k + 1),
        }));
        params = milestoneParams({ recipient: recipient.account.address, shape, start, milestones });
      }
      await vesting.write.create([token.address, params]);
      const id = (await vesting.read.nextStreamId()) - 1n;

      await networkHelpers.time.increase(rng.int(10, duration + DAY));
      const withdrawable = await vesting.read.withdrawableAmountOf([id]);
      if (withdrawable > 0n && rng.int(0, 1) === 1) {
        await vesting.write.withdraw([id, recipient.account.address, 1n + rng.below(withdrawable)], {
          account: recipient.account,
        });
      }
      if ((await vesting.read.refundableAmountOf([id])) > 0n && rng.int(0, 1) === 1) {
        await vesting.write.cancel([id]);
      }
      await networkHelpers.time.increase(rng.int(1, YEAR));

      const gas = await estimateTokenUri(id);
      assert.ok(gas < TOKEN_URI_GAS_BUDGET, `stream ${id}: tokenURI used ${gas} gas`);
      assertWellFormedSvg(decodeTokenUri(await vesting.read.tokenURI([id])).svg);
    }
  });
});
