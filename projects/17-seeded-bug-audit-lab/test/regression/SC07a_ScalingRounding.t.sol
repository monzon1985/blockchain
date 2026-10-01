// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockERC20 } from "../helpers/MockERC20.sol";
import { KestrelPool } from "kestrel/KestrelPool.sol";
import { BatchRoundingAttacker } from "../attacks/BatchRoundingAttacker.sol";

/// @notice SC07a regression (fixed profile): the batch path downscales rounding DOWN, exactly
///         like the single path, so the {PrecisionAmplifier} measures zero extractable error.
contract SC07aScalingRoundingRegression is BaseTest {
    uint256 internal constant N = 1000;
    uint256 internal constant AMT_IN = 1e18;

    MockERC20 internal stable;
    MockERC20 internal usdc;
    KestrelPool internal pool6;

    function setUp() public override {
        super.setUp();
        stable = new MockERC20("Stable", "STB", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool6 = new KestrelPool(
            IERC20(address(stable)), IERC20(address(usdc)), 0.5e18, IERC20(address(reward)), 0, NATIVE_FEE
        );
        stable.mint(deployer, 1_000_000e18);
        usdc.mint(deployer, 1_000_000e6);
        stable.approve(address(pool6), type(uint256).max);
        usdc.approve(address(pool6), type(uint256).max);
        pool6.addLiquidity(1_000_000e18, 1_000_000e6, deployer);
    }

    function test_regression_batchRoundsTowardPool() public {
        BatchRoundingAttacker atk = new BatchRoundingAttacker(pool6, address(stable), address(usdc));
        stable.mint(address(atk.op()), N * AMT_IN);

        uint256 extracted = atk.run(N, AMT_IN);

        assertEq(extracted, 0, "no rounding value leaks to the trader");
        (, uint256 steps,,) = atk.amplifier().stats(atk.OP());
        assertEq(steps, N, "every amplified swap executed");
    }

    /// @dev Any input size: the amplified error stays zero.
    function testFuzz_regression_noLeakAnySize(uint256 amountIn, uint8 n) public {
        amountIn = bound(amountIn, 1e9, 1000e18);
        uint256 reps = bound(n, 1, 32);
        BatchRoundingAttacker atk = new BatchRoundingAttacker(pool6, address(stable), address(usdc));
        stable.mint(address(atk.op()), reps * amountIn);
        assertEq(atk.run(reps, amountIn), 0, "zero extractable rounding error");
    }
}
