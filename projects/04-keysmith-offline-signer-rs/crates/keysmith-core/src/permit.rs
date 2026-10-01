// SPDX-License-Identifier: MIT
//! ERC-2612 `permit` helper.
//!
//! Computes the EIP-712 digest for
//! `Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)` under the
//! OpenZeppelin `ERC20Permit` domain `EIP712Domain(string name,string version,uint256 chainId,
//! address verifyingContract)`, signs it and returns `(v, r, s)` ready for `permit(...)`.
//!
//! The digest is computed directly from the type hashes; [`Permit::to_typed_data`] produces the
//! equivalent `eth_signTypedData_v4` JSON, and tests assert both paths agree.

use crate::address::Address;
use crate::eip712::{Eip712Error, TypedData};
use crate::hash::{keccak256, keccak256_concat};
use crate::keys::{PrivateKey, Signature, SignatureError};
use crate::u256::U256;
use alloc::string::String;

/// `keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")`.
pub const DOMAIN_TYPEHASH: [u8; 32] =
    hex32(b"8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f");

/// `keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")`.
pub const PERMIT_TYPEHASH: [u8; 32] =
    hex32(b"6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9");

const fn hex32(s: &[u8; 64]) -> [u8; 32] {
    const fn nib(c: u8) -> u8 {
        match c {
            b'0'..=b'9' => c - b'0',
            b'a'..=b'f' => c - b'a' + 10,
            _ => 0,
        }
    }
    let mut out = [0u8; 32];
    let mut i = 0;
    while i < 32 {
        out[i] = (nib(s[2 * i]) << 4) | nib(s[2 * i + 1]);
        i += 1;
    }
    out
}

/// An ERC-2612 permit request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Permit {
    /// Token `name()` (EIP-712 domain name).
    pub token_name: String,
    /// EIP-712 domain version (`"1"` for OpenZeppelin tokens).
    pub token_version: String,
    /// Chain id of the token deployment.
    pub chain_id: U256,
    /// Token contract (EIP-712 `verifyingContract`).
    pub token: Address,
    /// Token holder granting the allowance (must be the signer).
    pub owner: Address,
    /// Account receiving the allowance.
    pub spender: Address,
    /// Allowance amount in token base units.
    pub value: U256,
    /// Current `nonces(owner)` of the token.
    pub nonce: U256,
    /// Unix timestamp after which the permit is invalid.
    pub deadline: U256,
}

fn word(a: &Address) -> [u8; 32] {
    let mut out = [0u8; 32];
    out[12..].copy_from_slice(&a.0);
    out
}

/// A signed permit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SignedPermit {
    /// The EIP-712 digest that was signed.
    pub digest: [u8; 32],
    /// The signature (`v = 27 + y_parity` when passed to Solidity).
    pub signature: Signature,
}

impl SignedPermit {
    /// The `v` argument of `permit(...)`.
    pub fn v(&self) -> u8 {
        27 + u8::from(self.signature.y_parity)
    }
}

impl Permit {
    /// The token's EIP-712 domain separator.
    pub fn domain_separator(&self) -> [u8; 32] {
        keccak256_concat(&[
            &DOMAIN_TYPEHASH,
            &keccak256(self.token_name.as_bytes()),
            &keccak256(self.token_version.as_bytes()),
            &self.chain_id.to_be_bytes(),
            &word(&self.token),
        ])
    }

    /// `hashStruct(Permit)`.
    pub fn struct_hash(&self) -> [u8; 32] {
        keccak256_concat(&[
            &PERMIT_TYPEHASH,
            &word(&self.owner),
            &word(&self.spender),
            &self.value.to_be_bytes(),
            &self.nonce.to_be_bytes(),
            &self.deadline.to_be_bytes(),
        ])
    }

    /// The EIP-712 digest.
    pub fn signing_hash(&self) -> [u8; 32] {
        keccak256_concat(&[&[0x19, 0x01], &self.domain_separator(), &self.struct_hash()])
    }

