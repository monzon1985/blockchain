// SPDX-License-Identifier: MIT
//! Intrinsic gas, fee math and pre-signing sanity checks (Osaka rules).
//!
//! Intrinsic gas follows the execution specs for Prague/Osaka:
//!
//! ```text
//! intrinsic = 21000
//!           + 4 * zero_bytes + 16 * nonzero_bytes            (calldata)
//!           + [create] 32000 + 2 * ceil(len(initcode) / 32)  (EIP-2 / EIP-3860)
//!           + 2400 * addresses + 1900 * storage_keys         (EIP-2930)
//!           + 25000 * authorizations                         (EIP-7702)
//! floor     = 21000 + 10 * (zero_bytes + 4 * nonzero_bytes)  (EIP-7623)
//! gas_limit >= max(intrinsic, floor)
//! gas_limit <= 2^24 on Osaka networks                         (EIP-7825)
//! ```

use crate::tx::{Transaction, TxKind, TxType};
use crate::u256::U256;
use alloc::string::String;
use alloc::vec::Vec;

/// Base cost of every transaction.
pub const TX_BASE_COST: u64 = 21_000;
/// Extra cost of a contract-creation transaction.
pub const TX_CREATE_COST: u64 = 32_000;
/// Calldata cost per zero byte.
pub const TX_DATA_ZERO_COST: u64 = 4;
/// Calldata cost per non-zero byte.
pub const TX_DATA_NONZERO_COST: u64 = 16;
/// EIP-2930 cost per access-list address.
pub const ACCESS_LIST_ADDRESS_COST: u64 = 2_400;
/// EIP-2930 cost per access-list storage key.
pub const ACCESS_LIST_STORAGE_KEY_COST: u64 = 1_900;
/// EIP-3860 cost per 32-byte word of initcode.
pub const INITCODE_WORD_COST: u64 = 2;
/// EIP-7702 intrinsic cost per authorization (`PER_EMPTY_ACCOUNT_COST`).
pub const PER_AUTHORIZATION_COST: u64 = 25_000;
/// EIP-7623 floor cost per calldata token.
pub const FLOOR_COST_PER_TOKEN: u64 = 10;
/// EIP-3860 maximum initcode size in bytes.
pub const MAX_INITCODE_SIZE: usize = 49_152;
/// EIP-7825 per-transaction gas-limit cap (Osaka).
pub const MAX_TX_GAS_LIMIT_OSAKA: u64 = 1 << 24;

/// Itemised intrinsic gas.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IntrinsicGas {
    /// 21000.
    pub base: u64,
    /// Calldata cost (4 / 16 per byte).
    pub calldata: u64,
    /// 32000 if the transaction creates a contract.
    pub create: u64,
    /// EIP-3860 initcode word cost.
    pub initcode: u64,
    /// EIP-2930 access-list cost.
    pub access_list: u64,
    /// EIP-7702 authorization cost.
    pub authorizations: u64,
    /// Sum of the above (the classic intrinsic gas).
    pub total: u64,
    /// EIP-7623 calldata floor.
    pub floor: u64,
    /// `max(total, floor)`: the smallest valid gas limit.
    pub minimum_gas_limit: u64,
}

