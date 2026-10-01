// SPDX-License-Identifier: MIT
//! JSON envelopes that cross the air gap, and the offline signing procedure.
//!
//! * `keysmith/unsigned-tx@1`: produced on the online machine (`keysmith-relay prepare`),
//!   carried to the offline machine, and consumed by `keysmith sign`.
//! * `keysmith/signed-tx@1`: produced by `keysmith sign`, carried back, and consumed by
//!   `keysmith-relay broadcast`.
//!
//! The signer never trusts a hash, an encoding or a "summary" computed online: it rebuilds the
//! transaction from its fields, re-validates it, applies the local [`Policy`], and only then
//! signs. `to` must be present; `null` explicitly requests contract creation, so a field
//! dropped in transit cannot silently turn a payment into a deployment.

use crate::address::Address;
use crate::authorization::{Authorization, Executor, SignedAuthorization};
use crate::gas::{self, Finding};
use crate::hex;
use crate::keys::{PrivateKey, SignatureError};
use crate::policy::{Policy, Violation};
use crate::quantity::{hex_bytes, opt_u64_str, opt_u128_str, u64_str};
use crate::tx::{
    AccessListItem, SignedTransaction, Transaction, TxEip1559, TxEip2930, TxEip7702, TxError,
    TxKind, TxLegacy, TxType,
};
use crate::u256::U256;
use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec::Vec;
use serde::{Deserialize, Deserializer};

/// Format tag of unsigned envelopes.
pub const UNSIGNED_FORMAT: &str = "keysmith/unsigned-tx@1";
/// Format tag of signed envelopes.
pub const SIGNED_FORMAT: &str = "keysmith/signed-tx@1";

fn present<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Option<Address>>, D::Error> {
    Option::<Address>::deserialize(d).map(Some)
}

/// Transaction fields as JSON. Integers are decimal strings (hex strings and small JSON
/// numbers are accepted on input).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TxRequest {
    /// Envelope type.
    #[serde(rename = "type")]
    pub tx_type: TxType,
    /// Chain id (omit or `null` only for pre-EIP-155 legacy).
    #[serde(default, with = "opt_u64_str", skip_serializing_if = "Option::is_none")]
    pub chain_id: Option<u64>,
    /// Sender nonce.
    #[serde(with = "u64_str")]
    pub nonce: u64,
    /// Gas limit.
    #[serde(with = "u64_str")]
    pub gas_limit: u64,
    /// Legacy / EIP-2930 gas price.
    #[serde(
        default,
        with = "opt_u128_str",
        skip_serializing_if = "Option::is_none"
    )]
    pub gas_price: Option<u128>,
    /// EIP-1559 / EIP-7702 fee cap.
    #[serde(
        default,
        with = "opt_u128_str",
        skip_serializing_if = "Option::is_none"
    )]
    pub max_fee_per_gas: Option<u128>,
    /// EIP-1559 / EIP-7702 tip cap.
    #[serde(
        default,
        with = "opt_u128_str",
        skip_serializing_if = "Option::is_none"
    )]
    pub max_priority_fee_per_gas: Option<u128>,
    /// Destination: required; `null` means contract creation.
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    pub to: Option<Option<Address>>,
    /// Value in wei.
    #[serde(default)]
    pub value: U256,
    /// Calldata / initcode.
    #[serde(default, with = "hex_bytes")]
    pub input: Vec<u8>,
    /// EIP-2930 access list.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub access_list: Vec<AccessListItem>,
    /// Already-signed EIP-7702 authorizations (e.g. from other authorities, sponsor flow).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub authorization_list: Vec<SignedAuthorization>,
}

/// A delegation the signing key should authorize for itself (self-executed EIP-7702).
/// Its nonce is not supplied: the signer assigns `tx.nonce + 1`, `tx.nonce + 2`, ... in list
/// order (after any of the signer's own tuples already in `tx.authorizationList`), because
/// EIP-7702 bumps the sender's nonce before the list is processed and the authority's nonce
/// again after every tuple that applies.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SelfAuthorization {
    /// Chain id of the delegation (0 = every chain; flagged and policy-gated).
    pub chain_id: U256,
    /// Delegation target.
    pub address: Address,
}

