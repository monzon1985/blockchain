// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FixedPointGolf} from "../../src/math/FixedPointGolf.sol";
import {FixedPointLegacy} from "../../src/math/FixedPointLegacy.sol";
import {FixedPointRef} from "../../src/math/FixedPointRef.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibBit} from "solady/utils/LibBit.sol";

/// @notice Every probe returns (result, gas used between two GAS reads). `baseline` measures an empty window
///         so the bench can subtract the measurement overhead. All probes have the same shape, so the
///         overhead is identical across kernels.
interface IMathProbe {
    function baseline(uint256 x) external view returns (uint256 r, uint256 g);
    function mulDiv(uint256 x, uint256 y, uint256 d) external view returns (uint256 r, uint256 g);
    function mulDivUp(uint256 x, uint256 y, uint256 d) external view returns (uint256 r, uint256 g);
    function sqrt(uint256 x) external view returns (uint256 r, uint256 g);
    function log2(uint256 x) external view returns (uint256 r, uint256 g);
    function log2Up(uint256 x) external view returns (uint256 r, uint256 g);
    function clz(uint256 x) external view returns (uint256 r, uint256 g);
}

contract RefProbe is IMathProbe {
    function baseline(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = x;
        g = g0 - gasleft();
    }

    function mulDiv(uint256 x, uint256 y, uint256 d) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointRef.mulDiv(x, y, d);
        g = g0 - gasleft();
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointRef.mulDivUp(x, y, d);
        g = g0 - gasleft();
    }

    function sqrt(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointRef.sqrt(x);
        g = g0 - gasleft();
    }

    function log2(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointRef.log2(x);
        g = g0 - gasleft();
    }

    function log2Up(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointRef.log2Up(x);
        g = g0 - gasleft();
    }

    function clz(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointRef.clz(x);
        g = g0 - gasleft();
    }
}

contract GolfProbe is IMathProbe {
    function baseline(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = x;
        g = g0 - gasleft();
    }

    function mulDiv(uint256 x, uint256 y, uint256 d) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointGolf.mulDiv(x, y, d);
        g = g0 - gasleft();
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointGolf.mulDivUp(x, y, d);
        g = g0 - gasleft();
    }

    function sqrt(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointGolf.sqrt(x);
        g = g0 - gasleft();
    }

    function log2(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointGolf.log2(x);
        g = g0 - gasleft();
    }

    function log2Up(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointGolf.log2Up(x);
        g = g0 - gasleft();
    }

    function clz(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointGolf.clz(x);
        g = g0 - gasleft();
    }
}

/// @dev mulDiv needs no CLZ, so the pre-Osaka build uses FixedPointGolf.mulDiv unchanged.
contract LegacyProbe is IMathProbe {
    function baseline(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = x;
        g = g0 - gasleft();
    }

    function mulDiv(uint256 x, uint256 y, uint256 d) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointGolf.mulDiv(x, y, d);
        g = g0 - gasleft();
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointGolf.mulDivUp(x, y, d);
        g = g0 - gasleft();
    }

    function sqrt(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointLegacy.sqrt(x);
        g = g0 - gasleft();
    }

    function log2(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointLegacy.log2(x);
        g = g0 - gasleft();
    }

    function log2Up(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointLegacy.log2Up(x);
        g = g0 - gasleft();
    }

    function clz(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointLegacy.clz(x);
        g = g0 - gasleft();
    }
}

contract OzProbe is IMathProbe {
    function baseline(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = x;
        g = g0 - gasleft();
    }

    function mulDiv(uint256 x, uint256 y, uint256 d) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = Math.mulDiv(x, y, d);
        g = g0 - gasleft();
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = Math.mulDiv(x, y, d, Math.Rounding.Ceil);
        g = g0 - gasleft();
    }

    function sqrt(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = Math.sqrt(x);
        g = g0 - gasleft();
    }

    function log2(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = Math.log2(x);
        g = g0 - gasleft();
    }

    function log2Up(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = Math.log2(x, Math.Rounding.Ceil);
        g = g0 - gasleft();
    }

    function clz(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = Math.clz(x);
        g = g0 - gasleft();
    }
}

contract SoladyProbe is IMathProbe {
    function baseline(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = x;
        g = g0 - gasleft();
    }

    function mulDiv(uint256 x, uint256 y, uint256 d) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointMathLib.fullMulDiv(x, y, d);
        g = g0 - gasleft();
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointMathLib.fullMulDivUp(x, y, d);
        g = g0 - gasleft();
    }

    function sqrt(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointMathLib.sqrt(x);
        g = g0 - gasleft();
    }

    function log2(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointMathLib.log2(x);
        g = g0 - gasleft();
    }

    function log2Up(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointMathLib.log2Up(x);
        g = g0 - gasleft();
    }

    function clz(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = LibBit.clz(x);
        g = g0 - gasleft();
    }
}
