// SPDX-License-Identifier: MIT
//! EIP-7702 set-code authorizations.
//!
//! An authorization tuple `(chain_id, address, nonce)` lets an EOA delegate its code to
//! `address`. It is signed over `keccak256(0x05 || rlp([chain_id, address, nonce]))` and carried
//! in the `authorization_list` of a type-4 transaction as
//! `rlp([chain_id, address, nonce, y_parity, r, s])`.
//!
//! Two sharp edges are handled explicitly:
//!
//! * **`chain_id = 0`** makes the delegation valid on *every* chain. [`Authorization::is_any_chain`]
//!   lets callers warn, and the policy engine can forbid it.
//! * **Self-execution.** When the authority also sends the type-4 transaction, the sender's
//!   nonce is incremented *before* the authorization list is processed, so the authorization
//!   must carry `account_nonce + 1` ([`Executor::SelfExecuting`]).

use crate::address::Address;
use crate::hash::keccak256;
use crate::keys::{PrivateKey, Signature, SignatureError};
use crate::quantity::u64_str;
use crate::rlp::{self, Item, ListDecoder, RlpError};
use crate::u256::U256;
use alloc::vec::Vec;

/// The EIP-7702 signing-domain magic byte.
pub const MAGIC: u8 = 0x05;

/// Who will submit the type-4 transaction carrying the authorization.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Executor {
    /// Another account (a sponsor / relayer) sends the transaction: nonce = current nonce.
    Sponsor,
    /// The authority sends the transaction itself: nonce = current nonce + 1.
    #[serde(rename = "self")]
    SelfExecuting,
}

impl Executor {
    /// The nonce the authorization must carry, given the authority's current account nonce.
    ///
    /// Returns `None` if `account_nonce + 1` overflows (EIP-2681 caps nonces at `2^64 - 2`).
    pub fn authorization_nonce(self, account_nonce: u64) -> Option<u64> {
        match self {
            Executor::Sponsor => Some(account_nonce),
            Executor::SelfExecuting => account_nonce.checked_add(1),
        }
    }
}

/// An unsigned authorization tuple.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Authorization {
    /// Chain the delegation is valid on (`0` = every chain).
    pub chain_id: U256,
    /// Contract whose code the authority delegates to.
    pub address: Address,
    /// The authority's nonce at the time the authorization is processed.
    #[serde(with = "u64_str")]
    pub nonce: u64,
}

impl Authorization {
    fn encode_fields(&self, out: &mut Vec<u8>) {
        rlp::encode_u256(out, &self.chain_id);
        rlp::encode_bytes(out, &self.address.0);
        rlp::encode_u64(out, self.nonce);
    }

    /// `keccak256(0x05 || rlp([chain_id, address, nonce]))`.
    pub fn signing_hash(&self) -> [u8; 32] {
        let mut buf = alloc::vec![MAGIC];
        buf.extend_from_slice(&rlp::list_with(|p| self.encode_fields(p)));
        keccak256(&buf)
    }

    /// `true` when `chain_id == 0`, i.e. the delegation can be replayed on any chain.
    pub fn is_any_chain(&self) -> bool {
        self.chain_id.is_zero()
    }

    /// Signs the tuple (low-s).
    pub fn sign(self, key: &PrivateKey) -> Result<SignedAuthorization, SignatureError> {
        let sig = key.sign_hash(&self.signing_hash())?;
        Ok(SignedAuthorization {
            chain_id: self.chain_id,
            address: self.address,
            nonce: self.nonce,
            y_parity: u8::from(sig.y_parity),
            r: sig.r,
            s: sig.s,
        })
    }
}

/// A signed authorization as it appears in a type-4 transaction.
///
/// `y_parity` is kept as a raw byte (the wire format allows any `u8`); validity is checked at
/// recovery time, as the EVM does, so decoding never rejects what a node would accept on the wire.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SignedAuthorization {
    /// Chain the delegation is valid on (`0` = every chain).
    pub chain_id: U256,
    /// Delegation target.
    pub address: Address,
    /// Authority nonce.
    #[serde(with = "u64_str")]
    pub nonce: u64,
    /// Signature y-parity (valid values: 0 or 1).
    #[serde(with = "crate::quantity::u8_str")]
    pub y_parity: u8,
    /// Signature `r`.
    pub r: U256,
    /// Signature `s`.
    pub s: U256,
}

