// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import {RLP} from "@openzeppelin-contracts/utils/RLP.sol";

import {OriginSettler} from "../../src/OriginSettler.sol";
import {IEscrowSettler, OrderStatus} from "../../src/interfaces/IEscrowSettler.sol";
import {FillProofLib} from "../../src/libraries/FillProofLib.sol";
import {DestinationRegistry} from "../../src/settlement/proof/DestinationRegistry.sol";
import {HeaderStore} from "../../src/settlement/proof/HeaderStore.sol";
import {StorageProofSettlementModule} from "../../src/settlement/proof/StorageProofSettlementModule.sol";
import {IntentTestBase} from "../utils/IntentTestBase.sol";
import {MerklePatriciaBuilder} from "../utils/MerklePatriciaBuilder.sol";

/// @dev Exposes the registry's internal lookup.
contract RegistryHarness is DestinationRegistry {
    constructor(address authority) DestinationRegistry(authority) {}

    function settlerOf(uint256 chainId) external view returns (address) {
        return _settlerOf(chainId);
    }

    function hasPendingClaim(bytes32) external pure returns (bool) {
        return false;
    }
}

/// @dev External wrapper for FillProofLib.storageRoot.
contract AccountProofHarness {
    function storageRoot(bytes32 stateRoot, address account, bytes[] memory proof) external pure returns (bytes32) {
        return FillProofLib.storageRoot(stateRoot, account, proof);
    }
}

