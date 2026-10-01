// SPDX-License-Identifier: MIT
//! Candidate selection: which positions to liquidate and how, computed with `risk-math`.

use alloy::primitives::{Address, U256};
use risk_math::liquidation::position_health;
use risk_math::{LiquidationConfig, LiquidationPlan, MarketState, WAD, plan_full_liquidation};

use crate::book::PositionBook;

/// An unhealthy position and the liquidation planned for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    /// The borrower.
    pub borrower: Address,
    /// Its health factor at the snapshot (WAD).
    pub health: U256,
    /// The planned call and its simulated outcome.
    pub plan: LiquidationPlan,
}

/// Returns every liquidatable position with the close planned for it, most unhealthy first.
///
/// The plan is a close request (`repaidShares = type(uint256).max`), priced exactly as the engine will price it at
/// the same state and price: a full repayment while the collateral covers debt plus bonus, a full repayment for all
/// the collateral (bonus capped at the borrower's equity) while it covers the debt, otherwise a closeout that seizes
/// everything and writes off the rest. Because the request is sized "whatever the position is", a dust deposit or
/// repayment sent in front of it cannot make it revert.
pub fn find_candidates(
    book: &PositionBook,
    market: &MarketState,
    price: U256,
    config: &LiquidationConfig,
) -> Vec<Candidate> {
    let mut candidates: Vec<Candidate> = book
        .borrowers()
        .filter_map(|(borrower, position)| {
            let health = position_health(position, market, price, config.lltv).ok()?;
            if health >= WAD {
                return None;
            }
            let plan = plan_full_liquidation(market, position, price, config)?;
            Some(Candidate { borrower: *borrower, health, plan })
        })
        .collect();
    candidates.sort_by(|a, b| a.health.cmp(&b.health).then(a.borrower.cmp(&b.borrower)));
    candidates
}

/// Flash-loan size for a plan: the simulated repayment plus a buffer (in basis points, plus one unit) that
/// absorbs interest accrued between the snapshot and inclusion. Unused funds are returned by the flash loan.
pub fn flash_amount(plan: &LiquidationPlan, buffer_bps: u64) -> U256 {
    let repaid = plan.outcome.repaid_assets;
    repaid + repaid * U256::from(buffer_bps) / U256::from(10_000u64) + U256::from(1u8)
}

/// Converts a gas cost in wei into loan-token base units, given the price of 1 ETH in loan base units.
pub fn gas_cost_in_loan(gas_cost_wei: U256, eth_price_in_loan: U256) -> U256 {
    gas_cost_wei * eth_price_in_loan / U256::from(1_000_000_000_000_000_000u128)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::book::EngineEvent;
    use proptest::prelude::*;
    use risk_math::{LiquidationInput, ORACLE_PRICE_SCALE};

    fn e18(x: u64) -> U256 {
        U256::from(x) * WAD
    }

    fn setup(positions: &[(u8, u64, u64)]) -> (PositionBook, MarketState, LiquidationConfig) {
        let mut book = PositionBook::new();
        let mut market = MarketState {
            total_supply_assets: e18(10_000),
            total_supply_shares: e18(10_000) * U256::from(1_000_000u64),
            ..MarketState::default()
        };
        for &(who, collateral, debt) in positions {
            let shares = e18(debt) * U256::from(1_000_000u64);
            book.apply(EngineEvent::SupplyCollateral { on_behalf: Address::repeat_byte(who), assets: e18(collateral) })
                .unwrap();
            book.apply(EngineEvent::Borrow { on_behalf: Address::repeat_byte(who), shares }).unwrap();
            market.total_borrow_assets += e18(debt);
            market.total_borrow_shares += shares;
        }
        let config = LiquidationConfig {
            lltv: U256::from(860_000_000_000_000_000u64),
            max_bonus: U256::from(50_000_000_000_000_000u64),
            bonus_slope: e18(2),
        };
        (book, market, config)
    }

    #[test]
    fn picks_unhealthy_positions_most_unhealthy_first() {
        // At price 0.9: health 1.075*0.9=0.9675 (80 debt), 0.86*100*0.9/70=1.105 (70 debt), 0.86*0.9/0.85=0.9106.
        let (book, market, config) = setup(&[(1, 100, 80), (2, 100, 70), (3, 100, 85)]);
        let price = ORACLE_PRICE_SCALE * U256::from(9u8) / U256::from(10u8);
        let candidates = find_candidates(&book, &market, price, &config);
        let who: Vec<Address> = candidates.iter().map(|c| c.borrower).collect();
        assert_eq!(who, vec![Address::repeat_byte(3), Address::repeat_byte(1)]);
        assert!(candidates.iter().all(|c| matches!(c.plan.input, LiquidationInput::Repay(_))));
    }

    #[test]
    fn every_plan_is_a_close_that_resolves_the_position() {
        let (book, market, config) = setup(&[(1, 100, 80), (2, 100, 60)]);
        // Price 0.6: position 1 (collateral worth 60 against 80 of debt) is under water, position 2 (60 against 60)
        // sits exactly at the boundary where the closeout pays no bonus and realizes no bad debt.
        let price = ORACLE_PRICE_SCALE * U256::from(6u8) / U256::from(10u8);
        let candidates = find_candidates(&book, &market, price, &config);
        assert_eq!(candidates.len(), 2);
        for c in &candidates {
            assert_eq!(c.plan.input, LiquidationInput::close());
            assert!(c.plan.outcome.position.collateral.is_zero());
            assert!(c.plan.outcome.position.borrow_shares.is_zero());
        }
        assert!(candidates[0].plan.outcome.bad_debt_assets > U256::ZERO);
        assert_eq!(candidates[1].plan.outcome.bad_debt_assets, U256::ZERO);
        assert_eq!(candidates[1].plan.outcome.repaid_assets, e18(60));
    }

    #[test]
    fn helpers() {
        let (book, market, config) = setup(&[(1, 100, 80)]);
        let price = ORACLE_PRICE_SCALE * U256::from(9u8) / U256::from(10u8);
        let plan = &find_candidates(&book, &market, price, &config)[0].plan;
        assert!(flash_amount(plan, 50) > plan.outcome.repaid_assets);
        // 300k gas at 1 gwei with ETH at 2000 loan units = 0.6 loan units.
        let cost = gas_cost_in_loan(U256::from(300_000u64 * 1_000_000_000u64), e18(2_000));
        assert_eq!(cost, U256::from(600_000_000_000_000_000u128));
    }

    proptest! {
        /// Every candidate is unhealthy and its plan leaves no debt.
        #[test]
        fn candidates_are_unhealthy_and_fully_resolved(
            debts in proptest::collection::vec(1u64..99, 1..8),
            price_bps in 3_000u64..12_000,
        ) {
            let positions: Vec<(u8, u64, u64)> = debts.iter().enumerate().map(|(i, &d)| (i as u8 + 1, 100, d)).collect();
            let (book, market, config) = setup(&positions);
            let price = ORACLE_PRICE_SCALE * U256::from(price_bps) / U256::from(10_000u64);
            let candidates = find_candidates(&book, &market, price, &config);
            for window in candidates.windows(2) {
                prop_assert!(window[0].health <= window[1].health);
            }
            for c in &candidates {
                prop_assert!(c.health < WAD);
                prop_assert!(c.plan.outcome.position.borrow_shares.is_zero());
            }
        }
    }
}
