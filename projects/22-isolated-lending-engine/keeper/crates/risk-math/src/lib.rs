// SPDX-License-Identifier: MIT
//! Bit-exact Rust port of the lending engine's share, health and liquidation arithmetic.
//!
//! Every function mirrors a Solidity counterpart line for line, including its rounding direction and the
//! order in which the engine checks its revert conditions:
//!
//! | Rust | Solidity |
//! |---|---|
//! | [`math::mul_div_down`] / [`math::mul_div_up`] | `MathLib.mulDivDown` / `mulDivUp` (256-bit, checked) |
//! | [`math::full_mul_div`] / [`math::full_mul_div_up`] | Solady `fullMulDiv` / `fullMulDivUp` (512-bit) |
//! | [`shares`] | `SharesMathLib` |
//! | [`liquidation::max_borrow`], [`liquidation::health_factor`], [`liquidation::liquidation_bonus`] | `LiquidationMath` |
//! | [`liquidation::liquidate`] | `LendingEngine.liquidate` (state transition and revert order) |
//!
//! The Foundry suite `test/vectors/HealthVectors.t.sol` replays vectors produced by this crate (through
//! `cascade-sim export-vectors`) against the deployed engine and requires identical results, so the keeper and
//! the simulator reason with exactly the numbers the contracts will produce.

pub mod liquidation;
pub mod math;
pub mod shares;
pub mod vectors;

pub use alloy_primitives::U256;
pub use liquidation::{
    LiquidationConfig, LiquidationError, LiquidationInput, LiquidationOutcome, LiquidationPlan, MarketState,
    PositionState, liquidate, plan_full_liquidation,
};
pub use math::MathError;

/// 1.0 in WAD fixed point.
pub const WAD: U256 = U256::from_limbs([1_000_000_000_000_000_000, 0, 0, 0]);

/// Scale of oracle prices (`ORACLE_PRICE_SCALE = 1e36`).
pub const ORACLE_PRICE_SCALE: U256 = U256::from_limbs([0xb34b_9f10_0000_0000, 0x00c0_97ce_7bc9_0715, 0, 0]);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn constants_match_solidity() {
        assert_eq!(WAD, U256::from(10u64).pow(U256::from(18u64)));
        assert_eq!(ORACLE_PRICE_SCALE, U256::from(10u64).pow(U256::from(36u64)));
    }
}
