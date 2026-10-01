// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Minimal smart-contract wallet: accepts ERC-1271 signatures produced by its owner key and can execute
///         arbitrary calls for its owner. The owner can also switch validation off to model a wallet that revokes
///         a previously valid signature.
contract MockERC1271Wallet is IERC1271 {
    address public immutable owner;
    bool public rejectAll;

    error NotOwner();

    constructor(address owner_) {
        owner = owner_;
    }

    function setRejectAll(bool reject) external {
        require(msg.sender == owner, NotOwner());
        rejectAll = reject;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == owner, NotOwner());
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (rejectAll) return 0xffffffff;
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(hash, signature);
        return err == ECDSA.RecoverError.NoError && recovered == owner ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}