    /// Equivalent `eth_signTypedData_v4` JSON (what a wallet would be asked to sign).
    pub fn to_typed_data(&self) -> serde_json::Value {
        serde_json::json!({
            "types": {
                "EIP712Domain": [
                    {"name": "name", "type": "string"},
                    {"name": "version", "type": "string"},
                    {"name": "chainId", "type": "uint256"},
                    {"name": "verifyingContract", "type": "address"}
                ],
                "Permit": [
                    {"name": "owner", "type": "address"},
                    {"name": "spender", "type": "address"},
                    {"name": "value", "type": "uint256"},
                    {"name": "nonce", "type": "uint256"},
                    {"name": "deadline", "type": "uint256"}
                ]
            },
            "primaryType": "Permit",
            "domain": {
                "name": self.token_name,
                "version": self.token_version,
                "chainId": alloc::format!("{}", self.chain_id),
                "verifyingContract": self.token.to_checksum()
            },
            "message": {
                "owner": self.owner.to_checksum(),
                "spender": self.spender.to_checksum(),
                "value": alloc::format!("{}", self.value),
                "nonce": alloc::format!("{}", self.nonce),
                "deadline": alloc::format!("{}", self.deadline)
            }
        })
    }

    /// Parses [`Self::to_typed_data`] with the generic EIP-712 engine.
    pub fn typed_data(&self) -> Result<TypedData, Eip712Error> {
        TypedData::from_value(&self.to_typed_data())
    }

    /// Signs the permit. Fails with [`PermitError::OwnerMismatch`] if `key` is not the owner.
    pub fn sign(&self, key: &PrivateKey) -> Result<SignedPermit, PermitError> {
        let signer = key.address();
        if signer != self.owner {
            return Err(PermitError::OwnerMismatch {
                owner: self.owner,
                signer,
            });
        }
        let digest = self.signing_hash();
        let signature = key.sign_hash(&digest)?;
        Ok(SignedPermit { digest, signature })
    }
}

/// Errors produced by [`Permit::sign`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum PermitError {
    /// The signing key is not the permit owner (the token would reject the signature).
    #[error("permit owner {owner} is not the signing key's address {signer}")]
    OwnerMismatch {
        /// Declared owner.
        owner: Address,
        /// Address of the signing key.
        signer: Address,
    },
    /// Signing failed.
    #[error(transparent)]
    Signature(#[from] SignatureError),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn typehash_constants_match_their_strings() {
        assert_eq!(
            DOMAIN_TYPEHASH,
            keccak256(b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
        );
        assert_eq!(
            PERMIT_TYPEHASH,
            keccak256(b"Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
        );
    }

    #[test]
    fn direct_digest_equals_generic_eip712_and_signs() {
        let key = PrivateKey::from_bytes(&[0x42; 32]).unwrap();
        let permit = Permit {
            token_name: "Keysmith Test Token".into(),
            token_version: "1".into(),
            chain_id: U256::from_u64(31_337),
            token: Address([0xaa; 20]),
            owner: key.address(),
            spender: Address([0xbb; 20]),
            value: U256::MAX,
            nonce: U256::ZERO,
            deadline: U256::from_u64(4_102_444_800),
        };
        let td = permit.typed_data().unwrap();
        assert_eq!(td.signing_hash().unwrap(), permit.signing_hash());
        assert_eq!(td.domain_separator().unwrap(), permit.domain_separator());
        let signed = permit.sign(&key).unwrap();
        assert_eq!(
            signed.signature.recover_address(&signed.digest).unwrap(),
            key.address()
        );
        assert!(signed.v() == 27 || signed.v() == 28);
        let other = PrivateKey::from_bytes(&[0x43; 32]).unwrap();
        assert!(matches!(
            permit.sign(&other),
            Err(PermitError::OwnerMismatch { .. })
        ));
    }
}