/// @notice Settlement mode 3 against synthetic tries built from the destination settler's real storage.
/// test/fixtures/AnvilStorageProof.t.sol repeats the key cases on real eth_getProof output.
contract StorageProofSettlementTest is IntentTestBase {
    OrderParams internal p;
    bytes32 internal orderId;
    bytes internal originData;

    function setUp() public override {
        super.setUp();
        p = _params(address(proofModule));
        (orderId, originData) = _openGasless(p, 1);
    }

    function test_proveFill_repaysRecordedFiller() public {
        _fill(orderId, originData, solver, solverRepayment);
        uint64 filledAt = uint64(block.timestamp);
        DestProof memory proof = _relayDestState(orderId);

        vm.expectEmit(address(proofModule));
        emit StorageProofSettlementModule.FillProven(orderId, DEST, proof.blockNumber, solverRepayment, filledAt);
        vm.prank(rival); // anyone can submit; the money goes to the recorded filler
        proofModule.proveFill(orderId, proof.blockNumber, keccak256(originData), proof.accountProof, proof.slotProof);

        assertEq(inputToken.balanceOf(solverRepayment), p.inputAmount);
        assertEq(inputToken.balanceOf(rival), 0);
        assertEq(uint8(origin.escrowOf(orderId).status), uint8(OrderStatus.Repaid));

        vm.expectRevert(abi.encodeWithSelector(OriginSettler.OrderNotOpen.selector, orderId, OrderStatus.Repaid));
        proofModule.proveFill(orderId, proof.blockNumber, keccak256(originData), proof.accountProof, proof.slotProof);
    }

    function test_proveFill_rejectsUnfilledOrder() public {
        DestProof memory proof = _relayDestState(orderId); // exclusion proof of the slot
        vm.expectRevert();
        proofModule.proveFill(orderId, proof.blockNumber, keccak256(originData), proof.accountProof, proof.slotProof);
    }

    function test_proveFill_rejectsStateFromBeforeTheFill() public {
        DestProof memory before = _relayDestState(orderId);
        _fill(orderId, originData, solver, solverRepayment);
        _relayDestState(orderId);
        // Proof of the post-fill trie against the pre-fill header: the roots do not match.
        DestProof memory afterFill = _relayDestState(orderId);
        vm.expectRevert();
        proofModule.proveFill(
            orderId, before.blockNumber, keccak256(originData), afterFill.accountProof, afterFill.slotProof
        );
    }

    function test_proveFill_rejectsForeignFillHash() public {
        _fill(orderId, originData, solver, solverRepayment);
        DestProof memory proof = _relayDestState(orderId);
        vm.expectRevert(abi.encodeWithSelector(OriginSettler.FillHashMismatch.selector, orderId, bytes32(uint256(5))));
        proofModule.proveFill(orderId, proof.blockNumber, bytes32(uint256(5)), proof.accountProof, proof.slotProof);
    }

    function test_proveFill_rejectsAnotherOrdersRecord() public {
        (bytes32 otherId, bytes memory otherData) = _openGasless(p, 2);
        _fill(otherId, otherData, solver, solverRepayment);
        DestProof memory proof = _relayDestState(otherId);
        vm.expectRevert();
        proofModule.proveFill(orderId, proof.blockNumber, keccak256(originData), proof.accountProof, proof.slotProof);
    }

    function test_proveFill_rejectsTamperedAccountProof() public {
        _fill(orderId, originData, solver, solverRepayment);
        DestProof memory proof = _relayDestState(orderId);
        bytes memory last = proof.accountProof[proof.accountProof.length - 1];
        last[last.length - 1] = bytes1(uint8(last[last.length - 1]) ^ 1);
        vm.expectRevert();
        proofModule.proveFill(orderId, proof.blockNumber, keccak256(originData), proof.accountProof, proof.slotProof);
    }

    function test_proveFill_rejectsUnknownHeaderAndUnknownOrder() public {
        vm.expectRevert(abi.encodeWithSelector(HeaderStore.UnknownHeader.selector, DEST, 777));
        proofModule.proveFill(orderId, 777, keccak256(originData), new bytes[](0), new bytes[](0));
        // An unknown order has no destination chain; no header can exist for chain 0.
        vm.expectRevert(abi.encodeWithSelector(HeaderStore.UnknownHeader.selector, 0, 1));
        proofModule.proveFill(bytes32(uint256(1)), 1, bytes32(0), new bytes[](0), new bytes[](0));
    }

    function test_constructor_rejectsZeroDependencies() public {
        vm.expectRevert(StorageProofSettlementModule.ZeroDependency.selector);
        new StorageProofSettlementModule(IEscrowSettler(address(0)), headers, address(originManager));
        vm.expectRevert(StorageProofSettlementModule.ZeroDependency.selector);
        new StorageProofSettlementModule(
            IEscrowSettler(address(origin)), HeaderStore(address(0)), address(originManager)
        );
    }

    function test_registry_revertsForUnknownChain() public {
        RegistryHarness registry = new RegistryHarness(address(originManager));
        vm.expectRevert(abi.encodeWithSelector(DestinationRegistry.UnknownDestinationChain.selector, 42));
        registry.settlerOf(42);
    }

    /// @dev A proven account whose RLP is not [nonce, balance, storageRoot, codeHash] is rejected.
    function test_accountProof_rejectsMalformedAccount() public {
        bytes[] memory fields = new bytes[](3);
        fields[0] = RLP.encode(uint256(1));
        fields[1] = RLP.encode(uint256(0));
        fields[2] = RLP.encode(keccak256("storage"));
        bytes32[] memory keys = new bytes32[](1);
        bytes[] memory values = new bytes[](1);
        keys[0] = keccak256(abi.encodePacked(address(dest)));
        values[0] = RLP.encode(fields);
        (bytes32 root, bytes[] memory proof) = MerklePatriciaBuilder.prove(keys, values, keys[0]);
        AccountProofHarness h = new AccountProofHarness();
        vm.expectRevert(FillProofLib.MalformedAccount.selector);
        h.storageRoot(root, address(dest), proof);
    }

    function test_registry_isWriteOnceAndRestricted() public {
        vm.chainId(ORIGIN);
        assertEq(proofModule.destinationSettler(DEST), address(dest));
        assertFalse(proofModule.hasPendingClaim(orderId));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        proofModule.setDestinationSettler(7, address(1));
        vm.startPrank(admin);
        vm.expectRevert(DestinationRegistry.ZeroDestinationSettler.selector);
        proofModule.setDestinationSettler(7, address(0));
        vm.expectRevert(abi.encodeWithSelector(DestinationRegistry.DestinationSettlerAlreadySet.selector, DEST));
        proofModule.setDestinationSettler(DEST, address(1));
        vm.expectEmit(address(proofModule));
        emit DestinationRegistry.DestinationSettlerSet(7, address(1));
        proofModule.setDestinationSettler(7, address(1));
        vm.stopPrank();
    }
}