/// `keysmith/unsigned-tx@1`.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UnsignedEnvelope {
    /// Must be [`UNSIGNED_FORMAT`].
    pub format: String,
    /// Expected signer; signing aborts if the key's address differs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<Address>,
    /// The transaction.
    pub tx: TxRequest,
    /// Delegations to sign with the same key (consecutive nonces from `tx.nonce + 1`) and append.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub self_authorizations: Vec<SelfAuthorization>,
    /// Free-form note from the envelope's author. Untrusted: `keysmith sign` shows it escaped
    /// and labelled as such, never as a description of what is signed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

/// `keysmith/signed-tx@1`.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SignedEnvelope {
    /// Must be [`SIGNED_FORMAT`].
    pub format: String,
    /// Envelope type.
    #[serde(rename = "type")]
    pub tx_type: TxType,
    /// Signer address.
    pub from: Address,
    /// Transaction hash (`0x`-hex).
    pub hash: String,
    /// Raw signed transaction (`0x`-hex), ready for `eth_sendRawTransaction`.
    pub raw: String,
    /// Note carried over from the unsigned envelope.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

/// Errors produced while converting or signing envelopes.
#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum EnvelopeError {
    /// Malformed JSON or schema violation.
    #[error("invalid envelope JSON: {0}")]
    Json(String),
    /// Unknown `format` tag.
    #[error("unsupported envelope format `{0}`")]
    UnsupportedFormat(String),
    /// A field required by the transaction type is missing.
    #[error("{tx_type} transactions require `{field}`")]
    MissingField {
        /// Transaction type.
        tx_type: TxType,
        /// Missing field.
        field: &'static str,
    },
    /// A field that the transaction type does not have was supplied.
    #[error("{tx_type} transactions do not take `{field}`")]
    ForbiddenField {
        /// Transaction type.
        tx_type: TxType,
        /// Unexpected field.
        field: &'static str,
    },
    /// `to` was omitted (use `null` to create a contract).
    #[error("`to` is required; use null to deploy a contract")]
    MissingTo,
    /// `selfAuthorizations` on a non-7702 transaction.
    #[error("selfAuthorizations require an eip7702 transaction")]
    SelfAuthorizationsRequire7702,
    /// A self-authorization nonce (`tx.nonce + k`) overflows.
    #[error("self-authorization nonce overflows u64")]
    NonceOverflow,
    /// The key does not match `from`.
    #[error("envelope expects signer {expected} but the key is {actual}")]
    FromMismatch {
        /// Declared signer.
        expected: Address,
        /// Key address.
        actual: Address,
    },
    /// Consensus-level problems; nothing was signed.
    #[error("transaction is invalid: {}", summarize_findings(.0))]
    Invalid(Vec<Finding>),
    /// Policy violations; nothing was signed.
    #[error("policy violation: {}", summarize_violations(.0))]
    PolicyViolation(Vec<Violation>),
    /// Signing failed.
    #[error("signing failed: {0}")]
    Signature(SignatureError),
    /// The raw transaction does not decode.
    #[error("raw transaction does not decode: {0}")]
    Decode(TxError),
    /// Signed envelope fields disagree with its raw bytes.
    #[error("signed envelope is inconsistent: {0}")]
    Inconsistent(&'static str),
}

fn summarize_findings(f: &[Finding]) -> String {
    f.iter()
        .filter(|x| x.severity == gas::Severity::Error)
        .map(|x| x.message.clone())
        .collect::<Vec<_>>()
        .join("; ")
}

fn summarize_violations(v: &[Violation]) -> String {
    v.iter()
        .map(|x| format!("[{}] {}", x.rule, x.message))
        .collect::<Vec<_>>()
        .join("; ")
}

impl TxRequest {
    fn need<T>(&self, v: Option<T>, field: &'static str) -> Result<T, EnvelopeError> {
        v.ok_or(EnvelopeError::MissingField {
            tx_type: self.tx_type,
            field,
        })
    }

