// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {
    IERC7579Execution,
    IERC7579Module,
    MODULE_TYPE_EXECUTOR
} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Minimal ERC-1271 contract signer that accepts raw ECDSA signatures of one EOA.
contract Mock1271Signer is IERC1271 {
    address public immutable SIGNER;

    constructor(address signer) {
        SIGNER = signer;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(hash, signature);
        return err == ECDSA.RecoverError.NoError && recovered == SIGNER ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}

/// @notice Executor module that tries to make the account delegatecall into it (to prove the account refuses).
contract MaliciousDelegatecallExecutor is IERC7579Module {
    function onInstall(bytes calldata) external {}

    function onUninstall(bytes calldata) external {}

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    /// @notice Asks `account` to delegatecall `target` with `data` (CALLTYPE_DELEGATECALL = 0xff).
    function attack(address account, address target, bytes calldata data) external returns (bytes[] memory) {
        bytes32 mode = bytes32(bytes1(0xff));
        return IERC7579Execution(account).executeFromExecutor(mode, abi.encodePacked(target, data));
    }

    /// @notice Batch-mode call through the account (allowed, used to show only delegatecall is blocked).
    function single(address account, address target, bytes calldata data) external returns (bytes[] memory) {
        return IERC7579Execution(account).executeFromExecutor(bytes32(0), abi.encodePacked(target, uint256(0), data));
    }
}

/// @notice Contract whose code would take over an account's storage if it were ever delegatecalled.
contract StorageClobberer {
    function clobber() external {
        assembly ("memory-safe") {
            sstore(0, 0xdead)
        }
    }
}

/// @notice Deliberately non-standard settlement token used to exercise the defensive balance-delta checks:
///         - `feeBps` skims a fee on every transfer (fee-on-transfer token);
///         - `returnsBool == false` makes `transfer` return no data (USDT-style).
///         Authorization methods skip signature checks: only the accounting matters here.
contract QuirkyToken {
    mapping(address => uint256) public balanceOf;
    uint256 public feeBps;
    bool public returnsBool = true;

    function setFee(uint256 bps) external {
        feeBps = bps;
    }

    function setReturnsBool(bool value) external {
        returnsBool = value;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount - (amount * feeBps) / 10_000;
    }

    function transfer(address to, uint256 amount) external {
        _move(msg.sender, to, amount);
        if (returnsBool) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 32)
            }
        }
    }

    function transferWithAuthorization(address from, address to, uint256 value, uint256, uint256, bytes32, bytes memory)
        external
    {
        _move(from, to, value);
    }

    function receiveWithAuthorization(address from, address to, uint256 value, uint256, uint256, bytes32, bytes memory)
        external
    {
        require(msg.sender == to, "caller");
        _move(from, to, value);
    }
}