/// Computes the intrinsic gas of `tx`. Saturating arithmetic: absurd inputs yield `u64::MAX`,
/// which then fails every gas-limit check rather than wrapping to a small number.
pub fn intrinsic_gas(tx: &Transaction) -> IntrinsicGas {
    let input = tx.input();
    // usize -> u64 is lossless on every supported target (usize <= 64 bits).
    let zeros = input.iter().filter(|b| **b == 0).count() as u64;
    let nonzeros = input.len() as u64 - zeros;
    let calldata = zeros
        .saturating_mul(TX_DATA_ZERO_COST)
        .saturating_add(nonzeros.saturating_mul(TX_DATA_NONZERO_COST));
    let tokens = zeros.saturating_add(nonzeros.saturating_mul(4));
    let (create, initcode) = match tx.kind() {
        TxKind::Create => (
            TX_CREATE_COST,
            (input.len() as u64)
                .div_ceil(32)
                .saturating_mul(INITCODE_WORD_COST),
        ),
        TxKind::Call(_) => (0, 0),
    };
    let (addresses, keys) = tx.access_list().iter().fold((0u64, 0u64), |(a, k), item| {
        (a + 1, k.saturating_add(item.storage_keys.len() as u64))
    });
    let access_list = addresses
        .saturating_mul(ACCESS_LIST_ADDRESS_COST)
        .saturating_add(keys.saturating_mul(ACCESS_LIST_STORAGE_KEY_COST));
    let authorizations =
        (tx.authorization_list().len() as u64).saturating_mul(PER_AUTHORIZATION_COST);
    let total = TX_BASE_COST
        .saturating_add(calldata)
        .saturating_add(create)
        .saturating_add(initcode)
        .saturating_add(access_list)
        .saturating_add(authorizations);
    let floor = TX_BASE_COST.saturating_add(tokens.saturating_mul(FLOOR_COST_PER_TOKEN));
    IntrinsicGas {
        base: TX_BASE_COST,
        calldata,
        create,
        initcode,
        access_list,
        authorizations,
        total,
        floor,
        minimum_gas_limit: total.max(floor),
    }
}

/// Worst-case and (optionally) base-fee-dependent cost figures.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FeeSummary {
    /// Fee cap per gas in wei.
    #[serde(with = "crate::quantity::u128_str")]
    pub max_fee_per_gas: u128,
    /// Tip cap per gas in wei (typed-fee transactions only).
    #[serde(with = "crate::quantity::opt_u128_str")]
    pub max_priority_fee_per_gas: Option<u128>,
    /// `gas_limit * max_fee_per_gas`.
    pub max_gas_cost: U256,
    /// `max_gas_cost + value`: the balance the sender must hold.
    pub max_total_cost: U256,
    /// Price actually paid per gas at `base_fee`, if a base fee was supplied.
    #[serde(with = "crate::quantity::opt_u128_str")]
    pub effective_gas_price: Option<u128>,
}

/// Fee math for `tx`, optionally at a given base fee per gas.
pub fn fee_summary(tx: &Transaction, base_fee: Option<u128>) -> FeeSummary {
    let max_fee = tx.max_fee_per_gas();
    let max_gas_cost = U256::from_u64(tx.gas_limit())
        .checked_mul(&U256::from_u128(max_fee))
        .unwrap_or(U256::MAX);
    let max_total_cost = max_gas_cost.checked_add(&tx.value()).unwrap_or(U256::MAX);
    let effective_gas_price = base_fee.map(|base| match tx.max_priority_fee_per_gas() {
        Some(tip) => max_fee.min(base.saturating_add(tip)),
        None => max_fee,
    });
    FeeSummary {
        max_fee_per_gas: max_fee,
        max_priority_fee_per_gas: tx.max_priority_fee_per_gas(),
        max_gas_cost,
        max_total_cost,
        effective_gas_price,
    }
}

/// Severity of a [`Finding`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    /// The transaction is invalid; Keysmith refuses to sign it.
    Error,
    /// Valid but risky; shown to the operator before signing.
    Warning,
}

/// A semantic problem found in a transaction before signing or while decoding.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Finding {
    /// Error or warning.
    pub severity: Severity,
    /// Stable machine-readable code.
    pub code: &'static str,
    /// Human-readable explanation.
    pub message: String,
}

fn finding(severity: Severity, code: &'static str, message: String) -> Finding {
    Finding {
        severity,
        code,
        message,
    }
}

