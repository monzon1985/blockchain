// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin-contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {OriginSettler} from "../../src/OriginSettler.sol";
import {OnchainCrossChainOrder} from "../../src/erc7683/IERC7683.sol";
import {IEscrowSettler, OrderStatus} from "../../src/interfaces/IEscrowSettler.sol";
import {FillProofLib} from "../../src/libraries/FillProofLib.sol";
import {Intent, IntentLib} from "../../src/libraries/IntentLib.sol";
import {MerklePatriciaExclusion} from "../../src/libraries/MerklePatriciaExclusion.sol";
import {OptimisticSettlementModule} from "../../src/settlement/optimistic/OptimisticSettlementModule.sol";
import {HeaderStore} from "../../src/settlement/proof/HeaderStore.sol";
import {StorageProofSettlementModule} from "../../src/settlement/proof/StorageProofSettlementModule.sol";
import {MockERC20} from "./TestTokens.sol";

/// @dev External wrappers so reverts inside libraries can be asserted.
contract ProofHarness {
    function storageRoot(bytes32 stateRoot, address account, bytes[] memory proof) external pure returns (bytes32) {
        return FillProofLib.storageRoot(stateRoot, account, proof);
    }

    function includedSlot(bytes32 root, bytes32 slot, bytes[] memory proof) external pure returns (uint256) {
        return FillProofLib.includedSlot(root, slot, proof);
    }

    function slotValue(bytes32 root, bytes32 slot, bytes[] memory proof) external pure returns (uint256) {
        return FillProofLib.slotValue(root, slot, proof);
    }

    function isAbsent(bytes32 root, bytes32 slot, bytes[] memory proof) external pure returns (bool) {
        return MerklePatriciaExclusion.isAbsent(root, abi.encodePacked(keccak256(abi.encode(slot))), proof);
    }

    /// @notice Account proof, then one storage slot: what settlement mode 3 verifies.
    function verifyRecord(
        bytes32 stateRoot,
        address account,
        bytes[] memory accountProof,
        bytes32 slot,
        bytes[] memory proof
    ) external pure returns (uint256) {
        return FillProofLib.includedSlot(FillProofLib.storageRoot(stateRoot, account, accountProof), slot, proof);
    }

    /// @notice Account proof, then both FillRecord slots: the design mode 3 avoids (gas baseline).
    function verifyRecordAndFillHash(
        bytes32 stateRoot,
        address account,
        bytes[] memory accountProof,
        bytes32 slot,
        bytes[] memory proof,
        bytes32 fillHashSlot,
        bytes[] memory fillHashProof
    ) external pure returns (uint256 record, uint256 fillHash) {
        bytes32 root = FillProofLib.storageRoot(stateRoot, account, accountProof);
        record = FillProofLib.includedSlot(root, slot, proof);
        fillHash = FillProofLib.includedSlot(root, fillHashSlot, fillHashProof);
    }
}

