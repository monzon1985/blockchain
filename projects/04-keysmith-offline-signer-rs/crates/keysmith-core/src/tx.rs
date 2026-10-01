// SPDX-License-Identifier: MIT
//! Ethereum transaction envelopes: legacy (with and without EIP-155), EIP-2930, EIP-1559 and
//! EIP-7702, encoded and decoded with the hand-written [`crate::rlp`] core.
//!
//! | Type | Signing payload | Signed encoding |
//! |---|---|---|
//! | legacy, pre-155 | `rlp([nonce, gasPrice, gas, to, value, data])` | `rlp([.., v=27+y, r, s])` |
//! | legacy, EIP-155 | `rlp([nonce, gasPrice, gas, to, value, data, chainId, 0, 0])` | `rlp([.., v=2*chainId+35+y, r, s])` |
//! | 0x01 EIP-2930 | `0x01 ‖ rlp([chainId, nonce, gasPrice, gas, to, value, data, accessList])` | `0x01 ‖ rlp([.., y, r, s])` |
//! | 0x02 EIP-1559 | `0x02 ‖ rlp([chainId, nonce, maxPriority, maxFee, gas, to, value, data, accessList])` | `0x02 ‖ rlp([.., y, r, s])` |
//! | 0x04 EIP-7702 | `0x04 ‖ rlp([chainId, nonce, maxPriority, maxFee, gas, to, value, data, accessList, authList])` | `0x04 ‖ rlp([.., y, r, s])` |
//!
//! Blob transactions (type 0x03) are out of scope and rejected by the decoder.

use crate::address::Address;
use crate::authorization::SignedAuthorization;
use crate::hash::keccak256;
use crate::keys::{PrivateKey, Signature, SignatureError};
use crate::quantity::hex_b256_vec;
use crate::rlp::{self, ListDecoder, RlpError};
use crate::u256::U256;
use alloc::vec::Vec;
use core::fmt;

/// Transaction envelope type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TxType {
    /// Untyped legacy transaction (EIP-155 replay protection optional).
    Legacy,
    /// Type 0x01, access lists.
    Eip2930,
    /// Type 0x02, dynamic fees.
    Eip1559,
    /// Type 0x04, set-code (account delegation).
    Eip7702,
}

impl TxType {
    /// The EIP-2718 type byte (`None` for legacy).
    pub fn type_byte(self) -> Option<u8> {
        match self {
            TxType::Legacy => None,
            TxType::Eip2930 => Some(0x01),
            TxType::Eip1559 => Some(0x02),
            TxType::Eip7702 => Some(0x04),
        }
    }

    /// Human-readable name.
    pub fn name(self) -> &'static str {
        match self {
            TxType::Legacy => "legacy",
            TxType::Eip2930 => "EIP-2930",
            TxType::Eip1559 => "EIP-1559",
            TxType::Eip7702 => "EIP-7702",
        }
    }
}

impl fmt::Display for TxType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// Errors produced while decoding signed transactions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum TxError {
    /// Malformed or non-canonical RLP.
    #[error("rlp: {0}")]
    Rlp(#[from] RlpError),
    /// No bytes at all.
    #[error("empty transaction bytes")]
    Empty,
    /// A type byte Keysmith does not handle (e.g. 0x03 blob transactions).
    #[error("unsupported transaction type {0:#04x}")]
    UnsupportedType(u8),
    /// Legacy `v` is neither 27/28 nor >= 35.
    #[error("invalid legacy v value {0}")]
    InvalidV(u128),
    /// Typed `y_parity` is not 0 or 1.
    #[error("y-parity must be 0 or 1, got {0}")]
    InvalidParity(u8),
    /// `to` is neither empty nor 20 bytes.
    #[error("destination must be empty (create) or 20 bytes, got {0} bytes")]
    InvalidTo(usize),
    /// A type-4 transaction with an empty destination.
    #[error("EIP-7702 transactions cannot create contracts")]
    CreateNotAllowed,
    /// EIP-155 chain id derived from `v` does not fit in 64 bits.
    #[error("chain id does not fit in 64 bits")]
    ChainIdOverflow,
}

