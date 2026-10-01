// SPDX-License-Identifier: MIT
//! `export-vectors`: 100 liquidation scenarios whose expectations come from `risk-math`, replayed by Foundry.
//!
//! Scenarios cover every branch of `LendingEngine.liquidate` (partial liquidations, full repayments, closeouts that
//! cap the bonus at the borrower's equity, under-water closeouts with bad debt, oversized requests that close the
//! position, and every revert) with randomized magnitudes (collateral from 1 wei to 1e27, prices across 30 orders
//! of magnitude, share prices after interest) so that rounding, not just the happy path, is compared between the two
//! implementations.

use risk_math::liquidation::{MarketState, PositionState, position_health};
use risk_math::shares::to_shares_down;
use risk_math::vectors::{SCHEMA, Vector, VectorFile};
use risk_math::{ORACLE_PRICE_SCALE, U256};

use crate::config::bps_to_wad;
use crate::rng::{Rng, stream_seed};

/// Default seed of the committed vector file.
pub const DEFAULT_SEED: u64 = 0x005e_ed22;

/// (LLTV, bonus cap, slope) triples in basis points; each is accepted by `enableLltv`.
const CONFIGS: [(u64, u64, u64); 5] =
    [(8_600, 500, 20_000), (9_150, 200, 10_000), (7_700, 1_000, 30_000), (6_250, 1_500, 5_000), (9_450, 300, 40_000)];

/// Scenario categories and how many vectors of each the file contains (sums to 100).
const CATEGORIES: [(Category, usize); 11] = [
    (Category::SolventSeize, 16),
    (Category::SolventRepay, 16),
    (Category::FullRepay, 10),
    (Category::BandCloseout, 10),
    (Category::UnderwaterCloseout, 12),
    (Category::InsolventPartial, 8),
    (Category::Healthy, 6),
    (Category::RepayExceedsDebt, 6),
    (Category::SeizeExceedsCollateral, 6),
    (Category::OversizeClose, 6),
    (Category::Dust, 4),
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Category {
    SolventSeize,
    SolventRepay,
    FullRepay,
    BandCloseout,
    UnderwaterCloseout,
    InsolventPartial,
    Healthy,
    RepayExceedsDebt,
    SeizeExceedsCollateral,
    OversizeClose,
    Dust,
}

impl Category {
    fn name(self) -> &'static str {
        match self {
            Self::SolventSeize => "solvent-partial-seize",
            Self::SolventRepay => "solvent-partial-repay",
            Self::FullRepay => "solvent-full-repay",
            Self::BandCloseout => "band-closeout-equity-bonus",
            Self::UnderwaterCloseout => "underwater-closeout",
            Self::InsolventPartial => "insolvent-partial-rejected",
            Self::Healthy => "healthy-rejected",
            Self::RepayExceedsDebt => "partial-seize-exceeds-debt",
            Self::SeizeExceedsCollateral => "partial-repay-exceeds-collateral",
            Self::OversizeClose => "oversize-request-closes",
            Self::Dust => "dust-rounding",
        }
    }

    /// Whether a generated vector exercises the branch this category is meant to cover (`None`: any outcome).
    fn accepts(self, v: &Vector) -> bool {
        let e = &v.expected;
        let ok = e.outcome == "ok";
        match self {
            Self::SolventSeize | Self::SolventRepay => ok && !e.collateral_after.is_zero(),
            Self::FullRepay => ok && e.borrow_shares_after.is_zero() && !e.collateral_after.is_zero(),
            Self::BandCloseout => ok && e.collateral_after.is_zero() && e.bad_debt_assets.is_zero(),
            Self::UnderwaterCloseout => ok && !e.bad_debt_assets.is_zero(),
            Self::OversizeClose => ok && e.borrow_shares_after.is_zero(),
            Self::InsolventPartial => e.outcome == "HealthDecreased",
            Self::Healthy => e.outcome == "HealthyPosition",
            Self::RepayExceedsDebt => e.outcome == "RepayExceedsDebt",
            Self::SeizeExceedsCollateral => e.outcome == "SeizeExceedsCollateral",
            Self::Dust => true,
        }
    }
}

/// Log-uniform integer in `[10^lo, 10^hi)`.
fn log_uniform(rng: &mut Rng, lo: f64, hi: f64) -> U256 {
    let exponent = rng.range(lo, hi);
    let whole = libm::floor(exponent);
    let mantissa = libm::pow(10.0, exponent - whole); // in [1, 10)
    // Keep 15 significant digits from the mantissa and the rest from the power of ten.
    let digits = (mantissa * 1e14) as u128;
    let scale = whole as i32 - 14;
    if scale >= 0 {
        U256::from(digits) * U256::from(10u8).pow(U256::from(scale as u32))
    } else {
        U256::from(digits) / U256::from(10u8).pow(U256::from((-scale) as u32))
    }
}

