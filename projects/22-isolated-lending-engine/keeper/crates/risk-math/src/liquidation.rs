// SPDX-License-Identifier: MIT
//! Health factor, reverse-Dutch bonus and the full liquidation state transition of `LendingEngine.liquidate`.

use alloy_primitives::U256;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::math::{
    MathError, MathResult, full_mul_div, full_mul_div_up, mul_div_down, to_u128, w_div_up, w_mul_down, zero_floor_sub,
};
use crate::shares::{to_assets_down, to_assets_up, to_shares_up};
use crate::{ORACLE_PRICE_SCALE, WAD};

/// Market accounting (`Market` without `lastUpdate` and `fee`, which liquidation does not read).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct MarketState {
    /// `totalSupplyAssets`.
    pub total_supply_assets: U256,
    /// `totalSupplyShares`.
    pub total_supply_shares: U256,
    /// `totalBorrowAssets`.
    pub total_borrow_assets: U256,
    /// `totalBorrowShares`.
    pub total_borrow_shares: U256,
}

/// The borrower-side fields of a `Position`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct PositionState {
    /// Collateral posted (collateral base units).
    pub collateral: U256,
    /// Debt shares owed.
    pub borrow_shares: U256,
}

/// Risk parameters of a market: its LLTV and the reverse-Dutch schedule bound to it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct LiquidationConfig {
    /// Liquidation loan-to-value (WAD).
    pub lltv: U256,
    /// Bonus cap (WAD).
    pub max_bonus: U256,
    /// Bonus per unit of health deficit (WAD).
    pub bonus_slope: U256,
}

/// Which side of the liquidation the caller fixes (exactly one of `seizedAssets` / `repaidShares`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LiquidationInput {
    /// Seize this much collateral; the repayment is derived (rounded up).
    Seize(U256),
    /// Repay this many debt shares; the seizure is derived (rounded down).
    Repay(U256),
}

impl LiquidationInput {
    /// A request that closes the whole position whatever its current size: `repaidShares = type(uint256).max`.
    ///
    /// The engine treats any request at or above the position's size as "close it" and prices it from the state at
    /// execution, so a dust deposit or repayment sent in front of the transaction cannot make it revert.
    pub const fn close() -> Self {
        Self::Repay(U256::MAX)
    }

    /// Whether this request covers the whole of `position` (and therefore closes it).
    pub fn closes(&self, position: &PositionState) -> bool {
        match *self {
            Self::Seize(seized) => seized >= position.collateral,
            Self::Repay(shares) => shares >= position.borrow_shares,
        }
    }

    /// The `(seizedAssets, repaidShares)` arguments of `LendingEngine.liquidate`.
    pub fn as_call_args(&self) -> (U256, U256) {
        match *self {
            Self::Seize(seized) => (seized, U256::ZERO),
            Self::Repay(shares) => (U256::ZERO, shares),
        }
    }
}

/// Everything a successful liquidation emits and leaves behind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct LiquidationOutcome {
    /// Health factor before the liquidation (WAD).
    pub health_before: U256,
    /// Bonus applied (WAD): the schedule's, or the borrower's equity in a closeout whose collateral covers the debt
    /// but not the scheduled bonus.
    pub bonus: U256,
    /// Collateral sent to the liquidator.
    pub seized_assets: U256,
    /// Debt shares burned by the repayment.
    pub repaid_shares: U256,
    /// Loan tokens pulled from the liquidator.
    pub repaid_assets: U256,
    /// Debt written off against suppliers.
    pub bad_debt_assets: U256,
    /// Debt shares written off.
    pub bad_debt_shares: U256,
    /// Health factor after the liquidation (`U256::MAX` when no debt is left).
    pub health_after: U256,
    /// Market totals after the liquidation.
    pub market: MarketState,
    /// Position after the liquidation.
    pub position: PositionState,
}

