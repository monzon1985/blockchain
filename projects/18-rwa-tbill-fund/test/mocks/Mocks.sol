// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC1271} from "@openzeppelin-contracts/interfaces/IERC1271.sol";
import {
    IComplianceEngine,
    IComplianceModule,
    TransferContext,
    TransferKind
} from "../../src/interfaces/ICompliance.sol";
// The USDC mock is shared with the local demo script, which must not depend on test code; re-exported here.
import {MockUSDC} from "../../script/mocks/MockUSDC.sol";

/// @notice ERC-1271 claim issuer: a contract that approves specific digests (e.g. a multisig KYC provider).
contract MockERC1271Issuer is IERC1271 {
    mapping(bytes32 digest => bool approved) public approved;

    function approve(bytes32 digest, bool status) external {
        approved[digest] = status;
    }

    function isValidSignature(bytes32 hash, bytes memory) external view returns (bytes4) {
        return approved[hash] ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

/// @notice Test-only stateful module that mirrors every movement it is told about. If any code path moved
///         shares without going through the engine, the mirror would diverge from `balanceOf`.
contract ComplianceProbe is IComplianceModule {
    address public immutable engine;
    mapping(address wallet => uint256 balance) public mirror;
    uint256 public mirroredSupply;
    uint256 public calls;
    mapping(TransferKind kind => uint256 count) public callsByKind;

    constructor(address engine_) {
        engine = engine_;
    }

    function name() external pure returns (string memory) {
        return "ComplianceProbe";
    }

    function isStateful() external pure returns (bool) {
        return true;
    }

    function check(TransferContext calldata) external pure returns (bool) {
        return true;
    }

    function onTransfer(TransferContext calldata ctx) external {
        require(msg.sender == engine, "probe: not engine");
        ++calls;
        ++callsByKind[ctx.kind];
        if (ctx.from == address(0)) mirroredSupply += ctx.amount;
        else mirror[ctx.from] -= ctx.amount;
        if (ctx.to == address(0)) mirroredSupply -= ctx.amount;
        else mirror[ctx.to] += ctx.amount;
    }
}

/// @notice Module whose check reverts (exercises the never-revert guarantee of `canTransfer`).
contract RevertingModule is IComplianceModule {
    address public immutable engine;

    constructor(address engine_) {
        engine = engine_;
    }

    function name() external pure returns (string memory) {
        return "Reverting";
    }

    function isStateful() external pure returns (bool) {
        return false;
    }

    function check(TransferContext calldata) external pure returns (bool) {
        revert("boom");
    }

    function onTransfer(TransferContext calldata) external pure {}
}

/// @notice Module with a configurable verdict.
contract ToggleModule is IComplianceModule {
    address public immutable engine;
    bool public allow = true;

    constructor(address engine_) {
        engine = engine_;
    }

    function setAllow(bool value) external {
        allow = value;
    }

    function name() external pure returns (string memory) {
        return "Toggle";
    }

    function isStateful() external pure returns (bool) {
        return false;
    }

    function check(TransferContext calldata) external view returns (bool) {
        return allow;
    }

    function onTransfer(TransferContext calldata) external pure {}
}

/// @notice Minimal token that reports to an engine, for engine unit tests without the real token's checks.
contract MockLedgerToken {
    IComplianceEngine public immutable engine;
    mapping(address account => uint256 balance) public balanceOf;

    constructor(IComplianceEngine engine_) {
        engine = engine_;
    }

    function move(TransferKind kind, address from, address to, uint256 amount) external {
        engine.transferred(kind, from, to, amount);
        if (from != address(0)) balanceOf[from] -= amount;
        if (to != address(0)) balanceOf[to] += amount;
    }
}

/// @notice Settable registry for engine unit tests.
contract MockIdentityRegistry {
    mapping(address wallet => bytes32 identity) public identityOf;
    mapping(bytes32 identity => uint16 country) public investorCountry;
    mapping(address wallet => bool verified) public isVerified;

    function set(address wallet, bytes32 identity, uint16 country) external {
        identityOf[wallet] = identity;
        investorCountry[identity] = country;
        isVerified[wallet] = identity != bytes32(0);
    }

    function setCountry(bytes32 identity, uint16 country) external {
        investorCountry[identity] = country;
    }
}

/// @notice Stateful module that tries to move shares from inside the engine callback.
contract ReentrantModule is IComplianceModule {
    address public immutable engine;
    address public immutable token;

    constructor(address engine_, address token_) {
        engine = engine_;
        token = token_;
    }

    function name() external pure returns (string memory) {
        return "Reentrant";
    }

    function isStateful() external pure returns (bool) {
        return true;
    }

    function check(TransferContext calldata) external pure returns (bool) {
        return true;
    }

    function onTransfer(TransferContext calldata ctx) external {
        if (ctx.kind == TransferKind.Transfer) {
            (bool ok, bytes memory ret) =
                token.call(abi.encodeWithSignature("transfer(address,uint256)", ctx.to, uint256(0)));
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}
