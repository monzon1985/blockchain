// SPDX-License-Identifier: MIT
//! Agent-based simulation of one market along one price path.
//!
//! Agents:
//! - **Borrowers** open positions at the start (log-normal sizes, each using a random share of its borrowing
//!   capacity) and then stay passive: no top-ups, no voluntary deleveraging. This is the conservative case.
//! - **Liquidators** see a position only after it has been liquidatable for `liquidator_latency_blocks`, then pick
//!   the most profitable valid liquidation (a close of the whole position, or a partial repayment of 1/2, 1/4 or
//!   1/10 of the debt while collateral covers debt plus bonus), sell the seized collateral into the pool and act
//!   only if the proceeds cover the repayment and gas. A close pays the scheduled bonus while the collateral covers
//!   debt plus bonus, the borrower's equity while it only covers the debt, and the scheduled bonus again (with bad
//!   debt) once the position is under water: exactly the engine's rules.
//! - **Arbitrageurs** pull the pool price toward the external path at a fixed speed.
//!
//! Every liquidation is priced and applied with `risk_math::liquidate`, i.e. with the contract's exact integer
//! arithmetic, including the health guard and bad-debt write-off. Only the price process and the pool are
//! floating point.

use risk_math::liquidation::{LiquidationConfig, MarketState, PositionState, debt_of, position_health};
use risk_math::shares::to_shares_up;
use risk_math::{LiquidationInput, LiquidationOutcome, U256, WAD, liquidate};

use crate::amm::Pool;
use crate::config::{SimConfig, bps_to_f64, bps_to_wad};
use crate::paths::PricePath;
use crate::rng::{Rng, stream_seed};

const TOKEN: f64 = 1e18;

/// A borrower of the synthetic population (identical across cells, so cells are compared on the same users).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Borrower {
    /// Collateral value at the starting price, in loan-token units.
    pub collateral_value: f64,
    /// Share of the borrowing capacity used (`debt = value * lltv * capacity_used`).
    pub capacity_used: f64,
}

/// Generates the borrower population for `config`.
pub fn population(config: &SimConfig) -> Vec<Borrower> {
    let mut rng = Rng::new(stream_seed(config.seed, u64::MAX));
    let raw: Vec<(f64, f64)> = (0..config.borrowers)
        .map(|_| {
            let size = rng.lognormal(1.0, config.position_size_sigma);
            let used = rng.range(config.min_capacity_used, config.max_capacity_used);
            (size, used)
        })
        .collect();
    let total: f64 = raw.iter().map(|(s, _)| s).sum();
    raw.into_iter()
        .map(|(size, used)| Borrower {
            collateral_value: size / total * config.total_collateral_value,
            capacity_used: used,
        })
        .collect()
}

/// A grid cell: an LLTV and a bonus cap (basis points).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cell {
    /// LLTV in basis points.
    pub lltv_bps: u64,
    /// Bonus cap in basis points.
    pub bonus_cap_bps: u64,
}

/// What happened along one path.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct PathOutcome {
    /// Total debt at the start (loan-token units).
    pub initial_borrow: f64,
    /// Total collateral value at the start (loan-token units).
    pub initial_collateral_value: f64,
    /// Debt written off by the engine during closeouts.
    pub realized_bad_debt: f64,
    /// Debt exceeding collateral value at the end, on positions nobody liquidated.
    pub unrealized_bad_debt: f64,
    /// Liquidations executed.
    pub liquidations: u32,
    /// Liquidations that exhausted the collateral (closeouts).
    pub closeouts: u32,
    /// Block-position pairs where a liquidatable position was left alone because no liquidation paid for itself.
    pub unprofitable_skips: u32,
    /// Sum of liquidator profit after gas.
    pub liquidator_profit: f64,
    /// Lowest oracle price seen, relative to the start.
    pub min_price_ratio: f64,
}

impl PathOutcome {
    /// Realized plus unrealized bad debt, as a fraction of initial borrows.
    pub fn bad_debt_ratio(&self) -> f64 {
        if self.initial_borrow == 0.0 {
            0.0
        } else {
            (self.realized_bad_debt + self.unrealized_bad_debt) / self.initial_borrow
        }
    }
}

