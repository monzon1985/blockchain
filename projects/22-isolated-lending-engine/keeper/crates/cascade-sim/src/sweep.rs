// SPDX-License-Identifier: MIT
//! Grid sweep over LLTV x bonus cap and per-cell statistics.

use rayon::prelude::*;

use crate::config::SimConfig;
use crate::rng::{Rng, stream_seed};
use crate::sim::{Cell, PathOutcome, population, simulate_path};

/// Stream tag of the bootstrap RNG (kept apart from the path streams).
const BOOTSTRAP_STREAM: u64 = 0xb007_57a9;

/// Aggregated results of one grid cell.
#[derive(Debug, Clone, PartialEq)]
pub struct CellStats {
    /// The cell.
    pub cell: Cell,
    /// Whether the engine accepts this configuration (`lltv * (1 + cap) < 1`); invalid cells are not simulated.
    pub valid: bool,
    /// Paths simulated.
    pub paths: usize,
    /// Initial borrows over initial collateral value (capital efficiency).
    pub initial_ltv: f64,
    /// Mean bad debt / initial borrows.
    pub mean_bad_debt: f64,
    /// 95th percentile (nearest rank) of bad debt / initial borrows.
    pub p95_bad_debt: f64,
    /// 99th percentile (nearest rank) of bad debt / initial borrows.
    pub p99_bad_debt: f64,
    /// Lower end of the bootstrap 95 % interval of `p99_bad_debt` (percentile method over the cell's paths).
    pub p99_ci_low: f64,
    /// Upper end of the bootstrap 95 % interval of `p99_bad_debt`.
    pub p99_ci_high: f64,
    /// Worst path.
    pub max_bad_debt: f64,
    /// Share of paths with any bad debt.
    pub prob_bad_debt: f64,
    /// Mean liquidations per path.
    pub mean_liquidations: f64,
    /// Mean closeouts per path.
    pub mean_closeouts: f64,
    /// Mean liquidator profit after gas per path.
    pub mean_liquidator_profit: f64,
    /// Mean count of (block, position) pairs left unliquidated because no liquidation paid for itself.
    pub mean_unprofitable_skips: f64,
    /// Mean of the per-path minimum price (relative to the start).
    pub mean_min_price: f64,
}

/// Nearest-rank percentile of a sorted slice.
pub fn percentile(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let rank = libm::ceil(q * sorted.len() as f64) as usize;
    sorted[rank.clamp(1, sorted.len()) - 1]
}

/// Percentile-bootstrap 95 % interval of the nearest-rank p99 of `ratios`: resample the paths with replacement
/// `resamples` times, take each resample's p99, and report the 2.5th and 97.5th percentiles of those.
pub fn bootstrap_p99_interval(ratios: &[f64], resamples: usize, rng: &mut Rng) -> (f64, f64) {
    if ratios.is_empty() || resamples == 0 {
        return (0.0, 0.0);
    }
    let n = ratios.len() as u64;
    let mut sample = vec![0.0; ratios.len()];
    let mut p99s: Vec<f64> = (0..resamples)
        .map(|_| {
            for x in &mut sample {
                *x = ratios[rng.below(n) as usize];
            }
            sample.sort_by(f64::total_cmp);
            percentile(&sample, 0.99)
        })
        .collect();
    p99s.sort_by(f64::total_cmp);
    (percentile(&p99s, 0.025), percentile(&p99s, 0.975))
}