fn fraction(x: U256, rng: &mut Rng, lo: f64, hi: f64) -> U256 {
    let f = (rng.range(lo, hi) * 1e9) as u64;
    x * U256::from(f) / U256::from(1_000_000_000u64)
}

/// Builds one candidate vector (its expectation may not match the category; the caller retries).
fn candidate(rng: &mut Rng, category: Category, index: usize) -> Vector {
    let (lltv_bps, cap_bps, slope_bps) = CONFIGS[rng.below(CONFIGS.len() as u64) as usize];
    let lltv = bps_to_wad(lltv_bps) as f64 / 1e18;
    let cap = bps_to_wad(cap_bps) as f64 / 1e18;

    // Debt and market around it; share prices reflect accrued interest (fewer than 1e6 shares per asset).
    let (debt, collateral) = if category == Category::Dust {
        (log_uniform(rng, 0.0, 4.0) + U256::from(1u8), log_uniform(rng, 0.0, 4.0) + U256::from(1u8))
    } else {
        (log_uniform(rng, 9.0, 26.0), log_uniform(rng, 6.0, 27.0))
    };
    let others = fraction(debt, rng, 0.0, 50.0);
    let total_borrow_assets = debt + others;
    let shares_per_asset = rng.range(0.3e6, 1e6);
    let total_borrow_shares =
        total_borrow_assets * U256::from(shares_per_asset as u64) + U256::from(rng.below(1_000_000));
    let borrow_shares =
        to_shares_down(debt, total_borrow_assets, total_borrow_shares).unwrap_or(U256::ZERO).min(total_borrow_shares);
    let total_supply_assets = total_borrow_assets * U256::from(1_000u64) / U256::from(rng.range(500.0, 999.0) as u64);
    let total_supply_shares = total_supply_assets * U256::from(rng.range(0.5e6, 1e6) as u64);

    // Price that puts the position at the target health factor: health = collateral * price / 1e36 * lltv / debt.
    // In health terms, collateral value / debt = health / lltv: the position is under water below `lltv` and cannot
    // pay debt plus the full bonus below `lltv * (1 + cap)`.
    let target_health = match category {
        Category::SolventSeize | Category::SolventRepay | Category::FullRepay | Category::RepayExceedsDebt => {
            rng.range(lltv * (1.0 + cap) + 0.005, 0.9999)
        }
        Category::BandCloseout => rng.range(lltv * 1.0005, lltv * (1.0 + cap) * 0.9995),
        Category::UnderwaterCloseout | Category::InsolventPartial | Category::SeizeExceedsCollateral => {
            rng.range(0.05, lltv * 0.97)
        }
        Category::OversizeClose => rng.range(0.05, 0.9999),
        Category::Healthy => rng.range(1.0, 3.0),
        Category::Dust => rng.range(0.05, 1.2),
    };
    let health_wad = U256::from((target_health * 1e18) as u128);
    let denominator = collateral * U256::from(bps_to_wad(lltv_bps));
    let price = (health_wad * debt * ORACLE_PRICE_SCALE / denominator).max(U256::from(1u8));

    let (seized_assets, repaid_shares) = match category {
        Category::SolventSeize => (fraction(collateral, rng, 0.001, 0.5).max(U256::from(1u8)), U256::ZERO),
        Category::SolventRepay => (U256::ZERO, fraction(borrow_shares, rng, 0.001, 0.9).max(U256::from(1u8))),
        Category::FullRepay => (U256::ZERO, borrow_shares),
        Category::BandCloseout | Category::UnderwaterCloseout => {
            if rng.uniform() < 0.5 {
                (collateral, U256::ZERO)
            } else {
                (U256::ZERO, borrow_shares)
            }
        }
        Category::InsolventPartial => (fraction(collateral, rng, 0.01, 0.9).max(U256::from(1u8)), U256::ZERO),
        Category::Healthy => (fraction(collateral, rng, 0.0, 0.5).max(U256::from(1u8)), U256::ZERO),
        // A partial seizure (less than all collateral) that would repay more than the debt.
        Category::RepayExceedsDebt => (fraction(collateral, rng, 0.99, 0.99999).max(U256::from(1u8)), U256::ZERO),
        // A partial repayment (less than all shares) that would seize more than the collateral.
        Category::SeizeExceedsCollateral => {
            (U256::ZERO, fraction(borrow_shares, rng, 0.9, 0.99999).max(U256::from(1u8)))
        }
        // More than the whole position, or `type(uint256).max`, on either side.
        Category::OversizeClose => match rng.below(4) {
            0 => (collateral + fraction(collateral, rng, 0.0, 1.0).max(U256::from(1u8)), U256::ZERO),
            1 => (U256::ZERO, borrow_shares + fraction(borrow_shares, rng, 0.0, 1.0).max(U256::from(1u8))),
            2 => (U256::MAX, U256::ZERO),
            _ => (U256::ZERO, U256::MAX),
        },
        Category::Dust => {
            if rng.uniform() < 0.5 {
                (U256::from(1u8) + U256::from(rng.below(collateral.saturating_to::<u64>().max(1))), U256::ZERO)
            } else {
                (U256::ZERO, U256::from(1u8) + U256::from(rng.below(borrow_shares.saturating_to::<u64>().max(1))))
            }
        }
    };

    let mut vector = Vector {
        name: format!("{:03}-{}", index, category.name()),
        lltv: U256::from(bps_to_wad(lltv_bps)),
        max_bonus: U256::from(bps_to_wad(cap_bps)),
        bonus_slope: U256::from(bps_to_wad(slope_bps)),
        price,
        total_supply_assets,
        total_supply_shares,
        total_borrow_assets,
        total_borrow_shares,
        collateral,
        borrow_shares,
        seized_assets,
        repaid_shares,
        expected: risk_math::vectors::Expected {
            outcome: String::new(),
            error_args: [U256::ZERO, U256::ZERO],
            health_before: U256::ZERO,
            bonus: U256::ZERO,
            seized_assets: U256::ZERO,
            repaid_shares: U256::ZERO,
            repaid_assets: U256::ZERO,
            bad_debt_assets: U256::ZERO,
            bad_debt_shares: U256::ZERO,
            health_after: U256::ZERO,
            collateral_after: U256::ZERO,
            borrow_shares_after: U256::ZERO,
            total_supply_assets_after: U256::ZERO,
            total_borrow_assets_after: U256::ZERO,
            total_borrow_shares_after: U256::ZERO,
        },
    };
    if let Some(expected) = vector.compute_expected() {
        vector.expected = expected;
    }
    vector
}