/// Call target: a contract creation or a call to an address.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TxKind {
    /// Contract creation (`to` is the empty string).
    Create,
    /// Message call.
    Call(Address),
}

impl TxKind {
    /// The destination address, if any.
    pub fn to(&self) -> Option<Address> {
        match self {
            TxKind::Create => None,
            TxKind::Call(a) => Some(*a),
        }
    }

    fn encode(&self, out: &mut Vec<u8>) {
        match self {
            TxKind::Create => rlp::encode_bytes(out, &[]),
            TxKind::Call(a) => rlp::encode_bytes(out, &a.0),
        }
    }

    fn decode(d: &mut ListDecoder<'_>) -> Result<Self, TxError> {
        let bytes = d.bytes()?;
        match bytes.len() {
            0 => Ok(TxKind::Create),
            20 => {
                let mut a = [0u8; 20];
                a.copy_from_slice(bytes);
                Ok(TxKind::Call(Address(a)))
            }
            n => Err(TxError::InvalidTo(n)),
        }
    }
}

/// One EIP-2930 access-list entry.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AccessListItem {
    /// Account to pre-warm.
    pub address: Address,
    /// Storage slots of that account to pre-warm.
    #[serde(with = "hex_b256_vec")]
    pub storage_keys: Vec<[u8; 32]>,
}

fn encode_access_list(out: &mut Vec<u8>, list: &[AccessListItem]) {
    let mut payload = Vec::new();
    for item in list {
        let mut entry = Vec::new();
        rlp::encode_bytes(&mut entry, &item.address.0);
        let mut keys = Vec::new();
        for key in &item.storage_keys {
            rlp::encode_bytes(&mut keys, key);
        }
        rlp::encode_list(&mut entry, &keys);
        rlp::encode_list(&mut payload, &entry);
    }
    rlp::encode_list(out, &payload);
}

fn decode_access_list(d: &mut ListDecoder<'_>) -> Result<Vec<AccessListItem>, TxError> {
    let mut list = d.list()?;
    let mut out = Vec::new();
    while !list.is_empty() {
        let mut entry = list.list()?;
        let address = Address(entry.fixed::<20>()?);
        let mut keys = entry.list()?;
        let mut storage_keys = Vec::new();
        while !keys.is_empty() {
            storage_keys.push(keys.fixed::<32>()?);
        }
        entry.finish()?;
        out.push(AccessListItem {
            address,
            storage_keys,
        });
    }
    Ok(out)
}

fn encode_authorization_list(out: &mut Vec<u8>, list: &[SignedAuthorization]) {
    let mut payload = Vec::new();
    for auth in list {
        auth.encode_into(&mut payload);
    }
    rlp::encode_list(out, &payload);
}

fn decode_authorization_list(d: &mut ListDecoder<'_>) -> Result<Vec<SignedAuthorization>, TxError> {
    let mut list = d.list()?;
    let mut out = Vec::new();
    while !list.is_empty() {
        out.push(SignedAuthorization::decode_from(&mut list)?);
    }
    Ok(out)
}

/// Legacy transaction. `chain_id: None` means pre-EIP-155 (replayable on every chain).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TxLegacy {
    /// EIP-155 chain id, or `None` for an unprotected transaction.
    pub chain_id: Option<u64>,
    /// Sender nonce.
    pub nonce: u64,
    /// Gas price in wei.
    pub gas_price: u128,
    /// Gas limit.
    pub gas_limit: u64,
    /// Destination or contract creation.
    pub to: TxKind,
    /// Value in wei.
    pub value: U256,
    /// Calldata or initcode.
    pub input: Vec<u8>,
}

