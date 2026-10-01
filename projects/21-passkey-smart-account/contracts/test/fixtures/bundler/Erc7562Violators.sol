// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccount, PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";

// Accounts that break ERC-7562 opcode rules during validation. bundler-lite must reject their user operations even
// though the EntryPoint itself would happily execute them. Test fixtures only: never deploy outside a devnet.

/// @dev OP-011: reads TIMESTAMP in validateUserOp (instead of returning a validity window).
contract TimestampAccount is IAccount {
    address public immutable ENTRY_POINT;

    constructor(address entryPoint_) {
        ENTRY_POINT = entryPoint_;
    }

    function validateUserOp(PackedUserOperation calldata, bytes32, uint256 missingAccountFunds)
        external
        returns (uint256)
    {
        require(msg.sender == ENTRY_POINT, "only EntryPoint");
        if (missingAccountFunds > 0) {
            (bool ok,) = payable(msg.sender).call{value: missingAccountFunds}("");
            ok;
        }
        return block.timestamp > 0 ? 0 : 1;
    }

    receive() external payable {}
}

/// @dev OP-061: sends value to an address other than the EntryPoint during validation.
contract ValueLeakAccount is IAccount {
    address public immutable ENTRY_POINT;

    constructor(address entryPoint_) {
        ENTRY_POINT = entryPoint_;
    }

    function validateUserOp(PackedUserOperation calldata, bytes32, uint256 missingAccountFunds)
        external
        returns (uint256)
    {
        require(msg.sender == ENTRY_POINT, "only EntryPoint");
        (bool sent,) = payable(address(0xdEaD)).call{value: 1}("");
        sent;
        if (missingAccountFunds > 0) {
            (bool ok,) = payable(msg.sender).call{value: missingAccountFunds}("");
            ok;
        }
        return 0;
    }

    receive() external payable {}
}

interface IEntryPointLike {
    function depositTo(address account) external payable;
    function incrementNonce(uint192 key) external;
}

/// @dev OP-054: calls an EntryPoint function other than `depositTo(sender)` or the fallback during validation.
contract EntryPointToucherAccount is IAccount {
    address public immutable ENTRY_POINT;

    constructor(address entryPoint_) {
        ENTRY_POINT = entryPoint_;
    }

    function validateUserOp(PackedUserOperation calldata, bytes32, uint256 missingAccountFunds)
        external
        returns (uint256)
    {
        require(msg.sender == ENTRY_POINT, "only EntryPoint");
        IEntryPointLike(msg.sender).incrementNonce(7);
        if (missingAccountFunds > 0) {
            (bool ok,) = payable(msg.sender).call{value: missingAccountFunds}("");
            ok;
        }
        return 0;
    }

    receive() external payable {}
}

/// @dev Allowed (OP-052): pays the prefund through `depositTo(sender)` instead of the EntryPoint's fallback.
contract DepositToAccount is IAccount {
    address public immutable ENTRY_POINT;

    constructor(address entryPoint_) {
        ENTRY_POINT = entryPoint_;
    }

    function validateUserOp(PackedUserOperation calldata, bytes32, uint256 missingAccountFunds)
        external
        returns (uint256)
    {
        require(msg.sender == ENTRY_POINT, "only EntryPoint");
        IEntryPointLike(msg.sender).depositTo{value: missingAccountFunds}(address(this));
        return 0;
    }

    receive() external payable {}
}
