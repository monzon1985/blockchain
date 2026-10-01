// SPDX-License-Identifier: MIT
//! Base58 and Base58Check (Bitcoin alphabet), used for BIP-32 extended keys.
//!
//! Extended private keys pass through here, so every intermediate buffer is zeroised and
//! decoded output is returned in a [`Zeroizing`] container.

use crate::hash::sha256;
use alloc::string::String;
use alloc::vec::Vec;
use zeroize::{Zeroize, Zeroizing};

const ALPHABET: &[u8; 58] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// Errors produced by Base58 / Base58Check decoding.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum Base58Error {
    /// A character outside the Base58 alphabet.
    #[error("invalid base58 character at position {index}")]
    InvalidChar {
        /// Zero-based character position.
        index: usize,
    },
    /// The payload is shorter than the 4-byte checksum.
    #[error("base58check payload too short")]
    TooShort,
    /// The trailing 4 bytes do not match `SHA256(SHA256(payload))[..4]`.
    #[error("base58check checksum mismatch")]
    BadChecksum,
}

fn checksum(payload: &[u8]) -> [u8; 4] {
    let h = sha256(&sha256(payload));
    [h[0], h[1], h[2], h[3]]
}

/// Encodes bytes as Base58.
pub fn encode(data: &[u8]) -> String {
    let zeros = data.iter().take_while(|b| **b == 0).count();
    // Little-endian base-58 digits; log(256)/log(58) < 1.37.
    let mut digits: Vec<u8> = Vec::with_capacity(data.len() * 137 / 100 + 1);
    for byte in &data[zeros..] {
        let mut carry = u32::from(*byte);
        for d in digits.iter_mut() {
            carry += u32::from(*d) << 8;
            // carry % 58 < 58, so the cast is exact.
            *d = (carry % 58) as u8;
            carry /= 58;
        }
        while carry > 0 {
            digits.push((carry % 58) as u8);
            carry /= 58;
        }
    }
    let mut out = String::with_capacity(zeros + digits.len());
    out.extend(core::iter::repeat_n('1', zeros));
    out.extend(
        digits
            .iter()
            .rev()
            .map(|d| char::from(ALPHABET[usize::from(*d)])),
    );
    digits.zeroize();
    out
}

/// Decodes Base58 text.
pub fn decode(s: &str) -> Result<Zeroizing<Vec<u8>>, Base58Error> {
    let zeros = s.bytes().take_while(|c| *c == b'1').count();
    // Little-endian base-256 accumulator.
    let mut acc: Zeroizing<Vec<u8>> = Zeroizing::new(Vec::with_capacity(s.len()));
    for (index, c) in s.bytes().enumerate() {
        let value = ALPHABET
            .iter()
            .position(|a| *a == c)
            .ok_or(Base58Error::InvalidChar { index })?;
        // value < 58, so the cast is exact.
        let mut carry = value as u32;
        for b in acc.iter_mut() {
            carry += u32::from(*b) * 58;
            *b = (carry & 0xff) as u8;
            carry >>= 8;
        }
        while carry > 0 {
            acc.push((carry & 0xff) as u8);
            carry >>= 8;
        }
    }
    let mut out = Zeroizing::new(Vec::with_capacity(zeros + acc.len()));
    out.extend(core::iter::repeat_n(0u8, zeros));
    out.extend(acc.iter().rev());
    Ok(out)
}

/// Encodes `payload || SHA256d(payload)[..4]` as Base58.
pub fn encode_check(payload: &[u8]) -> String {
    let mut buf = Zeroizing::new(Vec::with_capacity(payload.len() + 4));
    buf.extend_from_slice(payload);
    buf.extend_from_slice(&checksum(payload));
    encode(&buf)
}

/// Decodes Base58Check text and verifies the checksum, returning the payload.
pub fn decode_check(s: &str) -> Result<Zeroizing<Vec<u8>>, Base58Error> {
    let raw = decode(s)?;
    if raw.len() < 4 {
        return Err(Base58Error::TooShort);
    }
    let (payload, sum) = raw.split_at(raw.len() - 4);
    if checksum(payload) != sum {
        return Err(Base58Error::BadChecksum);
    }
    Ok(Zeroizing::new(payload.to_vec()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hex;

    #[test]
    fn known_encodings() {
        assert_eq!(encode(b""), "");
        assert_eq!(encode(&[0, 0, 1]), "112");
        assert_eq!(encode(b"hello world"), "StV1DL6CwTryKyV");
        assert_eq!(
            decode("StV1DL6CwTryKyV").unwrap().as_slice(),
            b"hello world"
        );
        assert_eq!(decode("112").unwrap().as_slice(), &[0, 0, 1]);
        // Bitcoin genesis coinbase address (version 0x00 + HASH160).
        let payload = hex::decode("0062e907b15cbf27d5425399ebf6f0fb50ebb88f18").unwrap();
        assert_eq!(encode_check(&payload), "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa");
        assert_eq!(
            decode_check("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
                .unwrap()
                .as_slice(),
            payload.as_slice()
        );
    }

    #[test]
    fn rejects_bad_input() {
        assert_eq!(
            decode("0OIl").map(|_| ()),
            Err(Base58Error::InvalidChar { index: 0 })
        );
        assert_eq!(
            decode_check("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb").map(|_| ()),
            Err(Base58Error::BadChecksum)
        );
        assert_eq!(decode_check("2").map(|_| ()), Err(Base58Error::TooShort));
    }
}
