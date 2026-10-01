// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IEscrowSettler} from "../../interfaces/IEscrowSettler.sol";
import {ISettlementModule} from "../../interfaces/ISettlementModule.sol";
import {FillProofLib} from "../../libraries/FillProofLib.sol";
import {DestinationRegistry} from "./DestinationRegistry.sol";
import {HeaderStore} from "./HeaderStore.sol";

/// @title StorageProofSettlementModule
/// @notice Settlement mode 3. Releases an escrow on a Merkle-Patricia proof that the destination settler's storage,
/// under a relayed destination block header, holds the fill record of the order.
/// @dev Trust model: only the header relayer (HeaderStore). No liveness assumption beyond "someone submits the
///      proof", no bond, no challenge window; repayment is final as soon as the proof verifies. Permissionless: the
///      escrow always goes to the repayment address recorded by the fill, whoever submits the proof.
contract StorageProofSettlementModule is DestinationRegistry {
    /// @notice OriginSettler whose escrows this module releases.
    IEscrowSettler public immutable ORIGIN_SETTLER;

    /// @notice Source of trusted destination state roots.
    HeaderStore public immutable HEADERS;

    /// @notice Emitted when a fill is proven and forwarded to the OriginSettler.
    /// @param orderId The order id.
    /// @param chainId The destination chain.
    /// @param blockNumber Destination block the proof was made against.
    /// @param filler The proven repayment address.
    /// @param filledAt The proven fill timestamp.
    event FillProven(
        bytes32 indexed orderId, uint256 indexed chainId, uint256 blockNumber, address indexed filler, uint64 filledAt
    );

    /// @notice A constructor dependency is the zero address.
    error ZeroDependency();

    /// @param originSettler OriginSettler whose escrows this module releases.
    /// @param headers HeaderStore of destination headers.
    /// @param authority AccessManager governing `setDestinationSettler`.
    constructor(IEscrowSettler originSettler, HeaderStore headers, address authority) DestinationRegistry(authority) {
        require(address(originSettler) != address(0) && address(headers) != address(0), ZeroDependency());
        ORIGIN_SETTLER = originSettler;
        HEADERS = headers;
    }

    /// @notice Proves the fill of `orderId` and repays its filler.
    /// @param orderId The order id.
    /// @param blockNumber A destination block whose header is in the HeaderStore and that includes the fill.
    /// @param fillHash keccak256 of the filled originData; checked against `orderId` by the OriginSettler.
    /// @param accountProof eth_getProof(destinationSettler, [slot], blockNumber).accountProof
    /// @param slotProof eth_getProof(...).storageProof[0].proof for `FillProofLib.fillerSlot(orderId)`.
    function proveFill(
        bytes32 orderId,
        uint256 blockNumber,
        bytes32 fillHash,
        bytes[] calldata accountProof,
        bytes[] calldata slotProof
    ) external {
        uint256 chainId = ORIGIN_SETTLER.escrowOf(orderId).destinationChainId;
        (address filler, uint64 filledAt) = _provenRecord(orderId, chainId, blockNumber, accountProof, slotProof);
        // Prior external calls are view calls to immutable protocol contracts (HeaderStore, OriginSettler).
        // forge-lint: disable-next-line(reentrancy-events)
        emit FillProven(orderId, chainId, blockNumber, filler, filledAt);
        ORIGIN_SETTLER.settle(orderId, chainId, filler, fillHash);
    }

    /// @dev Verifies header -> account -> slot and returns the recorded (filler, filledAt).
    function _provenRecord(
        bytes32 orderId,
        uint256 chainId,
        uint256 blockNumber,
        bytes[] calldata accountProof,
        bytes[] calldata slotProof
    ) internal view returns (address filler, uint64 filledAt) {
        // The header timestamp is irrelevant for an inclusion proof: fill records are write-once.
        // slither-disable-start unused-return
        // forge-lint: disable-next-line(unused-return)
        (bytes32 stateRoot,) = HEADERS.stateRootAt(chainId, blockNumber);
        // slither-disable-end unused-return
        bytes32 storageRoot = FillProofLib.storageRoot(stateRoot, _settlerOf(chainId), accountProof);
        return FillProofLib.unpack(FillProofLib.includedSlot(storageRoot, FillProofLib.fillerSlot(orderId), slotProof));
    }

    /// @inheritdoc ISettlementModule
    /// @dev Proofs settle atomically, so there is never a pending claim.
    function hasPendingClaim(bytes32) external pure returns (bool) {
        return false;
    }
}
