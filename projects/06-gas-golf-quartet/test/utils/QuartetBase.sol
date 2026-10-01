// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {QuartetAssembly} from "../../src/assembly/QuartetAssembly.sol";
import {YulBytecode} from "../../src/generated/YulBytecode.sol";
import {IQuartetToken} from "../../src/interfaces/IQuartetToken.sol";
import {QuartetSolidity} from "../../src/solidity/QuartetSolidity.sol";
import {OZReference} from "../reference/OZReference.sol";
import {Impl, RevertClass, RevertClassifier} from "./RevertClassifier.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title QuartetBase
/// @notice Deployment, signing and call-capture helpers shared by every token test.
abstract contract QuartetBase is Test {
    uint256 internal constant SUPPLY = 1_000_000e18;
    string internal constant VYPER_ARTIFACT = "QuartetVyper.vy:QuartetVyper";
    string internal constant TOKEN_NAME = "Gas Golf Quartet";
    string internal constant TOKEN_SYMBOL = "GOLF";

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /// @dev secp256k1 group order.
    uint256 internal constant SECP256K1_N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;

    /// @notice Everything observable about one call.
    struct Outcome {
        bool ok;
        bytes ret;
        Vm.Log[] logs;
    }

    function _name(Impl impl) internal pure returns (string memory) {
        if (impl == Impl.OpenZeppelin) return "OpenZeppelin";
        if (impl == Impl.Solidity) return "Solidity";
        if (impl == Impl.Assembly) return "Assembly";
        if (impl == Impl.Yul) return "Yul";
        return "Vyper";
    }

    /// @notice Creation code including the ABI-encoded constructor arguments.
    function _initcode(Impl impl, address holder, uint256 supply) internal view returns (bytes memory) {
        bytes memory args = abi.encode(holder, supply);
        if (impl == Impl.OpenZeppelin) return bytes.concat(type(OZReference).creationCode, args);
        if (impl == Impl.Solidity) return bytes.concat(type(QuartetSolidity).creationCode, args);
        if (impl == Impl.Assembly) return bytes.concat(type(QuartetAssembly).creationCode, args);
        if (impl == Impl.Yul) return bytes.concat(YulBytecode.CREATION, args);
        return bytes.concat(vm.getCode(VYPER_ARTIFACT), args);
    }

    /// @notice CREATE with `value`; returns the address (zero on failure) and the revert data.
    function _create(bytes memory initcode, uint256 value)
        internal
        returns (address deployed, bytes memory revertData)
    {
        // Memory-safe: the returndata copy is allocated at the free memory pointer and the pointer is bumped.
        assembly ("memory-safe") {
            deployed := create(value, add(initcode, 0x20), mload(initcode))
            if iszero(deployed) {
                revertData := mload(0x40)
                mstore(revertData, returndatasize())
                returndatacopy(add(revertData, 0x20), 0, returndatasize())
                mstore(0x40, add(add(revertData, 0x20), and(add(returndatasize(), 0x1f), not(0x1f))))
            }
        }
    }

    function _deploy(Impl impl, address holder, uint256 supply) internal returns (IQuartetToken token) {
        (address deployed, bytes memory revertData) = _create(_initcode(impl, holder, supply), 0);
        require(deployed != address(0), string(revertData));
        vm.label(deployed, _name(impl));
        token = IQuartetToken(deployed);
    }

    /// @dev Reads the chain id through the cheatcode so the optimizer cannot reuse a CHAINID value read
    ///      before a `vm.chainId` call in the same test.
    function _expectedDomainSeparator(address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256(bytes(TOKEN_NAME)), keccak256("1"), vm.getChainId(), verifyingContract
            )
        );
    }

    function _permitDigest(
        address verifyingContract,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked(hex"1901", _expectedDomainSeparator(verifyingContract), structHash));
    }

    /// @notice Signs a permit for `token` with the owner's current nonce.
    function _signPermit(uint256 key, IQuartetToken token, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address owner = vm.addr(key);
        return vm.sign(key, _permitDigest(address(token), owner, spender, value, token.nonces(owner), deadline));
    }

    /// @notice The malleable twin (n - s, flipped v) of a valid signature. ecrecover accepts it;
    ///         every implementation must reject it.
    function _malleate(uint8 v, bytes32 s) internal pure returns (uint8, bytes32) {
        return (v == 27 ? 28 : 27, bytes32(SECP256K1_N - uint256(s)));
    }

    /// @notice Calls `target` as `caller` and captures success, return data and logs.
    function _capture(address caller, address target, bytes memory data, uint256 value)
        internal
        returns (Outcome memory out)
    {
        vm.recordLogs();
        vm.prank(caller);
        (out.ok, out.ret) = target.call{value: value}(data);
        out.logs = vm.getRecordedLogs();
    }

    function _classOf(Impl impl, Outcome memory out) internal pure returns (RevertClass) {
        return out.ok ? RevertClass.None : RevertClassifier.classify(impl, out.ret);
    }
}
