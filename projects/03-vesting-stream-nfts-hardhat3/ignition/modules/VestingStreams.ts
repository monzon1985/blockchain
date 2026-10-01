// SPDX-License-Identifier: MIT
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/**
 * The protocol: the SVG renderer (which writes its static SVG fragments to SSTORE2 in its constructor) and the
 * vesting contract, owned by the deployer. The owner can only swap the renderer.
 */
export default buildModule("VestingStreamsModule", (m) => {
  const owner = m.getParameter("owner", m.getAccount(0));
  const renderer = m.contract("StreamRenderer");
  const vesting = m.contract("VestingStreams", [renderer, owner]);
  return { renderer, vesting };
});
