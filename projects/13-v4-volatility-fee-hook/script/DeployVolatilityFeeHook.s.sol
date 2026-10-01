// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {VolatilityFeeHook} from "../src/VolatilityFeeHook.sol";
import {IVolatilityFeeHook} from "../src/interfaces/IVolatilityFeeHook.sol";
import {HookDeployment} from "./HookDeployment.sol";

/// @notice Deploys VolatilityFeeHook next to an existing PoolManager.
///
/// Keystore-based; no private key ever appears in the command line or the environment:
///   POOL_MANAGER=0x... HOOK_OWNER=0x... \
///   forge script script/DeployVolatilityFeeHook.s.sol --rpc-url <url> --account <keystore-name> --broadcast
///
/// Optional fee-curve overrides: ALPHA_WAD, FEE_SLOPE_PIPS, SURCHARGE_SLOPE_PIPS, MAX_SURCHARGE_PIPS.
contract DeployVolatilityFeeHook is HookDeployment {
    function run() external returns (VolatilityFeeHook) {
        return _deployHook(IPoolManager(vm.envAddress("POOL_MANAGER")), vm.envAddress("HOOK_OWNER"), readConfig());
    }

    /// @notice The fee curve to deploy: defaults, overridden by the optional environment variables.
    /// @dev Values are read as uint256 and narrowed with SafeCast, so an out-of-range override (a typo such as
    /// FEE_SLOPE_PIPS=16777716) reverts instead of silently wrapping to a different value that the constructor's range
    /// checks would accept. The fee curve is immutable, so a wrapped value could never be corrected.
    /// @return config The fee-curve parameters.
    function readConfig() public view returns (IVolatilityFeeHook.FeeConfig memory config) {
        config = IVolatilityFeeHook.FeeConfig({
            alphaWad: SafeCast.toUint64(vm.envOr("ALPHA_WAD", uint256(0.1e18))),
            feeSlopePips: SafeCast.toUint24(vm.envOr("FEE_SLOPE_PIPS", uint256(500))),
            surchargeSlopePips: SafeCast.toUint24(vm.envOr("SURCHARGE_SLOPE_PIPS", uint256(250))),
            maxSurchargePips: SafeCast.toUint24(vm.envOr("MAX_SURCHARGE_PIPS", uint256(5000)))
        });
    }
}