/// Consensus-level validity checks and operator warnings.
pub fn check_transaction(tx: &Transaction) -> Vec<Finding> {
    use alloc::format;
    let mut out = Vec::new();
    let gas = intrinsic_gas(tx);
    if tx.gas_limit() < gas.minimum_gas_limit {
        out.push(finding(
            Severity::Error,
            "gas-below-intrinsic",
            format!(
                "gas limit {} is below the minimum {} (intrinsic {}, EIP-7623 floor {})",
                tx.gas_limit(),
                gas.minimum_gas_limit,
                gas.total,
                gas.floor
            ),
        ));
    }
    if tx.gas_limit() > MAX_TX_GAS_LIMIT_OSAKA {
        out.push(finding(
            Severity::Warning,
            "gas-above-osaka-cap",
            format!(
                "gas limit {} exceeds the EIP-7825 cap of {} (rejected on Osaka networks)",
                tx.gas_limit(),
                MAX_TX_GAS_LIMIT_OSAKA
            ),
        ));
    }
    if tx.nonce() == u64::MAX {
        out.push(finding(
            Severity::Error,
            "nonce-max",
            String::from("nonce 2^64-1 is invalid (EIP-2681)"),
        ));
    }
    if let Some(tip) = tx.max_priority_fee_per_gas()
        && tip > tx.max_fee_per_gas()
    {
        out.push(finding(
            Severity::Error,
            "tip-above-fee-cap",
            format!(
                "maxPriorityFeePerGas {tip} exceeds maxFeePerGas {}",
                tx.max_fee_per_gas()
            ),
        ));
    }
    if tx.kind() == TxKind::Create && tx.input().len() > MAX_INITCODE_SIZE {
        out.push(finding(
            Severity::Error,
            "initcode-too-large",
            format!(
                "initcode is {} bytes; EIP-3860 limit is {MAX_INITCODE_SIZE}",
                tx.input().len()
            ),
        ));
    }
    if tx.tx_type() == TxType::Eip7702 && tx.authorization_list().is_empty() {
        out.push(finding(
            Severity::Error,
            "empty-authorization-list",
            String::from("EIP-7702 transactions must carry at least one authorization"),
        ));
    }
    if tx.chain_id().is_none() {
        out.push(finding(
            Severity::Warning,
            "no-replay-protection",
            String::from("pre-EIP-155 legacy transaction: replayable on every chain"),
        ));
    }
    if tx.kind() == TxKind::Call(crate::address::Address::ZERO) {
        out.push(finding(
            Severity::Warning,
            "zero-address-recipient",
            String::from("recipient is the zero address; value sent there is burned"),
        ));
    }
    for (i, auth) in tx.authorization_list().iter().enumerate() {
        if auth.chain_id.is_zero() {
            out.push(finding(
                Severity::Warning,
                "authorization-any-chain",
                format!(
                    "authorization #{i} has chainId 0: the delegation to {} is valid on EVERY chain",
                    auth.address
                ),
            ));
        }
    }
    out
}