/// EIP-2930 transaction.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TxEip2930 {
    /// Chain id.
    pub chain_id: u64,
    /// Sender nonce.
    pub nonce: u64,
    /// Gas price in wei.
    pub gas_price: u128,
    /// Gas limit.
    pub gas_limit: u64,
    /// Destination or contract creation.
    pub to: TxKind,
    /// Value in wei.
    pub value: U256,
    /// Calldata or initcode.
    pub input: Vec<u8>,
    /// Pre-warmed accounts and slots.
    pub access_list: Vec<AccessListItem>,
}

/// EIP-1559 transaction.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TxEip1559 {
    /// Chain id.
    pub chain_id: u64,
    /// Sender nonce.
    pub nonce: u64,
    /// Tip cap in wei per gas.
    pub max_priority_fee_per_gas: u128,
    /// Fee cap in wei per gas.
    pub max_fee_per_gas: u128,
    /// Gas limit.
    pub gas_limit: u64,
    /// Destination or contract creation.
    pub to: TxKind,
    /// Value in wei.
    pub value: U256,
    /// Calldata or initcode.
    pub input: Vec<u8>,
    /// Pre-warmed accounts and slots.
    pub access_list: Vec<AccessListItem>,
}

/// EIP-7702 set-code transaction. Always a call (no contract creation).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TxEip7702 {
    /// Chain id.
    pub chain_id: u64,
    /// Sender nonce.
    pub nonce: u64,
    /// Tip cap in wei per gas.
    pub max_priority_fee_per_gas: u128,
    /// Fee cap in wei per gas.
    pub max_fee_per_gas: u128,
    /// Gas limit.
    pub gas_limit: u64,
    /// Destination.
    pub to: Address,
    /// Value in wei.
    pub value: U256,
    /// Calldata.
    pub input: Vec<u8>,
    /// Pre-warmed accounts and slots.
    pub access_list: Vec<AccessListItem>,
    /// Signed delegations applied before execution.
    pub authorization_list: Vec<SignedAuthorization>,
}

/// Any supported unsigned transaction.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Transaction {
    /// Legacy.
    Legacy(TxLegacy),
    /// EIP-2930.
    Eip2930(TxEip2930),
    /// EIP-1559.
    Eip1559(TxEip1559),
    /// EIP-7702.
    Eip7702(TxEip7702),
}

impl Transaction {
    /// Envelope type.
    pub fn tx_type(&self) -> TxType {
        match self {
            Transaction::Legacy(_) => TxType::Legacy,
            Transaction::Eip2930(_) => TxType::Eip2930,
            Transaction::Eip1559(_) => TxType::Eip1559,
            Transaction::Eip7702(_) => TxType::Eip7702,
        }
    }

    /// Chain id (`None` only for pre-EIP-155 legacy transactions).
    pub fn chain_id(&self) -> Option<u64> {
        match self {
            Transaction::Legacy(t) => t.chain_id,
            Transaction::Eip2930(t) => Some(t.chain_id),
            Transaction::Eip1559(t) => Some(t.chain_id),
            Transaction::Eip7702(t) => Some(t.chain_id),
        }
    }

    /// Sender nonce.
    pub fn nonce(&self) -> u64 {
        match self {
            Transaction::Legacy(t) => t.nonce,
            Transaction::Eip2930(t) => t.nonce,
            Transaction::Eip1559(t) => t.nonce,
            Transaction::Eip7702(t) => t.nonce,
        }
    }

    /// Gas limit.
    pub fn gas_limit(&self) -> u64 {
        match self {
            Transaction::Legacy(t) => t.gas_limit,
            Transaction::Eip2930(t) => t.gas_limit,
            Transaction::Eip1559(t) => t.gas_limit,
            Transaction::Eip7702(t) => t.gas_limit,
        }
    }

    /// Destination or creation.
    pub fn kind(&self) -> TxKind {
        match self {
            Transaction::Legacy(t) => t.to,
            Transaction::Eip2930(t) => t.to,
            Transaction::Eip1559(t) => t.to,
            Transaction::Eip7702(t) => TxKind::Call(t.to),
        }
    }

