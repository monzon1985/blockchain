// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice EIP-7702 delegate in the style of a smart-account implementation: `isValidSignature` accepts the EOA's own
///         key and, optionally, one session key that the account sets on itself.
contract SmartAccount7702 is IERC1271 {
    /// @dev Lives in the delegating EOA's storage.
    address public sessionKey;

    function setSessionKey(address key) external {
        require(msg.sender == address(this), "only self");
        sessionKey = key;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered != address(0)) {
            if (recovered == address(this) || recovered == sessionKey) return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }
}

/// @notice EIP-7702 delegate that only batches calls and implements no ERC-1271 hook. An EOA delegating to it still
///         controls its key, so its plain ECDSA signatures must keep working.
contract BatchExecutor7702 {
    struct Call {
        address target;
        bytes data;
    }

    function execute(Call[] calldata calls) external {
        require(msg.sender == address(this), "only self");
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].target.call(calls[i].data);
            if (!ok) {
                // Bubble the revert reason. Memory-safe: reads the returned bytes only.
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}

/// @notice EIP-7702 delegate whose ERC-1271 hook rejects everything. The EOA key must still be authoritative.
contract RejectingDelegate7702 is IERC1271 {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff;
    }
}