    fn forbid<T>(&self, v: &Option<T>, field: &'static str) -> Result<(), EnvelopeError> {
        match v {
            Some(_) => Err(EnvelopeError::ForbiddenField {
                tx_type: self.tx_type,
                field,
            }),
            None => Ok(()),
        }
    }

    /// Converts to a typed [`Transaction`], enforcing which fields each type takes.
    pub fn to_transaction(&self) -> Result<Transaction, EnvelopeError> {
        let to = match self.to {
            None => return Err(EnvelopeError::MissingTo),
            Some(None) => TxKind::Create,
            Some(Some(a)) => TxKind::Call(a),
        };
        let ty = self.tx_type;
        if ty != TxType::Eip7702 && !self.authorization_list.is_empty() {
            return Err(EnvelopeError::ForbiddenField {
                tx_type: ty,
                field: "authorizationList",
            });
        }
        if ty == TxType::Legacy && !self.access_list.is_empty() {
            return Err(EnvelopeError::ForbiddenField {
                tx_type: ty,
                field: "accessList",
            });
        }
        Ok(match ty {
            TxType::Legacy | TxType::Eip2930 => {
                self.forbid(&self.max_fee_per_gas, "maxFeePerGas")?;
                self.forbid(&self.max_priority_fee_per_gas, "maxPriorityFeePerGas")?;
                let gas_price = self.need(self.gas_price, "gasPrice")?;
                if ty == TxType::Legacy {
                    Transaction::Legacy(TxLegacy {
                        chain_id: self.chain_id,
                        nonce: self.nonce,
                        gas_price,
                        gas_limit: self.gas_limit,
                        to,
                        value: self.value,
                        input: self.input.clone(),
                    })
                } else {
                    Transaction::Eip2930(TxEip2930 {
                        chain_id: self.need(self.chain_id, "chainId")?,
                        nonce: self.nonce,
                        gas_price,
                        gas_limit: self.gas_limit,
                        to,
                        value: self.value,
                        input: self.input.clone(),
                        access_list: self.access_list.clone(),
                    })
                }
            }
            TxType::Eip1559 | TxType::Eip7702 => {
                self.forbid(&self.gas_price, "gasPrice")?;
                let chain_id = self.need(self.chain_id, "chainId")?;
                let max_fee_per_gas = self.need(self.max_fee_per_gas, "maxFeePerGas")?;
                let max_priority_fee_per_gas =
                    self.need(self.max_priority_fee_per_gas, "maxPriorityFeePerGas")?;
                if ty == TxType::Eip1559 {
                    Transaction::Eip1559(TxEip1559 {
                        chain_id,
                        nonce: self.nonce,
                        max_priority_fee_per_gas,
                        max_fee_per_gas,
                        gas_limit: self.gas_limit,
                        to,
                        value: self.value,
                        input: self.input.clone(),
                        access_list: self.access_list.clone(),
                    })
                } else {
                    let TxKind::Call(to) = to else {
                        return Err(EnvelopeError::ForbiddenField {
                            tx_type: ty,
                            field: "to: null (contract creation)",
                        });
                    };
                    Transaction::Eip7702(TxEip7702 {
                        chain_id,
                        nonce: self.nonce,
                        max_priority_fee_per_gas,
                        max_fee_per_gas,
                        gas_limit: self.gas_limit,
                        to,
                        value: self.value,
                        input: self.input.clone(),
                        access_list: self.access_list.clone(),
                        authorization_list: self.authorization_list.clone(),
                    })
                }
            }
        })
    }

