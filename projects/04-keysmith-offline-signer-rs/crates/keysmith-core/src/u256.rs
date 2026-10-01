// SPDX-License-Identifier: MIT
//! A minimal, audit-friendly 256-bit unsigned integer.
//!
//! Only what transaction encoding and fee math need: byte conversions, checked add/sub/mul,
//! comparisons and decimal/hex parsing and printing. Every arithmetic operation is checked;
//! there is no wrapping API. The type is differential-tested against `ruint` (alloy's `U256`).

use alloc::string::String;
use alloc::vec::Vec;
use core::cmp::Ordering;
use core::fmt;

/// 256-bit unsigned integer stored as four little-endian 64-bit limbs.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct U256([u64; 4]);

/// Errors produced when parsing a [`U256`] from text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum ParseU256Error {
    /// The string (after an optional `0x` prefix) is empty.
    #[error("empty number")]
    Empty,
    /// A character is not a digit in the selected radix.
    #[error("invalid digit at position {index}")]
    InvalidDigit {
        /// Zero-based position of the character.
        index: usize,
    },
    /// The value does not fit in 256 bits.
    #[error("number does not fit in 256 bits")]
    Overflow,
}

impl U256 {
    /// Zero.
    pub const ZERO: Self = Self([0; 4]);
    /// One.
    pub const ONE: Self = Self([1, 0, 0, 0]);
    /// 2^256 - 1.
    pub const MAX: Self = Self([u64::MAX; 4]);

    /// Builds a value from little-endian limbs.
    pub const fn from_limbs(limbs: [u64; 4]) -> Self {
        Self(limbs)
    }

    /// Returns the little-endian limbs.
    pub const fn as_limbs(&self) -> &[u64; 4] {
        &self.0
    }

    /// Widens a `u64`.
    pub const fn from_u64(v: u64) -> Self {
        Self([v, 0, 0, 0])
    }

    /// Widens a `u128`.
    pub const fn from_u128(v: u128) -> Self {
        // Truncating casts split the u128 into its two 64-bit halves; nothing is lost.
        Self([v as u64, (v >> 64) as u64, 0, 0])
    }

    /// Interprets 32 big-endian bytes.
    pub fn from_be_bytes(bytes: [u8; 32]) -> Self {
        let mut limbs = [0u64; 4];
        for (limb, chunk) in limbs.iter_mut().zip(bytes.rchunks_exact(8)) {
            let mut word = [0u8; 8];
            word.copy_from_slice(chunk);
            *limb = u64::from_be_bytes(word);
        }
        Self(limbs)
    }

    /// Interprets up to 32 big-endian bytes (shorter inputs are left-padded with zeros).
    pub fn from_be_slice(bytes: &[u8]) -> Option<Self> {
        if bytes.len() > 32 {
            return None;
        }
        let mut buf = [0u8; 32];
        buf[32 - bytes.len()..].copy_from_slice(bytes);
        Some(Self::from_be_bytes(buf))
    }

    /// Returns the 32-byte big-endian representation.
    pub fn to_be_bytes(&self) -> [u8; 32] {
        let mut out = [0u8; 32];
        for (chunk, limb) in out.rchunks_exact_mut(8).zip(self.0.iter()) {
            chunk.copy_from_slice(&limb.to_be_bytes());
        }
        out
    }

    /// Returns the minimal big-endian representation (empty for zero), as RLP requires.
    pub fn to_be_bytes_trimmed(&self) -> Vec<u8> {
        let bytes = self.to_be_bytes();
        let first = bytes.iter().position(|b| *b != 0).unwrap_or(32);
        bytes[first..].to_vec()
    }

    /// `true` if the value is zero.
    pub fn is_zero(&self) -> bool {
        self.0 == [0; 4]
    }

    /// Number of significant bits (0 for zero).
    pub fn bits(&self) -> u32 {
        for (i, limb) in self.0.iter().enumerate().rev() {
            if *limb != 0 {
                // i < 4, so the cast cannot truncate.
                return 64 * (i as u32) + (64 - limb.leading_zeros());
            }
        }
        0
    }

