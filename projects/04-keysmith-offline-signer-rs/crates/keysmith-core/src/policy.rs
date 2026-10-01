// SPDX-License-Identifier: MIT
//! Signing policy: restrictions the offline signer enforces before producing any signature.
//!
//! A policy is a JSON file kept on the air-gapped machine. Every numeric or list constraint is
//! optional (absent = unrestricted); every boolean permission defaults to **deny**. Unknown keys
//! are rejected, so a typo such as `"maxValeuWei"` cannot silently disable a limit.
//!
//! ```json
//! {
//!   "allowedChainIds": [1, 8453],
//!   "allowedRecipients": ["0x..."],
//!   "maxValueWei": "1000000000000000000",
//!   "maxFeePerGasWei": "200000000000",
//!   "maxTotalCostWei": "1100000000000000000",
//!   "allowContractCreation": false,
//!   "allowedDelegates": ["0x..."],
//!   "allowAnyChainAuthorizations": false,
//!   "allowUnprotectedLegacy": false
//! }
//! ```

use crate::address::Address;
use crate::authorization::Authorization;
use crate::gas::fee_summary;
use crate::tx::{Transaction, TxKind};
use crate::u256::U256;
use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec::Vec;

/// A parsed policy file.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Policy {
    /// Chain ids transactions (and non-zero authorization chain ids) may target.
    #[serde(default)]
    pub allowed_chain_ids: Option<Vec<u64>>,
    /// Allowed `to` addresses (7702 transactions included).
    #[serde(default)]
    pub allowed_recipients: Option<Vec<Address>>,
    /// Maximum `value` per transaction, in wei.
    #[serde(default)]
    pub max_value_wei: Option<U256>,
    /// Maximum fee cap per gas (`gasPrice` / `maxFeePerGas`), in wei.
    #[serde(default)]
    pub max_fee_per_gas_wei: Option<U256>,
    /// Maximum `gasLimit * feeCap + value`, in wei.
    #[serde(default)]
    pub max_total_cost_wei: Option<U256>,
    /// Permit contract-creation transactions.
    #[serde(default)]
    pub allow_contract_creation: bool,
    /// Contracts an EIP-7702 authorization may delegate to.
    #[serde(default)]
    pub allowed_delegates: Option<Vec<Address>>,
    /// Permit authorizations with `chainId = 0` (valid on every chain).
    #[serde(default)]
    pub allow_any_chain_authorizations: bool,
    /// Permit pre-EIP-155 legacy transactions (no replay protection).
    #[serde(default)]
    pub allow_unprotected_legacy: bool,
}

/// A policy rule that a request breaks.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Violation {
    /// Stable rule identifier (the policy key that was violated).
    pub rule: &'static str,
    /// Human-readable explanation.
    pub message: String,
}

fn violation(rule: &'static str, message: String) -> Violation {
    Violation { rule, message }
}

/// Errors produced while loading a policy.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PolicyError {
    /// Malformed JSON, wrong types or unknown keys.
    #[error("invalid policy file: {0}")]
    InvalidJson(String),
}

impl Policy {
    /// Parses a policy document.
    pub fn from_json_str(s: &str) -> Result<Self, PolicyError> {
        serde_json::from_str(s).map_err(|e| PolicyError::InvalidJson(e.to_string()))
    }

    fn chain_allowed(&self, chain_id: u64) -> bool {
        self.allowed_chain_ids
            .as_ref()
            .is_none_or(|ids| ids.contains(&chain_id))
    }

    /// Checks a transaction, including every authorization it carries.
    pub fn check_transaction(&self, tx: &Transaction) -> Vec<Violation> {
        let mut out = Vec::new();
        match tx.chain_id() {
            None if !self.allow_unprotected_legacy => out.push(violation(
                "allowUnprotectedLegacy",
                "pre-EIP-155 legacy transactions are not allowed".into(),
            )),
            None => {}
            Some(id) if !self.chain_allowed(id) => out.push(violation(
                "allowedChainIds",
                format!("chain id {id} is not allowed"),
            )),
            Some(_) => {}
        }
        match tx.kind() {
            TxKind::Create if !self.allow_contract_creation => out.push(violation(
                "allowContractCreation",
                "contract creation is not allowed".into(),
            )),
            TxKind::Create => {}
            TxKind::Call(to) => {
                if let Some(list) = &self.allowed_recipients
                    && !list.contains(&to)
                {
                    out.push(violation(
                        "allowedRecipients",
                        format!("recipient {to} is not on the allow-list"),
                    ));
                }
            }
        }
        if let Some(max) = &self.max_value_wei
            && tx.value() > *max
        {
            out.push(violation(
                "maxValueWei",
                format!("value {} wei exceeds the limit {max}", tx.value()),
            ));
        }
        let fees = fee_summary(tx, None);
        if let Some(max) = &self.max_fee_per_gas_wei
            && U256::from_u128(fees.max_fee_per_gas) > *max
        {
            out.push(violation(
                "maxFeePerGasWei",
                format!(
                    "fee cap {} wei/gas exceeds the limit {max}",
                    fees.max_fee_per_gas
                ),
            ));
        }
        if let Some(max) = &self.max_total_cost_wei
            && fees.max_total_cost > *max
        {
            out.push(violation(
                "maxTotalCostWei",
                format!(
                    "worst-case cost {} wei exceeds the limit {max}",
                    fees.max_total_cost
                ),
            ));
        }
        for auth in tx.authorization_list() {
            out.extend(self.check_authorization(&auth.authorization()));
        }
        out
    }