    /// Converts a typed [`Transaction`] back to its JSON form.
    pub fn from_transaction(tx: &Transaction) -> Self {
        let (gas_price, max_fee, tip) = match tx.max_priority_fee_per_gas() {
            Some(tip) => (None, Some(tx.max_fee_per_gas()), Some(tip)),
            None => (Some(tx.max_fee_per_gas()), None, None),
        };
        Self {
            tx_type: tx.tx_type(),
            chain_id: tx.chain_id(),
            nonce: tx.nonce(),
            gas_limit: tx.gas_limit(),
            gas_price,
            max_fee_per_gas: max_fee,
            max_priority_fee_per_gas: tip,
            to: Some(tx.kind().to()),
            value: tx.value(),
            input: tx.input().to_vec(),
            access_list: tx.access_list().to_vec(),
            authorization_list: tx.authorization_list().to_vec(),
        }
    }
}

impl UnsignedEnvelope {
    /// Wraps a transaction.
    pub fn new(tx: &Transaction, from: Option<Address>) -> Self {
        Self {
            format: UNSIGNED_FORMAT.into(),
            from,
            tx: TxRequest::from_transaction(tx),
            self_authorizations: Vec::new(),
            note: None,
        }
    }

    /// Parses and checks the format tag.
    pub fn from_json_str(s: &str) -> Result<Self, EnvelopeError> {
        let env: Self = serde_json::from_str(s).map_err(|e| EnvelopeError::Json(e.to_string()))?;
        if env.format != UNSIGNED_FORMAT {
            return Err(EnvelopeError::UnsupportedFormat(env.format));
        }
        Ok(env)
    }
}

/// A transaction that passed every check and the policy but is **not signed yet**: what the
/// operator reviews before confirming. Produced by [`plan_envelope`], consumed by
/// [`SigningPlan::sign`].
#[derive(Debug, Clone)]
pub struct SigningPlan {
    /// The transaction exactly as it will be signed (self-authorizations appended).
    pub tx: Transaction,
    /// Address of the key that will sign.
    pub signer: Address,
    /// Non-fatal findings the operator should see.
    pub warnings: Vec<Finding>,
    /// Self-executed authorizations prepared for this transaction (they are part of
    /// `tx.authorization_list`). They are signed in memory because they are part of what is
    /// reviewed; nothing leaves the process until [`SigningPlan::sign`] returns.
    pub self_authorizations: Vec<SignedAuthorization>,
    /// The envelope's untrusted note.
    pub note: Option<String>,
}

/// Everything the offline signer produced and observed.
#[derive(Debug, Clone)]
pub struct SignOutcome {
    /// The signed transaction.
    pub signed: SignedTransaction,
    /// The JSON envelope to carry back across the air gap.
    pub envelope: SignedEnvelope,
    /// Non-fatal findings the operator should see.
    pub warnings: Vec<Finding>,
    /// Authorizations this call signed (self-executed delegations).
    pub self_authorizations: Vec<SignedAuthorization>,
}

/// Steps 1-5 of the offline procedure, without the transaction signature:
///
/// 1. check the format tag and that `key` is the expected `from`;
/// 2. rebuild the transaction from its fields;
/// 3. sign any `selfAuthorizations` at consecutive nonces `tx.nonce + 1 + m`, `+ m + 1`, ...
///    (`m` = tuples already in the list that the same key signed) and append them;
/// 4. run consensus checks, including the EIP-7702 authorization rules (refuse on any error);
/// 5. enforce `policy` (refuse on any violation).
pub fn plan_envelope(
    env: &UnsignedEnvelope,
    key: &PrivateKey,
    policy: Option<&Policy>,
) -> Result<SigningPlan, EnvelopeError> {
    if env.format != UNSIGNED_FORMAT {
        return Err(EnvelopeError::UnsupportedFormat(env.format.clone()));
    }
    let signer = key.address();
    if let Some(expected) = env.from
        && expected != signer
    {
        return Err(EnvelopeError::FromMismatch {
            expected,
            actual: signer,
        });
    }
    let mut tx = env.tx.to_transaction()?;
    let mut self_signed = Vec::new();
    if !env.self_authorizations.is_empty() {
        let Transaction::Eip7702(ref mut inner) = tx else {
            return Err(EnvelopeError::SelfAuthorizationsRequire7702);
        };
        let own_supplied = inner
            .authorization_list
            .iter()
            .filter(|a| a.recover_authority().ok() == Some(signer))
            .count() as u64;
        let mut nonce = Executor::SelfExecuting
            .authorization_nonce(inner.nonce)
            .and_then(|n| n.checked_add(own_supplied))
            .ok_or(EnvelopeError::NonceOverflow)?;
        for (k, req) in env.self_authorizations.iter().enumerate() {
            if k > 0 {
                nonce = nonce.checked_add(1).ok_or(EnvelopeError::NonceOverflow)?;
            }
            let auth = Authorization {
                chain_id: req.chain_id,
                address: req.address,
                nonce,
            }
            .sign(key)
            .map_err(EnvelopeError::Signature)?;
            self_signed.push(auth.clone());
            inner.authorization_list.push(auth);
        }
    }
    let findings = gas::check_transaction(&tx, Some(&signer));
    if gas::has_errors(&findings) {
        return Err(EnvelopeError::Invalid(findings));
    }
    if let Some(policy) = policy {
        let violations = policy.check_transaction(&tx);
        if !violations.is_empty() {
            return Err(EnvelopeError::PolicyViolation(violations));
        }
    }
    Ok(SigningPlan {
        tx,
        signer,
        warnings: findings,
        self_authorizations: self_signed,
        note: env.note.clone(),
    })
}