    /// Narrows to `u64` if the value fits.
    pub fn to_u64(&self) -> Option<u64> {
        (self.0[1] == 0 && self.0[2] == 0 && self.0[3] == 0).then_some(self.0[0])
    }

    /// Narrows to `u128` if the value fits.
    pub fn to_u128(&self) -> Option<u128> {
        (self.0[2] == 0 && self.0[3] == 0)
            .then_some((u128::from(self.0[1]) << 64) | u128::from(self.0[0]))
    }

    /// Checked addition.
    pub fn checked_add(&self, rhs: &Self) -> Option<Self> {
        let mut out = [0u64; 4];
        let mut carry = false;
        for (i, slot) in out.iter_mut().enumerate() {
            let (s1, c1) = self.0[i].overflowing_add(rhs.0[i]);
            let (s2, c2) = s1.overflowing_add(u64::from(carry));
            *slot = s2;
            carry = c1 || c2;
        }
        (!carry).then_some(Self(out))
    }

    /// Checked subtraction.
    pub fn checked_sub(&self, rhs: &Self) -> Option<Self> {
        let mut out = [0u64; 4];
        let mut borrow = false;
        for (i, slot) in out.iter_mut().enumerate() {
            let (d1, b1) = self.0[i].overflowing_sub(rhs.0[i]);
            let (d2, b2) = d1.overflowing_sub(u64::from(borrow));
            *slot = d2;
            borrow = b1 || b2;
        }
        (!borrow).then_some(Self(out))
    }

    /// Checked multiplication (schoolbook, 4x4 limbs into an 8-limb accumulator).
    pub fn checked_mul(&self, rhs: &Self) -> Option<Self> {
        let mut acc = [0u64; 8];
        for i in 0..4 {
            let mut carry: u128 = 0;
            for j in 0..4 {
                // (2^64-1)^2 + 2*(2^64-1) = 2^128 - 1, so the u128 sum cannot overflow.
                let t =
                    u128::from(self.0[i]) * u128::from(rhs.0[j]) + u128::from(acc[i + j]) + carry;
                acc[i + j] = t as u64;
                carry = t >> 64;
            }
            acc[i + 4] = carry as u64;
        }
        if acc[4..].iter().any(|limb| *limb != 0) {
            return None;
        }
        Some(Self([acc[0], acc[1], acc[2], acc[3]]))
    }

    /// Divides by a non-zero `u64`, returning quotient and remainder.
    ///
    /// Returns `None` when `divisor` is zero.
    pub fn div_rem_u64(&self, divisor: u64) -> Option<(Self, u64)> {
        if divisor == 0 {
            return None;
        }
        let d = u128::from(divisor);
        let mut quotient = [0u64; 4];
        let mut rem: u128 = 0;
        for i in (0..4).rev() {
            let cur = (rem << 64) | u128::from(self.0[i]);
            // rem < d <= 2^64 - 1, so cur / d < 2^64 and the cast is exact.
            quotient[i] = (cur / d) as u64;
            rem = cur % d;
        }
        Some((Self(quotient), rem as u64))
    }

    fn mul_add_small(&self, mul: u64, add: u64) -> Option<Self> {
        self.checked_mul(&Self::from_u64(mul))?
            .checked_add(&Self::from_u64(add))
    }

    /// Parses digits in radix 10 or 16 (no prefix, no sign, no separators).
    pub fn from_str_radix(digits: &str, radix: u32) -> Result<Self, ParseU256Error> {
        if digits.is_empty() {
            return Err(ParseU256Error::Empty);
        }
        let mut acc = Self::ZERO;
        for (index, c) in digits.chars().enumerate() {
            let digit = c
                .to_digit(radix)
                .ok_or(ParseU256Error::InvalidDigit { index })?;
            acc = acc
                .mul_add_small(u64::from(radix), u64::from(digit))
                .ok_or(ParseU256Error::Overflow)?;
        }
        Ok(acc)
    }

