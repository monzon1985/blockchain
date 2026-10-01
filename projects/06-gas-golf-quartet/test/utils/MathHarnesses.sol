// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FixedPointGolf} from "../../src/math/FixedPointGolf.sol";
import {FixedPointLegacy} from "../../src/math/FixedPointLegacy.sol";
import {FixedPointRef} from "../../src/math/FixedPointRef.sol";

/// @notice Common external surface so every kernel can be called (and its reverts captured) the same way.
interface IMathKernel {
    function mulDiv(uint256 x, uint256 y, uint256 d) external pure returns (uint256);
    function mulDivUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256);
    function sqrt(uint256 x) external pure returns (uint256);
    function log2(uint256 x) external pure returns (uint256);
    function log2Up(uint256 x) external pure returns (uint256);
    function clz(uint256 x) external pure returns (uint256);
}

/// @notice External wrapper around the Solidity reference kernel.
contract MathRefHarness is IMathKernel {
    function mulDiv(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FixedPointRef.mulDiv(x, y, d);
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FixedPointRef.mulDivUp(x, y, d);
    }

    function sqrt(uint256 x) external pure returns (uint256) {
        return FixedPointRef.sqrt(x);
    }

    function log2(uint256 x) external pure returns (uint256) {
        return FixedPointRef.log2(x);
    }

    function log2Up(uint256 x) external pure returns (uint256) {
        return FixedPointRef.log2Up(x);
    }

    function clz(uint256 x) external pure returns (uint256) {
        return FixedPointRef.clz(x);
    }
}

/// @notice External wrapper around the golfed (CLZ) kernel.
contract MathGolfHarness is IMathKernel {
    function mulDiv(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FixedPointGolf.mulDiv(x, y, d);
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FixedPointGolf.mulDivUp(x, y, d);
    }

    function sqrt(uint256 x) external pure returns (uint256) {
        return FixedPointGolf.sqrt(x);
    }

    function log2(uint256 x) external pure returns (uint256) {
        return FixedPointGolf.log2(x);
    }

    function log2Up(uint256 x) external pure returns (uint256) {
        return FixedPointGolf.log2Up(x);
    }

    function clz(uint256 x) external pure returns (uint256) {
        return FixedPointGolf.clz(x);
    }
}

/// @notice External wrapper around the pre-Osaka fallback. `mulDiv` needs no CLZ, so it forwards to the
///         golfed kernel, exactly as a pre-Osaka deployment would.
contract MathLegacyHarness is IMathKernel {
    function mulDiv(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FixedPointGolf.mulDiv(x, y, d);
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FixedPointGolf.mulDivUp(x, y, d);
    }

    function sqrt(uint256 x) external pure returns (uint256) {
        return FixedPointLegacy.sqrt(x);
    }

    function log2(uint256 x) external pure returns (uint256) {
        return FixedPointLegacy.log2(x);
    }

    function log2Up(uint256 x) external pure returns (uint256) {
        return FixedPointLegacy.log2Up(x);
    }

    function clz(uint256 x) external pure returns (uint256) {
        return FixedPointLegacy.clz(x);
    }
}