fn fits_engine_storage(v: &Vector) -> bool {
    let max = U256::from(u128::MAX);
    [
        v.total_supply_assets,
        v.total_supply_shares,
        v.total_borrow_assets,
        v.total_borrow_shares,
        v.collateral,
        v.borrow_shares,
    ]
    .iter()
    .all(|x| *x <= max)
        && v.total_borrow_assets <= v.total_supply_assets
        && v.borrow_shares <= v.total_borrow_shares
        && !v.borrow_shares.is_zero()
}

fn sanity(v: &Vector) -> bool {
    let (market, position, config): (MarketState, PositionState, _) = v.state();
    position_health(&position, &market, v.price, config.lltv).is_ok() && v.price >= U256::from(1u8)
}

/// Generates the vector file.
pub fn generate(seed: u64) -> anyhow::Result<VectorFile> {
    let mut vectors = Vec::with_capacity(100);
    for (category_index, &(category, count)) in CATEGORIES.iter().enumerate() {
        let mut rng = Rng::new(stream_seed(seed, category_index as u64));
        let mut produced = 0;
        let mut attempts = 0;
        while produced < count {
            attempts += 1;
            anyhow::ensure!(attempts < 100_000, "could not generate {} vectors", category.name());
            let v = candidate(&mut rng, category, vectors.len());
            if v.expected.outcome.is_empty() || !fits_engine_storage(&v) || !sanity(&v) || !category.accepts(&v) {
                continue;
            }
            vectors.push(v);
            produced += 1;
        }
    }
    Ok(VectorFile {
        schema: SCHEMA.to_string(),
        generator: "cascade-sim export-vectors".to_string(),
        seed,
        count: vectors.len(),
        vectors,
    })
}

/// Serializes the vector file (pretty JSON with a trailing newline).
pub fn render(file: &VectorFile) -> anyhow::Result<String> {
    Ok(serde_json::to_string_pretty(file)? + "\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generates_one_hundred_vectors_covering_every_outcome() {
        let file = generate(DEFAULT_SEED).unwrap();
        assert_eq!(file.count, 100);
        assert_eq!(file.vectors.len(), 100);
        for outcome in ["ok", "HealthDecreased", "HealthyPosition", "RepayExceedsDebt", "SeizeExceedsCollateral"] {
            assert!(file.vectors.iter().any(|v| v.expected.outcome == outcome), "missing {outcome}");
        }
        assert!(file.vectors.iter().any(|v| !v.expected.bad_debt_assets.is_zero()), "no bad-debt vector");
        assert!(
            file.vectors.iter().any(|v| v.expected.outcome == "ok"
                && v.expected.collateral_after.is_zero()
                && v.expected.bad_debt_assets.is_zero()),
            "no closeout capped at the borrower's equity"
        );
        assert!(file.vectors.iter().any(|v| v.seized_assets == U256::MAX || v.repaid_shares == U256::MAX));
        // Every expectation is reproducible.
        for v in &file.vectors {
            assert_eq!(v.compute_expected().as_ref(), Some(&v.expected), "{}", v.name);
        }
    }

    #[test]
    fn deterministic() {
        let a = render(&generate(1).unwrap()).unwrap();
        let b = render(&generate(1).unwrap()).unwrap();
        assert_eq!(a, b);
    }
}
