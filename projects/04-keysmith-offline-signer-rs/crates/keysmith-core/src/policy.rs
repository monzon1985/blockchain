// SPDX-License-Identifier: MIT
//! Signing policy: restrictions the offline signer enforces before producing any signature.
//!
//! A policy is a JSON file kept on the air-gapped machine. Every numeric or list constraint is
//! optional (absent = unrestricted); every boolean permission defaults to **deny**. Unknown keys
//! are rejected, so a typo such as `"maxValeuWei"` cannot silently disable a limit.
//! [`Policy::default`] (the empty policy `{}`) is what the `keysmith` CLI applies when no policy
//! file is given, so the deny-by-default booleans always hold unless `--no-policy` is passed.
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
//!   "allowUnprotectedLegacy": false,
//!   "allowedVerifyingContracts": ["0x..."],
//!   "allowedSpenders": ["0x..."],
//!   "maxPermitValue": "1000000000"
//! }
//! ```
//!
//! Transactions are checked by [`Policy::check_transaction`], EIP-7702 tuples by
//! [`Policy::check_authorization`], and EIP-712 documents (including ERC-2612 permits) by
//! [`Policy::check_typed_data`].

use crate::address::Address;
use crate::authorization::Authorization;
use crate::eip712::{Eip712Error, Field, FieldValue, TypedData};
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
    /// Contracts an EIP-712 domain may name as `verifyingContract` (typed data and permits).
    /// When set, a domain without a `verifyingContract` is refused too.
    #[serde(default)]
    pub allowed_verifying_contracts: Option<Vec<Address>>,
    /// Addresses a typed-data message may name in a top-level `spender` member (ERC-2612
    /// `Permit`, Permit2 `PermitSingle` / `PermitBatch` / `PermitTransferFrom`, DAI-style
    /// permits).
    #[serde(default)]
    pub allowed_spenders: Option<Vec<Address>>,
    /// Maximum `value` of an ERC-2612 `Permit` (primary type `Permit` with a top-level
    /// `value`), in token base units.
    #[serde(default)]
    pub max_permit_value: Option<U256>,
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

    /// Checks an EIP-712 document (the `keysmith sign-typed-data` and `keysmith permit` paths):
    ///
    /// * `allowedChainIds`: the domain's `chainId` must be allowed; a domain without one is
    ///   refused, because its signature is valid on every chain;
    /// * `allowedVerifyingContracts`: the domain's `verifyingContract` must be listed;
    /// * `allowedSpenders`: a top-level `spender` address in the message must be listed;
    /// * `maxPermitValue`: an ERC-2612 `Permit.value` must not exceed the limit.
    pub fn check_typed_data(&self, td: &TypedData) -> Result<Vec<Violation>, Eip712Error> {
        let mut out = Vec::new();
        if let Some(ids) = &self.allowed_chain_ids {
            match td.domain_chain_id() {
                Some(id) if id.to_u64().is_some_and(|id| ids.contains(&id)) => {}
                Some(id) => out.push(violation(
                    "allowedChainIds",
                    format!("typed-data domain chain id {id} is not allowed"),
                )),
                None => out.push(violation(
                    "allowedChainIds",
                    "the typed-data domain has no chainId (valid on every chain)".into(),
                )),
            }
        }
        if let Some(list) = &self.allowed_verifying_contracts {
            match td.domain_verifying_contract() {
                Some(c) if list.contains(&c) => {}
                Some(c) => out.push(violation(
                    "allowedVerifyingContracts",
                    format!("verifying contract {c} is not on the allow-list"),
                )),
                None => out.push(violation(
                    "allowedVerifyingContracts",
                    "the typed-data domain names no verifyingContract".into(),
                )),
            }
        }
        let fields = td.message_fields()?;
        let top = |name: &str| fields.iter().find(|f| f.path == name);
        if let Some(list) = &self.allowed_spenders
            && let Some(Field {
                value: FieldValue::Address(spender),
                ..
            }) = top("spender")
            && !list.contains(spender)
        {
            out.push(violation(
                "allowedSpenders",
                format!("spender {spender} is not on the allow-list"),
            ));
        }
        if let Some(max) = &self.max_permit_value
            && td.primary_type() == "Permit"
            && let Some(Field {
                value: FieldValue::Uint(value),
                ..
            }) = top("value")
            && value > max
        {
            out.push(violation(
                "maxPermitValue",
                format!("permit value {value} exceeds the limit {max}"),
            ));
        }
        Ok(out)
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

    fn permit_doc(
        chain: Option<u64>,
        contract: Option<&str>,
        spender: &str,
        value: &str,
    ) -> TypedData {
        let mut domain = serde_json::json!({"name": "Token", "version": "1"});
        if let Some(c) = chain {
            domain["chainId"] = serde_json::json!(c);
        }
        if let Some(c) = contract {
            domain["verifyingContract"] = serde_json::json!(c);
        }
        TypedData::from_value(&serde_json::json!({
            "types": {"Permit": [
                {"name": "owner", "type": "address"}, {"name": "spender", "type": "address"},
                {"name": "value", "type": "uint256"}, {"name": "nonce", "type": "uint256"},
                {"name": "deadline", "type": "uint256"}]},
            "primaryType": "Permit",
            "domain": domain,
            "message": {"owner": "0x0101010101010101010101010101010101010101", "spender": spender,
                        "value": value, "nonce": "0", "deadline": "1"}
        }))
        .unwrap()
    }

    /// Regression: typed data and permits were never policy-checked, so a dApp-supplied
    /// unlimited permit to an arbitrary spender on any chain was signed as long as it parsed.
    #[test]
    fn typed_data_rules() {
        const TOKEN: &str = "0x0303030303030303030303030303030303030303";
        const FRIEND: &str = "0x0404040404040404040404040404040404040404";
        const ATTACKER: &str = "0x0505050505050505050505050505050505050505";
        let p = Policy::from_json_str(&format!(
            r#"{{"allowedChainIds":[1],"allowedVerifyingContracts":["{TOKEN}"],
                "allowedSpenders":["{FRIEND}"],"maxPermitValue":"1000"}}"#
        ))
        .unwrap();
        let check = |td: &TypedData| rules(&p.check_typed_data(td).unwrap());
        assert!(check(&permit_doc(Some(1), Some(TOKEN), FRIEND, "1000")).is_empty());
        assert_eq!(
            check(&permit_doc(Some(5), Some(ATTACKER), ATTACKER, "1001")),
            [
                "allowedChainIds",
                "allowedVerifyingContracts",
                "allowedSpenders",
                "maxPermitValue"
            ]
        );
        // A domain without chainId or verifyingContract cannot satisfy an allow-list.
        assert_eq!(
            check(&permit_doc(None, None, FRIEND, "1")),
            ["allowedChainIds", "allowedVerifyingContracts"]
        );
        // The empty (default) policy constrains no typed data.
        assert!(
            Policy::default()
                .check_typed_data(&permit_doc(None, None, ATTACKER, "1"))
                .unwrap()
                .is_empty()
        );
        // maxPermitValue is specific to ERC-2612 `Permit`; allowedSpenders to a `spender`.
        let mail = TypedData::from_value(&serde_json::json!({
            "types": {"Mail": [{"name": "value", "type": "uint256"}]},
            "primaryType": "Mail",
            "domain": {"chainId": 1, "verifyingContract": TOKEN},
            "message": {"value": "99999"}
        }))
        .unwrap();
        assert!(check(&mail).is_empty());
    }
}