impl SignedAuthorization {
    /// The unsigned tuple.
    pub fn authorization(&self) -> Authorization {
        Authorization {
            chain_id: self.chain_id,
            address: self.address,
            nonce: self.nonce,
        }
    }

    pub(crate) fn encode_into(&self, out: &mut Vec<u8>) {
        let payload = {
            let mut p = Vec::new();
            self.authorization().encode_fields(&mut p);
            rlp::encode_u64(&mut p, u64::from(self.y_parity));
            rlp::encode_u256(&mut p, &self.r);
            rlp::encode_u256(&mut p, &self.s);
            p
        };
        rlp::encode_list(out, &payload);
    }

    /// `rlp([chain_id, address, nonce, y_parity, r, s])` (the format `cast wallet sign-auth` prints).
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        self.encode_into(&mut out);
        out
    }

    fn from_fields(mut d: ListDecoder<'_>) -> Result<Self, RlpError> {
        let auth = Self {
            chain_id: d.u256()?,
            address: Address(d.fixed::<20>()?),
            nonce: d.u64()?,
            y_parity: d.u8()?,
            r: d.u256()?,
            s: d.u256()?,
        };
        d.finish()?;
        Ok(auth)
    }

    pub(crate) fn decode_from(list: &mut ListDecoder<'_>) -> Result<Self, RlpError> {
        Self::from_fields(list.list()?)
    }

    /// Strictly decodes a standalone RLP-encoded signed authorization.
    pub fn decode(bytes: &[u8]) -> Result<Self, RlpError> {
        match rlp::decode_exact(bytes)? {
            Item::List(payload) => Self::from_fields(ListDecoder::new(payload)),
            Item::String(_) => Err(RlpError::ExpectedList),
        }
    }

    /// The signature, if `y_parity` is 0 or 1.
    pub fn signature(&self) -> Result<Signature, SignatureError> {
        let y_parity = match self.y_parity {
            0 => false,
            1 => true,
            other => return Err(SignatureError::InvalidParity(u64::from(other))),
        };
        Ok(Signature {
            r: self.r,
            s: self.s,
            y_parity,
        })
    }

    /// Recovers the authority (the delegating EOA). Rejects high-s and bad parity, as EIP-7702
    /// requires.
    pub fn recover_authority(&self) -> Result<Address, SignatureError> {
        self.signature()?
            .recover_address(&self.authorization().signing_hash())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hex;

    fn key() -> PrivateKey {
        PrivateKey::from_hex("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
            .unwrap()
    }

    #[test]
    fn nonce_rule() {
        assert_eq!(Executor::Sponsor.authorization_nonce(7), Some(7));
        assert_eq!(Executor::SelfExecuting.authorization_nonce(7), Some(8));
        assert_eq!(Executor::SelfExecuting.authorization_nonce(u64::MAX), None);
    }

    #[test]
    fn sign_encode_decode_recover() {
        let auth = Authorization {
            chain_id: U256::ONE,
            address: Address::parse("0x5FbDB2315678afecb367f032d93F642f64180aa3").unwrap(),
            nonce: 5,
        };
        assert!(!auth.is_any_chain());
        let signed = auth.clone().sign(&key()).unwrap();
        // Matches `cast wallet sign-auth 0x5FbDB... --nonce 5 --chain 1` with anvil key 0.
        assert_eq!(
            hex::encode_prefixed(&signed.encode()),
            "0xf85a01945fbdb2315678afecb367f032d93f642f64180aa30501a06e0089c7283c53da6377df27399347d3578ff4276431e323f1d897a39e40f22ba01608b9af83e8953b993de8a64a9274eb7183f687048a0e0155cc267d93d73abe"
        );
        let decoded = SignedAuthorization::decode(&signed.encode()).unwrap();
        assert_eq!(decoded, signed);
        assert_eq!(decoded.recover_authority().unwrap(), key().address());
        let mut bad = signed.clone();
        bad.y_parity = 2;
        assert_eq!(
            bad.recover_authority(),
            Err(SignatureError::InvalidParity(2))
        );
        let mut trailing = signed.encode();
        trailing.push(0x80);
        assert_eq!(
            SignedAuthorization::decode(&trailing),
            Err(RlpError::TrailingBytes { count: 1 })
        );
        assert_eq!(
            SignedAuthorization::decode(&[0x80]),
            Err(RlpError::ExpectedList)
        );
        assert!(
            Authorization {
                chain_id: U256::ZERO,
                ..auth
            }
            .is_any_chain()
        );
    }
}
