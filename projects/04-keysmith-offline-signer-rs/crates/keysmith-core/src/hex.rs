// SPDX-License-Identifier: MIT
//! Hexadecimal encoding and decoding.
//!
//! Decoding accepts an optional `0x`/`0X` prefix and either case. Errors report positions and
//! lengths only, never the offending characters, so a mistyped private key is not echoed back.

use alloc::string::String;
use alloc::vec::Vec;

const ALPHABET: &[u8; 16] = b"0123456789abcdef";

/// Errors produced while decoding hexadecimal text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum HexError {
    /// The number of hex digits (after the optional prefix) is odd.
    #[error("odd number of hex digits ({len})")]
    OddLength {
        /// Number of digits seen.
        len: usize,
    },
    /// A character that is not a hex digit was found.
    #[error("invalid hex character at position {index}")]
    InvalidChar {
        /// Zero-based position of the character, counted after the prefix.
        index: usize,
    },
    /// The decoded value has the wrong number of bytes.
    #[error("expected {expected} bytes, got {got}")]
    WrongLength {
        /// Required length in bytes.
        expected: usize,
        /// Decoded length in bytes.
        got: usize,
    },
}

/// Encodes bytes as lowercase hex without a prefix.
pub fn encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(char::from(ALPHABET[usize::from(b >> 4)]));
        out.push(char::from(ALPHABET[usize::from(b & 0x0f)]));
    }
    out
}

/// Encodes bytes as lowercase hex with a `0x` prefix.
pub fn encode_prefixed(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(2 + bytes.len() * 2);
    out.push_str("0x");
    out.push_str(&encode(bytes));
    out
}

/// Strips an optional `0x` / `0X` prefix.
pub fn strip_prefix(s: &str) -> &str {
    s.strip_prefix("0x")
        .or_else(|| s.strip_prefix("0X"))
        .unwrap_or(s)
}

const fn nibble(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

/// Decodes hex text (optional `0x` prefix) into bytes.
pub fn decode(s: &str) -> Result<Vec<u8>, HexError> {
    let digits = strip_prefix(s).as_bytes();
    if !digits.len().is_multiple_of(2) {
        return Err(HexError::OddLength { len: digits.len() });
    }
    let mut out = Vec::with_capacity(digits.len() / 2);
    for (i, pair) in digits.as_chunks::<2>().0.iter().enumerate() {
        let hi = nibble(pair[0]).ok_or(HexError::InvalidChar { index: 2 * i })?;
        let lo = nibble(pair[1]).ok_or(HexError::InvalidChar { index: 2 * i + 1 })?;
        out.push((hi << 4) | lo);
    }
    Ok(out)
}

/// Decodes hex text into a fixed-size array, rejecting any other length.
pub fn decode_array<const N: usize>(s: &str) -> Result<[u8; N], HexError> {
    let bytes = decode(s)?;
    <[u8; N]>::try_from(bytes.as_slice()).map_err(|_| HexError::WrongLength {
        expected: N,
        got: bytes.len(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_prefixes() {
        assert_eq!(encode(&[0x00, 0xab, 0xff]), "00abff");
        assert_eq!(encode_prefixed(&[]), "0x");
        assert_eq!(decode("0x00AbfF").unwrap(), [0x00, 0xab, 0xff]);
        assert_eq!(decode("0X01").unwrap(), [0x01]);
        assert_eq!(decode("").unwrap(), [0u8; 0]);
        assert_eq!(decode_array::<2>("0x0102").unwrap(), [1, 2]);
    }

    #[test]
    fn rejects_bad_input_without_echoing_it() {
        assert_eq!(decode("0x123"), Err(HexError::OddLength { len: 3 }));
        assert_eq!(decode("0x12zz"), Err(HexError::InvalidChar { index: 2 }));
        assert_eq!(decode("0x1g"), Err(HexError::InvalidChar { index: 1 }));
        assert_eq!(
            decode_array::<2>("0x010203"),
            Err(HexError::WrongLength {
                expected: 2,
                got: 3
            })
        );
        let msg = alloc::format!("{}", decode("0xsecretzz").unwrap_err());
        assert!(!msg.contains("secret"));
    }
}