    /// Checks an EIP-7702 authorization tuple.
    pub fn check_authorization(&self, auth: &Authorization) -> Vec<Violation> {
        let mut out = Vec::new();
        if auth.is_any_chain() {
            if !self.allow_any_chain_authorizations {
                out.push(violation(
                    "allowAnyChainAuthorizations",
                    format!(
                        "authorization to {} has chainId 0 (valid on every chain)",
                        auth.address
                    ),
                ));
            }
        } else {
            let allowed = auth
                .chain_id
                .to_u64()
                .is_some_and(|id| self.chain_allowed(id));
            if !allowed {
                out.push(violation(
                    "allowedChainIds",
                    format!("authorization chain id {} is not allowed", auth.chain_id),
                ));
            }
        }
        if let Some(list) = &self.allowed_delegates
            && !list.contains(&auth.address)
        {
            out.push(violation(
                "allowedDelegates",
                format!("delegate {} is not on the allow-list", auth.address),
            ));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::authorization::SignedAuthorization;
    use crate::tx::{TxEip1559, TxEip7702, TxLegacy};

    fn tx(to: TxKind, value: u64, chain: u64) -> Transaction {
        Transaction::Eip1559(TxEip1559 {
            chain_id: chain,
            nonce: 0,
            max_priority_fee_per_gas: 1,
            max_fee_per_gas: 100,
            gas_limit: 21_000,
            to,
            value: U256::from_u64(value),
            input: Vec::new(),
            access_list: Vec::new(),
        })
    }

    fn rules(v: &[Violation]) -> Vec<&'static str> {
        v.iter().map(|x| x.rule).collect()
    }

    #[test]
    fn empty_policy_denies_only_risky_defaults() {
        let p = Policy::from_json_str("{}").unwrap();
        assert!(
            p.check_transaction(&tx(TxKind::Call(Address([1; 20])), 5, 1))
                .is_empty()
        );
        assert_eq!(
            rules(&p.check_transaction(&tx(TxKind::Create, 0, 1))),
            ["allowContractCreation"]
        );
        let legacy = Transaction::Legacy(TxLegacy {
            chain_id: None,
            nonce: 0,
            gas_price: 1,
            gas_limit: 21_000,
            to: TxKind::Call(Address([1; 20])),
            value: U256::ZERO,
            input: Vec::new(),
        });
        assert_eq!(
            rules(&p.check_transaction(&legacy)),
            ["allowUnprotectedLegacy"]
        );
        let permissive = Policy {
            allow_unprotected_legacy: true,
            allow_contract_creation: true,
            ..Policy::default()
        };
        assert!(permissive.check_transaction(&legacy).is_empty());
        assert!(
            permissive
                .check_transaction(&tx(TxKind::Create, 0, 1))
                .is_empty()
        );
    }

    #[test]
    fn limits_and_allow_lists() {
        let p = Policy::from_json_str(
            r#"{"allowedChainIds":[1],"allowedRecipients":["0x0101010101010101010101010101010101010101"],
                "maxValueWei":"10","maxFeePerGasWei":50,"maxTotalCostWei":"1000"}"#,
        )
        .unwrap();
        assert_eq!(
            rules(&p.check_transaction(&tx(TxKind::Call(Address([2; 20])), 11, 5))),
            [
                "allowedChainIds",
                "allowedRecipients",
                "maxValueWei",
                "maxFeePerGasWei",
                "maxTotalCostWei"
            ]
        );
        assert!(
            Policy::from_json_str(r#"{"maxValeuWei":"1"}"#).is_err(),
            "typos must not disable limits"
        );
    }

    #[test]
    fn authorization_rules() {
        let p = Policy::from_json_str(
            r#"{"allowedChainIds":[1],"allowedDelegates":["0x0303030303030303030303030303030303030303"]}"#,
        )
        .unwrap();
        let auth = |chain: u64, delegate: u8| SignedAuthorization {
            chain_id: U256::from_u64(chain),
            address: Address([delegate; 20]),
            nonce: 0,
            y_parity: 0,
            r: U256::ONE,
            s: U256::ONE,
        };
        let set_code = |a: SignedAuthorization| {
            Transaction::Eip7702(TxEip7702 {
                chain_id: 1,
                nonce: 0,
                max_priority_fee_per_gas: 1,
                max_fee_per_gas: 1,
                gas_limit: 50_000,
                to: Address([1; 20]),
                value: U256::ZERO,
                input: Vec::new(),
                access_list: Vec::new(),
                authorization_list: alloc::vec![a],
            })
        };
        assert!(p.check_transaction(&set_code(auth(1, 3))).is_empty());
        assert_eq!(
            rules(&p.check_transaction(&set_code(auth(0, 3)))),
            ["allowAnyChainAuthorizations"]
        );
        assert_eq!(
            rules(&p.check_transaction(&set_code(auth(2, 4)))),
            ["allowedChainIds", "allowedDelegates"]
        );
        let any = Policy {
            allow_any_chain_authorizations: true,
            ..Policy::default()
        };
        assert!(any.check_transaction(&set_code(auth(0, 9))).is_empty());
        let huge = SignedAuthorization {
            chain_id: U256::MAX,
            ..auth(1, 3)
        };
        assert_eq!(
            rules(&p.check_authorization(&huge.authorization())),
            ["allowedChainIds"]
        );
    }
}
