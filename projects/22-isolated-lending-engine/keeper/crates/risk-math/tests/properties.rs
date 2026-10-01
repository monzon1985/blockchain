// SPDX-License-Identifier: MIT
//! Property tests of the Rust port: the same properties the Foundry fuzz and Halmos suites check on-chain.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use proptest::prelude::*;
use risk_math::liquidation::{LiquidationError, collateral_value, debt_of, liquidation_bonus, position_health};
use risk_math::shares::{to_assets_down, to_assets_up, to_shares_down, to_shares_up};
use risk_math::{
    LiquidationConfig, LiquidationInput, MarketState, ORACLE_PRICE_SCALE, PositionState, U256, WAD, liquidate,
    plan_full_liquidation,
};

fn u(x: u128) -> U256 {
    U256::from(x)
}

/// A market with one borrower whose health factor is `health_milli / 1000` (approximately).
fn position(
    collateral: u128,
    debt: u128,
    share_ratio: u64,
    health_milli: u64,
    lltv_bps: u64,
) -> (MarketState, PositionState, U256, U256) {
    let total_borrow_assets = u(debt);
    let total_borrow_shares = u(debt) * U256::from(share_ratio);
    let market = MarketState {
        total_supply_assets: total_borrow_assets * u(2),
        total_supply_shares: total_borrow_assets * u(2_000_000),
        total_borrow_assets,
        total_borrow_shares,
    };
    let position = PositionState { collateral: u(collateral), borrow_shares: total_borrow_shares };
    let lltv = U256::from(lltv_bps) * U256::from(100_000_000_000_000u64);
    // health = collateral * price / 1e36 * lltv / debt
    let price = U256::from(health_milli) * WAD / u(1000) * u(debt) * ORACLE_PRICE_SCALE / (u(collateral) * lltv);
    (market, position, price.max(u(1)), lltv)
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 2_000, ..ProptestConfig::default() })]

    /// Supplying then withdrawing the minted shares never returns more than supplied.
    #[test]
    fn supply_withdraw_round_trip(assets in 0u128..u128::MAX / 2, total_assets in 0u128..u64::MAX as u128, total_shares in 0u128..u64::MAX as u128) {
        let shares = to_shares_down(u(assets), u(total_assets), u(total_shares)).unwrap();
        let back = to_assets_down(shares, u(total_assets), u(total_shares));
        if let Ok(back) = back { prop_assert!(back <= u(assets)); }
    }

    /// Borrowed assets are always covered by the debt they mint.
    #[test]
    fn borrow_mints_enough_debt(assets in 0u128..u64::MAX as u128, total_assets in 0u128..u64::MAX as u128, total_shares in 0u128..u64::MAX as u128) {
        let shares = to_shares_up(u(assets), u(total_assets), u(total_shares)).unwrap();
        prop_assert!(to_assets_up(shares, u(total_assets), u(total_shares)).unwrap() >= u(assets));
    }

    /// The bonus is non-decreasing in the deficit and bounded by its cap.
    #[test]
    fn bonus_monotonic(h1 in 0u64..2_000_000_000_000_000_000, delta in 0u64..2_000_000_000_000_000_000, cap in 1u64..250_000_000_000_000_000, slope in 1u128..20_000_000_000_000_000_000) {
        let h2 = h1.saturating_sub(delta);
        let b1 = liquidation_bonus(U256::from(h1), U256::from(cap), U256::from(slope)).unwrap();
        let b2 = liquidation_bonus(U256::from(h2), U256::from(cap), U256::from(slope)).unwrap();
        prop_assert!(b1 <= b2);
        prop_assert!(b2 <= U256::from(cap));
    }

    /// A successful liquidation raises (or keeps) the health factor unless it exhausts the collateral and writes
    /// off the rest; the only allowed failures are the documented custom errors.
    #[test]
    fn liquidation_never_lowers_health_unless_bad_debt(
        collateral in 1_000_000u128..1_000_000_000_000_000_000_000_000_000,
        debt in 1_000_000u128..1_000_000_000_000_000_000_000_000_000,
        share_ratio in 300_000u64..1_000_000,
        health_milli in 50u64..999,
        seize_ppm in 1u64..1_200_000,
        by_seizure in any::<bool>(),
    ) {
        let (market, pos, price, lltv) = position(collateral, debt, share_ratio, health_milli, 8_600);
        let config = LiquidationConfig { lltv, max_bonus: u(50_000_000_000_000_000), bonus_slope: u(2) * WAD };
        let input = if by_seizure {
            LiquidationInput::Seize((pos.collateral * U256::from(seize_ppm) / u(1_000_000)).max(u(1)))
        } else {
            LiquidationInput::Repay((pos.borrow_shares * U256::from(seize_ppm) / u(1_000_000)).max(u(1)))
        };
        let before = position_health(&pos, &market, price, lltv).unwrap();
        match liquidate(&market, &pos, price, &config, input) {
            Ok(out) => {
                if out.position.collateral.is_zero() {
                    prop_assert!(out.position.borrow_shares.is_zero());
                } else {
                    prop_assert!(out.health_after >= before);
                }
                prop_assert!(out.market.total_borrow_assets <= market.total_borrow_assets);
            }
            Err(e) => prop_assert!(matches!(
                e,
                LiquidationError::HealthDecreased { .. }
                    | LiquidationError::RepayExceedsDebt { .. }
                    | LiquidationError::SeizeExceedsCollateral { .. }
                    | LiquidationError::HealthyPosition { .. }
            ), "unexpected error {e:?}"),
        }
    }

    /// Every unhealthy position has a valid full liquidation (a close), and it resolves the position.
    #[test]
    fn unhealthy_positions_can_always_be_closed(
        collateral in 1_000_000u128..1_000_000_000_000_000_000_000_000_000,
        debt in 1_000_000u128..1_000_000_000_000_000_000_000_000_000,
        share_ratio in 300_000u64..1_000_000,
        health_milli in 20u64..999,
    ) {
        let (market, pos, price, lltv) = position(collateral, debt, share_ratio, health_milli, 8_600);
        let config = LiquidationConfig { lltv, max_bonus: u(50_000_000_000_000_000), bonus_slope: u(2) * WAD };
        let health = position_health(&pos, &market, price, lltv).unwrap();
        prop_assume!(health < WAD);
        let plan = plan_full_liquidation(&market, &pos, price, &config);
        prop_assert!(plan.is_some(), "no valid full liquidation at health {health}");
        let out = plan.unwrap().outcome;
        prop_assert!(out.position.borrow_shares.is_zero());
    }

    /// Any request at or above the position's size closes it, whichever side it is denominated in, including after
    /// a dust deposit or repayment front-runs a request sized on the old state.
    #[test]
    fn close_requests_cannot_be_blocked_by_dust(
        collateral in 1_000_000u128..1_000_000_000_000_000_000_000_000_000,
        debt in 1_000_000u128..1_000_000_000_000_000_000_000_000_000,
        share_ratio in 300_000u64..1_000_000,
        health_milli in 20u64..999,
        dust in 1u64..1_000_000,
        repay_dust in any::<bool>(),
        by_seizure in any::<bool>(),
    ) {
        let (mut market, mut pos, price, lltv) = position(collateral, debt, share_ratio, health_milli, 8_600);
        let config = LiquidationConfig { lltv, max_bonus: u(50_000_000_000_000_000), bonus_slope: u(2) * WAD };
        prop_assume!(position_health(&pos, &market, price, lltv).unwrap() < WAD);
        let observed = pos;
        // The front-run: a dust collateral deposit, or a dust repayment that leaves some debt.
        if repay_dust {
            let d = U256::from(dust).min(pos.borrow_shares - u(1));
            pos.borrow_shares -= d;
            market.total_borrow_shares -= d;
        } else {
            pos.collateral += U256::from(dust);
        }
        prop_assume!(position_health(&pos, &market, price, lltv).unwrap() < WAD);
        let input = if by_seizure {
            LiquidationInput::Seize(observed.collateral.max(pos.collateral))
        } else {
            LiquidationInput::Repay(observed.borrow_shares)
        };
        let out = liquidate(&market, &pos, price, &config, input);
        prop_assert!(out.is_ok(), "{input:?} blocked: {out:?}");
        prop_assert!(out.unwrap().position.borrow_shares.is_zero());
        let out = liquidate(&market, &pos, price, &config, LiquidationInput::close()).unwrap();
        prop_assert!(out.position.borrow_shares.is_zero());
    }

    /// Suppliers never lose anything to a liquidation of a position whose collateral is still worth its debt, and
    /// bad debt is realized only by a closeout that takes all the collateral of an under-water position.
    #[test]
    fn no_supplier_loss_while_collateral_covers_debt(
        collateral in 1_000_000u128..1_000_000_000_000_000_000_000_000_000,
        debt in 1_000_000u128..1_000_000_000_000_000_000_000_000_000,
        share_ratio in 300_000u64..1_000_000,
        health_milli in 500u64..999,
        amount_ppm in 1u64..1_200_000,
        by_seizure in any::<bool>(),
    ) {
        let (market, pos, price, lltv) = position(collateral, debt, share_ratio, health_milli, 8_600);
        let config = LiquidationConfig { lltv, max_bonus: u(50_000_000_000_000_000), bonus_slope: u(2) * WAD };
        let value = collateral_value(pos.collateral, price).unwrap();
        let owed = debt_of(&pos, &market).unwrap();
        let input = if by_seizure {
            LiquidationInput::Seize((pos.collateral * U256::from(amount_ppm) / u(1_000_000)).max(u(1)))
        } else {
            LiquidationInput::Repay((pos.borrow_shares * U256::from(amount_ppm) / u(1_000_000)).max(u(1)))
        };
        if let Ok(out) = liquidate(&market, &pos, price, &config, input) {
            if value >= owed {
                prop_assert_eq!(out.bad_debt_assets, U256::ZERO);
                prop_assert_eq!(out.market.total_supply_assets, market.total_supply_assets);
            }
            if !out.bad_debt_assets.is_zero() {
                prop_assert!(value < owed);
                prop_assert!(out.position.collateral.is_zero());
            }
        }
    }
}
