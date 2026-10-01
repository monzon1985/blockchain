// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { KestrelLending } from "kestrel/KestrelLending.sol";
import { SpotOracleAttacker } from "../attacks/SpotOracleAttacker.sol";

/// @notice SC03 regression (fixed profile): collateral is valued from the published TWAP, so the
///         same one-transaction pump leaves borrowing power unchanged and the borrow reverts.
contract SC03SpotOracleRegression is BaseTest {
    uint256 internal constant LIQUIDITY = 500_000e18;
    uint256 internal constant PLEDGE = 80_000e18;
    uint256 internal constant PUMP = 2_000_000e18;

    function test_regression_pumpDoesNotMoveValuation() public {
        _seedLending(LIQUIDITY);
        SpotOracleAttacker atk = new SpotOracleAttacker(pool, lending);
        collateral.mint(address(atk), PLEDGE);
        debt.mint(address(atk), PUMP);

        // Fair borrowing power: 80k collateral at the TWAP price 1.0, 75% LTV.
        uint256 fairMax = PLEDGE * LTV_BPS / 10_000;
        vm.expectRevert(
            abi.encodeWithSelector(KestrelLending.Undercollateralized.selector, LIQUIDITY, fairMax)
        );
        atk.attack(PLEDGE, PUMP, LIQUIDITY, attacker);
    }

    /// @dev Spot moves, the valuation does not.
    function test_regression_valuationIgnoresSameBlockSwap() public {
        _mintApprove(collateral, alice, 1000e18, address(lending));
        vm.prank(alice);
        lending.depositCollateral(1000e18);
        uint256 before = lending.collateralValue(alice);

        _mintApprove(debt, bob, 2_000_000e18, address(pool));
        vm.prank(bob);
        pool.swap(address(debt), 2_000_000e18, 0, bob);

        assertGt(pool.spotPrice0In1(), 8e18, "spot pumped ~9x");
        assertEq(lending.collateralValue(alice), before, "valuation unchanged in the same block");
    }
}
