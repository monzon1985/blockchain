// SPDX-License-Identifier: MIT
//! Agent-based liquidation-cascade simulator for the isolated lending engine.
//!
//! It sweeps a grid of LLTV x liquidation-bonus cap under a stress calibration (GBM with downward jumps,
//! a constant-product pool that liquidations sell into, arbitrage, liquidator latency and gas costs) and reports
//! the bad debt each configuration leaves behind. Liquidations are computed with `risk-math`, the Rust port of the
//! contract arithmetic that `test/vectors/HealthVectors.t.sol` checks bit for bit against the engine on 100 shared
//! vectors (the liquidation state transition; the simulator accrues no interest).

pub mod amm;
pub mod config;
pub mod paths;
pub mod report;
pub mod rng;
pub mod sim;
pub mod sweep;
pub mod vectors;
