// SPDX-License-Identifier: MIT
//! Fixed-point primitives with explicit rounding, mirroring `MathLib.sol` and Solady's `fullMulDiv`.

use alloy_primitives::{U256, U512};
use thiserror::Error;

use crate::WAD;

/// Arithmetic failures. Each corresponds to a revert of the Solidity original.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum MathError {
    /// A 256-bit product or sum overflowed (Solidity: `Panic(0x11)` or Solady `MulDivFailed`).
    #[error("arithmetic overflow")]
    Overflow,
    /// Division by zero (Solidity: `Panic(0x12)` or Solady `FullMulDivFailed`).
    #[error("division by zero")]
    DivisionByZero,
    /// A value does not fit in `uint128` (OpenZeppelin `SafeCast.toUint128`).
    #[error("value does not fit in uint128")]
    Uint128Overflow,
}

/// Result alias for this module.
pub type MathResult<T> = Result<T, MathError>;

/// `floor(x * y / d)` with a checked 256-bit product (`MathLib.mulDivDown`).
pub fn mul_div_down(x: U256, y: U256, d: U256) -> MathResult<U256> {
    let p = x.checked_mul(y).ok_or(MathError::Overflow)?;
    p.checked_div(d).ok_or(MathError::DivisionByZero)
}

/// `ceil(x * y / d)` with a checked 256-bit product (`MathLib.mulDivUp`).
pub fn mul_div_up(x: U256, y: U256, d: U256) -> MathResult<U256> {
    let p = x.checked_mul(y).ok_or(MathError::Overflow)?;
    let q = p.checked_div(d).ok_or(MathError::DivisionByZero)?;
    let r = p.checked_rem(d).ok_or(MathError::DivisionByZero)?;
    Ok(if r.is_zero() { q } else { q + U256::from(1u8) })
}

/// `floor(x * y / d)` with a 512-bit intermediate product (Solady `fullMulDiv`).
pub fn full_mul_div(x: U256, y: U256, d: U256) -> MathResult<U256> {
    if d.is_zero() {
        return Err(MathError::DivisionByZero);
    }
    let p: U512 = x.widening_mul(y);
    let q = p / U512::from_limbs_slice(d.as_limbs());
    U256::checked_from_limbs_slice(q.as_limbs()).ok_or(MathError::Overflow)
}

/// `ceil(x * y / d)` with a 512-bit intermediate product (Solady `fullMulDivUp`).
pub fn full_mul_div_up(x: U256, y: U256, d: U256) -> MathResult<U256> {
    let q = full_mul_div(x, y, d)?;
    let p: U512 = x.widening_mul(y);
    let rem = p % U512::from_limbs_slice(d.as_limbs());
    if rem.is_zero() { Ok(q) } else { q.checked_add(U256::from(1u8)).ok_or(MathError::Overflow) }
}

/// `floor(x * y / WAD)`.
pub fn w_mul_down(x: U256, y: U256) -> MathResult<U256> {
    mul_div_down(x, y, WAD)
}

/// `floor(x * WAD / y)`.
pub fn w_div_down(x: U256, y: U256) -> MathResult<U256> {
    mul_div_down(x, WAD, y)
}

/// `ceil(x * WAD / y)`.
pub fn w_div_up(x: U256, y: U256) -> MathResult<U256> {
    mul_div_up(x, WAD, y)
}

/// `max(0, x - y)`.
pub fn zero_floor_sub(x: U256, y: U256) -> U256 {
    x.saturating_sub(y)
}

/// Checked addition.
pub fn add(x: U256, y: U256) -> MathResult<U256> {
    x.checked_add(y).ok_or(MathError::Overflow)
}

/// Asserts that `x` fits in `uint128` (OpenZeppelin `SafeCast.toUint128`).
pub fn to_u128(x: U256) -> MathResult<U256> {
    if x > U256::from(u128::MAX) { Err(MathError::Uint128Overflow) } else { Ok(x) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(x: u128) -> U256 {
        U256::from(x)
    }

    #[test]
    fn rounding_directions() {
        assert_eq!(mul_div_down(u(7), u(3), u(2)), Ok(u(10)));
        assert_eq!(mul_div_up(u(7), u(3), u(2)), Ok(u(11)));
        assert_eq!(mul_div_up(u(8), u(3), u(2)), Ok(u(12)));
        assert_eq!(full_mul_div(u(7), u(3), u(2)), Ok(u(10)));
        assert_eq!(full_mul_div_up(u(7), u(3), u(2)), Ok(u(11)));
    }

    #[test]
    fn division_by_zero_is_an_error() {
        assert_eq!(mul_div_down(u(1), u(1), U256::ZERO), Err(MathError::DivisionByZero));
        assert_eq!(mul_div_up(u(1), u(1), U256::ZERO), Err(MathError::DivisionByZero));
        assert_eq!(full_mul_div(u(1), u(1), U256::ZERO), Err(MathError::DivisionByZero));
        assert_eq!(full_mul_div_up(u(1), u(1), U256::ZERO), Err(MathError::DivisionByZero));
    }

    #[test]
    fn checked_product_overflows_where_solidity_reverts() {
        assert_eq!(mul_div_down(U256::MAX, u(2), u(4)), Err(MathError::Overflow));
        assert_eq!(mul_div_up(U256::MAX, u(2), u(4)), Err(MathError::Overflow));
    }

    #[test]
    fn full_mul_div_survives_512_bit_products() {
        // (2^255) * 4 / 8 = 2^254 needs a 257-bit intermediate.
        let two_255 = U256::from(1u8) << 255;
        assert_eq!(full_mul_div(two_255, u(4), u(8)), Ok(U256::from(1u8) << 254));
        assert_eq!(full_mul_div(U256::MAX, U256::MAX, U256::MAX), Ok(U256::MAX));
        assert_eq!(full_mul_div(U256::MAX, u(2), u(1)), Err(MathError::Overflow));
        assert_eq!(full_mul_div_up(U256::MAX, U256::MAX, U256::MAX), Ok(U256::MAX));
    }

    #[test]
    fn uint128_cast() {
        assert!(to_u128(U256::from(u128::MAX)).is_ok());
        assert_eq!(to_u128(U256::from(u128::MAX) + u(1)), Err(MathError::Uint128Overflow));
    }

    #[test]
    fn wad_helpers() {
        assert_eq!(w_mul_down(u(3), WAD / u(2)), Ok(u(1)));
        assert_eq!(w_div_down(WAD, u(3) * WAD), Ok(u(333_333_333_333_333_333)));
        assert_eq!(w_div_up(WAD, u(3) * WAD), Ok(u(333_333_333_333_333_334)));
        assert_eq!(zero_floor_sub(u(1), u(2)), U256::ZERO);
        assert_eq!(add(U256::MAX, u(1)), Err(MathError::Overflow));
    }
}
