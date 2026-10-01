// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManager} from "@openzeppelin-contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

import {OrderStatus} from "../../src/interfaces/IEscrowSettler.sol";
import {FillProofLib} from "../../src/libraries/FillProofLib.sol";
import {Intent, IntentLib} from "../../src/libraries/IntentLib.sol";
import {OptimisticSettlementModule} from "../../src/settlement/optimistic/OptimisticSettlementModule.sol";
import {HeaderStore} from "../../src/settlement/proof/HeaderStore.sol";
import {AnvilFixture} from "../utils/AnvilFixture.sol";
import {MerklePatriciaBuilder} from "../utils/MerklePatriciaBuilder.sol";

/// @title AnvilStorageProofTest
/// @notice Verifies, on-chain, real eth_getProof output captured from anvil by `npm run capture-proofs`
/// (test/fixtures/anvil-proofs.json): the header, the account proof, inclusion proofs of two fill records and the
/// exclusion proof of an unfilled order, plus tampered variants of each. The reference trie builder used by the
/// invariant suites is checked to reproduce anvil's storage root and proofs byte for byte. Finally the captured
/// orders are replayed at their original addresses and settled with the captured proofs.
contract AnvilStorageProofTest is AnvilFixture {
    function setUp() public {
        _loadFixture();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Header and account
    // ------------------------------------------------------------------------------------------------------------

    function test_header_hashesAndParses() public {
        assertEq(keccak256(headerRlp), blockHash, "anvil header RLP hashes to its block hash");
        vm.chainId(ORIGIN);
        AccessManager manager = new AccessManager(address(this));
        HeaderStore headers = new HeaderStore(address(manager));
        headers.submitHeader(DEST, headerRlp);
        (bytes32 root, uint64 timestamp) = headers.stateRootAt(DEST, blockNumber);
        assertEq(root, stateRoot);
        assertEq(timestamp, headerTimestamp);
        assertEq(headers.header(DEST, blockNumber).blockHash, blockHash);
    }

    function test_accountProof_yieldsAnvilStorageRoot() public view {
        assertEq(h.storageRoot(stateRoot, settler, accountProof), storageHash);
    }

    function test_accountProof_rejectsEveryTamperedByte() public {
        for (uint256 n = 0; n < accountProof.length; ++n) {
            for (uint256 i = 0; i < accountProof[n].length; i += 7) {
                bytes[] memory tampered = _copy(accountProof);
                tampered[n][i] ^= 0x01;
                vm.expectRevert();
                h.storageRoot(stateRoot, settler, tampered);
            }
        }
    }

    function test_accountProof_rejectsOtherAccount() public {
        vm.expectRevert();
        h.storageRoot(stateRoot, address(0xBEEF), accountProof);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Storage proofs
    // ------------------------------------------------------------------------------------------------------------

    function test_inclusion_ofBothFillRecords() public view {
        address repayment = vm.parseJsonAddress(json, ".repayment");
        string[2] memory names = ["filledProof", "filledOptimistic"];
        for (uint256 k = 0; k < 2; ++k) {
            (bytes32 orderId, bytes memory originData, bytes32 slot, uint256 value, bytes[] memory proof) =
                _order(names[k]);
            assertEq(slot, FillProofLib.fillerSlot(orderId), "slot derivation matches the TypeScript solver");
            assertEq(
                orderId,
                IntentLib.orderId(ORIGIN, abi.decode(originData, (Intent)).originSettler, keccak256(originData))
            );
            assertEq(h.includedSlot(storageHash, slot, proof), value);
            assertEq(h.slotValue(storageHash, slot, proof), value);
            assertFalse(h.isAbsent(storageHash, slot, proof));
            (address filler,) = FillProofLib.unpack(value);
            assertEq(filler, repayment);
        }
    }

    function test_exclusion_ofUnfilledOrder() public {
        (bytes32 orderId,, bytes32 slot, uint256 value, bytes[] memory proof) = _order("unfilledOptimistic");
        assertEq(value, 0);
        assertEq(slot, FillProofLib.fillerSlot(orderId));
        assertTrue(h.isAbsent(storageHash, slot, proof), "anvil exclusion proof accepted");
        assertEq(h.slotValue(storageHash, slot, proof), 0);
        vm.expectRevert();
        h.includedSlot(storageHash, slot, proof);
    }

    function test_proofsCannotBeSwappedBetweenSlots() public {
        (,, bytes32 filledSlot,, bytes[] memory filledProof) = _order("filledProof");
        (,, bytes32 emptySlot,, bytes[] memory emptyProof) = _order("unfilledOptimistic");
        // Exclusion proof of the empty slot does not prove the filled slot absent...
        assertFalse(h.isAbsent(storageHash, filledSlot, emptyProof));
        // ...and the inclusion proof of the filled slot never proves the empty one present.
        vm.expectRevert();
        h.includedSlot(storageHash, emptySlot, filledProof);
        // It can prove the empty slot ABSENT, which is true: when both secure-trie keys start with the same nibble
        // (1 capture in 16), the empty key's path ends at the filled slot's leaf and diverges there, exactly like
        // anvil's own exclusion proof. With different first nibbles the filled path never reaches the empty key.
        bool sameFirstNibble = keccak256(abi.encode(emptySlot))[0] >> 4 == keccak256(abi.encode(filledSlot))[0] >> 4;
        if (!sameFirstNibble) assertFalse(h.isAbsent(storageHash, emptySlot, filledProof));
        try h.slotValue(storageHash, emptySlot, filledProof) returns (uint256 value) {
            assertEq(value, 0, "a swapped proof shows a value for the empty slot");
        } catch {}
    }

    function test_storageProofs_rejectEveryTamperedByte() public {
        string[3] memory names = ["filledProof", "unfilledOptimistic", "filledOptimistic"];
        for (uint256 k = 0; k < 3; ++k) {
            (,, bytes32 slot,, bytes[] memory proof) = _order(names[k]);
            for (uint256 n = 0; n < proof.length; ++n) {
                for (uint256 i = 0; i < proof[n].length; i += 5) {
                    bytes[] memory tampered = _copy(proof);
                    tampered[n][i] ^= 0x80;
                    assertFalse(_absentOrReverts(slot, tampered), "tampered exclusion accepted");
                    vm.expectRevert();
                    h.includedSlot(storageHash, slot, tampered);
                }
            }
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Differential: reference builder vs anvil
    // ------------------------------------------------------------------------------------------------------------

    function _anvilStorage() internal view returns (bytes32[] memory keys, bytes[] memory values) {
        uint256 n = 0;
        while (vm.keyExistsJson(json, string.concat(".storage[", vm.toString(n), "]"))) ++n;
        keys = new bytes32[](n);
        values = new bytes[](n);
        for (uint256 i = 0; i < n; ++i) {
            string memory base = string.concat(".storage[", vm.toString(i), "]");
            keys[i] = keccak256(abi.encode(vm.parseJsonBytes32(json, string.concat(base, ".slot"))));
            values[i] =
                MerklePatriciaBuilder.storageLeaf(uint256(vm.parseJsonBytes32(json, string.concat(base, ".value"))));
        }
    }

    function test_builder_reproducesAnvilStorageRootAndProofs() public view {
        (bytes32[] memory keys, bytes[] memory values) = _anvilStorage();
        assertEq(keys.length, 4, "two fill records of two words each");
        assertEq(MerklePatriciaBuilder.root(keys, values), storageHash, "same storage root as anvil");
        string[3] memory names = ["filledProof", "unfilledOptimistic", "filledOptimistic"];
        for (uint256 k = 0; k < 3; ++k) {
            (,, bytes32 slot,, bytes[] memory anvilProof) = _order(names[k]);
            (, bytes[] memory built) = MerklePatriciaBuilder.prove(keys, values, keccak256(abi.encode(slot)));
            assertEq(built.length, anvilProof.length, "proof length");
            for (uint256 i = 0; i < built.length; ++i) {
                assertEq(built[i], anvilProof[i], "proof node");
            }
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // End to end at the captured addresses
    // ------------------------------------------------------------------------------------------------------------

    function test_replay_proofModeRepaysWithAnvilProof() public {
        Replay memory r = _replay();
        (bytes32 orderId, bytes memory originData,,, bytes[] memory proof) = _order("filledProof");
        address repayment = vm.parseJsonAddress(json, ".repayment");
        IERC20 token = IERC20(vm.parseJsonAddress(json, ".origin.inputToken"));
        uint256 amount = abi.decode(originData, (Intent)).data.inputAmount;
        r.proofModule.proveFill(orderId, blockNumber, keccak256(originData), accountProof, proof);
        assertEq(token.balanceOf(repayment), amount);
        assertEq(uint8(r.origin.escrowOf(orderId).status), uint8(OrderStatus.Repaid));
    }

    function test_replay_proofModeRejectsUnfilledOrder() public {
        Replay memory r = _replay();
        (bytes32 orderId, bytes memory originData,,, bytes[] memory proof) = _order("unfilledOptimistic");
        vm.expectRevert();
        r.proofModule.proveFill(orderId, blockNumber, keccak256(originData), accountProof, proof);
    }

    function test_replay_fraudOnUnfilledOrderSlashedWithAnvilExclusionProof() public {
        Replay memory r = _replay();
        (bytes32 orderId, bytes memory originData,,, bytes[] memory proof) = _order("unfilledOptimistic");
        address attacker = makeAddr("attacker");
        uint64 claimedAt = uint64(headerTimestamp - 10);
        _claim(r, attacker, orderId, attacker, claimedAt, keccak256(originData));
        address watcher = makeAddr("watcher");
        vm.prank(watcher);
        r.optimistic.challenge(orderId, attacker, claimedAt, blockNumber, accountProof, proof);
        assertEq(r.bond.balanceOf(watcher), 50e18);
        assertEq(uint8(r.origin.escrowOf(orderId).status), uint8(OrderStatus.Open));
    }

    function test_replay_fraudOnFilledOrderSlashedWithAnvilInclusionProof() public {
        Replay memory r = _replay();
        (bytes32 orderId, bytes memory originData,,, bytes[] memory proof) = _order("filledOptimistic");
        address attacker = makeAddr("attacker");
        uint64 claimedAt = uint64(headerTimestamp - 10);
        _claim(r, attacker, orderId, attacker, claimedAt, keccak256(originData));
        address watcher = makeAddr("watcher");
        vm.prank(watcher);
        r.optimistic.challenge(orderId, attacker, claimedAt, blockNumber, accountProof, proof);
        assertEq(r.bond.balanceOf(watcher), 50e18);
    }

    function test_replay_honestClaimCannotBeChallengedWithAnvilProof() public {
        Replay memory r = _replay();
        (bytes32 orderId, bytes memory originData,, uint256 value, bytes[] memory proof) = _order("filledOptimistic");
        (address filler, uint64 filledAt) = FillProofLib.unpack(value);
        _claim(r, makeAddr("solver"), orderId, filler, filledAt, keccak256(originData));
        vm.expectRevert(abi.encodeWithSelector(OptimisticSettlementModule.ClaimNotFraudulent.selector, orderId));
        r.optimistic.challenge(orderId, filler, filledAt, blockNumber, accountProof, proof);
    }

    // ------------------------------------------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------------------------------------------

    function _absentOrReverts(bytes32 slot, bytes[] memory proof) internal view returns (bool) {
        try h.isAbsent(storageHash, slot, proof) returns (bool absent) {
            return absent;
        } catch {
            return false;
        }
    }

    function _copy(bytes[] memory proof) internal pure returns (bytes[] memory out) {
        out = new bytes[](proof.length);
        for (uint256 i = 0; i < proof.length; ++i) {
            out[i] = bytes.concat(proof[i]);
        }
    }
}