/// Why `LendingEngine.liquidate` would revert, in the order the engine checks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum LiquidationError {
    /// `InconsistentInput`: both or neither of the inputs are zero.
    #[error("inconsistent input")]
    InconsistentInput,
    /// `ZeroPrice`.
    #[error("oracle price is zero")]
    ZeroPrice,
    /// `HealthyPosition(healthFactor)`.
    #[error("position is healthy (health factor {health})")]
    HealthyPosition {
        /// The health factor (>= 1e18).
        health: U256,
    },
    /// `RepayExceedsDebt(repaidShares, borrowShares)`.
    #[error("repaying {repaid_shares} shares exceeds the {borrow_shares} owed")]
    RepayExceedsDebt {
        /// Shares the liquidation would burn.
        repaid_shares: U256,
        /// Shares owed.
        borrow_shares: U256,
    },
    /// `SeizeExceedsCollateral(seizedAssets, collateral)`.
    #[error("seizing {seized_assets} exceeds the {collateral} posted")]
    SeizeExceedsCollateral {
        /// Collateral the liquidation would seize.
        seized_assets: U256,
        /// Collateral posted.
        collateral: U256,
    },
    /// `HealthDecreased(healthBefore, healthAfter)`.
    #[error("partial liquidation would lower health from {before} to {after}")]
    HealthDecreased {
        /// Health before.
        before: U256,
        /// Health the liquidation would leave.
        after: U256,
    },
    /// An arithmetic revert (`Panic` or a Solady math error).
    #[error(transparent)]
    Math(#[from] MathError),
}

/// Collateral value in loan units: `floor(collateral * price / 1e36)` (`LiquidationMath.collateralValue`).
pub fn collateral_value(collateral: U256, price: U256) -> MathResult<U256> {
    full_mul_div(collateral, price, ORACLE_PRICE_SCALE)
}

/// Borrowing capacity: `floor(floor(collateral * price / 1e36) * lltv / 1e18)` (`LiquidationMath.maxBorrow`).
pub fn max_borrow(collateral: U256, price: U256, lltv: U256) -> MathResult<U256> {
    full_mul_div(collateral_value(collateral, price)?, lltv, WAD)
}

/// Bonus of a closeout whose collateral covers the debt but not the scheduled bonus:
/// `min(bonus, floor((value - debt) * 1e18 / debt))` (`LiquidationMath.equityCappedBonus`).
pub fn equity_capped_bonus(bonus: U256, value: U256, debt: U256) -> MathResult<U256> {
    Ok(bonus.min(full_mul_div(sub(value, debt)?, WAD, debt)?))
}

/// Health factor `floor(maxBorrow * 1e18 / debt)`, or `U256::MAX` without debt (`LiquidationMath.healthFactor`).
pub fn health_factor(max_borrow_assets: U256, debt: U256) -> MathResult<U256> {
    if debt.is_zero() {
        return Ok(U256::MAX);
    }
    full_mul_div(max_borrow_assets, WAD, debt)
}

/// Reverse-Dutch bonus `min(maxBonus, floor(slope * (1 - health)))` (`LiquidationMath.liquidationBonus`).
pub fn liquidation_bonus(health: U256, max_bonus: U256, bonus_slope: U256) -> MathResult<U256> {
    if health >= WAD {
        return Ok(U256::ZERO);
    }
    Ok(max_bonus.min(mul_div_down(bonus_slope, WAD - health, WAD)?))
}

/// Debt of a position, rounded up.
pub fn debt_of(position: &PositionState, market: &MarketState) -> MathResult<U256> {
    to_assets_up(position.borrow_shares, market.total_borrow_assets, market.total_borrow_shares)
}

/// Health factor of a position at `price`.
pub fn position_health(position: &PositionState, market: &MarketState, price: U256, lltv: U256) -> MathResult<U256> {
    health_factor(max_borrow(position.collateral, price, lltv)?, debt_of(position, market)?)
}

/// Debt shares to repay for seizing `seized_assets` (`LiquidationMath.repaidSharesForSeizure`).
pub fn repaid_shares_for_seizure(
    seized_assets: U256,
    price: U256,
    incentive_factor: U256,
    market: &MarketState,
) -> MathResult<U256> {
    let seized_quoted = full_mul_div_up(seized_assets, price, ORACLE_PRICE_SCALE)?;
    to_shares_up(w_div_up(seized_quoted, incentive_factor)?, market.total_borrow_assets, market.total_borrow_shares)
}