impl SigningPlan {
    /// Step 6: signs the planned transaction. `key` must be the key the plan was made with.
    pub fn sign(self, key: &PrivateKey) -> Result<SignOutcome, EnvelopeError> {
        let actual = key.address();
        if actual != self.signer {
            return Err(EnvelopeError::FromMismatch {
                expected: self.signer,
                actual,
            });
        }
        let signed = self.tx.sign(key).map_err(EnvelopeError::Signature)?;
        let envelope = SignedEnvelope {
            format: SIGNED_FORMAT.into(),
            tx_type: signed.tx.tx_type(),
            from: self.signer,
            hash: hex::encode_prefixed(&signed.hash()),
            raw: hex::encode_prefixed(&signed.encoded()),
            note: self.note,
        };
        Ok(SignOutcome {
            signed,
            envelope,
            warnings: self.warnings,
            self_authorizations: self.self_authorizations,
        })
    }
}

/// The complete offline signing procedure for an unsigned envelope: [`plan_envelope`]
/// followed immediately by [`SigningPlan::sign`] (no operator review in between; the CLI
/// shows the plan and asks for confirmation first).
pub fn sign_envelope(
    env: &UnsignedEnvelope,
    key: &PrivateKey,
    policy: Option<&Policy>,
) -> Result<SignOutcome, EnvelopeError> {
    plan_envelope(env, key, policy)?.sign(key)
}

impl SignedEnvelope {
    /// Parses and checks the format tag.
    pub fn from_json_str(s: &str) -> Result<Self, EnvelopeError> {
        let env: Self = serde_json::from_str(s).map_err(|e| EnvelopeError::Json(e.to_string()))?;
        if env.format != SIGNED_FORMAT {
            return Err(EnvelopeError::UnsupportedFormat(env.format));
        }
        Ok(env)
    }

