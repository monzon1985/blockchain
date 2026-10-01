// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {WebAuthn} from "@openzeppelin/contracts/utils/cryptography/WebAuthn.sol";

// Deliberately vulnerable "before the fix" implementations. Test fixtures only: never deploy.

/// @notice H01 baseline: a 7702 delegate whose initializer is "first caller wins".
contract NaiveInitAccount {
    address public owner;

    function initialize(address owner_) external {
        require(owner == address(0), "already initialized");
        owner = owner_;
    }

    function execute(address to, uint256 value, bytes calldata data) external {
        require(msg.sender == owner || msg.sender == address(this), "not owner");
        (bool ok,) = to.call{value: value}(data);
        require(ok, "call failed");
    }

    receive() external payable {}
}

/// @notice H02 baseline A: plain storage layout (slot 0 nonce, slot 1 session key).
contract SessionKeyAccountA {
    uint256 public nonce;
    address public sessionKey;

    function grantSession(address key) external {
        require(msg.sender == address(this), "only self");
        nonce += 1;
        sessionKey = key;
    }

    receive() external payable {}
}

/// @notice H02 baseline B: another vendor's plain layout (slot 0 initialized version, slot 1 owner).
contract PlainOwnerAccountB {
    uint256 public initializedVersion;
    address public owner;

    function initialize(address owner_) external {
        require(msg.sender == address(this), "only self");
        require(initializedVersion == 0, "already initialized");
        initializedVersion = 1;
        owner = owner_;
    }

    function execute(address to, uint256 value) external {
        require(msg.sender == owner, "not owner");
        (bool ok,) = to.call{value: value}("");
        require(ok, "call failed");
    }

    receive() external payable {}
}

/// @notice H03: what an attacker places at the delegation target address on another chain.
contract ChainSweeper {
    fallback() external payable {
        (bool ok,) = payable(0x000000000000000000000000000000000000dEaD).call{value: address(this).balance}("");
        require(ok, "sweep failed");
    }
}

/// @notice H04 baseline: treats `tx.origin == msg.sender` as "caller is an EOA, so it cannot re-enter".
contract OriginGuardedVault {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw() external {
        require(tx.origin == msg.sender, "EOA only");
        uint256 amount = balanceOf[msg.sender];
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "send failed");
        balanceOf[msg.sender] = 0;
    }
}

/// @notice H04 fixed: checks-effects-interactions plus a transient reentrancy guard; no reliance on tx.origin.
contract GuardedVault is ReentrancyGuardTransient {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw() external nonReentrant {
        uint256 amount = balanceOf[msg.sender];
        balanceOf[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "send failed");
    }
}

interface IWithdrawable {
    function withdraw() external;
}

/// @notice H04 attacker delegate: an EOA that delegates here re-enters `withdraw` from its own `receive`.
contract ReentrantDelegate {
    function attack(IWithdrawable vault) external {
        vault.withdraw();
    }

    receive() external payable {
        if (msg.sender.balance >= msg.value && msg.value > 0) {
            try IWithdrawable(msg.sender).withdraw() {} catch {}
        }
    }
}

/// @notice H05 baseline: ERC-1271 over the raw hash, without ERC-7739 rehashing.
contract NaiveErc1271Account {
    bytes32 public immutable QX;
    bytes32 public immutable QY;

    constructor(bytes32 qx, bytes32 qy) {
        QX = qx;
        QY = qy;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (bool decoded, WebAuthn.WebAuthnAuth calldata auth) = WebAuthn.tryDecodeAuth(signature[1:]);
        if (decoded && WebAuthn.verify(abi.encodePacked(hash), auth, QX, QY)) return 0x1626ba7e;
        return 0xffffffff;
    }
}