/// Collateral seized for repaying `repaid_shares` (`LiquidationMath.seizureForRepaidShares`).
pub fn seizure_for_repaid_shares(
    repaid_shares: U256,
    price: U256,
    incentive_factor: U256,
    market: &MarketState,
) -> MathResult<U256> {
    let repaid = to_assets_down(repaid_shares, market.total_borrow_assets, market.total_borrow_shares)?;
    full_mul_div(w_mul_down(repaid, incentive_factor)?, ORACLE_PRICE_SCALE, price)
}

fn sub(x: U256, y: U256) -> MathResult<U256> {
    x.checked_sub(y).ok_or(MathError::Overflow)
}

/// Prices a close of the whole position (`LendingEngine._priceClose`): returns `(seized, repaid_shares, bonus)`.
///
/// 1. Collateral covers debt plus the scheduled bonus: repay every share, seize what that buys.
/// 2. Collateral covers the debt but not the bonus: repay every share, seize all collateral, bonus capped at the
///    borrower's equity (no supplier loss).
/// 3. Collateral is worth less than the debt: seize all of it at the scheduled bonus; the rest becomes bad debt.
fn price_close(
    market: &MarketState,
    position: &PositionState,
    price: U256,
    debt: U256,
    bonus: U256,
) -> MathResult<(U256, U256, U256)> {
    let incentive_factor = WAD + bonus;
    let seized = seizure_for_repaid_shares(position.borrow_shares, price, incentive_factor, market)?;
    if seized <= position.collateral {
        return Ok((seized, position.borrow_shares, bonus));
    }
    let value = collateral_value(position.collateral, price)?;
    if value >= debt {
        return Ok((position.collateral, position.borrow_shares, equity_capped_bonus(bonus, value, debt)?));
    }
    let repaid = repaid_shares_for_seizure(position.collateral, price, incentive_factor, market)?;
    Ok((position.collateral, repaid.min(position.borrow_shares), bonus))
}

/// Simulates `LendingEngine.liquidate` (after interest accrual) on `market` and `position`.
///
/// Returns the exact values the engine would emit and store, or the error it would revert with, checking
/// conditions in the same order as the contract. A request at or above the position's size closes it (see
/// [`LiquidationInput::closes`]); any other request is partial and may neither lower the health factor nor exhaust
/// the collateral while debt remains.
pub fn liquidate(
    market: &MarketState,
    position: &PositionState,
    price: U256,
    config: &LiquidationConfig,
    input: LiquidationInput,
) -> Result<LiquidationOutcome, LiquidationError> {
    let (seized_in, repaid_in) = input.as_call_args();
    if seized_in.is_zero() == repaid_in.is_zero() {
        return Err(LiquidationError::InconsistentInput);
    }
    if price.is_zero() {
        return Err(LiquidationError::ZeroPrice);
    }

    let max_borrow_assets = max_borrow(position.collateral, price, config.lltv)?;
    let debt = debt_of(position, market)?;
    let health_before = health_factor(max_borrow_assets, debt)?;
    if max_borrow_assets >= debt {
        return Err(LiquidationError::HealthyPosition { health: health_before });
    }

    let scheduled_bonus = liquidation_bonus(health_before, config.max_bonus, config.bonus_slope)?;
    let incentive_factor = WAD + scheduled_bonus;

    let close = input.closes(position);
    let (seized_assets, repaid_shares, bonus) = if close {
        price_close(market, position, price, debt, scheduled_bonus)?
    } else {
        match input {
            LiquidationInput::Seize(seized) => {
                let repaid_shares = repaid_shares_for_seizure(seized, price, incentive_factor, market)?;
                if repaid_shares > position.borrow_shares {
                    return Err(LiquidationError::RepayExceedsDebt {
                        repaid_shares,
                        borrow_shares: position.borrow_shares,
                    });
                }
                (seized, repaid_shares, scheduled_bonus)
            }
            LiquidationInput::Repay(shares) => {
                let seized_assets = seizure_for_repaid_shares(shares, price, incentive_factor, market)?;
                if seized_assets > position.collateral {
                    return Err(LiquidationError::SeizeExceedsCollateral {
                        seized_assets,
                        collateral: position.collateral,
                    });
                }
                (seized_assets, shares, scheduled_bonus)
            }
        }
    };
    let repaid_assets = to_assets_up(repaid_shares, market.total_borrow_assets, market.total_borrow_shares)?;

    let mut m = *market;
    let mut p = *position;
    p.borrow_shares = sub(p.borrow_shares, repaid_shares)?;
    m.total_borrow_shares = sub(m.total_borrow_shares, repaid_shares)?;
    m.total_borrow_assets = to_u128(zero_floor_sub(m.total_borrow_assets, repaid_assets))?;
    p.collateral = sub(p.collateral, seized_assets)?;

    let mut bad_debt_assets = U256::ZERO;
    let mut bad_debt_shares = U256::ZERO;
    let health_after;
    if !close {
        health_after = position_health(&p, &m, price, config.lltv)?;
        if health_after < health_before || (p.collateral.is_zero() && !p.borrow_shares.is_zero()) {
            return Err(LiquidationError::HealthDecreased { before: health_before, after: health_after });
        }
    } else {
        if !p.borrow_shares.is_zero() {
            bad_debt_shares = p.borrow_shares;
            bad_debt_assets =
                m.total_borrow_assets.min(to_assets_up(bad_debt_shares, m.total_borrow_assets, m.total_borrow_shares)?);
            m.total_borrow_assets -= bad_debt_assets;
            m.total_supply_assets = to_u128(zero_floor_sub(m.total_supply_assets, bad_debt_assets))?;
            m.total_borrow_shares = sub(m.total_borrow_shares, bad_debt_shares)?;
            p.borrow_shares = U256::ZERO;
        }
        health_after = U256::MAX;
    }

    Ok(LiquidationOutcome {
        health_before,
        bonus,
        seized_assets,
        repaid_shares,
        repaid_assets,
        bad_debt_assets,
        bad_debt_shares,
        health_after,
        market: m,
        position: p,
    })
}

