// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";

/// @notice The subset of the eth-infinitism EntryPoint v0.9 ABI the tests use, typed with OpenZeppelin's
/// `PackedUserOperation` (ABI-identical to the eth-infinitism struct).
interface IEntryPointV09 {
    struct DepositInfo {
        uint256 deposit;
        bool staked;
        uint112 stake;
        uint32 unstakeDelaySec;
        uint48 withdrawTime;
    }

    event UserOperationEvent(
        bytes32 indexed userOpHash,
        address indexed sender,
        address indexed paymaster,
        uint256 nonce,
        bool success,
        uint256 actualGasCost,
        uint256 actualGasUsed
    );
    event UserOperationRevertReason(
        bytes32 indexed userOpHash, address indexed sender, uint256 nonce, bytes revertReason
    );
    event PostOpRevertReason(bytes32 indexed userOpHash, address indexed sender, uint256 nonce, bytes revertReason);

    error FailedOp(uint256 opIndex, string reason);
    error FailedOpWithRevert(uint256 opIndex, string reason, bytes inner);

    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external;
    function getUserOpHash(PackedUserOperation calldata userOp) external view returns (bytes32);
    function getNonce(address sender, uint192 key) external view returns (uint256 nonce);
    function balanceOf(address account) external view returns (uint256);
    function depositTo(address account) external payable;
    function getDepositInfo(address account) external view returns (DepositInfo memory info);
    function senderCreator() external view returns (address);
}
