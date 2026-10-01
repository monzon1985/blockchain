// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {DeployVolatilityFeeHook} from "../../script/DeployVolatilityFeeHook.s.sol";
import {IVolatilityFeeHook} from "../../src/interfaces/IVolatilityFeeHook.sol";

/// @notice The deployment script's fee-curve overrides are narrowed with SafeCast. A plain `uint24(...)` cast would
/// silently wrap an out-of-range value (FEE_SLOPE_PIPS=16777716 is 2^24 + 500 and would deploy as 500, which the
/// constructor accepts), and the curve is immutable. All environment writes live in this one test so that parallel
/// tests never observe them.
contract DeployScriptTest is Test {
    function test_readConfig_overridesAreCheckedNotWrapped() public {
        DeployVolatilityFeeHook script = new DeployVolatilityFeeHook();
        vm.setEnv("ALPHA_WAD", "200000000000000000");
        vm.setEnv("FEE_SLOPE_PIPS", "700");
        vm.setEnv("SURCHARGE_SLOPE_PIPS", "300");
        vm.setEnv("MAX_SURCHARGE_PIPS", "4000");
        IVolatilityFeeHook.FeeConfig memory c = script.readConfig();
        assertEq(c.alphaWad, 0.2e18);
        assertEq(c.feeSlopePips, 700);
        assertEq(c.surchargeSlopePips, 300);
        assertEq(c.maxSurchargePips, 4000);

        vm.setEnv("FEE_SLOPE_PIPS", "16777716");
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 24, 16_777_716));
        script.readConfig();
        vm.setEnv("FEE_SLOPE_PIPS", "700");

        vm.setEnv("SURCHARGE_SLOPE_PIPS", "16777466");
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 24, 16_777_466));
        script.readConfig();
        vm.setEnv("SURCHARGE_SLOPE_PIPS", "300");

        vm.setEnv("MAX_SURCHARGE_PIPS", "16782216");
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 24, 16_782_216));
        script.readConfig();
        vm.setEnv("MAX_SURCHARGE_PIPS", "4000");

        vm.setEnv("ALPHA_WAD", "18446744073709551616"); // 2^64
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 64, 2 ** 64));
        script.readConfig();
        vm.setEnv("ALPHA_WAD", "100000000000000000");
    }
}
