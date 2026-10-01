// SPDX-License-Identifier: MIT
//
// End-to-end snarkjs prove/verify for both proof systems against the
// production verification keys produced by `npm run setup:dev`.
import assert from "node:assert/strict";
import {
  buildScenario,
  defaultCredentialFields,
  issueCredential,
  witnessFor,
  type Scenario,
} from "../src/lib/scenario.ts";
import { type CredentialCircuitInput } from "../src/lib/inputs.ts";
import {
  proveGroth16,
  verifyGroth16,
  provePlonk,
  verifyPlonk,
  groth16Calldata,
  plonkCalldata,
} from "../src/lib/prove.ts";

describe("end-to-end prove/verify", function () {
  let scenario: Scenario;
  let input: CredentialCircuitInput;

  before(async () => {
    scenario = await buildScenario();
    const cred = issueCredential(scenario, defaultCredentialFields(scenario.eddsa));
    input = await witnessFor(scenario, cred, scenario.appScopeA);
  });

  it("Groth16: a valid proof verifies; a tampered date or recipient does not", async () => {
    const { proof, publicSignals } = await proveGroth16("credential", input);
    assert.equal(publicSignals.length, 22);
    assert.equal(publicSignals[21], scenario.recipient.toString(), "recipient is bound as signal [21]");
    assert.ok(await verifyGroth16("credential", publicSignals, proof));

    const tamperedDate = publicSignals.slice();
    tamperedDate[1] = (BigInt(tamperedDate[1] as string) + 1n).toString(); // currentDate
    assert.equal(await verifyGroth16("credential", tamperedDate, proof), false);

    // Front-running: re-targeting the proof at another sender must fail.
    const tamperedRecipient = publicSignals.slice();
    tamperedRecipient[21] = BigInt("0x000000000000000000000000000000000000BAD0").toString();
    assert.equal(await verifyGroth16("credential", tamperedRecipient, proof), false);

    const cd = await groth16Calldata(proof, publicSignals);
    assert.equal(cd.a.length, 2);
    assert.equal(cd.pub.length, 22);
  });

  it("PLONK: a valid proof verifies; a tampered nullifier or recipient does not", async () => {
    const { proof, publicSignals } = await provePlonk("credential", input);
    assert.ok(await verifyPlonk("credential", publicSignals, proof));

    const tampered = publicSignals.slice();
    tampered[0] = (BigInt(tampered[0] as string) + 1n).toString(); // nullifier
    assert.equal(await verifyPlonk("credential", tampered, proof), false);

    const tamperedRecipient = publicSignals.slice();
    tamperedRecipient[21] = (BigInt(tamperedRecipient[21] as string) + 1n).toString();
    assert.equal(await verifyPlonk("credential", tamperedRecipient, proof), false);

    const cd = await plonkCalldata(proof, publicSignals);
    assert.equal(cd.proof.length, 24);
    assert.equal(cd.pub.length, 22);
  });
});