fn aggregate(config: &SimConfig, cell_index: usize, cell: Cell, outcomes: &[PathOutcome]) -> CellStats {
    let n = outcomes.len() as f64;
    let mut ratios: Vec<f64> = outcomes.iter().map(PathOutcome::bad_debt_ratio).collect();
    ratios.sort_by(f64::total_cmp);
    let mean = |f: fn(&PathOutcome) -> f64| outcomes.iter().map(f).sum::<f64>() / n;
    let mut rng = Rng::new(stream_seed(config.seed ^ BOOTSTRAP_STREAM, cell_index as u64));
    let (p99_ci_low, p99_ci_high) = bootstrap_p99_interval(&ratios, config.bootstrap_resamples, &mut rng);
    CellStats {
        cell,
        valid: true,
        paths: outcomes.len(),
        initial_ltv: outcomes.first().map_or(0.0, |o| o.initial_borrow / o.initial_collateral_value),
        mean_bad_debt: ratios.iter().sum::<f64>() / n,
        p95_bad_debt: percentile(&ratios, 0.95),
        p99_bad_debt: percentile(&ratios, 0.99),
        p99_ci_low,
        p99_ci_high,
        max_bad_debt: ratios.last().copied().unwrap_or(0.0),
        prob_bad_debt: ratios.iter().filter(|&&r| r > 0.0).count() as f64 / n,
        mean_liquidations: mean(|o| f64::from(o.liquidations)),
        mean_closeouts: mean(|o| f64::from(o.closeouts)),
        mean_liquidator_profit: mean(|o| o.liquidator_profit),
        mean_unprofitable_skips: mean(|o| f64::from(o.unprofitable_skips)),
        mean_min_price: mean(|o| o.min_price_ratio),
    }
}

/// Runs the sweep. Results do not depend on the thread count: paths are collected in order and aggregated
/// sequentially.
pub fn run(config: &SimConfig) -> Vec<CellStats> {
    let borrowers = population(config);
    let cells: Vec<(Cell, bool)> = config
        .lltvs_bps
        .iter()
        .flat_map(|&lltv_bps| {
            config.bonus_caps_bps.iter().map(move |&bonus_cap_bps| {
                (Cell { lltv_bps, bonus_cap_bps }, SimConfig::is_valid_cell(lltv_bps, bonus_cap_bps))
            })
        })
        .collect();

    let jobs: Vec<(usize, u64)> = cells
        .iter()
        .enumerate()
        .filter(|(_, (_, valid))| *valid)
        .flat_map(|(c, _)| (0..config.paths as u64).map(move |p| (c, p)))
        .collect();
    let outcomes: Vec<PathOutcome> =
        jobs.par_iter().map(|&(c, p)| simulate_path(config, &borrowers, cells[c].0, p)).collect();

    let mut stats = Vec::with_capacity(cells.len());
    let mut cursor = 0;
    for (index, (cell, valid)) in cells.into_iter().enumerate() {
        if valid {
            stats.push(aggregate(config, index, cell, &outcomes[cursor..cursor + config.paths]));
            cursor += config.paths;
        } else {
            stats.push(CellStats {
                cell,
                valid: false,
                paths: 0,
                initial_ltv: 0.0,
                mean_bad_debt: 0.0,
                p95_bad_debt: 0.0,
                p99_bad_debt: 0.0,
                p99_ci_low: 0.0,
                p99_ci_high: 0.0,
                max_bad_debt: 0.0,
                prob_bad_debt: 0.0,
                mean_liquidations: 0.0,
                mean_closeouts: 0.0,
                mean_liquidator_profit: 0.0,
                mean_unprofitable_skips: 0.0,
                mean_min_price: 0.0,
            });
        }
    }
    stats
}

/// The recommended cell: the highest LLTV (then the lowest cap) among valid cells whose p99 bad debt fits the
/// risk budget, and for each LLTV the cap that minimizes p99 bad debt (then mean bad debt, then the cap itself).
pub fn recommend(config: &SimConfig, stats: &[CellStats]) -> (Option<Cell>, Vec<Cell>) {
    let mut best_per_lltv = Vec::new();
    for &lltv in &config.lltvs_bps {
        let best = stats.iter().filter(|s| s.valid && s.cell.lltv_bps == lltv).min_by(|a, b| {
            a.p99_bad_debt
                .total_cmp(&b.p99_bad_debt)
                .then(a.mean_bad_debt.total_cmp(&b.mean_bad_debt))
                .then(a.cell.bonus_cap_bps.cmp(&b.cell.bonus_cap_bps))
        });
        if let Some(b) = best {
            best_per_lltv.push(b.cell);
        }
    }
    let overall = best_per_lltv
        .iter()
        .filter(|cell| stats.iter().any(|s| s.cell == **cell && s.p99_bad_debt <= config.risk_budget_p99))
        .max_by_key(|cell| cell.lltv_bps)
        .copied();
    (overall, best_per_lltv)
}