    /// Decodes `raw` and checks that `type`, `hash` and `from` all agree with it.
    /// The online side runs this before broadcasting anything.
    pub fn verify(&self) -> Result<SignedTransaction, EnvelopeError> {
        let raw =
            hex::decode(&self.raw).map_err(|_| EnvelopeError::Inconsistent("raw is not hex"))?;
        let signed = SignedTransaction::decode(&raw).map_err(EnvelopeError::Decode)?;
        if signed.tx.tx_type() != self.tx_type {
            return Err(EnvelopeError::Inconsistent("type does not match raw"));
        }
        if hex::encode_prefixed(&signed.hash()) != self.hash.to_ascii_lowercase() {
            return Err(EnvelopeError::Inconsistent("hash does not match raw"));
        }
        let from = signed.recover_signer().map_err(EnvelopeError::Signature)?;
        if from != self.from {
            return Err(EnvelopeError::Inconsistent(
                "from does not match the recovered signer",
            ));
        }
        Ok(signed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> PrivateKey {
        PrivateKey::from_hex("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
            .unwrap()
    }

    fn envelope(tx_json: &str) -> UnsignedEnvelope {
        UnsignedEnvelope::from_json_str(&format!(
            r#"{{"format":"keysmith/unsigned-tx@1","tx":{tx_json}}}"#
        ))
        .unwrap()
    }

    #[test]
    fn sign_and_verify_round_trip() {
        let env = envelope(
            r#"{"type":"eip1559","chainId":"1","nonce":0,"gasLimit":"21000","maxFeePerGas":"2000000000",
                "maxPriorityFeePerGas":"0x3b9aca00","to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","value":"1"}"#,
        );
        let out = sign_envelope(&env, &key(), None).unwrap();
        // Byte-identical to `cast mktx ... --gas-price 2000000000 --priority-gas-price 1000000000`.
        assert_eq!(
            out.envelope.raw,
            "0x02f86a0180843b9aca0084773594008252089470997970c51812dc3a010c7d01b50e0d17dc79c80180c001a08ba403cc571a96355d538d0aea89b8bd6c93db34dda23ebcd776a7920509551ba031d6e810740bc700a324b536aeadc6e26f274e22b9bd78294e3a644787f0d97a"
        );
        let json = serde_json::to_string(&out.envelope).unwrap();
        let back = SignedEnvelope::from_json_str(&json).unwrap();
        assert_eq!(back.verify().unwrap(), out.signed);
        let mut forged = back.clone();
        forged.from = Address([1; 20]);
        assert_eq!(
            forged.verify(),
            Err(EnvelopeError::Inconsistent(
                "from does not match the recovered signer"
            ))
        );
        let mut wrong_type = back.clone();
        wrong_type.tx_type = TxType::Legacy;
        assert!(matches!(
            wrong_type.verify(),
            Err(EnvelopeError::Inconsistent(_))
        ));
        let mut wrong_hash = back;
        wrong_hash.hash = hex::encode_prefixed(&[0u8; 32]);
        assert!(matches!(
            wrong_hash.verify(),
            Err(EnvelopeError::Inconsistent(_))
        ));
    }

    #[test]
    fn schema_rules() {
        let base = r#""chainId":"1","nonce":0,"gasLimit":"21000","value":"0""#;
        let to = r#","to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8""#;
        let conv = |json: String| envelope(&json).tx.to_transaction();
        assert_eq!(
            conv(format!(
                r#"{{"type":"eip1559",{base},"maxFeePerGas":"1","maxPriorityFeePerGas":"1"}}"#
            )),
            Err(EnvelopeError::MissingTo)
        );
        assert!(matches!(
            conv(format!(
                r#"{{"type":"eip1559",{base}{to},"gasPrice":"1","maxFeePerGas":"1","maxPriorityFeePerGas":"1"}}"#
            )),
            Err(EnvelopeError::ForbiddenField {
                field: "gasPrice",
                ..
            })
        ));
        assert!(matches!(
            conv(format!(r#"{{"type":"legacy",{base}{to}}}"#)),
            Err(EnvelopeError::MissingField {
                field: "gasPrice",
                ..
            })
        ));
        assert!(matches!(
            conv(format!(
                r#"{{"type":"legacy",{base}{to},"gasPrice":"1","maxFeePerGas":"1"}}"#
            )),
            Err(EnvelopeError::ForbiddenField {
                field: "maxFeePerGas",
                ..
            })
        ));
        assert!(matches!(
            conv(format!(
                r#"{{"type":"eip2930","nonce":0,"gasLimit":"21000"{to},"gasPrice":"1"}}"#
            )),
            Err(EnvelopeError::MissingField {
                field: "chainId",
                ..
            })
        ));
        assert!(matches!(
            conv(format!(
                r#"{{"type":"legacy",{base}{to},"gasPrice":"1","accessList":[{{"address":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","storageKeys":[]}}]}}"#
            )),
            Err(EnvelopeError::ForbiddenField {
                field: "accessList",
                ..
            })
        ));
        assert!(matches!(
            conv(format!(
                r#"{{"type":"eip7702",{base},"to":null,"maxFeePerGas":"1","maxPriorityFeePerGas":"1"}}"#
            )),
            Err(EnvelopeError::ForbiddenField { .. })
        ));
        assert!(matches!(
            conv(format!(
                r#"{{"type":"eip1559",{base}{to},"maxFeePerGas":"1"}}"#
            )),
            Err(EnvelopeError::MissingField {
                field: "maxPriorityFeePerGas",
                ..
            })
        ));
        let create = conv(format!(
            r#"{{"type":"legacy",{base},"to":null,"gasPrice":"1","input":"0x00"}}"#
        ))
        .unwrap();
        assert_eq!(create.kind(), TxKind::Create);
        let round = TxRequest::from_transaction(&create)
            .to_transaction()
            .unwrap();
        assert_eq!(round, create);
        assert!(UnsignedEnvelope::from_json_str(r#"{"format":"x","tx":{}}"#).is_err());
        assert!(matches!(
            UnsignedEnvelope::from_json_str(&format!(
                r#"{{"format":"keysmith/v0","tx":{{"type":"legacy",{base}{to},"gasPrice":"1"}}}}"#
            )),
            Err(EnvelopeError::UnsupportedFormat(_))
        ));
        assert!(matches!(
            SignedEnvelope::from_json_str("{}"),
            Err(EnvelopeError::Json(_))
        ));
    }

    #[test]
    fn refusals_happen_before_signing() {
        let k = key();
        let mut env = envelope(
            r#"{"type":"eip1559","chainId":"1","nonce":0,"gasLimit":"20000","maxFeePerGas":"1",
                "maxPriorityFeePerGas":"1","to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8"}"#,
        );
        assert!(matches!(
            sign_envelope(&env, &k, None),
            Err(EnvelopeError::Invalid(_))
        ));
        env.tx.gas_limit = 21_000;
        env.from = Some(Address([7; 20]));
        assert!(matches!(
            sign_envelope(&env, &k, None),
            Err(EnvelopeError::FromMismatch { .. })
        ));
        env.from = Some(k.address());
        let policy = Policy::from_json_str(r#"{"allowedChainIds":[5]}"#).unwrap();
        let err = sign_envelope(&env, &k, Some(&policy)).unwrap_err();
        assert!(err.to_string().contains("[allowedChainIds]"));
        env.self_authorizations.push(SelfAuthorization {
            chain_id: U256::ONE,
            address: Address([3; 20]),
        });
        assert_eq!(
            sign_envelope(&env, &k, None).unwrap_err(),
            EnvelopeError::SelfAuthorizationsRequire7702
        );
        env.format = "other".into();
        assert!(matches!(
            sign_envelope(&env, &k, None),
            Err(EnvelopeError::UnsupportedFormat(_))
        ));
    }

    #[test]
    fn self_authorization_uses_nonce_plus_one() {
        let k = key();
        let mut env = envelope(
            r#"{"type":"eip7702","chainId":"1","nonce":"4","gasLimit":"60000","maxFeePerGas":"2000000000",
                "maxPriorityFeePerGas":"1000000000","to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","value":"0"}"#,
        );
        env.self_authorizations.push(SelfAuthorization {
            chain_id: U256::ONE,
            address: Address::parse("0x5FbDB2315678afecb367f032d93F642f64180aa3").unwrap(),
        });
        let out = sign_envelope(&env, &k, None).unwrap();
        assert_eq!(out.self_authorizations[0].nonce, 5);
        // Byte-identical to `cast mktx ... --nonce 4 --auth 0x5FbDB...` (cast applies the same rule).
        assert_eq!(
            out.envelope.raw,
            "0x04f8c80104843b9aca00847735940082ea609470997970c51812dc3a010c7d01b50e0d17dc79c88080c0f85cf85a01945fbdb2315678afecb367f032d93f642f64180aa30501a06e0089c7283c53da6377df27399347d3578ff4276431e323f1d897a39e40f22ba01608b9af83e8953b993de8a64a9274eb7183f687048a0e0155cc267d93d73abe01a06cb3f9e532a55ab02922c7b4aed9943be9cb0072ffffb76d291db5860984d745a002f5a58d182130fc88a39a1b35e3e88749bccf6c7a5b49bc51b0f1ef6612bfa2"
        );
        env.tx.nonce = u64::MAX;
        assert_eq!(
            sign_envelope(&env, &k, None).unwrap_err(),
            EnvelopeError::NonceOverflow
        );
    }

    fn self_auth(byte: u8) -> SelfAuthorization {
        SelfAuthorization {
            chain_id: U256::ONE,
            address: Address([byte; 20]),
        }
    }

    /// Regression: every self-authorization used to be signed at `tx.nonce + 1`. EIP-7702 bumps
    /// the authority's nonce after each tuple that applies, so the second one was skipped on
    /// every node: its delegation silently never happened, with no finding.
    #[test]
    fn several_self_authorizations_get_consecutive_nonces() {
        let k = key();
        let mut env = envelope(
            r#"{"type":"eip7702","chainId":"1","nonce":"4","gasLimit":"100000","maxFeePerGas":"2",
                "maxPriorityFeePerGas":"1","to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8"}"#,
        );
        env.self_authorizations = alloc::vec![self_auth(0xa1), self_auth(0xb2), self_auth(0xc3)];
        let plan = plan_envelope(&env, &k, None).unwrap();
        let nonces: Vec<u64> = plan.self_authorizations.iter().map(|a| a.nonce).collect();
        assert_eq!(nonces, [5, 6, 7]);
        // Valid, but the operator is told that only the last delegation remains.
        let codes: Vec<_> = plan.warnings.iter().map(|f| f.code).collect();
        assert_eq!(
            codes,
            [
                "authorization-duplicate-authority",
                "authorization-duplicate-authority"
            ]
        );
        let out = plan.sign(&k).unwrap();
        assert_eq!(out.signed.tx.authorization_list().len(), 3);
        assert_eq!(out.signed.recover_signer().unwrap(), k.address());

        // A tuple of the same key already in the list (correctly at nonce + 1) shifts the
        // self-authorizations to nonce + 2.
        let own = Authorization {
            chain_id: U256::ONE,
            address: Address([0xd4; 20]),
            nonce: 5,
        }
        .sign(&k)
        .unwrap();
        env.tx.authorization_list = alloc::vec![own.clone()];
        env.self_authorizations = alloc::vec![self_auth(0xa1)];
        let plan = plan_envelope(&env, &k, None).unwrap();
        assert_eq!(plan.self_authorizations[0].nonce, 6);

        // A supplied tuple of the same key at a stale nonce is refused, not silently skipped.
        let stale = Authorization {
            nonce: 4,
            ..own.authorization()
        }
        .sign(&k)
        .unwrap();
        env.tx.authorization_list = alloc::vec![stale];
        env.self_authorizations.clear();
        match plan_envelope(&env, &k, None) {
            Err(EnvelopeError::Invalid(findings)) => {
                assert!(
                    findings
                        .iter()
                        .any(|f| f.code == "authorization-nonce-mismatch"),
                    "{findings:?}"
                );
            }
            other => panic!("expected a refusal, got {other:?}"),
        }
    }

    #[test]
    fn a_plan_signs_only_with_its_own_key() {
        let env = envelope(
            r#"{"type":"eip1559","chainId":"1","nonce":0,"gasLimit":"21000","maxFeePerGas":"2",
                "maxPriorityFeePerGas":"1","to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8"}"#,
        );
        let plan = plan_envelope(&env, &key(), None).unwrap();
        let other = PrivateKey::from_bytes(&[7; 32]).unwrap();
        assert!(matches!(
            plan.sign(&other),
            Err(EnvelopeError::FromMismatch { .. })
        ));
    }
}