fn to_units(x: f64) -> U256 {
    // `as u128` truncates toward zero and saturates: deterministic on every platform.
    U256::from((x * TOKEN) as u128)
}

fn to_f64(x: U256) -> f64 {
    x.saturating_to::<u128>() as f64 / TOKEN
}

/// Oracle price (1e36 scale) for a price in loan units per collateral unit, both with 18 decimals.
fn to_oracle_price(price: f64) -> U256 {
    U256::from((price * TOKEN) as u128) * U256::from(1_000_000_000_000_000_000u128)
}

/// Price at which a position's health factor crosses 1 (a filter for the exact check).
fn liquidation_price(position: &PositionState, market: &MarketState, lltv: f64) -> f64 {
    if position.borrow_shares.is_zero() || position.collateral.is_zero() {
        return if position.borrow_shares.is_zero() { 0.0 } else { f64::INFINITY };
    }
    let debt = debt_of(position, market).map(to_f64).unwrap_or(f64::INFINITY);
    debt / (to_f64(position.collateral) * lltv)
}

/// An f64 estimate below this profit (loan units) is trusted to mean "unprofitable" without the exact evaluation.
/// The estimate's error is many orders of magnitude smaller (relative error around 1e-12 on amounts below 1e9).
const PRUNE_MARGIN: f64 = 1.0;

/// Cheap f64 model of the engine's liquidation pricing, used only to skip exact (256/512-bit) evaluations of
/// liquidations that cannot be profitable. Positions that stay liquidatable but unprofitable for many blocks (low
/// bonus caps) would otherwise be re-priced exactly on every block. Skipping never changes a result: a candidate is
/// skipped only when its estimated profit is below `-PRUNE_MARGIN`, so its exact profit is negative too and it could
/// not have been executed, and never near the "collateral value = debt" boundary, where a closeout's exact
/// repayment jumps from the whole debt to the collateral's value net of the bonus.
struct ProfitEstimate {
    price: f64,
    collateral: f64,
    debt: f64,
    incentive: f64,
    ambiguous: bool,
}

impl ProfitEstimate {
    fn new(market: &MarketState, position: &PositionState, oracle: f64, config: &LiquidationConfig) -> Option<Self> {
        let debt = to_f64(debt_of(position, market).ok()?);
        let collateral = to_f64(position.collateral);
        let value = collateral * oracle;
        if debt <= 0.0 || oracle <= 0.0 {
            return None;
        }
        let health = value * wad_to_f64(config.lltv) / debt;
        let bonus = (wad_to_f64(config.bonus_slope) * (1.0 - health)).clamp(0.0, wad_to_f64(config.max_bonus));
        let ambiguous = (value - debt).abs() <= 1e-6 * debt;
        Some(Self { price: oracle, collateral, debt, incentive: 1.0 + bonus, ambiguous })
    }

    /// `(seized, repaid)` of a close, by regime.
    fn close(&self) -> (f64, f64) {
        let seized = self.debt * self.incentive / self.price;
        if seized <= self.collateral {
            (seized, self.debt)
        } else if self.collateral * self.price >= self.debt {
            (self.collateral, self.debt)
        } else {
            (self.collateral, self.collateral * self.price / self.incentive)
        }
    }

    /// Whether the exact evaluation of a liquidation repaying `(seized, repaid)` can be skipped.
    fn prunable(&self, (seized, repaid): (f64, f64), pool: &Pool, gas_cost: f64) -> bool {
        !self.ambiguous && pool.quote_sell(seized) - repaid - gas_cost < -PRUNE_MARGIN
    }
}

fn wad_to_f64(x: U256) -> f64 {
    x.saturating_to::<u128>() as f64 / TOKEN
}