/// @title AnvilFixture
/// @notice Loads test/fixtures/anvil-proofs.json (captured by `npm run capture-proofs`) and can replay the captured
/// origin side at its original addresses, so real anvil proofs settle real orders in a Foundry test.
abstract contract AnvilFixture is Test {
    uint256 internal constant ORIGIN = 1001;
    uint256 internal constant DEST = 1002;

    string internal json;
    ProofHarness internal h = new ProofHarness();

    bytes internal headerRlp;
    bytes32 internal blockHash;
    bytes32 internal stateRoot;
    uint256 internal blockNumber;
    uint256 internal headerTimestamp;
    bytes[] internal accountProof;
    bytes32 internal storageHash;
    address internal settler;

    function _loadFixture() internal {
        // ANVIL_FIXTURE lets CI verify a fixture freshly captured on its own anvil; the committed one is the default.
        string memory path = vm.envOr("ANVIL_FIXTURE", string("test/fixtures/anvil-proofs.json"));
        json = vm.readFile(string.concat(vm.projectRoot(), "/", path));
        headerRlp = vm.parseJsonBytes(json, ".header.rlp");
        blockHash = vm.parseJsonBytes32(json, ".header.hash");
        stateRoot = vm.parseJsonBytes32(json, ".header.stateRoot");
        blockNumber = vm.parseJsonUint(json, ".header.number");
        headerTimestamp = vm.parseJsonUint(json, ".header.timestamp");
        accountProof = vm.parseJsonBytesArray(json, ".account.proof");
        storageHash = vm.parseJsonBytes32(json, ".account.storageHash");
        settler = vm.parseJsonAddress(json, ".destinationSettler");
    }

    function _order(string memory name)
        internal
        view
        returns (bytes32 orderId, bytes memory originData, bytes32 slot, uint256 value, bytes[] memory proof)
    {
        string memory base = string.concat(".orders.", name);
        orderId = vm.parseJsonBytes32(json, string.concat(base, ".orderId"));
        originData = vm.parseJsonBytes(json, string.concat(base, ".originData"));
        slot = vm.parseJsonBytes32(json, string.concat(base, ".slot"));
        value = uint256(vm.parseJsonBytes32(json, string.concat(base, ".value")));
        proof = vm.parseJsonBytesArray(json, string.concat(base, ".proof"));
    }

    struct Replay {
        OriginSettler origin;
        HeaderStore headers;
        OptimisticSettlementModule optimistic;
        StorageProofSettlementModule proofModule;
        MockERC20 bond;
    }

    /// @dev Recreates the origin side at the captured addresses and re-opens the three captured orders (on-chain
    ///      nonces 0, 1, 2 of the captured user), which yields the same order ids.
    function _replay() internal returns (Replay memory r) {
        vm.chainId(ORIGIN);
        vm.warp(headerTimestamp);
        AccessManager manager = new AccessManager(address(this));
        r.headers = new HeaderStore(address(manager));
        r.bond = new MockERC20("Bond", "BOND");
        address originAddress = vm.parseJsonAddress(json, ".origin.originSettler");
        deployCodeTo(
            "OriginSettler.sol:OriginSettler",
            abi.encode(ISignatureTransfer(address(0xFEED)), uint256(1 hours), address(manager)),
            originAddress
        );
        r.origin = OriginSettler(originAddress);
        address proofAddress = vm.parseJsonAddress(json, ".origin.proofModule");
        deployCodeTo(
            "StorageProofSettlementModule.sol:StorageProofSettlementModule",
            abi.encode(IEscrowSettler(originAddress), r.headers, address(manager)),
            proofAddress
        );
        r.proofModule = StorageProofSettlementModule(proofAddress);
        address optimisticAddress = vm.parseJsonAddress(json, ".origin.optimisticModule");
        deployCodeTo(
            "OptimisticSettlementModule.sol:OptimisticSettlementModule",
            abi.encode(
                IEscrowSettler(originAddress), r.headers, r.bond, uint256(50e18), uint256(1 hours), address(manager)
            ),
            optimisticAddress
        );
        r.optimistic = OptimisticSettlementModule(optimisticAddress);
        address inputToken = vm.parseJsonAddress(json, ".origin.inputToken");
        deployCodeTo("TestTokens.sol:MockERC20", abi.encode("Input", "IN"), inputToken);

        r.proofModule.setDestinationSettler(DEST, settler);
        r.optimistic.setDestinationSettler(DEST, settler);
        r.origin.setSettlementModule(proofAddress, true);
        r.origin.setSettlementModule(optimisticAddress, true);
        r.headers.submitHeader(DEST, headerRlp);

        address user = vm.parseJsonAddress(json, ".user");
        string[3] memory names = ["filledProof", "unfilledOptimistic", "filledOptimistic"];
        for (uint256 k = 0; k < 3; ++k) {
            (bytes32 orderId, bytes memory originData,,,) = _order(names[k]);
            Intent memory intent = abi.decode(originData, (Intent));
            MockERC20(inputToken).mint(user, intent.data.inputAmount);
            vm.startPrank(user);
            IERC20(inputToken).approve(originAddress, intent.data.inputAmount);
            r.origin
                .open(
                    OnchainCrossChainOrder(
                        intent.fillDeadline, IntentLib.INTENT_ORDER_DATA_TYPEHASH, abi.encode(intent.data)
                    )
                );
            vm.stopPrank();
            assertEq(uint8(r.origin.escrowOf(orderId).status), uint8(OrderStatus.Open), "same order id as on anvil");
        }
    }

    function _claim(
        Replay memory r,
        address claimant,
        bytes32 orderId,
        address filler,
        uint64 filledAt,
        bytes32 fillHash
    ) internal {
        r.bond.mint(claimant, 50e18);
        vm.startPrank(claimant);
        r.bond.approve(address(r.optimistic), 50e18);
        r.optimistic.claim(orderId, filler, filledAt, fillHash);
        vm.stopPrank();
    }
}
