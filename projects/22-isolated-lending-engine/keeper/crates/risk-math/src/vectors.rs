// SPDX-License-Identifier: MIT
//! Shared liquidation test vectors.
//!
//! `cascade-sim export-vectors` writes a [`VectorFile`] to `test/vectors/liquidation-vectors.json`; the Foundry test
//! `HealthVectors.t.sol` replays every vector against a freshly deployed engine and requires the exact same
//! outcome, and `risk-math`'s own test suite recomputes every expectation. Numbers are encoded as decimal strings
//! so no JSON parser rounds them through a double.

use alloy_primitives::U256;
use serde::{Deserialize, Serialize};

use crate::liquidation::{
    LiquidationConfig, LiquidationError, LiquidationInput, MarketState, PositionState, liquidate,
};

/// Schema identifier written into every vector file.
pub const SCHEMA: &str = "isolated-lending/liquidation-vectors/v1";

/// A file of vectors.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VectorFile {
    /// Always [`SCHEMA`].
    pub schema: String,
    /// The command that produced the file.
    pub generator: String,
    /// RNG seed of the generator.
    pub seed: u64,
    /// Number of vectors (`vectors.len()`).
    pub count: usize,
    /// The vectors.
    pub vectors: Vec<Vector>,
}

/// One liquidation scenario: pre-state, call arguments and the engine's expected response.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Vector {
    /// Human-readable category and index.
    pub name: String,
    /// LLTV (WAD).
    #[serde(with = "dec")]
    pub lltv: U256,
    /// Bonus cap (WAD).
    #[serde(with = "dec")]
    pub max_bonus: U256,
    /// Bonus slope (WAD).
    #[serde(with = "dec")]
    pub bonus_slope: U256,
    /// Oracle price (1e36 scale).
    #[serde(with = "dec")]
    pub price: U256,
    /// Market `totalSupplyAssets`.
    #[serde(with = "dec")]
    pub total_supply_assets: U256,
    /// Market `totalSupplyShares`.
    #[serde(with = "dec")]
    pub total_supply_shares: U256,
    /// Market `totalBorrowAssets`.
    #[serde(with = "dec")]
    pub total_borrow_assets: U256,
    /// Market `totalBorrowShares`.
    #[serde(with = "dec")]
    pub total_borrow_shares: U256,
    /// Borrower collateral.
    #[serde(with = "dec")]
    pub collateral: U256,
    /// Borrower debt shares.
    #[serde(with = "dec")]
    pub borrow_shares: U256,
    /// `seizedAssets` argument.
    #[serde(with = "dec")]
    pub seized_assets: U256,
    /// `repaidShares` argument.
    #[serde(with = "dec")]
    pub repaid_shares: U256,
    /// What the engine must do.
    pub expected: Expected,
}

/// Expected engine response. Numeric fields of a reverting vector are zero except `errorArgs`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Expected {
    /// `ok` or the custom error name.
    pub outcome: String,
    /// Arguments of the custom error (unused slots are zero).
    #[serde(with = "dec_pair")]
    pub error_args: [U256; 2],
    /// Health factor before (also emitted in `Liquidate`).
    #[serde(with = "dec")]
    pub health_before: U256,
    /// Bonus applied.
    #[serde(with = "dec")]
    pub bonus: U256,
    /// Collateral seized.
    #[serde(with = "dec")]
    pub seized_assets: U256,
    /// Debt shares repaid.
    #[serde(with = "dec")]
    pub repaid_shares: U256,
    /// Loan tokens paid.
    #[serde(with = "dec")]
    pub repaid_assets: U256,
    /// Debt written off.
    #[serde(with = "dec")]
    pub bad_debt_assets: U256,
    /// Debt shares written off.
    #[serde(with = "dec")]
    pub bad_debt_shares: U256,
    /// Health factor after (`2^256 - 1` without debt).
    #[serde(with = "dec")]
    pub health_after: U256,
    /// Borrower collateral after.
    #[serde(with = "dec")]
    pub collateral_after: U256,
    /// Borrower debt shares after.
    #[serde(with = "dec")]
    pub borrow_shares_after: U256,
    /// Market `totalSupplyAssets` after.
    #[serde(with = "dec")]
    pub total_supply_assets_after: U256,
    /// Market `totalBorrowAssets` after.
    #[serde(with = "dec")]
    pub total_borrow_assets_after: U256,
    /// Market `totalBorrowShares` after.
    #[serde(with = "dec")]
    pub total_borrow_shares_after: U256,
}