/// `true` if any finding is an error.
pub fn has_errors(findings: &[Finding]) -> bool {
    findings.iter().any(|f| f.severity == Severity::Error)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::address::Address;
    use crate::authorization::SignedAuthorization;
    use crate::tx::{AccessListItem, TxEip1559, TxEip2930, TxEip7702, TxLegacy};

    fn call_1559(input: Vec<u8>, gas_limit: u64) -> Transaction {
        Transaction::Eip1559(TxEip1559 {
            chain_id: 1,
            nonce: 0,
            max_priority_fee_per_gas: 1,
            max_fee_per_gas: 10,
            gas_limit,
            to: TxKind::Call(Address([1; 20])),
            value: U256::from_u64(5),
            input,
            access_list: Vec::new(),
        })
    }

    #[test]
    fn plain_transfer_is_21000() {
        let g = intrinsic_gas(&call_1559(Vec::new(), 21_000));
        assert_eq!(
            (g.total, g.floor, g.minimum_gas_limit),
            (21_000, 21_000, 21_000)
        );
        assert!(check_transaction(&call_1559(Vec::new(), 21_000)).is_empty());
    }

    #[test]
    fn calldata_floor_dominates_for_data_heavy_calls() {
        // 100 non-zero bytes: standard 21000 + 1600 = 22600, floor 21000 + 10*400 = 25000.
        let g = intrinsic_gas(&call_1559(alloc::vec![0xff; 100], 30_000));
        assert_eq!(g.total, 22_600);
        assert_eq!(g.floor, 25_000);
        assert_eq!(g.minimum_gas_limit, 25_000);
        let findings = check_transaction(&call_1559(alloc::vec![0xff; 100], 24_999));
        assert!(has_errors(&findings));
        assert_eq!(findings[0].code, "gas-below-intrinsic");
    }

    #[test]
    fn create_access_list_and_authorizations() {
        let create = Transaction::Eip2930(TxEip2930 {
            chain_id: 1,
            nonce: 0,
            gas_price: 1,
            gas_limit: 100_000,
            to: TxKind::Create,
            value: U256::ZERO,
            input: alloc::vec![0x60; 33],
            access_list: alloc::vec![AccessListItem {
                address: Address([2; 20]),
                storage_keys: alloc::vec![[0; 32], [1; 32]],
            }],
        });
        let g = intrinsic_gas(&create);
        assert_eq!(g.create, 32_000);
        assert_eq!(g.initcode, 4);
        assert_eq!(g.access_list, 2_400 + 2 * 1_900);
        assert_eq!(g.total, 21_000 + 33 * 16 + 32_000 + 4 + 6_200);
        let auth = SignedAuthorization {
            chain_id: U256::ZERO,
            address: Address([3; 20]),
            nonce: 0,
            y_parity: 0,
            r: U256::ONE,
            s: U256::ONE,
        };
        let set_code = Transaction::Eip7702(TxEip7702 {
            chain_id: 1,
            nonce: 0,
            max_priority_fee_per_gas: 1,
            max_fee_per_gas: 1,
            gas_limit: 46_000,
            to: Address([4; 20]),
            value: U256::ZERO,
            input: Vec::new(),
            access_list: Vec::new(),
            authorization_list: alloc::vec![auth],
        });
        assert_eq!(intrinsic_gas(&set_code).total, 46_000);
        let codes: Vec<_> = check_transaction(&set_code)
            .iter()
            .map(|f| f.code)
            .collect();
        assert_eq!(codes, ["authorization-any-chain"]);
    }

    #[test]
    fn every_finding_fires() {
        let tx = Transaction::Eip7702(TxEip7702 {
            chain_id: 1,
            nonce: u64::MAX,
            max_priority_fee_per_gas: 11,
            max_fee_per_gas: 10,
            gas_limit: MAX_TX_GAS_LIMIT_OSAKA + 1,
            to: Address::ZERO,
            value: U256::ZERO,
            input: Vec::new(),
            access_list: Vec::new(),
            authorization_list: Vec::new(),
        });
        let codes: Vec<_> = check_transaction(&tx).iter().map(|f| f.code).collect();
        assert_eq!(
            codes,
            [
                "gas-above-osaka-cap",
                "nonce-max",
                "tip-above-fee-cap",
                "empty-authorization-list",
                "zero-address-recipient"
            ]
        );
        let legacy = Transaction::Legacy(TxLegacy {
            chain_id: None,
            nonce: 0,
            gas_price: 1,
            gas_limit: 10_000_000,
            to: TxKind::Create,
            value: U256::ZERO,
            input: alloc::vec![0; MAX_INITCODE_SIZE + 1],
        });
        let codes: Vec<_> = check_transaction(&legacy).iter().map(|f| f.code).collect();
        assert_eq!(codes, ["initcode-too-large", "no-replay-protection"]);
    }

    #[test]
    fn fee_math() {
        let tx = call_1559(Vec::new(), 21_000);
        let f = fee_summary(&tx, Some(4));
        assert_eq!(f.max_gas_cost, U256::from_u64(210_000));
        assert_eq!(f.max_total_cost, U256::from_u64(210_005));
        assert_eq!(f.effective_gas_price, Some(5));
        assert_eq!(fee_summary(&tx, Some(100)).effective_gas_price, Some(10));
        assert_eq!(fee_summary(&tx, None).effective_gas_price, None);
        let legacy = Transaction::Legacy(TxLegacy {
            chain_id: Some(1),
            nonce: 0,
            gas_price: 7,
            gas_limit: 21_000,
            to: TxKind::Call(Address([1; 20])),
            value: U256::MAX,
            input: Vec::new(),
        });
        let f = fee_summary(&legacy, Some(1));
        assert_eq!(f.effective_gas_price, Some(7));
        assert_eq!(
            f.max_total_cost,
            U256::MAX,
            "overflow saturates instead of wrapping"
        );
    }
}