/// The liquidation a profit-maximizing liquidator would submit, with its outcome and net profit.
fn best_liquidation(
    market: &MarketState,
    position: &PositionState,
    (price, oracle): (U256, f64),
    config: &LiquidationConfig,
    pool: &Pool,
    gas_cost: f64,
) -> Option<(LiquidationOutcome, f64)> {
    let estimate = ProfitEstimate::new(market, position, oracle, config);
    let evaluate = |input: LiquidationInput| {
        liquidate(market, position, price, config, input).ok().map(|outcome| {
            let proceeds = pool.quote_sell(to_f64(outcome.seized_assets));
            let profit = proceeds - to_f64(outcome.repaid_assets) - gas_cost;
            (outcome, profit)
        })
    };
    let shares = position.borrow_shares;
    // The close is valid in every regime; partial repayments only while collateral covers debt plus bonus.
    let mut candidates = vec![(LiquidationInput::close(), estimate.as_ref().map(ProfitEstimate::close))];
    for den in [2u64, 4, 10] {
        let repaid = shares / U256::from(den);
        if !repaid.is_zero() {
            let approx = estimate.as_ref().map(|e| {
                let assets = e.debt / den as f64;
                (assets * e.incentive / e.price, assets)
            });
            candidates.push((LiquidationInput::Repay(repaid), approx));
        }
    }
    candidates
        .into_iter()
        .filter(|(_, approx)| match (&estimate, approx) {
            (Some(e), Some(amounts)) => !e.prunable(*amounts, pool, gas_cost),
            _ => true,
        })
        .filter_map(|(input, _)| evaluate(input))
        .fold(None, |best: Option<(LiquidationOutcome, f64)>, candidate| match best {
            Some(b) if b.1 >= candidate.1 => Some(b),
            _ => Some(candidate),
        })
}

