// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IMathKernel, MathGolfHarness, MathLegacyHarness, MathRefHarness} from "../utils/MathHarnesses.sol";
import {Test} from "forge-std/Test.sol";

/// @title MathEquivalence
/// @notice Halmos proofs, for all 256-bit inputs, that the golfed kernel returns exactly what the Solidity
///         reference returns (same value, or the same revert data):
///           mulDiv, mulDivUp:   FixedPointGolf == FixedPointRef
///           log2, log2Up, clz:  FixedPointGolf == FixedPointRef == FixedPointLegacy
/// @dev In this profile the `clz/` remapping points FixedPointGolf at the plain-EVM CLZ model
///      (test/halmos/clz-model/Clz.sol) because halmos 0.3.3 does not implement opcode 0x1e; the model is
///      tested against the real opcode in test/math/ClzOpcode.t.sol. `sqrt` is not proven here (its
///      data-dependent Babylonian loop and 256-bit divisions are out of reach); it is fuzzed instead.
contract MathEquivalence is Test {
    IMathKernel internal ref;
    IMathKernel internal golf;
    IMathKernel internal legacy;

    function setUp() public {
        ref = new MathRefHarness();
        golf = new MathGolfHarness();
        legacy = new MathLegacyHarness();
    }

    function check_mulDiv(uint256 x, uint256 y, uint256 d) external view {
        bytes memory data = abi.encodeCall(IMathKernel.mulDiv, (x, y, d));
        _assertSame(_call(address(ref), data), _call(address(golf), data));
    }

    function check_mulDivUp(uint256 x, uint256 y, uint256 d) external view {
        bytes memory data = abi.encodeCall(IMathKernel.mulDivUp, (x, y, d));
        _assertSame(_call(address(ref), data), _call(address(golf), data));
    }

    function check_log2(uint256 x) external view {
        _assertAllSame(abi.encodeCall(IMathKernel.log2, (x)));
    }

    function check_log2Up(uint256 x) external view {
        _assertAllSame(abi.encodeCall(IMathKernel.log2Up, (x)));
    }

    function check_clz(uint256 x) external view {
        _assertAllSame(abi.encodeCall(IMathKernel.clz, (x)));
    }

    /// @dev The branchy reference runs once; both golfed kernels are compared against that one result.
    function _assertAllSame(bytes memory data) internal view {
        Result memory expected = _call(address(ref), data);
        _assertSame(expected, _call(address(golf), data));
        _assertSame(expected, _call(address(legacy), data));
    }

    struct Result {
        bool ok;
        bytes ret;
    }

    function _call(address target, bytes memory data) internal view returns (Result memory r) {
        (r.ok, r.ret) = target.staticcall(data);
    }

    function _assertSame(Result memory a, Result memory b) internal pure {
        assert(a.ok == b.ok);
        assert(a.ret.length == b.ret.length);
        assert(keccak256(a.ret) == keccak256(b.ret));
    }
}
