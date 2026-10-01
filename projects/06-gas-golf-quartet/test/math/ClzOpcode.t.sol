// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FixedPointLegacy} from "../../src/math/FixedPointLegacy.sol";
import {FixedPointRef} from "../../src/math/FixedPointRef.sol";
import {Clz as ClzModel} from "../halmos/clz-model/Clz.sol";
import {MathGolfHarness, MathLegacyHarness, MathRefHarness} from "../utils/MathHarnesses.sol";
import {QuartetBase} from "../utils/QuartetBase.sol";
import {Impl} from "../utils/RevertClassifier.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Clz} from "clz/Clz.sol";
import {LibBit} from "solady/utils/LibBit.sol";

/// @title ClzOpcodeTest
/// @notice Closes the gap left by halmos 0.3.3 not implementing opcode 0x1e: the real CLZ opcode (as
///         executed by Foundry's revm under Osaka rules) must agree with the plain-EVM model the halmos
///         proofs use, with the reference, the legacy emulation, OpenZeppelin and Solady on every bit
///         length, and under fuzzing. Also checks which bytecodes contain the opcode at all.
contract ClzOpcodeTest is QuartetBase {
    uint256 internal constant OP_CLZ = 0x1e;

    function _assertAllAgree(uint256 x) internal pure {
        uint256 expected = x == 0 ? 256 : 255 - _msb(x);
        assertEq(Clz.clz(x), expected, "opcode");
        assertEq(ClzModel.clz(x), expected, "model");
        assertEq(FixedPointRef.clz(x), expected, "reference");
        assertEq(FixedPointLegacy.clz(x), expected, "legacy");
        assertEq(Math.clz(x), expected, "OpenZeppelin");
        assertEq(LibBit.clz(x), expected, "Solady");
    }

    /// @dev Independent bit-by-bit MSB: the slowest, most obvious definition.
    function _msb(uint256 x) internal pure returns (uint256 i) {
        while (x > 1) {
            x >>= 1;
            ++i;
        }
    }

    function test_AllImplementationsAgreeOnEveryBitLength() public pure {
        _assertAllAgree(0);
        _assertAllAgree(type(uint256).max);
        for (uint256 e; e < 256; ++e) {
            uint256 lo = uint256(1) << e;
            uint256 hi = e == 255 ? type(uint256).max : (lo << 1) - 1;
            _assertAllAgree(lo);
            _assertAllAgree(hi);
            if (lo < hi) _assertAllAgree(lo + 1);
            if (hi - lo > 2) _assertAllAgree(lo + (hi - lo) / 2);
        }
    }

    function testFuzz_OpcodeMatchesModel(uint256 x) public pure {
        _assertAllAgree(x);
        _assertAllAgree(x >> (x % 256));
    }

    /// @notice The pre-Osaka fallback contains no CLZ opcode, so it runs on chains without EIP-7939; the
    ///         golfed kernel does contain it (which also shows the scanner finds it).
    function test_OnlyTheGolfedKernelEmitsClz() public {
        assertTrue(_containsOpcode(address(new MathGolfHarness()).code, OP_CLZ), "golfed kernel uses CLZ");
        assertFalse(_containsOpcode(address(new MathLegacyHarness()).code, OP_CLZ), "legacy kernel must not");
        assertFalse(_containsOpcode(address(new MathRefHarness()).code, OP_CLZ), "reference must not");
    }

    /// @notice None of the tokens uses CLZ: their bytecode is valid on Prague as well as Osaka.
    function test_TokensDoNotEmitClz() public {
        for (uint256 i; i < 5; ++i) {
            address token = address(_deploy(Impl(i), address(this), SUPPLY));
            assertFalse(_containsOpcode(token.code, OP_CLZ), _name(Impl(i)));
            // The constructors must not use it either (scan the creation code without the appended arguments).
            bytes memory initcode = _initcode(Impl(i), address(this), SUPPLY);
            // Memory-safe: shortens an array this function owns.
            assembly ("memory-safe") {
                mstore(initcode, sub(mload(initcode), 0x40))
            }
            assertFalse(_containsOpcode(initcode, OP_CLZ), _name(Impl(i)));
        }
    }

    /// @dev Walks bytecode as the EVM does, skipping PUSH1..PUSH32 immediates.
    function _containsOpcode(bytes memory code, uint256 opcode) internal pure returns (bool) {
        for (uint256 i; i < code.length; ++i) {
            uint256 op = uint8(code[i]);
            if (op == opcode) return true;
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        return false;
    }
}