/// Simulates one cell along path `path_index`.
pub fn simulate_path(config: &SimConfig, borrowers: &[Borrower], cell: Cell, path_index: u64) -> PathOutcome {
    let lltv = bps_to_f64(cell.lltv_bps);
    let liq_config = LiquidationConfig {
        lltv: U256::from(bps_to_wad(cell.lltv_bps)),
        max_bonus: U256::from(bps_to_wad(cell.bonus_cap_bps)),
        bonus_slope: U256::from(bps_to_wad(config.bonus_slope_bps)),
    };

    // Open the positions in order, exactly as `borrow` would mint shares.
    let mut market = MarketState::default();
    let mut positions: Vec<PositionState> = Vec::with_capacity(borrowers.len());
    let mut outcome = PathOutcome { min_price_ratio: 1.0, ..PathOutcome::default() };
    for b in borrowers {
        let collateral = to_units(b.collateral_value / config.initial_price);
        let debt = to_units(b.collateral_value * lltv * b.capacity_used);
        let shares = to_shares_up(debt, market.total_borrow_assets, market.total_borrow_shares).unwrap_or(U256::ZERO);
        market.total_borrow_assets += debt;
        market.total_borrow_shares += shares;
        positions.push(PositionState { collateral, borrow_shares: shares });
        outcome.initial_borrow += to_f64(debt);
        outcome.initial_collateral_value += b.collateral_value;
    }
    market.total_supply_assets = to_units(to_f64(market.total_borrow_assets) / config.initial_utilization);
    market.total_supply_shares = market.total_supply_assets * U256::from(1_000_000u64);

    let mut liq_price: Vec<f64> = positions.iter().map(|p| liquidation_price(p, &market, lltv)).collect();
    let mut order: Vec<usize> = (0..positions.len()).collect();
    let sort_order = |order: &mut Vec<usize>, liq_price: &[f64]| {
        order.sort_by(|&a, &b| liq_price[b].total_cmp(&liq_price[a]).then(a.cmp(&b)));
    };
    sort_order(&mut order, &liq_price);

    let mut path = PricePath::new(config, stream_seed(config.seed, path_index));
    let mut pool = Pool::new(config.initial_price, config.amm_loan_reserve, config.amm_fee);
    let mut unhealthy_since: Vec<Option<usize>> = vec![None; positions.len()];
    let mut flagged: Vec<usize> = Vec::new();
    let mut oracle = config.initial_price;

    for step in 1..=config.steps {
        pool.arbitrage(path.next_price(), config.arbitrage_speed);
        oracle = pool.price();
        outcome.min_price_ratio = outcome.min_price_ratio.min(oracle / config.initial_price);
        let price = to_oracle_price(oracle);

        // Detection: exact health for every position whose (approximate) liquidation price is within reach.
        let threshold = oracle * (1.0 - 1e-9);
        let mut now_unhealthy: Vec<(usize, U256)> = Vec::new();
        for &i in &order {
            if liq_price[i] < threshold {
                break;
            }
            if let Ok(health) = position_health(&positions[i], &market, price, liq_config.lltv)
                && health < WAD
            {
                now_unhealthy.push((i, health));
            }
        }
        for &i in &flagged {
            if !now_unhealthy.iter().any(|&(j, _)| j == i) {
                unhealthy_since[i] = None;
            }
        }
        flagged = now_unhealthy.iter().map(|&(i, _)| i).collect();
        for &(i, _) in &now_unhealthy {
            unhealthy_since[i].get_or_insert(step);
        }

        // Liquidation: most unhealthy first, once the latency has elapsed.
        now_unhealthy.sort_by(|a, b| a.1.cmp(&b.1).then(a.0.cmp(&b.0)));
        let mut changed = false;
        for (i, _) in now_unhealthy {
            let since = unhealthy_since[i].unwrap_or(step);
            if step - since < config.liquidator_latency_blocks {
                continue;
            }
            let Some((liq, profit)) =
                best_liquidation(&market, &positions[i], (price, oracle), &liq_config, &pool, config.gas_cost)
            else {
                outcome.unprofitable_skips += 1;
                continue;
            };
            if profit <= 0.0 {
                outcome.unprofitable_skips += 1;
                continue;
            }
            let proceeds = pool.sell(to_f64(liq.seized_assets));
            outcome.liquidator_profit += proceeds - to_f64(liq.repaid_assets) - config.gas_cost;
            outcome.realized_bad_debt += to_f64(liq.bad_debt_assets);
            outcome.liquidations += 1;
            if liq.position.collateral.is_zero() {
                outcome.closeouts += 1;
            }
            market = liq.market;
            positions[i] = liq.position;
            liq_price[i] = liquidation_price(&positions[i], &market, lltv);
            unhealthy_since[i] = None;
            changed = true;
        }
        if changed {
            sort_order(&mut order, &liq_price);
            flagged.retain(|&i| unhealthy_since[i].is_some());
        }
    }

    // Whatever is still under water at the end is bad debt nobody has realized yet.
    for p in &positions {
        if p.borrow_shares.is_zero() {
            continue;
        }
        let debt = debt_of(p, &market).map(to_f64).unwrap_or(0.0);
        let value = to_f64(p.collateral) * oracle;
        if debt > value {
            outcome.unrealized_bad_debt += debt - value;
        }
    }
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;

    fn quiet_config() -> SimConfig {
        let mut cfg = SimConfig::quick();
        cfg.annual_volatility = 0.0;
        cfg.jumps_per_day = 0.0;
        cfg
    }

    #[test]
    fn population_sums_to_target() {
        let cfg = SimConfig::quick();
        let pop = population(&cfg);
        let total: f64 = pop.iter().map(|b| b.collateral_value).sum();
        assert!((total - cfg.total_collateral_value).abs() < 1e-3);
        assert!(
            pop.iter().all(|b| b.capacity_used >= cfg.min_capacity_used && b.capacity_used < cfg.max_capacity_used)
        );
    }

    #[test]
    fn flat_market_has_no_liquidations() {
        let cfg = quiet_config();
        let pop = population(&cfg);
        let out = simulate_path(&cfg, &pop, Cell { lltv_bps: 8_600, bonus_cap_bps: 500 }, 0);
        assert_eq!(out.liquidations, 0);
        assert_eq!(out.bad_debt_ratio(), 0.0);
        assert!((out.min_price_ratio - 1.0).abs() < 1e-9, "exp(ln(p)) round trip: {}", out.min_price_ratio);
    }

    #[test]
    fn crash_triggers_liquidations_and_is_deterministic() {
        let mut cfg = quiet_config();
        cfg.jumps_per_day = 40.0;
        cfg.jump_log_mean = -0.05;
        cfg.jump_log_std = 0.0;
        let pop = population(&cfg);
        let cell = Cell { lltv_bps: 9_150, bonus_cap_bps: 500 };
        let a = simulate_path(&cfg, &pop, cell, 1);
        let b = simulate_path(&cfg, &pop, cell, 1);
        assert_eq!(a, b);
        assert!(a.liquidations > 0);
        assert!(a.min_price_ratio < 0.9);
    }

    /// The unpruned search: every candidate is priced exactly.
    fn best_liquidation_exact(
        market: &MarketState,
        position: &PositionState,
        price: U256,
        config: &LiquidationConfig,
        pool: &Pool,
        gas_cost: f64,
    ) -> Option<(LiquidationOutcome, f64)> {
        let evaluate = |input: LiquidationInput| {
            liquidate(market, position, price, config, input).ok().map(|outcome| {
                let profit = pool.quote_sell(to_f64(outcome.seized_assets)) - to_f64(outcome.repaid_assets) - gas_cost;
                (outcome, profit)
            })
        };
        let partials = [2u64, 4, 10].into_iter().filter_map(|den| {
            let repaid = position.borrow_shares / U256::from(den);
            if repaid.is_zero() { None } else { evaluate(LiquidationInput::Repay(repaid)) }
        });
        evaluate(LiquidationInput::close()).into_iter().chain(partials).fold(None, |best, candidate| match best {
            Some(b) if b.1 >= candidate.1 => Some(b),
            _ => Some(candidate),
        })
    }

    proptest::proptest! {
        #![proptest_config(proptest::prelude::ProptestConfig { cases: 3_000, ..Default::default() })]

        /// Pruning never changes what a liquidator does: whenever the exact search finds a profitable liquidation,
        /// the pruned search returns the same one, and it never finds a profitable one the exact search does not.
        /// Health factors are drawn across every regime, with extra weight on "collateral value = debt".
        #[test]
        fn pruning_never_changes_the_chosen_liquidation(
            collateral_units in 1u64..2_000_000,
            ltv_ppm in 300_000u64..1_300_000,
            near_boundary in proptest::prelude::any::<bool>(),
            boundary_ppb in 0u64..2_000,
            oracle_cents in 1_000u64..400_000,
            lltv_index in 0usize..5,
            cap_index in 0usize..6,
            pool_millions in 1u64..40,
            extra_shares in 0u64..1_000_000,
        ) {
            let lltvs = [6_250u64, 7_700, 8_600, 9_150, 9_450];
            let caps = [50u64, 100, 200, 500, 1_000, 1_500];
            let oracle = oracle_cents as f64 / 100.0;
            let config = LiquidationConfig {
                lltv: U256::from(bps_to_wad(lltvs[lltv_index])),
                max_bonus: U256::from(bps_to_wad(caps[cap_index])),
                bonus_slope: U256::from(bps_to_wad(20_000)),
            };
            let collateral = to_units(collateral_units as f64);
            // Debt as a share of the collateral's value: anywhere from 0.3x to 1.3x, or within 2 ppm of 1x.
            let ratio = if near_boundary { 1.0 + (boundary_ppb as f64 - 1_000.0) * 1e-9 } else { ltv_ppm as f64 / 1e6 };
            let debt = to_units(collateral_units as f64 * oracle * ratio);
            let market = MarketState {
                total_supply_assets: debt * U256::from(3u8),
                total_supply_shares: debt * U256::from(3_000_000u64),
                total_borrow_assets: debt,
                total_borrow_shares: debt * U256::from(900_000u64) + U256::from(extra_shares),
            };
            let position = PositionState { collateral, borrow_shares: market.total_borrow_shares };
            let pool = Pool::new(oracle, pool_millions as f64 * 1e6, 0.003);
            let price = to_oracle_price(oracle);
            let exact = best_liquidation_exact(&market, &position, price, &config, &pool, 25.0);
            let fast = best_liquidation(&market, &position, (price, oracle), &config, &pool, 25.0);
            match exact {
                Some((outcome, profit)) if profit > 0.0 => {
                    proptest::prop_assert_eq!(fast, Some((outcome, profit)));
                }
                _ => proptest::prop_assert!(fast.is_none_or(|(_, p)| p <= 0.0), "pruned search found {fast:?}"),
            }
        }
    }

    #[test]
    fn to_units_roundtrip() {
        assert_eq!(to_units(1.5), U256::from(1_500_000_000_000_000_000u128));
        assert!((to_f64(to_units(1234.5)) - 1234.5).abs() < 1e-9);
        assert_eq!(to_oracle_price(1.0), risk_math::ORACLE_PRICE_SCALE);
    }
}
