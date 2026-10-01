// SPDX-License-Identifier: MIT
//! Parity with the shared vector file that Foundry replays against the Solidity engine.
//!
//! `test/vectors/HealthVectors.t.sol` proves the engine reproduces every expectation in the file; this test proves
//! the current `risk-math` still computes the same expectations. Together they pin Rust and Solidity to each other.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::collections::BTreeMap;

use risk_math::U256;
use risk_math::vectors::{SCHEMA, VectorFile};

const VECTORS: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../test/vectors/liquidation-vectors.json");

fn load() -> VectorFile {
    let raw = std::fs::read_to_string(VECTORS).expect("vector file present (run `cascade-sim export-vectors`)");
    serde_json::from_str(&raw).expect("valid vector file")
}

#[test]
fn file_is_well_formed() {
    let file = load();
    assert_eq!(file.schema, SCHEMA);
    assert_eq!(file.count, 100);
    assert_eq!(file.vectors.len(), 100);
}

#[test]
fn every_expectation_is_recomputed_exactly() {
    for v in load().vectors {
        let recomputed = v.compute_expected().unwrap_or_else(|| panic!("{}: not expressible", v.name));
        assert_eq!(recomputed, v.expected, "{}", v.name);
    }
}

#[test]
fn file_covers_every_branch_of_liquidate() {
    let mut outcomes: BTreeMap<String, usize> = BTreeMap::new();
    let (mut bad_debt, mut equity_capped, mut by_repay, mut max_requests) = (0, 0, 0, 0);
    for v in load().vectors {
        *outcomes.entry(v.expected.outcome.clone()).or_default() += 1;
        if !v.expected.bad_debt_assets.is_zero() {
            bad_debt += 1;
        }
        if v.expected.outcome == "ok" && v.expected.collateral_after.is_zero() && v.expected.bad_debt_assets.is_zero() {
            equity_capped += 1;
        }
        if v.seized_assets.is_zero() {
            by_repay += 1;
        }
        if v.seized_assets == U256::MAX || v.repaid_shares == U256::MAX {
            max_requests += 1;
        }
    }
    for outcome in ["ok", "HealthyPosition", "HealthDecreased", "RepayExceedsDebt", "SeizeExceedsCollateral"] {
        assert!(outcomes.get(outcome).copied().unwrap_or(0) > 0, "no {outcome} vector: {outcomes:?}");
    }
    assert!(bad_debt >= 10, "only {bad_debt} under-water closeouts");
    assert!(equity_capped >= 5, "only {equity_capped} closeouts with the bonus capped at the borrower's equity");
    assert!(by_repay >= 20, "only {by_repay} repay-denominated vectors");
    assert!(max_requests >= 1, "no type(uint256).max close request");
}
