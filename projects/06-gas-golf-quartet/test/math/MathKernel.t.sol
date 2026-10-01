// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FixedPointGolf} from "../../src/math/FixedPointGolf.sol";
import {FixedPointLegacy} from "../../src/math/FixedPointLegacy.sol";
import {FixedPointRef} from "../../src/math/FixedPointRef.sol";
import {IMathKernel, MathGolfHarness, MathLegacyHarness, MathRefHarness} from "../utils/MathHarnesses.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice External wrapper around OpenZeppelin 5.7 Math, for differential testing.
contract OzMathHarness {
    function mulDiv(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return Math.mulDiv(x, y, d);
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return Math.mulDiv(x, y, d, Math.Rounding.Ceil);
    }
}

/// @notice External wrapper around Solady 0.1.26 FixedPointMathLib, for differential testing.
contract SoladyMathHarness {
    function mulDiv(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(x, y, d);
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FixedPointMathLib.fullMulDivUp(x, y, d);
    }
}

/// @title MathKernelTest
/// @notice The golfed and legacy kernels against (1) the Solidity reference, (2) OpenZeppelin 5.7 Math and
///         Solady 0.1.26 FixedPointMathLib, and (3) an independent 512-bit schoolbook oracle that shares no
///         code or technique with any of them. sqrt, the one function halmos does not prove, is also
///         checked exhaustively below 2**16 and at every bit length and perfect-square boundary.
contract MathKernelTest is Test {
    IMathKernel internal ref;
    IMathKernel internal golf;
    IMathKernel internal legacy;
    OzMathHarness internal oz;
    SoladyMathHarness internal solady;

    function setUp() public {
        ref = new MathRefHarness();
        golf = new MathGolfHarness();
        legacy = new MathLegacyHarness();
        oz = new OzMathHarness();
        solady = new SoladyMathHarness();
    }

    // ------------------------------------------------------------------ independent 512-bit oracle

    /// @dev Schoolbook product of two 256-bit words from 128-bit limbs, without mulmod.
    function _mul512(uint256 a, uint256 b) internal pure returns (uint256 hi, uint256 lo) {
        uint256 a0 = uint128(a);
        uint256 a1 = a >> 128;
        uint256 b0 = uint128(b);
        uint256 b1 = b >> 128;
        uint256 p00 = a0 * b0;
        uint256 p01 = a0 * b1;
        uint256 p10 = a1 * b0;
        uint256 p11 = a1 * b1;
        // middle = p01 + p10 may carry into bit 256.
        uint256 middle;
        uint256 carryMid;
        unchecked {
            middle = p01 + p10;
            carryMid = middle < p01 ? 1 : 0;
            lo = p00 + (middle << 128);
        }
        uint256 carryLo = lo < p00 ? 1 : 0;
        hi = p11 + (middle >> 128) + (carryMid << 128) + carryLo;
    }

    function _lt512(uint256 ahi, uint256 alo, uint256 bhi, uint256 blo) internal pure returns (bool) {
        return ahi < bhi || (ahi == bhi && alo < blo);
    }

    /// @dev floor(x * y / d) is the unique r with r * d <= x * y < (r + 1) * d.
    function _assertIsFloorQuotient(uint256 r, uint256 x, uint256 y, uint256 d) internal pure {
        (uint256 phi, uint256 plo) = _mul512(x, y);
        (uint256 lhi, uint256 llo) = _mul512(r, d);
        assertFalse(_lt512(phi, plo, lhi, llo), "r * d > x * y");
        // (r + 1) * d = r * d + d, as a 512-bit sum (cannot exceed 2**512 because r * d <= x * y).
        uint256 ulo;
        uint256 uhi;
        unchecked {
            ulo = llo + d;
            uhi = lhi + (ulo < llo ? 1 : 0);
        }
        assertTrue(_lt512(phi, plo, uhi, ulo), "x * y >= (r + 1) * d");
    }

    /// @dev The quotient overflows 256 bits iff the high word of x * y is >= d.
    function _quotientOverflows(uint256 x, uint256 y, uint256 d) internal pure returns (bool) {
        (uint256 hi,) = _mul512(x, y);
        return d == 0 || hi >= d;
    }

    function test_Mul512OracleSelfCheck() public pure {
        (uint256 hi, uint256 lo) = _mul512(type(uint256).max, type(uint256).max);
        assertEq(hi, type(uint256).max - 1);
        assertEq(lo, 1);
        (hi, lo) = _mul512(1 << 128, 1 << 128);
        assertEq(hi, 1);
        assertEq(lo, 0);
    }

    // ------------------------------------------------------------------ call helpers

    struct R {
        bool ok;
        bytes ret;
    }

    function _call(address target, bytes memory data) internal view returns (R memory r) {
        (r.ok, r.ret) = target.staticcall(data);
    }

    function _assertSame(R memory a, R memory b, string memory label) internal pure {
        assertEq(a.ok, b.ok, string.concat(label, ": success"));
        assertEq(a.ret, b.ret, string.concat(label, ": return or revert data"));
    }

    // ------------------------------------------------------------------ mulDiv

    function _checkMulDiv(uint256 x, uint256 y, uint256 d) internal view {
        bytes memory data = abi.encodeCall(IMathKernel.mulDiv, (x, y, d));
        R memory expected = _call(address(ref), data);
        _assertSame(expected, _call(address(golf), data), "golf");
        R memory ozR = _call(address(oz), data);
        R memory soladyR = _call(address(solady), data);
        assertEq(ozR.ok, expected.ok, "OpenZeppelin success");
        assertEq(soladyR.ok, expected.ok, "Solady success");
        // Same selector and bytes as Solady on failure (FullMulDivFailed()).
        assertEq(soladyR.ret, expected.ret, "Solady data");
        assertEq(expected.ok, !_quotientOverflows(x, y, d), "overflow oracle");
        if (expected.ok) {
            assertEq(ozR.ret, expected.ret, "OpenZeppelin value");
            _assertIsFloorQuotient(abi.decode(expected.ret, (uint256)), x, y, d);
        }
    }

    function _checkMulDivUp(uint256 x, uint256 y, uint256 d) internal view {
        bytes memory data = abi.encodeCall(IMathKernel.mulDivUp, (x, y, d));
        R memory expected = _call(address(ref), data);
        _assertSame(expected, _call(address(golf), data), "golf up");
        R memory ozR = _call(address(oz), data);
        R memory soladyR = _call(address(solady), data);
        assertEq(ozR.ok, expected.ok, "OpenZeppelin success");
        assertEq(soladyR.ok, expected.ok, "Solady success");
        if (expected.ok) {
            assertEq(ozR.ret, expected.ret, "OpenZeppelin value");
            assertEq(soladyR.ret, expected.ret, "Solady value");
            uint256 up = abi.decode(expected.ret, (uint256));
            uint256 down = FixedPointRef.mulDiv(x, y, d);
            assertEq(up, down + (mulmod(x, y, d) == 0 ? 0 : 1), "ceil = floor + (remainder != 0)");
        }
    }

    function testFuzz_MulDiv(uint256 x, uint256 y, uint256 d) public view {
        _checkMulDiv(x, y, d);
    }

    /// @dev Biased towards the interesting region: a quotient that just fits or just overflows. The slack is
    ///      clamped to the room left above the high word, which is below 3 only when x * y is within three
    ///      units of 2**512 (x = y = 2**256 - 1 gives hi = 2**256 - 2, so `hi + 3` would overflow).
    function testFuzz_MulDivNearOverflow(uint256 x, uint256 y, uint256 slack) public view {
        vm.assume(x != 0 && y != 0);
        (uint256 hi,) = _mul512(x, y);
        uint256 room = type(uint256).max - hi;
        uint256 d = hi + bound(slack, 0, room < 3 ? room : 3);
        if (d == 0) d = 1;
        _checkMulDiv(x, y, d);
        _checkMulDivUp(x, y, d);
        if (hi > 0) _checkMulDiv(x, y, hi);
    }

    /// @notice Regression: the near-overflow fuzz test itself overflowed (Panic 0x11) when the high word of
    ///         x * y was within three of 2**256 - 1, a corner Foundry's fuzz dictionary hits regularly. These
    ///         are the inputs that failed, run on every `forge test` regardless of the fuzz seed.
    function test_MulDivNearOverflow_HighWordNearMax() public view {
        uint256 max = type(uint256).max;
        // hi = 2**256 - 2: room = 1.
        testFuzz_MulDivNearOverflow(max, max, 0);
        testFuzz_MulDivNearOverflow(max, max, 1);
        testFuzz_MulDivNearOverflow(max, max, 2);
        testFuzz_MulDivNearOverflow(max, max, max);
        // hi = 2**256 - 3: room = 2.
        testFuzz_MulDivNearOverflow(max, max - 1, 3);
        testFuzz_MulDivNearOverflow(max - 1, max, max);
        // hi = 2**256 - 4: room = 3, the clamp is inactive.
        testFuzz_MulDivNearOverflow(max - 1, max - 1, 3);
    }

    function testFuzz_MulDivUp(uint256 x, uint256 y, uint256 d) public view {
        _checkMulDivUp(x, y, d);
    }

    function test_MulDiv_KnownVectors() public view {
        uint256 max = type(uint256).max;
        _checkMulDiv(0, 0, 0);
        _checkMulDiv(1, 1, 0);
        _checkMulDiv(max, max, max);
        _checkMulDiv(max - 1, max - 1, max);
        _checkMulDiv(max, max, max - 1);
        _checkMulDiv(max, 2, 1);
        _checkMulDiv(1 << 255, 2, 1);
        _checkMulDiv(1 << 255, (1 << 255) + 1, 1 << 254);
        _checkMulDiv(1e18, 1e18, 1e18);
        _checkMulDiv(3, 5, 2);
        // x * y = 2**256: low word 0, high word 1, remainder mod 3 is 1 > low word, so the 512-bit
        // subtraction of the remainder borrows from the high word (the reference's `prod1 -= 1` branch).
        _checkMulDiv(1 << 128, 1 << 128, 3);
        _checkMulDivUp(1 << 128, 1 << 128, 3);
        _checkMulDivUp(max, max, max);
        _checkMulDivUp(max, max - 1, max);
        _checkMulDivUp(max, 1, max - 1);
        _checkMulDivUp(5, 3, 2);
        assertEq(FixedPointGolf.mulDiv(max, max, max), max);
        assertEq(FixedPointGolf.mulDiv(max - 1, max - 1, max), max - 2);
        // (2**256 - 2)(2**256 - 3) = (2**256 - 1)(2**256 - 4) + 2: the floor quotient is exactly 2**256 - 1
        // with remainder 2, so mulDiv succeeds and only the rounding up overflows. This is the one revert of
        // mulDivUp that mulDiv cannot see; a fixed vector keeps it covered whatever the fuzz seed.
        _checkMulDiv(max - 1, max - 2, max - 3);
        _checkMulDivUp(max - 1, max - 2, max - 3);
        assertEq(FixedPointGolf.mulDiv(max - 1, max - 2, max - 3), max);
        (bool ok, bytes memory ret) =
            address(golf).staticcall(abi.encodeCall(IMathKernel.mulDivUp, (max - 1, max - 2, max - 3)));
        assertFalse(ok, "rounding up past 2**256 - 1 must revert");
        assertEq(ret, abi.encodeWithSelector(FixedPointGolf.FullMulDivFailed.selector));
    }

    // ------------------------------------------------------------------ sqrt

    function _checkSqrt(uint256 x) internal pure {
        uint256 r = FixedPointRef.sqrt(x);
        assertEq(FixedPointGolf.sqrt(x), r, "golf sqrt");
        assertEq(FixedPointLegacy.sqrt(x), r, "legacy sqrt");
        assertEq(Math.sqrt(x), r, "OpenZeppelin sqrt");
        assertEq(FixedPointMathLib.sqrt(x), r, "Solady sqrt");
        // r**2 <= x < (r + 1)**2, with the right side in 512 bits.
        assertLe(r * r, x);
        (uint256 hi, uint256 lo) = _mul512(r + 1, r + 1);
        assertTrue(hi > 0 || lo > x, "(r + 1)**2 <= x");
    }

    function test_Sqrt_ExhaustiveBelow2Pow16() public pure {
        for (uint256 x; x < 1 << 16; ++x) {
            uint256 r = FixedPointGolf.sqrt(x);
            assertTrue(r * r <= x && (r + 1) * (r + 1) > x);
            assertEq(FixedPointLegacy.sqrt(x), r);
        }
    }

    function test_Sqrt_EveryBitLengthAndSquareBoundary() public pure {
        _checkSqrt(type(uint256).max);
        for (uint256 e; e < 256; ++e) {
            uint256 lo = uint256(1) << e;
            uint256 hi = e == 255 ? type(uint256).max : (lo << 1) - 1;
            _checkSqrt(lo);
            _checkSqrt(hi);
            _checkSqrt(lo + (hi - lo) / 2);
            if (lo > 1) _checkSqrt(lo - 1);
        }
        for (uint256 k = 1; k <= 128; ++k) {
            uint256[3] memory roots = [(uint256(1) << k) - 1, uint256(1) << k, (uint256(1) << k) + 1];
            for (uint256 j; j < 3; ++j) {
                uint256 root = roots[j];
                if (root > type(uint128).max) continue;
                uint256 sq = root * root;
                _checkSqrt(sq);
                _checkSqrt(sq - 1);
                if (sq < type(uint256).max) _checkSqrt(sq + 1);
            }
        }
    }

    function testFuzz_Sqrt(uint256 x) public pure {
        _checkSqrt(x);
    }

    /// @dev Fuzz around perfect squares, where an off-by-one in the final correction would show.
    function testFuzz_SqrtAroundSquares(uint128 root, uint8 delta) public pure {
        uint256 sq = uint256(root) * root;
        _checkSqrt(sq);
        if (sq >= delta) _checkSqrt(sq - delta);
        if (sq <= type(uint256).max - delta) _checkSqrt(sq + delta);
    }

    // ------------------------------------------------------------------ log2

    function _checkLog2(uint256 x) internal pure {
        uint256 r = FixedPointRef.log2(x);
        assertEq(FixedPointGolf.log2(x), r, "golf log2");
        assertEq(FixedPointLegacy.log2(x), r, "legacy log2");
        assertEq(Math.log2(x), r, "OpenZeppelin log2");
        assertEq(FixedPointMathLib.log2(x), r, "Solady log2");
        if (x != 0) {
            assertLe(uint256(1) << r, x);
            assertTrue(r == 255 || (uint256(1) << (r + 1)) > x);
        }
        uint256 up = FixedPointRef.log2Up(x);
        assertEq(FixedPointGolf.log2Up(x), up, "golf log2Up");
        assertEq(FixedPointLegacy.log2Up(x), up, "legacy log2Up");
        assertEq(Math.log2(x, Math.Rounding.Ceil), up, "OpenZeppelin log2 ceil");
        assertEq(FixedPointMathLib.log2Up(x), up, "Solady log2Up");
    }

    function test_Log2_EveryBitLength() public pure {
        _checkLog2(0);
        for (uint256 e; e < 256; ++e) {
            uint256 lo = uint256(1) << e;
            _checkLog2(lo);
            _checkLog2(lo + 1);
            _checkLog2(e == 255 ? type(uint256).max : (lo << 1) - 1);
        }
    }

    function testFuzz_Log2(uint256 x) public pure {
        _checkLog2(x);
        _checkLog2(x >> (x % 256));
    }
}
