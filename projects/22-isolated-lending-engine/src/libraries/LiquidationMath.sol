// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MathLib, WAD} from "./MathLib.sol";
import {SharesMathLib} from "./SharesMathLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @dev Scale of `IOracle.price()`.
uint256 constant ORACLE_PRICE_SCALE = 1e36;

/// @title LiquidationMath
/// @notice Health factor and reverse-Dutch liquidation arithmetic.
/// @dev This library is the single source of truth for the numbers the Rust `risk-math` crate reproduces bit for
///      bit (see `test/vectors/HealthVectors.t.sol`). Products involving the 1e36 oracle scale use Solady's 512-bit
///      `fullMulDiv`, so realistic prices can never overflow an intermediate value.
///
///      Rounding policy, all against the party that receives value:
///      - collateral value and borrowing capacity round down;
///      - debt rounds up (computed by the caller with `toAssetsUp`);
///      - the bonus rounds down (the liquidator is paid by the borrower);
///      - collateral seized for a given repayment rounds down, repayment for a given seizure rounds up.
library LiquidationMath {
    using MathLib for uint256;
    using SharesMathLib for uint256;

    /// @notice Value of `collateral` in loan units: `collateral * price / 1e36`, rounded down.
    /// @param collateral Collateral amount (collateral base units).
    /// @param price Oracle price (1e36 scale).
    /// @return The collateral's value in loan base units.
    function collateralValue(uint256 collateral, uint256 price) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(collateral, price, ORACLE_PRICE_SCALE);
    }

    /// @notice Borrowing capacity of `collateral` in loan units: `collateral * price / 1e36 * lltv`, rounded down.
    /// @param collateral Collateral amount (collateral base units).
    /// @param price Oracle price (1e36 scale).
    /// @param lltv Liquidation loan-to-value (WAD).
    /// @return The maximum debt the collateral supports.
    function maxBorrow(uint256 collateral, uint256 price, uint256 lltv) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(collateralValue(collateral, price), lltv, WAD);
    }

    /// @notice Health factor `maxBorrow / debt` (WAD), rounded down; `type(uint256).max` without debt.
    /// @param maxBorrowAssets Borrowing capacity of the collateral.
    /// @param debt Debt of the position, rounded up.
    /// @return The health factor. The position is liquidatable iff it is below 1e18.
    function healthFactor(uint256 maxBorrowAssets, uint256 debt) internal pure returns (uint256) {
        if (debt == 0) return type(uint256).max;
        return FixedPointMathLib.fullMulDiv(maxBorrowAssets, WAD, debt);
    }

    /// @notice Reverse-Dutch bonus: `min(maxBonus, bonusSlope * (1 - health))`, rounded down.
    /// @dev Non-decreasing in the deficit `1 - health` by construction (a min of a constant and a non-decreasing
    ///      linear function). Halmos (`LiquidationBonusSymbolic`) proves the cap and the zero bonus of healthy
    ///      positions for every input, and monotonicity for the 1x slope; monotonicity for other slopes is fuzzed in
    ///      `LiquidationFuzz` and the Rust proptests, and the Rust vectors replay the exact values.
    /// @param health Health factor (WAD).
    /// @param maxBonus Bonus cap (WAD).
    /// @param bonusSlope Bonus per unit of deficit (WAD).
    /// @return The liquidation bonus (WAD). Zero for healthy positions.
    function liquidationBonus(uint256 health, uint256 maxBonus, uint256 bonusSlope) internal pure returns (uint256) {
        if (health >= WAD) return 0;
        return MathLib.min(maxBonus, (bonusSlope * (WAD - health)) / WAD);
    }

    /// @notice Bonus a closeout pays when the collateral covers the debt but not debt plus the scheduled bonus:
    ///         `min(bonus, (value - debt) / debt)`, rounded down. The liquidator's incentive then comes only out of the
    ///         borrower's equity, so suppliers lose nothing on a position that is not under water.
    /// @param bonus The scheduled bonus (WAD).
    /// @param value Collateral value in loan units (`collateralValue`), at least `debt`.
    /// @param debt Debt of the position (rounded up), non-zero.
    /// @return The bonus (WAD) the closeout actually pays.
    function equityCappedBonus(uint256 bonus, uint256 value, uint256 debt) internal pure returns (uint256) {
        return MathLib.min(bonus, FixedPointMathLib.fullMulDiv(value - debt, WAD, debt));
    }

    /// @notice Debt shares a liquidator must repay to seize `seizedAssets`, rounded up.
    /// @param seizedAssets Collateral to seize.
    /// @param price Oracle price (1e36 scale).
    /// @param incentiveFactor `1 + bonus` (WAD).
    /// @param totalBorrowAssets Market total borrow.
    /// @param totalBorrowShares Market total borrow shares.
    /// @return The debt shares to burn.
    function repaidSharesForSeizure(
        uint256 seizedAssets,
        uint256 price,
        uint256 incentiveFactor,
        uint256 totalBorrowAssets,
        uint256 totalBorrowShares
    ) internal pure returns (uint256) {
        uint256 seizedQuoted = FixedPointMathLib.fullMulDivUp(seizedAssets, price, ORACLE_PRICE_SCALE);
        return seizedQuoted.wDivUp(incentiveFactor).toSharesUp(totalBorrowAssets, totalBorrowShares);
    }

    /// @notice Collateral a liquidator receives for repaying `repaidShares`, rounded down.
    /// @param repaidShares Debt shares to burn.
    /// @param price Oracle price (1e36 scale, non-zero).
    /// @param incentiveFactor `1 + bonus` (WAD).
    /// @param totalBorrowAssets Market total borrow.
    /// @param totalBorrowShares Market total borrow shares.
    /// @return The collateral to seize.
    function seizureForRepaidShares(
        uint256 repaidShares,
        uint256 price,
        uint256 incentiveFactor,
        uint256 totalBorrowAssets,
        uint256 totalBorrowShares
    ) internal pure returns (uint256) {
        uint256 repaidValue = repaidShares.toAssetsDown(totalBorrowAssets, totalBorrowShares).wMulDown(incentiveFactor);
        return FixedPointMathLib.fullMulDiv(repaidValue, ORACLE_PRICE_SCALE, price);
    }
}