    /// Parses `0x`-prefixed hex or plain decimal.
    pub fn parse(s: &str) -> Result<Self, ParseU256Error> {
        match s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
            Some(hex) => Self::from_str_radix(hex, 16),
            None => Self::from_str_radix(s, 10),
        }
    }

    /// Formats as a `0x`-prefixed hex quantity without leading zeros (`0x0` for zero).
    pub fn to_hex_quantity(&self) -> String {
        alloc::format!("{self:#x}")
    }
}

impl Ord for U256 {
    fn cmp(&self, other: &Self) -> Ordering {
        for i in (0..4).rev() {
            match self.0[i].cmp(&other.0[i]) {
                Ordering::Equal => continue,
                ord => return ord,
            }
        }
        Ordering::Equal
    }
}

impl PartialOrd for U256 {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl From<u64> for U256 {
    fn from(v: u64) -> Self {
        Self::from_u64(v)
    }
}

impl From<u128> for U256 {
    fn from(v: u128) -> Self {
        Self::from_u128(v)
    }
}

impl core::str::FromStr for U256 {
    type Err = ParseU256Error;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse(s)
    }
}

impl fmt::Display for U256 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // 2^256 has 78 decimal digits.
        let mut buf = [0u8; 78];
        let mut pos = buf.len();
        let mut n = *self;
        loop {
            let Some((q, r)) = n.div_rem_u64(10) else {
                return Err(fmt::Error);
            };
            pos -= 1;
            // r < 10, so the cast is exact.
            buf[pos] = b'0' + r as u8;
            n = q;
            if n.is_zero() {
                break;
            }
        }
        let s = core::str::from_utf8(&buf[pos..]).map_err(|_| fmt::Error)?;
        f.pad_integral(true, "", s)
    }
}

impl fmt::Debug for U256 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}

impl fmt::LowerHex for U256 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let trimmed = self.to_be_bytes_trimmed();
        let mut s = crate::hex::encode(&trimmed);
        if let Some(stripped) = s.strip_prefix('0') {
            s = String::from(stripped);
        }
        if s.is_empty() {
            s.push('0');
        }
        f.pad_integral(true, "0x", &s)
    }
}

impl serde::Serialize for U256 {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

impl<'de> serde::Deserialize<'de> for U256 {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        crate::quantity::deserialize_u256(deserializer)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::string::ToString;

    #[test]
    fn display_and_parse_extremes() {
        let max = "115792089237316195423570985008687907853269984665640564039457584007913129639935";
        assert_eq!(U256::MAX.to_string(), max);
        assert_eq!(U256::parse(max).unwrap(), U256::MAX);
        assert_eq!(
            U256::parse(
                "115792089237316195423570985008687907853269984665640564039457584007913129639936"
            ),
            Err(ParseU256Error::Overflow)
        );
        assert_eq!(U256::ZERO.to_string(), "0");
        assert_eq!(U256::ZERO.to_hex_quantity(), "0x0");
        assert_eq!(U256::from_u64(0x1ab).to_hex_quantity(), "0x1ab");
        assert_eq!(U256::parse("0x"), Err(ParseU256Error::Empty));
        assert_eq!(
            U256::parse("12a"),
            Err(ParseU256Error::InvalidDigit { index: 2 })
        );
        assert_eq!(U256::from_be_slice(&[0u8; 33]), None);
    }

    #[test]
    fn checked_arithmetic_edges() {
        assert_eq!(U256::MAX.checked_add(&U256::ONE), None);
        assert_eq!(U256::ZERO.checked_sub(&U256::ONE), None);
        assert_eq!(U256::MAX.checked_mul(&U256::from_u64(2)), None);
        assert_eq!(U256::MAX.checked_mul(&U256::ONE), Some(U256::MAX));
        assert_eq!(U256::from_u64(7).div_rem_u64(0), None);
        assert_eq!(
            U256::from_u64(7).div_rem_u64(2),
            Some((U256::from_u64(3), 1))
        );
        assert_eq!(U256::from_u128(u128::MAX).to_u128(), Some(u128::MAX));
        assert_eq!(U256::from_u128(u128::MAX).to_u64(), None);
        assert_eq!(U256::MAX.bits(), 256);
        assert_eq!(U256::ZERO.bits(), 0);
    }
}
