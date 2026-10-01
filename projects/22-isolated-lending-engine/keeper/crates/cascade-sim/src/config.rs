// SPDX-License-Identifier: MIT
//! Simulation parameters.

use serde::Serialize;

/// Every parameter of a sweep. The defaults are a stress calibration, not a forecast.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct SimConfig {
    /// Base RNG seed. Path `i` uses `stream_seed(seed, i)` in every cell (common random numbers).
    pub seed: u64,
    /// Monte Carlo paths per grid cell.
    pub paths: usize,
    /// Blocks simulated per path.
    pub steps: usize,
    /// Seconds per block.
    pub block_seconds: f64,
    /// Borrowers in the market.
    pub borrowers: usize,
    /// Starting collateral price, in loan-token units (both tokens use 18 decimals).
    pub initial_price: f64,
    /// Annualized volatility of the diffusion.
    pub annual_volatility: f64,
    /// Expected jumps per day.
    pub jumps_per_day: f64,
    /// Mean of the log jump size.
    pub jump_log_mean: f64,
    /// Standard deviation of the log jump size.
    pub jump_log_std: f64,
    /// Total collateral posted, in loan-token units at the starting price.
    pub total_collateral_value: f64,
    /// Log-space standard deviation of position sizes (log-normal).
    pub position_size_sigma: f64,
    /// Lower bound of the share of its borrowing capacity each borrower uses.
    pub min_capacity_used: f64,
    /// Upper bound of the share of its borrowing capacity each borrower uses.
    pub max_capacity_used: f64,
    /// Market utilization at the start (total borrow / total supply).
    pub initial_utilization: f64,
    /// Loan-token reserve of the constant-product pool liquidators sell into.
    pub amm_loan_reserve: f64,
    /// Swap fee of the pool.
    pub amm_fee: f64,
    /// Share of the gap between the pool price and the external price closed by arbitrage each block.
    pub arbitrage_speed: f64,
    /// Blocks between a position becoming liquidatable and the first liquidator acting on it.
    pub liquidator_latency_blocks: usize,
    /// Gas cost of one liquidation, in loan-token units.
    pub gas_cost: f64,
    /// Slope of the reverse-Dutch schedule for every cell, in basis points (20_000 = 2 bonus points per point of
    /// health deficit).
    pub bonus_slope_bps: u64,
    /// LLTV axis of the grid, in basis points.
    pub lltvs_bps: Vec<u64>,
    /// Bonus-cap axis of the grid, in basis points.
    pub bonus_caps_bps: Vec<u64>,
    /// Maximum acceptable p99 of bad debt, as a fraction of initial borrows, for a recommendation.
    pub risk_budget_p99: f64,
    /// Bootstrap resamples (of each cell's paths) behind the 95 % interval reported for p99 bad debt.
    pub bootstrap_resamples: usize,
    /// Extra seeds on which the whole sweep is re-run to check that the recommendation is stable (full sweep only).
    pub stability_seeds: Vec<u64>,
}

impl SimConfig {
    /// The full sweep behind `reports/risk-grid.csv` and `reports/RISK.md`.
    pub fn full() -> Self {
        Self {
            seed: 0x22_1e_4d_1a_c0_de,
            paths: 400,
            steps: 7_200, // one day of 12-second blocks
            block_seconds: 12.0,
            borrowers: 160,
            initial_price: 2_000.0,
            annual_volatility: 0.9,
            jumps_per_day: 2.0,
            jump_log_mean: -0.045,
            jump_log_std: 0.035,
            total_collateral_value: 40_000_000.0,
            position_size_sigma: 1.3,
            min_capacity_used: 0.55,
            max_capacity_used: 0.98,
            initial_utilization: 0.9,
            amm_loan_reserve: 15_000_000.0,
            amm_fee: 0.003,
            arbitrage_speed: 0.2,
            liquidator_latency_blocks: 2,
            gas_cost: 25.0,
            bonus_slope_bps: 20_000,
            lltvs_bps: vec![6_250, 7_700, 8_600, 9_150, 9_450],
            bonus_caps_bps: vec![50, 100, 200, 500, 1_000, 1_500],
            risk_budget_p99: 0.005,
            bootstrap_resamples: 1_000,
            stability_seeds: vec![0x5eed_0001, 0x5eed_0002, 0x5eed_0003, 0x5eed_0004],
        }
    }

    /// A reduced sweep over the same grid, used by `--quick` and its golden file (no seed-stability re-runs).
    pub fn quick() -> Self {
        Self {
            paths: 24,
            steps: 1_800,
            borrowers: 40,
            bootstrap_resamples: 200,
            stability_seeds: Vec::new(),
            ..Self::full()
        }
    }

    /// The same sweep with another base seed.
    pub fn with_seed(&self, seed: u64) -> Self {
        Self { seed, ..self.clone() }
    }

    /// Whether the engine's `enableLltv` accepts this (LLTV, bonus cap) pair, evaluated with the contract's own
    /// integer check: `0 < lltv < 1`, `0 < cap <= 0.25` and `floor(lltv * (1 + cap)) < 1` in WAD.
    pub fn is_valid_cell(lltv_bps: u64, bonus_cap_bps: u64) -> bool {
        let lltv = bps_to_wad(lltv_bps);
        let cap = bps_to_wad(bonus_cap_bps);
        lltv > 0 && lltv < WAD && cap > 0 && cap <= WAD / 4 && lltv * (WAD + cap) / WAD < WAD
    }
}

/// 1.0 in WAD.
pub const WAD: u128 = 1_000_000_000_000_000_000;

/// Basis points to WAD, exactly.
pub const fn bps_to_wad(bps: u64) -> u128 {
    bps as u128 * 100_000_000_000_000
}

/// Basis points to a float fraction (for the stochastic parts of the model only).
pub fn bps_to_f64(bps: u64) -> f64 {
    bps as f64 / 10_000.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validity_mirrors_enable_lltv() {
        assert!(SimConfig::is_valid_cell(8_600, 1_500));
        assert!(SimConfig::is_valid_cell(9_450, 50));
        assert!(SimConfig::is_valid_cell(9_450, 500));
        assert!(!SimConfig::is_valid_cell(9_450, 1_000));
        assert!(!SimConfig::is_valid_cell(9_150, 1_000));
        assert!(!SimConfig::is_valid_cell(10_000, 100));
        assert!(!SimConfig::is_valid_cell(5_000, 2_600));
        assert_eq!(bps_to_wad(8_600), 860_000_000_000_000_000);
    }
}