impl Vector {
    /// Pre-state as `risk-math` types.
    pub fn state(&self) -> (MarketState, PositionState, LiquidationConfig) {
        (
            MarketState {
                total_supply_assets: self.total_supply_assets,
                total_supply_shares: self.total_supply_shares,
                total_borrow_assets: self.total_borrow_assets,
                total_borrow_shares: self.total_borrow_shares,
            },
            PositionState { collateral: self.collateral, borrow_shares: self.borrow_shares },
            LiquidationConfig { lltv: self.lltv, max_bonus: self.max_bonus, bonus_slope: self.bonus_slope },
        )
    }

    /// The call input.
    pub fn input(&self) -> LiquidationInput {
        if self.seized_assets.is_zero() {
            LiquidationInput::Repay(self.repaid_shares)
        } else {
            LiquidationInput::Seize(self.seized_assets)
        }
    }

    /// Computes the expectation from the pre-state with `risk-math`.
    ///
    /// Returns `None` for inputs the vector format cannot express (arithmetic reverts or inconsistent inputs).
    pub fn compute_expected(&self) -> Option<Expected> {
        let (market, position, config) = self.state();
        let zero = U256::ZERO;
        let mut expected = Expected {
            outcome: String::new(),
            error_args: [zero, zero],
            health_before: zero,
            bonus: zero,
            seized_assets: zero,
            repaid_shares: zero,
            repaid_assets: zero,
            bad_debt_assets: zero,
            bad_debt_shares: zero,
            health_after: zero,
            collateral_after: zero,
            borrow_shares_after: zero,
            total_supply_assets_after: zero,
            total_borrow_assets_after: zero,
            total_borrow_shares_after: zero,
        };
        match liquidate(&market, &position, self.price, &config, self.input()) {
            Ok(o) => {
                expected.outcome = "ok".into();
                expected.health_before = o.health_before;
                expected.bonus = o.bonus;
                expected.seized_assets = o.seized_assets;
                expected.repaid_shares = o.repaid_shares;
                expected.repaid_assets = o.repaid_assets;
                expected.bad_debt_assets = o.bad_debt_assets;
                expected.bad_debt_shares = o.bad_debt_shares;
                expected.health_after = o.health_after;
                expected.collateral_after = o.position.collateral;
                expected.borrow_shares_after = o.position.borrow_shares;
                expected.total_supply_assets_after = o.market.total_supply_assets;
                expected.total_borrow_assets_after = o.market.total_borrow_assets;
                expected.total_borrow_shares_after = o.market.total_borrow_shares;
            }
            Err(LiquidationError::HealthyPosition { health }) => {
                expected.outcome = "HealthyPosition".into();
                expected.error_args = [health, zero];
            }
            Err(LiquidationError::HealthDecreased { before, after }) => {
                expected.outcome = "HealthDecreased".into();
                expected.error_args = [before, after];
            }
            Err(LiquidationError::RepayExceedsDebt { repaid_shares, borrow_shares }) => {
                expected.outcome = "RepayExceedsDebt".into();
                expected.error_args = [repaid_shares, borrow_shares];
            }
            Err(LiquidationError::SeizeExceedsCollateral { seized_assets, collateral }) => {
                expected.outcome = "SeizeExceedsCollateral".into();
                expected.error_args = [seized_assets, collateral];
            }
            Err(LiquidationError::InconsistentInput | LiquidationError::ZeroPrice | LiquidationError::Math(_)) => {
                return None;
            }
        }
        Some(expected)
    }
}

/// Serde adapter: `U256` as a decimal string.
pub mod dec {
    use alloy_primitives::U256;
    use serde::{Deserialize, Deserializer, Serializer, de::Error};

    /// Serializes as a decimal string.
    pub fn serialize<S: Serializer>(value: &U256, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&value.to_string())
    }

    /// Parses a decimal string.
    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<U256, D::Error> {
        let s = String::deserialize(deserializer)?;
        U256::from_str_radix(&s, 10).map_err(D::Error::custom)
    }
}

/// Serde adapter: `[U256; 2]` as two decimal strings.
pub mod dec_pair {
    use alloy_primitives::U256;
    use serde::{Deserialize, Deserializer, Serializer, de::Error, ser::SerializeSeq};

    /// Serializes as an array of two decimal strings.
    pub fn serialize<S: Serializer>(value: &[U256; 2], serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(Some(2))?;
        for v in value {
            seq.serialize_element(&v.to_string())?;
        }
        seq.end()
    }

    /// Parses an array of two decimal strings.
    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<[U256; 2], D::Error> {
        let raw = <[String; 2]>::deserialize(deserializer)?;
        Ok([
            U256::from_str_radix(&raw[0], 10).map_err(D::Error::custom)?,
            U256::from_str_radix(&raw[1], 10).map_err(D::Error::custom)?,
        ])
    }
}