/// The recommendation of a sweep re-run on another seed.
#[derive(Debug, Clone, PartialEq)]
pub struct SeedCheck {
    /// The seed.
    pub seed: u64,
    /// The cell recommended on that seed.
    pub recommended: Option<Cell>,
    /// p99 bad debt, on that seed, of the cell the main seed recommends.
    pub p99_of_main_choice: Option<f64>,
}

/// Re-runs the sweep on `config.stability_seeds` and reports each seed's recommendation.
pub fn stability(config: &SimConfig, main_choice: Option<Cell>) -> Vec<SeedCheck> {
    config
        .stability_seeds
        .iter()
        .map(|&seed| {
            let reseeded = config.with_seed(seed);
            let stats = run(&reseeded);
            let (recommended, _) = recommend(&reseeded, &stats);
            let p99_of_main_choice =
                main_choice.and_then(|cell| stats.iter().find(|s| s.cell == cell)).map(|s| s.p99_bad_debt);
            SeedCheck { seed, recommended, p99_of_main_choice }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bootstrap_interval_brackets_the_estimate() {
        let ratios: Vec<f64> = (0..400).map(|i| if i < 392 { 0.0 } else { f64::from(i - 391) / 100.0 }).collect();
        let point = percentile(&ratios, 0.99);
        let (lo, hi) = bootstrap_p99_interval(&ratios, 500, &mut Rng::new(7));
        assert!(lo <= point && point <= hi, "{lo} <= {point} <= {hi}");
        assert!(lo < hi, "eight non-zero paths out of 400 leave the p99 uncertain");
        assert_eq!(bootstrap_p99_interval(&[0.0; 50], 100, &mut Rng::new(7)), (0.0, 0.0));
        assert_eq!(bootstrap_p99_interval(&ratios, 500, &mut Rng::new(7)), (lo, hi), "deterministic");
    }

    #[test]
    fn percentile_nearest_rank() {
        let v: Vec<f64> = (1..=100).map(f64::from).collect();
        assert_eq!(percentile(&v, 0.95), 95.0);
        assert_eq!(percentile(&v, 0.99), 99.0);
        assert_eq!(percentile(&v, 1.0), 100.0);
        assert_eq!(percentile(&[], 0.5), 0.0);
    }

    #[test]
    fn sweep_is_independent_of_thread_count() {
        let mut cfg = SimConfig::quick();
        cfg.paths = 4;
        cfg.steps = 300;
        cfg.lltvs_bps = vec![8_600, 9_450];
        cfg.bonus_caps_bps = vec![500, 1_000];
        let single = rayon::ThreadPoolBuilder::new().num_threads(1).build().map(|p| p.install(|| run(&cfg)));
        let multi = rayon::ThreadPoolBuilder::new().num_threads(3).build().map(|p| p.install(|| run(&cfg)));
        assert_eq!(single.ok(), multi.ok());
    }

    #[test]
    fn invalid_cells_are_reported_not_simulated() {
        let mut cfg = SimConfig::quick();
        cfg.paths = 2;
        cfg.steps = 50;
        cfg.lltvs_bps = vec![9_450];
        cfg.bonus_caps_bps = vec![500, 1_000];
        let stats = run(&cfg);
        assert!(stats[0].valid);
        assert!(!stats[1].valid);
        assert_eq!(stats[1].paths, 0);
    }
}
