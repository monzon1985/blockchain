// SPDX-License-Identifier: MIT
//! 20-byte Ethereum addresses with EIP-55 mixed-case checksums.

use crate::hash::keccak256;
use crate::hex::{self, HexError};
use crate::rlp;
use alloc::string::String;
use core::fmt;

/// A 20-byte account address.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Default)]
pub struct Address(pub [u8; 20]);

/// Errors produced when parsing an address.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum AddressError {
    /// The text is not valid hex.
    #[error("invalid address hex: {0}")]
    Hex(#[from] HexError),
    /// The value is not 20 bytes long.
    #[error("address must be 20 bytes, got {0}")]
    WrongLength(usize),
    /// The text is mixed-case but does not match its EIP-55 checksum.
    #[error("mixed-case address fails its EIP-55 checksum (typo?)")]
    BadChecksum,
}

impl Address {
    /// The zero address.
    pub const ZERO: Self = Self([0; 20]);

    /// Address of an uncompressed SEC1 public key: the last 20 bytes of `keccak256(x || y)`.
    pub fn from_public_key(key: &k256::PublicKey) -> Self {
        use k256::elliptic_curve::sec1::ToEncodedPoint;
        let point = key.to_encoded_point(false);
        // An uncompressed SEC1 point is 0x04 || x || y (65 bytes).
        let hash = keccak256(&point.as_bytes()[1..]);
        let mut out = [0u8; 20];
        out.copy_from_slice(&hash[12..]);
        Self(out)
    }

    /// Address of a contract created by `sender` with account nonce `nonce` (CREATE).
    pub fn create(sender: &Address, nonce: u64) -> Self {
        let encoded = rlp::list_with(|p| {
            rlp::encode_bytes(p, &sender.0);
            rlp::encode_u64(p, nonce);
        });
        let hash = keccak256(&encoded);
        let mut out = [0u8; 20];
        out.copy_from_slice(&hash[12..]);
        Self(out)
    }

    /// Parses `0x`-prefixed (or bare) hex. All-lowercase and all-uppercase inputs are accepted;
    /// mixed-case inputs must carry a valid EIP-55 checksum.
    pub fn parse(s: &str) -> Result<Self, AddressError> {
        let digits = hex::strip_prefix(s);
        let bytes = hex::decode(digits)?;
        let arr: [u8; 20] = bytes
            .as_slice()
            .try_into()
            .map_err(|_| AddressError::WrongLength(bytes.len()))?;
        let addr = Self(arr);
        let has_lower = digits.bytes().any(|c| c.is_ascii_lowercase());
        let has_upper = digits.bytes().any(|c| c.is_ascii_uppercase());
        if has_lower && has_upper && addr.to_checksum()[2..] != *digits {
            return Err(AddressError::BadChecksum);
        }
        Ok(addr)
    }

    /// EIP-55 checksummed representation with `0x` prefix.
    pub fn to_checksum(&self) -> String {
        let lower = hex::encode(&self.0);
        let hash = keccak256(lower.as_bytes());
        let mut out = String::with_capacity(42);
        out.push_str("0x");
        for (i, c) in lower.chars().enumerate() {
            let nibble = if i % 2 == 0 {
                hash[i / 2] >> 4
            } else {
                hash[i / 2] & 0x0f
            };
            if c.is_ascii_alphabetic() && nibble >= 8 {
                out.push(c.to_ascii_uppercase());
            } else {
                out.push(c);
            }
        }
        out
    }
}

impl fmt::Display for Address {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.to_checksum())
    }
}

impl fmt::Debug for Address {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.to_checksum())
    }
}

impl core::str::FromStr for Address {
    type Err = AddressError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse(s)
    }
}

impl serde::Serialize for Address {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_checksum())
    }
}

impl<'de> serde::Deserialize<'de> for Address {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = <String as serde::Deserialize>::deserialize(d)?;
        Self::parse(&s).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eip55_examples() {
        // Test cases from the EIP-55 specification.
        for s in [
            "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
            "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
            "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
            "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
            "0x52908400098527886E0F7030069857D2E4169EE7",
            "0x8617E340B3D01FA5F11F306F4090FD50E238070D",
            "0xde709f2102306220921060314715629080e2fb77",
            "0x27b1fdb04752bbc536007a920d24acb045561c26",
        ] {
            // Every example, including the all-caps and all-lowercase ones, is its own
            // canonical checksummed form.
            assert_eq!(Address::parse(s).unwrap().to_checksum(), s);
        }
    }

    #[test]
    fn rejects_bad_checksum_and_length() {
        assert_eq!(
            Address::parse("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD"),
            Err(AddressError::BadChecksum)
        );
        assert_eq!(Address::parse("0x1234"), Err(AddressError::WrongLength(2)));
        assert!(Address::parse("0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed").is_ok());
        assert!(Address::parse("5AAEB6053F3E94C9B9A09F33669435E7EF1BEAED").is_ok());
    }

    #[test]
    fn create_address_matches_known_deployment() {
        // anvil account 0 deploying its first contract.
        let sender = Address::parse("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266").unwrap();
        assert_eq!(
            Address::create(&sender, 0).to_checksum(),
            "0x5FbDB2315678afecb367f032d93F642f64180aa3"
        );
    }
}
