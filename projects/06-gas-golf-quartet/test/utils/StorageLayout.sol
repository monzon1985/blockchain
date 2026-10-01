// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Impl} from "./RevertClassifier.sol";

/// @title StorageLayout
/// @notice Storage slot of every balance, allowance and nonce in each implementation. Used to seed
///         symbolic state for halmos, to reach states no call sequence can produce (e.g. an infinite
///         allowance owned by the zero address), and verified directly in test/spec/StorageLayout.t.sol.
library StorageLayout {
    uint256 internal constant ASM_BALANCE_SEED = 0x87a211a2;
    uint256 internal constant ASM_ALLOWANCE_SEED = 0x7f5e9f20;
    uint256 internal constant ASM_NONCES_SEED = 0x38377508;
    uint256 internal constant YUL_NONCE_OFFSET = 1 << 160;

    /// @dev OpenZeppelin ERC20Permit: _balances @0, _allowances @1, _nonces @7 (after ERC20 and EIP712).
    uint256 internal constant OZ_NONCES_SLOT = 7;

    function balanceSlot(Impl impl, address owner) internal pure returns (bytes32) {
        if (impl == Impl.OpenZeppelin || impl == Impl.Solidity) return keccak256(abi.encode(owner, uint256(0)));
        if (impl == Impl.Assembly) return keccak256(abi.encodePacked(owner, uint64(0), uint32(ASM_BALANCE_SEED)));
        if (impl == Impl.Yul) return bytes32(uint256(uint160(owner)));
        // Vyper hashes the slot first: keccak256(slot ‖ key).
        return keccak256(abi.encode(uint256(0), owner));
    }

    function allowanceSlot(Impl impl, address owner, address spender) internal pure returns (bytes32) {
        if (impl == Impl.OpenZeppelin || impl == Impl.Solidity) {
            return keccak256(abi.encode(spender, keccak256(abi.encode(owner, uint256(1)))));
        }
        if (impl == Impl.Assembly) {
            return keccak256(abi.encodePacked(owner, uint64(0), uint32(ASM_ALLOWANCE_SEED), spender));
        }
        if (impl == Impl.Yul) return keccak256(abi.encode(owner, spender));
        return keccak256(abi.encode(keccak256(abi.encode(uint256(1), owner)), spender));
    }

    function nonceSlot(Impl impl, address owner) internal pure returns (bytes32) {
        if (impl == Impl.OpenZeppelin) return keccak256(abi.encode(owner, OZ_NONCES_SLOT));
        if (impl == Impl.Solidity) return keccak256(abi.encode(owner, uint256(2)));
        if (impl == Impl.Assembly) return keccak256(abi.encodePacked(owner, uint64(0), uint32(ASM_NONCES_SEED)));
        if (impl == Impl.Yul) return bytes32(YUL_NONCE_OFFSET + uint256(uint160(owner)));
        return keccak256(abi.encode(uint256(2), owner));
    }
}
