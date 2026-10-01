// SPDX-License-Identifier: MIT
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

import VestingStreamsModule from "./VestingStreams.js";

/**
 * Local demo: the protocol plus an 18-decimal demo token whose initial supply goes to the deployer, who also
 * pre-approves the vesting contract for the whole supply. Meant for the EDR simulated network only.
 */
export default buildModule("DemoModule", (m) => {
  const { renderer, vesting } = m.useModule(VestingStreamsModule);
  const deployer = m.getAccount(0);
  const supply = m.getParameter("supply", 1_000_000n * 10n ** 18n);
  const demoToken = m.contract("DemoToken", [deployer, supply]);
  m.call(demoToken, "approve", [vesting, supply]);
  return { renderer, vesting, demoToken };
});
