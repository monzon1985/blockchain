// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Address} from "@openzeppelin-contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import {IBridge} from "./interfaces/IBridge.sol";
import {IForcedInclusionQueue} from "./interfaces/IForcedInclusionQueue.sol";
import {IOutputOracle} from "./interfaces/IOutputOracle.sol";
import {SmtProof} from "./lib/Types.sol";
import {RollupSpec} from "./lib/RollupSpec.sol";
import {SparseMerkle} from "./lib/SparseMerkle.sol";

/// @title Bridge
/// @notice Holds deposited ETH. Deposits go through the forced-inclusion queue (so the sequencer cannot ignore them);
///         withdrawals are proven by a sparse-Merkle proof against the state root of a finalized epoch.
/// @dev The L2 writes withdrawal `id` at key `keccak256(abi.encode(3, id))` with value
///      `keccak256(abi.encode(recipient, amount))` and never deletes it, so any finalized epoch at or after the
///      withdrawal proves it; `finalized` prevents double payment.
contract Bridge is IBridge, ReentrancyGuardTransient {
    /// @notice Forced-inclusion queue that carries deposits to L2.
    IForcedInclusionQueue public immutable QUEUE;
    /// @notice Output oracle providing finalized state roots.
    IOutputOracle public immutable ORACLE;

    /// @inheritdoc IBridge
    mapping(uint256 withdrawalId => bool) public finalized;

    /// @param queue Forced-inclusion queue.
    /// @param oracle Output oracle.
    constructor(IForcedInclusionQueue queue, IOutputOracle oracle) {
        require(address(queue) != address(0) && address(oracle) != address(0), ZeroParameter());
        QUEUE = queue;
        ORACLE = oracle;
    }

    /// @inheritdoc IBridge
    function deposit(address to) external payable returns (uint256 queueIndex) {
        require(msg.value != 0, ZeroDeposit());
        // Trusted call into the protocol's own immutable queue, which never calls back; the event needs its result.
        // slither-disable-next-line reentrancy-events
        queueIndex = QUEUE.enqueueDeposit(msg.sender, to, msg.value);
        // The event needs the queue index, so it follows the (trusted, immutable) queue call.
        // forge-lint: disable-next-line(reentrancy-events)
        emit DepositInitiated(msg.sender, to, msg.value, queueIndex);
    }

    /// @inheritdoc IBridge
    function finalizeWithdrawal(
        uint64 epoch,
        uint256 withdrawalId,
        address recipient,
        uint256 amount,
        SmtProof calldata proof
    ) external nonReentrant {
        require(!finalized[withdrawalId], AlreadyFinalized(withdrawalId));
        bytes32 stateRoot = ORACLE.finalizedStateRoot(epoch);
        bytes32 computed = SparseMerkle.computeRoot(
            RollupSpec.withdrawalKey(withdrawalId),
            RollupSpec.withdrawalValue(recipient, amount),
            proof.bitmap,
            proof.siblings
        );
        require(computed == stateRoot, InvalidWithdrawalProof(stateRoot, computed));

        finalized[withdrawalId] = true;
        // Follows a view call on the protocol's own immutable oracle.
        // forge-lint: disable-next-line(reentrancy-events)
        emit WithdrawalFinalized(withdrawalId, recipient, amount, epoch);
        // The recipient is the one committed in the finalized L2 state, not caller input: the proof binds it.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        Address.sendValue(payable(recipient), amount);
    }
}
