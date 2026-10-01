// SPDX-License-Identifier: MIT
//! External (fair) price paths: geometric Brownian motion plus Merton log-normal jumps.
//!
//! Per block of length `dt` (in years): `ln S' = ln S - sigma^2 / 2 * dt + sigma * sqrt(dt) * Z + sum(J_k)`, with
//! `N ~ Poisson(lambda * dt)` jumps of size `J_k ~ N(mu_J, sigma_J^2)`. The jumps are deliberately *not*
//! drift-compensated: this is a stress calibration in which crashes are not paid back by a higher drift.

use crate::config::SimConfig;
use crate::rng::Rng;

const SECONDS_PER_YEAR: f64 = 365.0 * 24.0 * 3_600.0;

/// A seeded, lazily generated price path.
#[derive(Debug, Clone)]
pub struct PricePath {
    rng: Rng,
    log_price: f64,
    drift: f64,
    diffusion: f64,
    jump_rate: f64,
    jump_mean: f64,
    jump_std: f64,
}

impl PricePath {
    /// Creates the path for `seed` under `config`.
    pub fn new(config: &SimConfig, seed: u64) -> Self {
        let dt = config.block_seconds / SECONDS_PER_YEAR;
        let sigma = config.annual_volatility;
        Self {
            rng: Rng::new(seed),
            log_price: libm::log(config.initial_price),
            drift: -0.5 * sigma * sigma * dt,
            diffusion: sigma * libm::sqrt(dt),
            jump_rate: config.jumps_per_day * config.block_seconds / 86_400.0,
            jump_mean: config.jump_log_mean,
            jump_std: config.jump_log_std,
        }
    }

    /// Advances one block and returns the new price.
    pub fn next_price(&mut self) -> f64 {
        let mut step = self.drift + self.diffusion * self.rng.normal();
        let jumps = self.rng.poisson(self.jump_rate);
        for _ in 0..jumps {
            step += self.jump_mean + self.jump_std * self.rng.normal();
        }
        self.log_price += step;
        libm::exp(self.log_price)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_seed_same_path() {
        let cfg = SimConfig::quick();
        let mut a = PricePath::new(&cfg, 9);
        let mut b = PricePath::new(&cfg, 9);
        for _ in 0..1_000 {
            assert_eq!(a.next_price().to_bits(), b.next_price().to_bits());
        }
    }

    #[test]
    fn volatility_is_calibrated_without_jumps() {
        let mut cfg = SimConfig::quick();
        cfg.jumps_per_day = 0.0;
        let mut path = PricePath::new(&cfg, 3);
        let n = 200_000;
        let mut prev = cfg.initial_price;
        let mut sum_sq = 0.0;
        for _ in 0..n {
            let p = path.next_price();
            let r = libm::log(p / prev);
            sum_sq += r * r;
            prev = p;
        }
        let realized = libm::sqrt(sum_sq / n as f64 * SECONDS_PER_YEAR / cfg.block_seconds);
        assert!((realized - cfg.annual_volatility).abs() < 0.01, "realized vol {realized}");
    }

    #[test]
    fn jumps_push_prices_down_on_average() {
        let mut cfg = SimConfig::quick();
        cfg.annual_volatility = 0.0;
        cfg.jumps_per_day = 50.0;
        let mut path = PricePath::new(&cfg, 5);
        let mut p = cfg.initial_price;
        for _ in 0..7_200 {
            p = path.next_price();
        }
        assert!(p < cfg.initial_price);
    }
}