    /// Value in wei.
    pub fn value(&self) -> U256 {
        match self {
            Transaction::Legacy(t) => t.value,
            Transaction::Eip2930(t) => t.value,
            Transaction::Eip1559(t) => t.value,
            Transaction::Eip7702(t) => t.value,
        }
    }

    /// Calldata / initcode.
    pub fn input(&self) -> &[u8] {
        match self {
            Transaction::Legacy(t) => &t.input,
            Transaction::Eip2930(t) => &t.input,
            Transaction::Eip1559(t) => &t.input,
            Transaction::Eip7702(t) => &t.input,
        }
    }

    /// Access list (empty for legacy).
    pub fn access_list(&self) -> &[AccessListItem] {
        match self {
            Transaction::Legacy(_) => &[],
            Transaction::Eip2930(t) => &t.access_list,
            Transaction::Eip1559(t) => &t.access_list,
            Transaction::Eip7702(t) => &t.access_list,
        }
    }

    /// Authorization list (empty unless EIP-7702).
    pub fn authorization_list(&self) -> &[SignedAuthorization] {
        match self {
            Transaction::Eip7702(t) => &t.authorization_list,
            _ => &[],
        }
    }

    /// Fee cap per gas: `gasPrice` for legacy / 2930, `maxFeePerGas` otherwise.
    pub fn max_fee_per_gas(&self) -> u128 {
        match self {
            Transaction::Legacy(t) => t.gas_price,
            Transaction::Eip2930(t) => t.gas_price,
            Transaction::Eip1559(t) => t.max_fee_per_gas,
            Transaction::Eip7702(t) => t.max_fee_per_gas,
        }
    }

    /// Tip cap per gas (`None` for legacy / 2930, which pay `gasPrice - baseFee` as tip).
    pub fn max_priority_fee_per_gas(&self) -> Option<u128> {
        match self {
            Transaction::Eip1559(t) => Some(t.max_priority_fee_per_gas),
            Transaction::Eip7702(t) => Some(t.max_priority_fee_per_gas),
            _ => None,
        }
    }

    fn encode_body(&self, out: &mut Vec<u8>) {
        match self {
            Transaction::Legacy(t) => {
                rlp::encode_u64(out, t.nonce);
                rlp::encode_u128(out, t.gas_price);
                rlp::encode_u64(out, t.gas_limit);
                t.to.encode(out);
                rlp::encode_u256(out, &t.value);
                rlp::encode_bytes(out, &t.input);
            }
            Transaction::Eip2930(t) => {
                rlp::encode_u64(out, t.chain_id);
                rlp::encode_u64(out, t.nonce);
                rlp::encode_u128(out, t.gas_price);
                rlp::encode_u64(out, t.gas_limit);
                t.to.encode(out);
                rlp::encode_u256(out, &t.value);
                rlp::encode_bytes(out, &t.input);
                encode_access_list(out, &t.access_list);
            }
            Transaction::Eip1559(t) => {
                rlp::encode_u64(out, t.chain_id);
                rlp::encode_u64(out, t.nonce);
                rlp::encode_u128(out, t.max_priority_fee_per_gas);
                rlp::encode_u128(out, t.max_fee_per_gas);
                rlp::encode_u64(out, t.gas_limit);
                t.to.encode(out);
                rlp::encode_u256(out, &t.value);
                rlp::encode_bytes(out, &t.input);
                encode_access_list(out, &t.access_list);
            }
            Transaction::Eip7702(t) => {
                rlp::encode_u64(out, t.chain_id);
                rlp::encode_u64(out, t.nonce);
                rlp::encode_u128(out, t.max_priority_fee_per_gas);
                rlp::encode_u128(out, t.max_fee_per_gas);
                rlp::encode_u64(out, t.gas_limit);
                rlp::encode_bytes(out, &t.to.0);
                rlp::encode_u256(out, &t.value);
                rlp::encode_bytes(out, &t.input);
                encode_access_list(out, &t.access_list);
                encode_authorization_list(out, &t.authorization_list);
            }
        }
    }