/// A liquidation the keeper can submit, with its simulated outcome.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LiquidationPlan {
    /// The call arguments.
    pub input: LiquidationInput,
    /// What the engine will do with them (at the simulated price and state).
    pub outcome: LiquidationOutcome,
}

/// Plans the liquidation a keeper submits for an unhealthy position: a close of the whole position
/// ([`LiquidationInput::close`]).
///
/// The engine prices a close from the state at execution: a full repayment while the collateral covers debt plus
/// bonus (the borrower keeps the rest), a full repayment for all the collateral while it covers the debt, and
/// otherwise a closeout that seizes everything and writes off the rest. Returns `None` for positions without debt
/// and for healthy ones.
pub fn plan_full_liquidation(
    market: &MarketState,
    position: &PositionState,
    price: U256,
    config: &LiquidationConfig,
) -> Option<LiquidationPlan> {
    if position.borrow_shares.is_zero() {
        return None;
    }
    let input = LiquidationInput::close();
    liquidate(market, position, price, config, input).ok().map(|outcome| LiquidationPlan { input, outcome })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn e18(x: u64) -> U256 {
        U256::from(x) * WAD
    }

    /// The fixture used by `test/unit/Liquidation.t.sol`: 100 collateral, 80 debt, LLTV 86 %, 5 % cap, slope 2.
    fn fixture() -> (MarketState, PositionState, LiquidationConfig) {
        let market = MarketState {
            total_supply_assets: e18(1_000),
            total_supply_shares: e18(1_000) * U256::from(1_000_000u64),
            total_borrow_assets: e18(80),
            total_borrow_shares: e18(80) * U256::from(1_000_000u64),
        };
        let position = PositionState { collateral: e18(100), borrow_shares: e18(80) * U256::from(1_000_000u64) };
        let config = LiquidationConfig {
            lltv: U256::from(860_000_000_000_000_000u64),
            max_bonus: U256::from(50_000_000_000_000_000u64),
            bonus_slope: e18(2),
        };
        (market, position, config)
    }

    fn price(num: u64, den: u64) -> U256 {
        ORACLE_PRICE_SCALE * U256::from(num) / U256::from(den)
    }

    #[test]
    fn matches_solidity_unit_test_partial_seizure() {
        let (m, p, c) = fixture();
        let out = liquidate(&m, &p, price(9, 10), &c, LiquidationInput::Seize(e18(10))).unwrap();
        assert_eq!(out.health_before, U256::from(967_500_000_000_000_000u64));
        assert_eq!(out.bonus, U256::from(50_000_000_000_000_000u64));
        assert_eq!(out.repaid_assets, U256::from(8_571_428_571_428_571_429u64));
        assert!(out.health_after > out.health_before);
    }

    #[test]
    fn matches_solidity_unit_test_underwater_closeout() {
        // Price 0.7: collateral worth 70 < debt 80, so all collateral is seized at the 5 % bonus.
        let (m, p, c) = fixture();
        let out = liquidate(&m, &p, price(7, 10), &c, LiquidationInput::Seize(e18(100))).unwrap();
        let repaid = U256::from(66_666_666_666_666_666_667u128); // ceil(70e18 / 1.05)
        assert_eq!(out.repaid_assets, repaid);
        assert_eq!(out.bad_debt_assets, e18(80) - repaid);
        assert_eq!(out.bonus, U256::from(50_000_000_000_000_000u64));
        assert_eq!(out.position, PositionState::default());
        assert_eq!(out.market.total_supply_assets, e18(1_000) - out.bad_debt_assets);
    }

    #[test]
    fn band_closeout_repays_everything_and_caps_the_bonus_at_equity() {
        // Price 0.83: collateral worth 83 covers the 80 debt but not 84 (debt plus 5 %).
        let (m, p, c) = fixture();
        for input in [LiquidationInput::Seize(e18(100)), LiquidationInput::close(), LiquidationInput::Seize(U256::MAX)]
        {
            let out = liquidate(&m, &p, price(83, 100), &c, input).unwrap();
            assert_eq!(out.seized_assets, e18(100));
            assert_eq!(out.repaid_assets, e18(80));
            assert_eq!(out.bad_debt_assets, U256::ZERO);
            assert_eq!(out.bonus, U256::from(37_500_000_000_000_000u64)); // (83 - 80) / 80
            assert_eq!(out.position, PositionState::default());
            assert_eq!(out.market.total_supply_assets, e18(1_000), "suppliers lose nothing");
        }
        // At price 0.8 the collateral is worth exactly the debt: full repayment, zero bonus.
        let out = liquidate(&m, &p, price(8, 10), &c, LiquidationInput::close()).unwrap();
        assert_eq!((out.repaid_assets, out.bonus, out.bad_debt_assets), (e18(80), U256::ZERO, U256::ZERO));
    }

    #[test]
    fn dust_front_runs_cannot_block_a_close() {
        let (m, p, c) = fixture();
        // One wei of collateral deposited in front of a closeout: a request for the observed amount is now a
        // partial that would leave 1 wei behind (rejected), but a close request adapts to the new size.
        let bigger = PositionState { collateral: p.collateral + U256::from(1u8), ..p };
        assert!(matches!(
            liquidate(&m, &bigger, price(7, 10), &c, LiquidationInput::Seize(p.collateral)),
            Err(LiquidationError::HealthDecreased { .. })
        ));
        for input in [LiquidationInput::Seize(U256::MAX), LiquidationInput::close()] {
            let out = liquidate(&m, &bigger, price(7, 10), &c, input).unwrap();
            assert_eq!(out.seized_assets, bigger.collateral);
            assert_eq!(out.position, PositionState::default());
        }
        // One share repaid in front of an exact-amount full repayment.
        let smaller = PositionState { borrow_shares: p.borrow_shares - U256::from(1u8), ..p };
        let smaller_market = MarketState { total_borrow_shares: m.total_borrow_shares - U256::from(1u8), ..m };
        let out =
            liquidate(&smaller_market, &smaller, price(9, 10), &c, LiquidationInput::Repay(p.borrow_shares)).unwrap();
        assert_eq!(out.repaid_shares, smaller.borrow_shares);
        assert!(out.position.borrow_shares.is_zero());
    }

    #[test]
    fn insolvent_partial_is_rejected() {
        let (m, p, c) = fixture();
        let err = liquidate(&m, &p, price(8, 10), &c, LiquidationInput::Seize(e18(10))).unwrap_err();
        assert!(matches!(err, LiquidationError::HealthDecreased { .. }));
    }

    #[test]
    fn partial_that_exhausts_the_collateral_is_rejected() {
        // At price 0.7, repaying 66.666...667 assets seizes exactly all 100 collateral while debt remains.
        let (m, p, c) = fixture();
        let shares = U256::from(66_666_666_666_666_666_667u128) * U256::from(1_000_000u64);
        let err = liquidate(&m, &p, price(7, 10), &c, LiquidationInput::Repay(shares)).unwrap_err();
        assert_eq!(
            err,
            LiquidationError::HealthDecreased { before: U256::from(752_500_000_000_000_000u64), after: U256::ZERO }
        );
    }

    #[test]
    fn healthy_position_is_rejected() {
        let (m, p, c) = fixture();
        let err = liquidate(&m, &p, price(1, 1), &c, LiquidationInput::Seize(e18(1))).unwrap_err();
        assert_eq!(err, LiquidationError::HealthyPosition { health: U256::from(1_075_000_000_000_000_000u64) });
    }

    #[test]
    fn input_validation() {
        let (m, p, c) = fixture();
        assert_eq!(
            liquidate(&m, &p, price(9, 10), &c, LiquidationInput::Seize(U256::ZERO)),
            Err(LiquidationError::InconsistentInput)
        );
        assert_eq!(
            liquidate(&m, &p, U256::ZERO, &c, LiquidationInput::Seize(e18(1))),
            Err(LiquidationError::ZeroPrice)
        );
        // A partial seizure that would repay more than the debt, and a partial repayment that would seize more than
        // the collateral.
        assert!(matches!(
            liquidate(&m, &p, price(9, 10), &c, LiquidationInput::Seize(e18(99))),
            Err(LiquidationError::RepayExceedsDebt { .. })
        ));
        assert!(matches!(
            liquidate(&m, &p, price(7, 10), &c, LiquidationInput::Repay(e18(70) * U256::from(1_000_000u64))),
            Err(LiquidationError::SeizeExceedsCollateral { .. })
        ));
        // Oversized requests close the position instead of reverting.
        let out =
            liquidate(&m, &p, price(9, 10), &c, LiquidationInput::Repay(p.borrow_shares + U256::from(1u8))).unwrap();
        assert!(out.position.borrow_shares.is_zero());
        let out = liquidate(&m, &p, price(7, 10), &c, LiquidationInput::Seize(e18(101))).unwrap();
        assert!(out.position.collateral.is_zero() && out.position.borrow_shares.is_zero());
    }

    #[test]
    fn plan_is_a_close_in_every_regime() {
        let (m, p, c) = fixture();
        let solvent = plan_full_liquidation(&m, &p, price(9, 10), &c).unwrap();
        assert_eq!(solvent.input, LiquidationInput::close());
        assert_eq!(solvent.outcome.bad_debt_assets, U256::ZERO);
        assert!(solvent.outcome.position.collateral > U256::ZERO, "borrower keeps the excess collateral");

        let band = plan_full_liquidation(&m, &p, price(83, 100), &c).unwrap();
        assert_eq!(band.outcome.bad_debt_assets, U256::ZERO);
        assert!(band.outcome.position.collateral.is_zero());

        let underwater = plan_full_liquidation(&m, &p, price(6, 10), &c).unwrap();
        assert!(underwater.outcome.bad_debt_assets > U256::ZERO);

        assert!(plan_full_liquidation(&m, &p, price(1, 1), &c).is_none());
    }

    #[test]
    fn bonus_schedule() {
        let max = U256::from(50_000_000_000_000_000u64);
        let slope = e18(2);
        assert_eq!(liquidation_bonus(WAD, max, slope), Ok(U256::ZERO));
        assert_eq!(
            liquidation_bonus(U256::from(989_000_000_000_000_000u64), max, slope),
            Ok(U256::from(22_000_000_000_000_000u64))
        );
        assert_eq!(liquidation_bonus(U256::ZERO, max, slope), Ok(max));
    }
}
