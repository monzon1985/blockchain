// SPDX-License-Identifier: MIT
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { getAddress } from "viem";

import { attribute, decodeTokenUri } from "../support/metadata.js";
import {
  DAY,
  E18,
  MONTH,
  Shape,
  Status,
  T0,
  evenMilestones,
  linearParams,
  milestoneParams,
} from "../support/params.js";
import { deployAll } from "../support/scenario.js";

describe("stream lifecycle through viem and networkHelpers time travel", async () => {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;
  const publicClient = await viem.getPublicClient();

  async function deployFixture() {
    return deployAll(connection);
  }

  it("creates a batch with one transferFrom and emits StreamCreated plus ERC-4906 MetadataUpdate per stream", async () => {
    const { vesting, demoToken, alice, bob, deployer } = await networkHelpers.loadFixture(deployFixture);
    const batch = [
      linearParams({
        recipient: alice.account.address,
        deposit: 1_200n * E18,
        start: T0,
        cliff: T0 + 3 * MONTH,
        end: T0 + 12 * MONTH,
      }),
      milestoneParams({
        recipient: bob.account.address,
        shape: Shape.Tranched,
        start: T0,
        milestones: evenMilestones(4, 250n * E18, T0, MONTH),
      }),
    ];
    const before = await demoToken.read.balanceOf([deployer.account.address]);

    await viem.assertions.emitWithArgs(
      vesting.write.createBatch([demoToken.address, batch]),
      vesting,
      "StreamCreated",
      [
        1n,
        deployer.account.address,
        alice.account.address,
        demoToken.address,
        Shape.LinearCliff,
        1_200n * E18,
        T0,
        T0 + 12 * MONTH,
        true,
      ],
    );

    const block = await publicClient.getBlockNumber();
    const transfers = await publicClient.getContractEvents({
      address: demoToken.address,
      abi: demoToken.abi,
      eventName: "Transfer",
      fromBlock: block,
      toBlock: block,
    });
    assert.equal(transfers.length, 1, "exactly one token transfer for the whole batch");
    assert.equal(transfers[0]?.args.value, 2_200n * E18);
    const updates = await publicClient.getContractEvents({
      address: vesting.address,
      abi: vesting.abi,
      eventName: "MetadataUpdate",
      fromBlock: block,
      toBlock: block,
    });
    assert.deepEqual(
      updates.map((e) => e.args._tokenId),
      [1n, 2n],
    );
    assert.equal(before - (await demoToken.read.balanceOf([deployer.account.address])), 2_200n * E18);
    assert.equal(await vesting.read.ownerOf([2n]), getAddress(bob.account.address));
  });

  it("time-travels through cliff, withdrawal, NFT transfer and cancellation", async () => {
    const { vesting, demoToken, alice, bob, deployer } = await networkHelpers.loadFixture(deployFixture);
    await vesting.write.create([
      demoToken.address,
      linearParams({
        recipient: alice.account.address,
        deposit: 1_200n * E18,
        start: T0,
        cliff: T0 + 3 * MONTH,
        end: T0 + 12 * MONTH,
      }),
    ]);
    const id = 1n;

    // The next transaction is mined one second later, still before the cliff.
    await networkHelpers.time.increaseTo(T0 + 3 * MONTH - 2);
    assert.equal(await vesting.read.withdrawableAmountOf([id]), 0n, "nothing before the cliff");
    await viem.assertions.revertWithCustomErrorWithArgs(
      vesting.write.withdrawMax([id, alice.account.address], { account: alice.account }),
      vesting,
      "NothingToWithdraw",
      [id],
    );

    await networkHelpers.time.setNextBlockTimestamp(T0 + 6 * MONTH);
    await viem.assertions.emitWithArgs(
      vesting.write.withdraw([id, alice.account.address, 500n * E18], { account: alice.account }),
      vesting,
      "Withdrawn",
      [id, alice.account.address, alice.account.address, 500n * E18],
    );

    // The withdrawal right moves with the NFT.
    await vesting.write.safeTransferFrom([alice.account.address, bob.account.address, id], { account: alice.account });
    await viem.assertions.revertWithCustomErrorWithArgs(
      vesting.write.withdrawMax([id, alice.account.address], { account: alice.account }),
      vesting,
      "NotAuthorizedToWithdraw",
      [id, alice.account.address],
    );

    await networkHelpers.time.setNextBlockTimestamp(T0 + 8 * MONTH);
    await viem.assertions.emitWithArgs(vesting.write.cancel([id]), vesting, "Canceled", [
      id,
      deployer.account.address,
      bob.account.address,
      400n * E18,
      300n * E18,
    ]);
    assert.equal(await vesting.read.statusOf([id]), Status.Canceled);

    await networkHelpers.time.increase(365 * DAY);
    assert.equal(await vesting.read.streamedAmountOf([id]), 800n * E18, "frozen at cancellation");
    await vesting.write.withdrawMax([id, bob.account.address], { account: bob.account });
    assert.equal(await demoToken.read.balanceOf([bob.account.address]), 300n * E18);
    assert.equal(await vesting.read.statusOf([id]), Status.Depleted);
    assert.equal(await demoToken.read.balanceOf([vesting.address]), 0n);

    const { metadata } = decodeTokenUri(await vesting.read.tokenURI([id]));
    assert.equal(attribute(metadata, "Status"), "Depleted");
    assert.equal(attribute(metadata, "Vested"), 66);
  });

  it("rejects a fee-on-transfer token with UnsupportedToken(expected, received)", async () => {
    const { vesting, alice, deployer } = await networkHelpers.loadFixture(deployFixture);
    const fot = await viem.deployContract("FeeOnTransferToken", [50n]);
    await fot.write.mint([deployer.account.address, 10_000n]);
    await fot.write.approve([vesting.address, 10_000n]);
    await viem.assertions.revertWithCustomErrorWithArgs(
      vesting.write.create([
        fot.address,
        linearParams({ recipient: alice.account.address, deposit: 10_000n, start: T0, end: T0 + MONTH }),
      ]),
      vesting,
      "UnsupportedToken",
      [fot.address, 10_000n, 9_950n],
    );
  });

  it("calls the recipient hook of a contract owner on cancel, and survives a reverting one", async () => {
    const { vesting, demoToken } = await networkHelpers.loadFixture(deployFixture);
    const recording = await viem.deployContract("RecordingRecipient");
    const reverting = await viem.deployContract("RevertingRecipient");
    await vesting.write.createBatch([
      demoToken.address,
      [
        linearParams({ recipient: recording.address, deposit: 1_000n, start: T0, end: T0 + 10 * DAY }),
        linearParams({ recipient: reverting.address, deposit: 1_000n, start: T0, end: T0 + 10 * DAY }),
      ],
    ]);
    await networkHelpers.time.setNextBlockTimestamp(T0 + 4 * DAY);
    await vesting.write.cancel([1n]);
    assert.equal(await recording.read.calls(), 1);
    assert.equal(await recording.read.lastRefunded(), 600n);
    assert.equal(await recording.read.lastWithdrawable(), 400n);

    await viem.assertions.emitWithArgs(vesting.write.cancel([2n]), vesting, "RecipientHookFailed", [
      2n,
      reverting.address,
    ]);
    assert.equal(await vesting.read.statusOf([2n]), Status.Canceled);
  });
});