    fn with_type_byte(&self, list: Vec<u8>) -> Vec<u8> {
        match self.tx_type().type_byte() {
            None => list,
            Some(ty) => {
                let mut out = Vec::with_capacity(list.len() + 1);
                out.push(ty);
                out.extend_from_slice(&list);
                out
            }
        }
    }

    /// The exact bytes whose Keccak-256 is signed.
    pub fn signing_payload(&self) -> Vec<u8> {
        let list = rlp::list_with(|p| {
            self.encode_body(p);
            if let Transaction::Legacy(TxLegacy {
                chain_id: Some(id), ..
            }) = self
            {
                rlp::encode_u64(p, *id);
                rlp::encode_u64(p, 0);
                rlp::encode_u64(p, 0);
            }
        });
        self.with_type_byte(list)
    }

    /// Keccak-256 of [`Self::signing_payload`].
    pub fn signing_hash(&self) -> [u8; 32] {
        keccak256(&self.signing_payload())
    }

    /// The network encoding with `signature` attached.
    pub fn encode_signed(&self, signature: &Signature) -> Vec<u8> {
        let list = rlp::list_with(|p| {
            self.encode_body(p);
            match self {
                Transaction::Legacy(t) => {
                    let parity = u128::from(signature.y_parity);
                    let v = match t.chain_id {
                        Some(id) => u128::from(id) * 2 + 35 + parity,
                        None => 27 + parity,
                    };
                    rlp::encode_u128(p, v);
                }
                _ => rlp::encode_u64(p, u64::from(signature.y_parity)),
            }
            rlp::encode_u256(p, &signature.r);
            rlp::encode_u256(p, &signature.s);
        });
        self.with_type_byte(list)
    }

    /// Signs with `key` (RFC 6979, low-s).
    pub fn sign(self, key: &PrivateKey) -> Result<SignedTransaction, SignatureError> {
        let signature = key.sign_hash(&self.signing_hash())?;
        Ok(SignedTransaction {
            tx: self,
            signature,
        })
    }

    /// Address of the contract a creation transaction from `sender` would deploy.
    pub fn created_address(&self, sender: &Address) -> Option<Address> {
        match self.kind() {
            TxKind::Create => Some(Address::create(sender, self.nonce())),
            TxKind::Call(_) => None,
        }
    }
}

/// A transaction together with its signature.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignedTransaction {
    /// The unsigned fields.
    pub tx: Transaction,
    /// The signature.
    pub signature: Signature,
}

fn typed_parity(d: &mut ListDecoder<'_>) -> Result<bool, TxError> {
    match d.u8()? {
        0 => Ok(false),
        1 => Ok(true),
        other => Err(TxError::InvalidParity(other)),
    }
}

impl SignedTransaction {
    /// The raw network encoding (what `eth_sendRawTransaction` takes).
    pub fn encoded(&self) -> Vec<u8> {
        self.tx.encode_signed(&self.signature)
    }

    /// Transaction hash: Keccak-256 of the raw encoding.
    pub fn hash(&self) -> [u8; 32] {
        keccak256(&self.encoded())
    }

    /// Recovers the sender. Fails on high-s or out-of-range signatures.
    pub fn recover_signer(&self) -> Result<Address, SignatureError> {
        self.signature.recover_address(&self.tx.signing_hash())
    }

    /// Strictly decodes a raw signed transaction (legacy or typed 0x01 / 0x02 / 0x04).
    pub fn decode(raw: &[u8]) -> Result<Self, TxError> {
        let first = *raw.first().ok_or(TxError::Empty)?;
        match first {
            0xc0..=0xff => Self::decode_legacy(raw),
            0x01 | 0x02 | 0x04 => Self::decode_typed(first, &raw[1..]),
            other => Err(TxError::UnsupportedType(other)),
        }
    }

