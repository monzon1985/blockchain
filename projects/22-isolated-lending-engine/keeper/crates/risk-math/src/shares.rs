// SPDX-License-Identifier: MIT
//! Asset/share conversions with virtual liquidity, mirroring `SharesMathLib.sol`.

use alloy_primitives::U256;

use crate::math::{MathResult, add, mul_div_down, mul_div_up};

/// Virtual shares added to every share total (`SharesMathLib.VIRTUAL_SHARES`).
pub const VIRTUAL_SHARES: U256 = U256::from_limbs([1_000_000, 0, 0, 0]);

/// Virtual assets added to every asset total (`SharesMathLib.VIRTUAL_ASSETS`).
pub const VIRTUAL_ASSETS: U256 = U256::from_limbs([1, 0, 0, 0]);

/// Assets to shares, rounded down.
pub fn to_shares_down(assets: U256, total_assets: U256, total_shares: U256) -> MathResult<U256> {
    mul_div_down(assets, add(total_shares, VIRTUAL_SHARES)?, add(total_assets, VIRTUAL_ASSETS)?)
}

/// Shares to assets, rounded down.
pub fn to_assets_down(shares: U256, total_assets: U256, total_shares: U256) -> MathResult<U256> {
    mul_div_down(shares, add(total_assets, VIRTUAL_ASSETS)?, add(total_shares, VIRTUAL_SHARES)?)
}

/// Assets to shares, rounded up.
pub fn to_shares_up(assets: U256, total_assets: U256, total_shares: U256) -> MathResult<U256> {
    mul_div_up(assets, add(total_shares, VIRTUAL_SHARES)?, add(total_assets, VIRTUAL_ASSETS)?)
}

/// Shares to assets, rounded up.
pub fn to_assets_up(shares: U256, total_assets: U256, total_shares: U256) -> MathResult<U256> {
    mul_div_up(shares, add(total_assets, VIRTUAL_ASSETS)?, add(total_shares, VIRTUAL_SHARES)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_deposit_mints_one_million_shares_per_asset() {
        let shares = to_shares_down(U256::from(5u8), U256::ZERO, U256::ZERO);
        assert_eq!(shares, Ok(U256::from(5_000_000u64)));
    }

    #[test]
    fn up_is_down_plus_at_most_one() {
        let (ta, ts) = (U256::from(1_000_003u64), U256::from(999_999_999_937u64));
        for amount in [1u64, 7, 1_000, 123_456_789] {
            let a = U256::from(amount);
            let down = to_assets_down(a, ta, ts).unwrap_or_default();
            let up = to_assets_up(a, ta, ts).unwrap_or_default();
            assert!(up >= down && up - down <= U256::from(1u8));
        }
    }
}
