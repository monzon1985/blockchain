// SPDX-License-Identifier: MIT
//! Ether denominations: parse `"1.5ether"` / `"20 gwei"` / `"100"` (wei) and format wei amounts.

use crate::u256::{ParseU256Error, U256};
use alloc::string::String;

/// Errors produced by [`parse_units`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum UnitsError {
    /// The numeric part is malformed or overflows.
    #[error("invalid amount: {0}")]
    Number(#[from] ParseU256Error),
    /// Unknown unit suffix.
    #[error("unknown unit (use wei, gwei or ether)")]
    UnknownUnit,
    /// More fractional digits than the unit allows (sub-wei precision).
    #[error("amount has more decimals than the unit allows")]
    TooPrecise,
}

fn decimals_of(unit: &str) -> Option<usize> {
    match unit {
        "" | "wei" => Some(0),
        "gwei" => Some(9),
        "ether" | "eth" => Some(18),
        _ => None,
    }
}

/// Parses a decimal amount with an optional unit into wei. `0x` hex is accepted without a unit.
pub fn parse_units(s: &str) -> Result<U256, UnitsError> {
    let s = s.trim();
    if s.starts_with("0x") || s.starts_with("0X") {
        return Ok(U256::parse(s)?);
    }
    let split = s
        .find(|c: char| !(c.is_ascii_digit() || c == '.'))
        .unwrap_or(s.len());
    let (number, unit) = s.split_at(split);
    let decimals = decimals_of(&unit.trim().to_ascii_lowercase()).ok_or(UnitsError::UnknownUnit)?;
    let (int_part, frac_part) = match number.split_once('.') {
        Some((i, f)) => (i, f),
        None => (number, ""),
    };
    if frac_part.len() > decimals {
        return Err(UnitsError::TooPrecise);
    }
    let mut digits = String::from(if int_part.is_empty() { "0" } else { int_part });
    digits.push_str(frac_part);
    for _ in frac_part.len()..decimals {
        digits.push('0');
    }
    Ok(U256::from_str_radix(&digits, 10)?)
}

/// Formats `value` with `decimals` fractional digits, trimming trailing zeros (`1.5`, `0`, `12`).
pub fn format_units(value: &U256, decimals: usize) -> String {
    let digits = alloc::format!("{value}");
    if decimals == 0 {
        return digits;
    }
    let mut padded = String::new();
    if digits.len() <= decimals {
        for _ in 0..=(decimals - digits.len()) {
            padded.push('0');
        }
    }
    padded.push_str(&digits);
    let (int_part, frac_part) = padded.split_at(padded.len() - decimals);
    let frac = frac_part.trim_end_matches('0');
    if frac.is_empty() {
        String::from(int_part)
    } else {
        alloc::format!("{int_part}.{frac}")
    }
}

/// Formats wei as ether.
pub fn format_ether(wei: &U256) -> String {
    format_units(wei, 18)
}

/// Formats wei as gwei.
pub fn format_gwei(wei: &U256) -> String {
    format_units(wei, 9)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_and_format() {
        assert_eq!(
            parse_units("1ether").unwrap(),
            U256::from_u128(1_000_000_000_000_000_000)
        );
        assert_eq!(
            parse_units("1.5 ETH").unwrap(),
            U256::from_u128(1_500_000_000_000_000_000)
        );
        assert_eq!(
            parse_units("20gwei").unwrap(),
            U256::from_u64(20_000_000_000)
        );
        assert_eq!(parse_units(".5gwei").unwrap(), U256::from_u64(500_000_000));
        assert_eq!(parse_units("42").unwrap(), U256::from_u64(42));
        assert_eq!(parse_units("0x2a").unwrap(), U256::from_u64(42));
        assert_eq!(parse_units("1.5wei"), Err(UnitsError::TooPrecise));
        assert_eq!(parse_units("1 btc"), Err(UnitsError::UnknownUnit));
        assert!(matches!(
            parse_units("1.2.3ether"),
            Err(UnitsError::Number(_))
        ));
        assert_eq!(
            format_ether(&U256::from_u128(1_500_000_000_000_000_000)),
            "1.5"
        );
        assert_eq!(format_ether(&U256::from_u64(1)), "0.000000000000000001");
        assert_eq!(format_ether(&U256::ZERO), "0");
        assert_eq!(format_gwei(&U256::from_u64(20_000_000_000)), "20");
        assert_eq!(format_units(&U256::from_u64(7), 0), "7");
    }
}