    fn decode_legacy(raw: &[u8]) -> Result<Self, TxError> {
        let mut d = ListDecoder::from_exact(raw)?;
        let nonce = d.u64()?;
        let gas_price = d.u128()?;
        let gas_limit = d.u64()?;
        let to = TxKind::decode(&mut d)?;
        let value = d.u256()?;
        let input = d.bytes()?.to_vec();
        let v = d.u128()?;
        let r = d.u256()?;
        let s = d.u256()?;
        d.finish()?;
        let (chain_id, y_parity) = match v {
            27 | 28 => (None, v == 28),
            35.. => {
                let id = u64::try_from((v - 35) / 2).map_err(|_| TxError::ChainIdOverflow)?;
                (Some(id), (v - 35) % 2 == 1)
            }
            other => return Err(TxError::InvalidV(other)),
        };
        Ok(Self {
            tx: Transaction::Legacy(TxLegacy {
                chain_id,
                nonce,
                gas_price,
                gas_limit,
                to,
                value,
                input,
            }),
            signature: Signature { r, s, y_parity },
        })
    }

    fn decode_typed(ty: u8, body: &[u8]) -> Result<Self, TxError> {
        let mut d = ListDecoder::from_exact(body)?;
        let tx = match ty {
            0x01 => Transaction::Eip2930(TxEip2930 {
                chain_id: d.u64()?,
                nonce: d.u64()?,
                gas_price: d.u128()?,
                gas_limit: d.u64()?,
                to: TxKind::decode(&mut d)?,
                value: d.u256()?,
                input: d.bytes()?.to_vec(),
                access_list: decode_access_list(&mut d)?,
            }),
            0x02 => Transaction::Eip1559(TxEip1559 {
                chain_id: d.u64()?,
                nonce: d.u64()?,
                max_priority_fee_per_gas: d.u128()?,
                max_fee_per_gas: d.u128()?,
                gas_limit: d.u64()?,
                to: TxKind::decode(&mut d)?,
                value: d.u256()?,
                input: d.bytes()?.to_vec(),
                access_list: decode_access_list(&mut d)?,
            }),
            _ => {
                let chain_id = d.u64()?;
                let nonce = d.u64()?;
                let max_priority_fee_per_gas = d.u128()?;
                let max_fee_per_gas = d.u128()?;
                let gas_limit = d.u64()?;
                let to = match TxKind::decode(&mut d)? {
                    TxKind::Call(a) => a,
                    TxKind::Create => return Err(TxError::CreateNotAllowed),
                };
                Transaction::Eip7702(TxEip7702 {
                    chain_id,
                    nonce,
                    max_priority_fee_per_gas,
                    max_fee_per_gas,
                    gas_limit,
                    to,
                    value: d.u256()?,
                    input: d.bytes()?.to_vec(),
                    access_list: decode_access_list(&mut d)?,
                    authorization_list: decode_authorization_list(&mut d)?,
                })
            }
        };
        let y_parity = typed_parity(&mut d)?;
        let r = d.u256()?;
        let s = d.u256()?;
        d.finish()?;
        Ok(Self {
            tx,
            signature: Signature { r, s, y_parity },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hex;

    #[test]
    fn eip155_specification_example() {
        // The worked example from the EIP-155 specification.
        let tx = Transaction::Legacy(TxLegacy {
            chain_id: Some(1),
            nonce: 9,
            gas_price: 20_000_000_000,
            gas_limit: 21_000,
            to: TxKind::Call(Address([0x35; 20])),
            value: U256::from_u128(1_000_000_000_000_000_000),
            input: Vec::new(),
        });
        assert_eq!(
            hex::encode(&tx.signing_payload()),
            "ec098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a764000080018080"
        );
        assert_eq!(
            hex::encode(&tx.signing_hash()),
            "daf5a779ae972f972197303d7b574746c7ef83eadac0f2791ad23db92e4c8e53"
        );
        let key = PrivateKey::from_bytes(&[0x46; 32]).unwrap();
        let signed = tx.sign(&key).unwrap();
        assert_eq!(
            hex::encode(&signed.encoded()),
            "f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83"
        );
        let decoded = SignedTransaction::decode(&signed.encoded()).unwrap();
        assert_eq!(decoded, signed);
        assert_eq!(decoded.recover_signer().unwrap(), key.address());
    }

    #[test]
    fn decode_rejects_malformed_envelopes() {
        assert_eq!(SignedTransaction::decode(&[]), Err(TxError::Empty));
        assert_eq!(
            SignedTransaction::decode(&[0x03, 0xc0]),
            Err(TxError::UnsupportedType(0x03))
        );
        assert_eq!(
            SignedTransaction::decode(&[0x7f]),
            Err(TxError::UnsupportedType(0x7f))
        );
        // Legacy with v = 29.
        let legacy = rlp::list_with(|p| {
            for _ in 0..6 {
                rlp::encode_u64(p, 0);
            }
            rlp::encode_u64(p, 29);
            rlp::encode_u64(p, 1);
            rlp::encode_u64(p, 1);
        });
        assert_eq!(
            SignedTransaction::decode(&legacy),
            Err(TxError::InvalidV(29))
        );
        // Legacy with a 3-byte `to`.
        let bad_to = rlp::list_with(|p| {
            for _ in 0..3 {
                rlp::encode_u64(p, 0);
            }
            rlp::encode_bytes(p, &[1, 2, 3]);
            for _ in 0..2 {
                rlp::encode_u64(p, 0);
            }
            rlp::encode_u64(p, 27);
            rlp::encode_u64(p, 1);
            rlp::encode_u64(p, 1);
        });
        assert_eq!(
            SignedTransaction::decode(&bad_to),
            Err(TxError::InvalidTo(3))
        );
    }

    #[test]
    fn legacy_chain_id_overflow() {
        // v encodes a chain id of 2^64.
        let v: u128 = (1u128 << 64) * 2 + 35;
        let legacy = rlp::list_with(|p| {
            for _ in 0..6 {
                rlp::encode_u64(p, 0);
            }
            rlp::encode_u128(p, v);
            rlp::encode_u64(p, 1);
            rlp::encode_u64(p, 1);
        });
        assert_eq!(
            SignedTransaction::decode(&legacy),
            Err(TxError::ChainIdOverflow)
        );
    }

    #[test]
    fn typed_parity_and_create_rules() {
        let tx = Transaction::Eip1559(TxEip1559 {
            chain_id: 1,
            nonce: 0,
            max_priority_fee_per_gas: 1,
            max_fee_per_gas: 2,
            gas_limit: 21_000,
            to: TxKind::Create,
            value: U256::ZERO,
            input: Vec::new(),
            access_list: Vec::new(),
        });
        let sig = Signature {
            r: U256::ONE,
            s: U256::ONE,
            y_parity: true,
        };
        let mut raw = tx.encode_signed(&sig);
        // y_parity is the third-from-last item; it is the single byte 0x01 before r and s.
        let pos = raw.len() - 3;
        assert_eq!(raw[pos], 0x01);
        raw[pos] = 0x02;
        assert_eq!(
            SignedTransaction::decode(&raw),
            Err(TxError::InvalidParity(2))
        );
        // A type-4 payload whose destination is empty.
        let body = rlp::list_with(|p| {
            for _ in 0..5 {
                rlp::encode_u64(p, 1);
            }
            rlp::encode_bytes(p, &[]);
        });
        let mut raw7702 = alloc::vec![0x04];
        raw7702.extend_from_slice(&body);
        assert_eq!(
            SignedTransaction::decode(&raw7702),
            Err(TxError::CreateNotAllowed)
        );
        assert_eq!(alloc::format!("{}", TxType::Eip7702), "EIP-7702");
        assert_eq!(TxType::Legacy.type_byte(), None);
    }
}
