// SPDX-License-Identifier: MIT
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { getAddress } from "viem";

import DemoModule from "../../ignition/modules/Demo.js";
import VestingStreamsModule from "../../ignition/modules/VestingStreams.js";
import { E18, MONTH, T0, linearParams } from "../support/params.js";

describe("Hardhat Ignition modules on the EDR simulated network", async () => {
  const { ignition, viem } = await network.create();
  const [deployer, alice, multisig] = await viem.getWalletClients();
  assert.ok(deployer !== undefined && alice !== undefined && multisig !== undefined);

  it("DemoModule wires renderer, vesting and a pre-approved demo token", async () => {
    const { renderer, vesting, demoToken } = await ignition.deploy(DemoModule);
    const supply = 1_000_000n * E18;

    assert.equal(getAddress(await vesting.read.renderer()), getAddress(renderer.address));
    assert.equal(getAddress(await vesting.read.owner()), getAddress(deployer.account.address));
    assert.equal(await demoToken.read.balanceOf([deployer.account.address]), supply);
    assert.equal(await demoToken.read.allowance([deployer.account.address, vesting.address]), supply);
    assert.equal(await vesting.read.supportsInterface(["0x49064906"]), true);

    // The renderer's two SSTORE2 data contracts exist and start with the STOP guard byte.
    const publicClient = await viem.getPublicClient();
    for (const pointer of [await renderer.read.HEAD_POINTER(), await renderer.read.FRAME_POINTER()]) {
      const code = await publicClient.getCode({ address: pointer });
      assert.ok(code !== undefined && code.startsWith("0x00") && code.length > 200);
    }

    // The deployment is immediately usable: the pre-approval covers a stream creation.
    await vesting.write.create([
      demoToken.address,
      linearParams({ recipient: alice.account.address, deposit: 1_000n * E18, start: T0, end: T0 + MONTH }),
    ]);
    assert.equal(getAddress(await vesting.read.ownerOf([1n])), getAddress(alice.account.address));
  });

  it("VestingStreamsModule accepts the owner as a module parameter", async () => {
    const { vesting } = await ignition.deploy(VestingStreamsModule, {
      parameters: { VestingStreamsModule: { owner: multisig.account.address } },
    });
    assert.equal(getAddress(await vesting.read.owner()), getAddress(multisig.account.address));
  });
});
