// SPDX-License-Identifier: MIT
//! Human- and machine-readable decoding of a raw signed transaction (`keysmith decode`).

use crate::address::Address;
use crate::gas::{self, FeeSummary, Finding, IntrinsicGas};
use crate::hex;
use crate::quantity::{opt_u64_str, u64_str};
use crate::tx::{AccessListItem, SignedTransaction, Transaction, TxType};
use crate::u256::U256;
use crate::units::format_ether;
use alloc::string::{String, ToString};
use alloc::vec::Vec;

/// One decoded EIP-7702 authorization.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthorizationReport {
    /// Delegation chain id (0 = every chain).
    pub chain_id: U256,
    /// Delegation target.
    pub address: Address,
    /// Authority nonce.
    #[serde(with = "u64_str")]
    pub nonce: u64,
    /// Recovered authority, if the signature is valid.
    pub authority: Option<Address>,
    /// Why recovery failed (the EVM skips such tuples).
    pub error: Option<String>,
}

/// Signature components.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SignatureReport {
    /// y-parity.
    pub y_parity: bool,
    /// `r`.
    pub r: U256,
    /// `s`.
    pub s: U256,
    /// `s <= n/2` (EIP-2).
    pub low_s: bool,
}

/// Everything `keysmith decode` prints.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TxReport {
    /// Envelope type.
    #[serde(rename = "type")]
    pub tx_type: TxType,
    /// Transaction hash.
    pub hash: String,
    /// Recovered sender.
    pub signer: Option<Address>,
    /// Why sender recovery failed.
    pub signer_error: Option<String>,
    /// Chain id (`None` for pre-EIP-155).
    #[serde(with = "opt_u64_str")]
    pub chain_id: Option<u64>,
    /// Sender nonce.
    #[serde(with = "u64_str")]
    pub nonce: u64,
    /// Destination (`None` for contract creation).
    pub to: Option<Address>,
    /// Address the creation would deploy to (needs a recoverable signer).
    pub contract_address: Option<Address>,
    /// Value in wei.
    pub value: U256,
    /// Value in ether.
    pub value_ether: String,
    /// Calldata length.
    pub input_bytes: usize,
    /// First four calldata bytes of a call, if present.
    pub selector: Option<String>,
    /// Gas limit.
    #[serde(with = "u64_str")]
    pub gas_limit: u64,
    /// Fee math.
    pub fees: FeeSummary,
    /// Itemised intrinsic gas.
    pub intrinsic_gas: IntrinsicGas,
    /// Access list.
    pub access_list: Vec<AccessListItem>,
    /// Authorizations with their recovered authorities.
    pub authorizations: Vec<AuthorizationReport>,
    /// Signature components.
    pub signature: SignatureReport,
    /// Consensus errors and operator warnings.
    pub findings: Vec<Finding>,
}

/// Builds the report. `base_fee` enables the effective-gas-price figure and the
/// includability check.
pub fn report(signed: &SignedTransaction, base_fee: Option<u128>) -> TxReport {
    let tx: &Transaction = &signed.tx;
    let (signer, signer_error) = match signed.recover_signer() {
        Ok(a) => (Some(a), None),
        Err(e) => (None, Some(e.to_string())),
    };
    let authorizations = tx
        .authorization_list()
        .iter()
        .map(|a| {
            let (authority, error) = match a.recover_authority() {
                Ok(x) => (Some(x), None),
                Err(e) => (None, Some(e.to_string())),
            };
            AuthorizationReport {
                chain_id: a.chain_id,
                address: a.address,
                nonce: a.nonce,
                authority,
                error,
            }
        })
        .collect();
    let input = tx.input();
    TxReport {
        tx_type: tx.tx_type(),
        hash: hex::encode_prefixed(&signed.hash()),
        signer,
        signer_error,
        chain_id: tx.chain_id(),
        nonce: tx.nonce(),
        to: tx.kind().to(),
        contract_address: signer.and_then(|s| tx.created_address(&s)),
        value: tx.value(),
        value_ether: format_ether(&tx.value()),
        input_bytes: input.len(),
        selector: (input.len() >= 4 && tx.kind().to().is_some())
            .then(|| hex::encode_prefixed(&input[..4])),
        gas_limit: tx.gas_limit(),
        fees: gas::fee_summary(tx, base_fee),
        intrinsic_gas: gas::intrinsic_gas(tx),
        access_list: tx.access_list().to_vec(),
        authorizations,
        signature: SignatureReport {
            y_parity: signed.signature.y_parity,
            r: signed.signature.r,
            s: signed.signature.s,
            low_s: signed.signature.is_low_s(),
        },
        findings: findings(tx, base_fee),
    }
}

/// Consensus findings plus, when a base fee is supplied, whether the fee cap can be included.
fn findings(tx: &Transaction, base_fee: Option<u128>) -> Vec<Finding> {
    let mut out = gas::check_transaction(tx);
    if let Some(base) = base_fee
        && tx.max_fee_per_gas() < base
    {
        out.push(Finding {
            severity: gas::Severity::Warning,
            code: "fee-cap-below-base-fee",
            message: alloc::format!(
                "fee cap {} wei/gas is below the base fee {base} wei/gas: not includable until the base fee drops",
                tx.max_fee_per_gas()
            ),
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keys::{CURVE_ORDER, PrivateKey};
    use crate::tx::{TxEip1559, TxKind};

    fn signed(to: TxKind, input: Vec<u8>) -> SignedTransaction {
        let key = PrivateKey::from_bytes(&[0x21; 32]).unwrap();
        Transaction::Eip1559(TxEip1559 {
            chain_id: 1,
            nonce: 0,
            max_priority_fee_per_gas: 1_000_000_000,
            max_fee_per_gas: 3_000_000_000,
            gas_limit: 100_000,
            to,
            value: U256::from_u64(5),
            input,
            access_list: Vec::new(),
        })
        .sign(&key)
        .unwrap()
    }

    #[test]
    fn creation_selector_and_base_fee_findings() {
        let create = signed(TxKind::Create, alloc::vec![0x60, 0x00]);
        let r = report(&create, None);
        let signer = r.signer.unwrap();
        assert_eq!(r.contract_address, Some(Address::create(&signer, 0)));
        assert_eq!(r.selector, None, "initcode has no selector");
        assert_eq!(r.fees.effective_gas_price, None);
        let call = signed(
            TxKind::Call(Address([7; 20])),
            alloc::vec![0xa9, 0x05, 0x9c, 0xbb, 0],
        );
        let r = report(&call, Some(1_000_000_000));
        assert_eq!(r.selector.as_deref(), Some("0xa9059cbb"));
        assert_eq!(r.fees.effective_gas_price, Some(2_000_000_000));
        assert!(r.findings.is_empty());
        let r = report(&call, Some(4_000_000_000));
        let codes: Vec<_> = r.findings.iter().map(|f| f.code).collect();
        assert_eq!(codes, ["fee-cap-below-base-fee"]);
    }

    #[test]
    fn unrecoverable_signatures_are_reported_not_hidden() {
        let mut tx = signed(TxKind::Call(Address([7; 20])), Vec::new());
        tx.signature.s = CURVE_ORDER.checked_sub(&tx.signature.s).unwrap();
        tx.signature.y_parity = !tx.signature.y_parity;
        let r = report(&tx, None);
        assert_eq!(r.signer, None);
        assert!(!r.signature.low_s);
        assert!(r.signer_error.unwrap().contains("EIP-2"));
    }
}
