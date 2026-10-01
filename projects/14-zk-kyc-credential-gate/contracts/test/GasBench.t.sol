// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FixtureLoader} from "./base/FixtureLoader.sol";
import {ZkGate} from "../src/ZkGate.sol";
import {CredentialVerifier} from "generated/CredentialVerifier.sol";
import {CredentialVerifierPlonk} from "generated/CredentialVerifierPlonk.sol";
import {BaselineCommittedListVerifier} from "generated/BaselineCommittedListVerifier.sol";

/// @title GasBench
/// @notice Gas benchmarks for verification and end-to-end registration, for both proof systems, plus a
///         Groth16 baseline with 7 public signals (the sanctioned list committed to one element).
/// @dev Each test loads its fixture into MEMORY inside the test (no storage reads) and records exactly
///      the external call under test with `vm.snapshotGasLastFrame`, committed in snapshots/GasBench.json
///      and checked in CI with FORGE_SNAPSHOT_CHECK=true. The whole-test numbers in .gas-snapshot
///      (forge snapshot --check) additionally include fixture parsing and are a regression guard only.
contract GasBench is FixtureLoader {
    ZkGate internal gate;
    CredentialVerifier internal groth16;
    CredentialVerifierPlonk internal plonk;
    BaselineCommittedListVerifier internal baseline;
    address internal recipient;

    function setUp() public {
        GateFixture memory g = loadGate();
        useFixtureChain(g);
        recipient = g.recipient;
        groth16 = new CredentialVerifier();
        plonk = new CredentialVerifierPlonk();
        baseline = new BaselineCommittedListVerifier();
        gate = deployGateAt(g.gateAddress, fixtureConfig(g, address(groth16), address(plonk), address(this)));
    }

    function test_Gas_Groth16Verify() public {
        Groth16Fixture memory f = loadGroth16("valid_groth16.json");
        bool ok = groth16.verifyProof(f.a, f.b, f.c, f.pub);
        vm.snapshotGasLastFrame("groth16_verify_22_signals");
        assertTrue(ok);
    }

    function test_Gas_PlonkVerify() public {
        PlonkFixture memory f = loadPlonk("valid_plonk.json");
        bool ok = plonk.verifyProof(f.proof, f.pub);
        vm.snapshotGasLastFrame("plonk_verify_22_signals");
        assertTrue(ok);
    }

    function test_Gas_RegisterGroth16() public {
        Groth16Fixture memory f = loadGroth16("valid_groth16.json");
        vm.prank(recipient);
        gate.registerWithGroth16(f.a, f.b, f.c, f.pub);
        vm.snapshotGasLastFrame("register_groth16");
        assertTrue(gate.isRegistered(recipient));
    }

    function test_Gas_RegisterPlonk() public {
        PlonkFixture memory f = loadPlonk("valid_plonk.json");
        vm.prank(recipient);
        gate.registerWithPlonk(f.proof, f.pub);
        vm.snapshotGasLastFrame("register_plonk");
        assertTrue(gate.isRegistered(recipient));
    }

    function test_Gas_BaselineGroth16Verify7Signals() public {
        string memory json = _read("baseline_groth16.json");
        uint256[] memory a = vm.parseJsonUintArray(json, ".a");
        uint256[] memory b0 = vm.parseJsonUintArray(json, ".b[0]");
        uint256[] memory b1 = vm.parseJsonUintArray(json, ".b[1]");
        uint256[] memory c = vm.parseJsonUintArray(json, ".c");
        uint256[] memory p = vm.parseJsonUintArray(json, ".pub");
        require(p.length == 7, "baseline has 7 public signals");
        uint256[7] memory pub;
        for (uint256 i = 0; i < 7; i++) {
            pub[i] = p[i];
        }
        bool ok = baseline.verifyProof([a[0], a[1]], [[b0[0], b0[1]], [b1[0], b1[1]]], [c[0], c[1]], pub);
        vm.snapshotGasLastFrame("groth16_verify_7_signals_baseline");
        assertTrue(ok);
    }
}
