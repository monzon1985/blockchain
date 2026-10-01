// SPDX-License-Identifier: MIT
//! Settlement arithmetic: pro-rata pricing, protocol fee and Token-2022
//! gross-vs-net amounts, all in checked `u128` intermediate math.
//!
//! ```text
//! taker_net_owed  = ceil(taker_amount * fill / maker_amount)      maker must RECEIVE this (net)
//! taker_gross_in  = gross_for_net(taker_mint_fee, taker_net_owed) taker SENDS this      ≤ max_in
//! maker_net_in    = post_fee(taker_mint_fee, taker_gross_in)      ≥ taker_net_owed
//! protocol_fee    = ceil(fill * fee_bps / 10_000)                 in maker_mint, to the fee vault
//! taker_gross_out = fill - protocol_fee                           leaves the maker vault
//! taker_net_out   = post_fee(maker_mint_fee, taker_gross_out)     taker RECEIVES this   ≥ min_out
//! ```
//!
//! Every rounding decision favours the party that did not choose the amount:
//! the maker's price rounds up (the taker picks `fill`), the protocol fee rounds
//! up, and transfer fees are grossed up on the taker's leg so the maker is never
//! short-changed by a fee-bearing `taker_mint`.

#![deny(clippy::arithmetic_side_effects)]

use crate::{RfqError, transfer_fee::TransferFee};

/// Hard cap on the protocol fee (10 %).
pub const MAX_PROTOCOL_FEE_BPS: u16 = 1_000;

/// Inputs to [`compute_settlement`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SettleInputs {
    /// Quote size in `maker_mint` base units.
    pub maker_amount: u64,
    /// Quote price: `taker_mint` the maker must net for a full fill.
    pub taker_amount: u64,
    /// Amount of the quote already filled.
    pub filled_before: u64,
    /// Gross `maker_mint` amount this fill takes out of the maker vault.
    pub fill: u64,
    /// Protocol fee rate.
    pub protocol_fee_bps: u16,
    /// Fee schedule of `maker_mint` at the current epoch.
    pub maker_mint_fee: TransferFee,
    /// Fee schedule of `taker_mint` at the current epoch.
    pub taker_mint_fee: TransferFee,
    /// Minimum `maker_mint` the taker must be credited (slippage bound).
    pub min_out: u64,
    /// Maximum `taker_mint` the taker agrees to send (slippage bound).
    pub max_in: u64,
}

/// The amounts a successful fill moves.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Settlement {
    /// Net `taker_mint` the maker is owed for this fill.
    pub taker_net_owed: u64,
    /// Gross `taker_mint` the taker sends to the maker vault.
    pub taker_gross_in: u64,
    /// `taker_mint` actually credited to the maker vault.
    pub maker_net_in: u64,
    /// `maker_mint` sent to the protocol fee vault.
    pub protocol_fee: u64,
    /// Gross `maker_mint` sent from the maker vault to the taker.
    pub taker_gross_out: u64,
    /// `maker_mint` actually credited to the taker.
    pub taker_net_out: u64,
    /// Cumulative filled amount after this fill.
    pub filled_after: u64,
    /// `true` when this fill exhausts the quote.
    pub completes: bool,
}

/// `ceil(a * b / c)` in `u128`; `None` on division by zero or overflow of `u64`.
pub fn mul_div_ceil(a: u64, b: u64, c: u64) -> Option<u64> {
    if c == 0 {
        return None;
    }
    let num = u128::from(a).checked_mul(u128::from(b))?;
    let c = u128::from(c);
    let q = num.checked_add(c.checked_sub(1)?)?.checked_div(c)?;
    u64::try_from(q).ok()
}

/// Protocol fee on `amount` at `bps`, rounded up.
pub fn protocol_fee(amount: u64, bps: u16) -> Option<u64> {
    mul_div_ceil(amount, u64::from(bps), 10_000)
}

/// Computes every amount of a fill and enforces the fill, slippage and
/// overflow rules. Pure function: identical results on host and on-chain.
pub fn compute_settlement(i: &SettleInputs) -> Result<Settlement, RfqError> {
    if i.fill == 0 {
        return Err(RfqError::ZeroAmount);
    }
    let remaining = i
        .maker_amount
        .checked_sub(i.filled_before)
        .ok_or(RfqError::FillExceedsRemaining)?;
    if i.fill > remaining {
        return Err(RfqError::FillExceedsRemaining);
    }
    let filled_after = i
        .filled_before
        .checked_add(i.fill)
        .ok_or(RfqError::MathOverflow)?;

    let taker_net_owed =
        mul_div_ceil(i.taker_amount, i.fill, i.maker_amount).ok_or(RfqError::MathOverflow)?;
    let taker_gross_in = i
        .taker_mint_fee
        .gross_for_net(taker_net_owed)
        .ok_or(RfqError::MathOverflow)?;
    if taker_gross_in > i.max_in {
        return Err(RfqError::SlippageMaxIn);
    }
    let maker_net_in = i
        .taker_mint_fee
        .calculate_post_fee_amount(taker_gross_in)
        .ok_or(RfqError::MathOverflow)?;
    // Guaranteed by `gross_for_net`; kept as an explicit invariant check.
    if maker_net_in < taker_net_owed {
        return Err(RfqError::MathOverflow);
    }

    let protocol_fee = protocol_fee(i.fill, i.protocol_fee_bps).ok_or(RfqError::MathOverflow)?;
    let taker_gross_out = i
        .fill
        .checked_sub(protocol_fee)
        .ok_or(RfqError::MathOverflow)?;
    let taker_net_out = i
        .maker_mint_fee
        .calculate_post_fee_amount(taker_gross_out)
        .ok_or(RfqError::MathOverflow)?;
    if taker_net_out < i.min_out {
        return Err(RfqError::SlippageMinOut);
    }

    Ok(Settlement {
        taker_net_owed,
        taker_gross_in,
        maker_net_in,
        protocol_fee,
        taker_gross_out,
        taker_net_out,
        filled_after,
        completes: filled_after == i.maker_amount,
    })
}

#[cfg(test)]
#[allow(clippy::arithmetic_side_effects)]
mod tests {
    use {super::*, proptest::prelude::*};

    fn base() -> SettleInputs {
        SettleInputs {
            maker_amount: 1_000_000,
            taker_amount: 2_000_000,
            filled_before: 0,
            fill: 1_000_000,
            protocol_fee_bps: 30,
            maker_mint_fee: TransferFee::ZERO,
            taker_mint_fee: TransferFee::ZERO,
            min_out: 0,
            max_in: u64::MAX,
        }
    }

    #[test]
    fn full_fill_no_transfer_fees() {
        let s = compute_settlement(&base()).expect("ok");
        assert_eq!(s.taker_net_owed, 2_000_000);
        assert_eq!(s.taker_gross_in, 2_000_000);
        assert_eq!(s.maker_net_in, 2_000_000);
        assert_eq!(s.protocol_fee, 3_000); // 0.30 % of 1_000_000
        assert_eq!(s.taker_gross_out, 997_000);
        assert_eq!(s.taker_net_out, 997_000);
        assert!(s.completes);
    }

    #[test]
    fn partial_fill_rounds_price_up_for_the_maker() {
        let i = SettleInputs {
            maker_amount: 3,
            taker_amount: 10,
            fill: 1,
            protocol_fee_bps: 0,
            ..base()
        };
        let s = compute_settlement(&i).expect("ok");
        assert_eq!(s.taker_net_owed, 4); // ceil(10/3)
        assert!(!s.completes);
    }

    #[test]
    fn transfer_fees_gross_up_and_reduce_output() {
        let i = SettleInputs {
            maker_mint_fee: TransferFee {
                epoch: 0,
                maximum_fee: u64::MAX,
                basis_points: 100,
            },
            taker_mint_fee: TransferFee {
                epoch: 0,
                maximum_fee: u64::MAX,
                basis_points: 250,
            },
            protocol_fee_bps: 0,
            ..base()
        };
        let s = compute_settlement(&i).expect("ok");
        assert_eq!(s.taker_net_owed, 2_000_000);
        assert_eq!(s.taker_gross_in, 2_051_283); // ceil(2e6 / 0.975); 2_051_282 would net 1_999_999
        assert!(s.maker_net_in >= 2_000_000);
        assert_eq!(s.taker_net_out, 990_000);
    }

    #[test]
    fn error_paths() {
        assert_eq!(
            compute_settlement(&SettleInputs { fill: 0, ..base() }),
            Err(RfqError::ZeroAmount)
        );
        // A 100 % transfer fee without a cap can never net the maker anything.
        assert_eq!(
            compute_settlement(&SettleInputs {
                taker_mint_fee: TransferFee {
                    epoch: 0,
                    maximum_fee: u64::MAX,
                    basis_points: 10_000
                },
                ..base()
            }),
            Err(RfqError::MathOverflow)
        );
        assert_eq!(
            compute_settlement(&SettleInputs {
                fill: 1_000_001,
                ..base()
            }),
            Err(RfqError::FillExceedsRemaining)
        );
        assert_eq!(
            compute_settlement(&SettleInputs {
                filled_before: 999_999,
                fill: 2,
                ..base()
            }),
            Err(RfqError::FillExceedsRemaining)
        );
        assert_eq!(
            compute_settlement(&SettleInputs {
                filled_before: 2_000_000,
                ..base()
            }),
            Err(RfqError::FillExceedsRemaining)
        );
        assert_eq!(
            compute_settlement(&SettleInputs {
                max_in: 1_999_999,
                ..base()
            }),
            Err(RfqError::SlippageMaxIn)
        );
        assert_eq!(
            compute_settlement(&SettleInputs {
                min_out: 997_001,
                ..base()
            }),
            Err(RfqError::SlippageMinOut)
        );
        // Price overflowing u64 is reported, not wrapped.
        assert_eq!(
            compute_settlement(&SettleInputs {
                maker_amount: 1,
                taker_amount: u64::MAX,
                fill: 1,
                ..base()
            })
            .map(|s| s.taker_net_owed),
            Ok(u64::MAX)
        );
        assert_eq!(
            compute_settlement(&SettleInputs {
                maker_amount: 2,
                taker_amount: u64::MAX,
                fill: 2,
                taker_mint_fee: TransferFee {
                    epoch: 0,
                    maximum_fee: 1,
                    basis_points: 1
                },
                ..base()
            }),
            Err(RfqError::MathOverflow)
        );
    }

    #[test]
    fn mul_div_ceil_edges() {
        assert_eq!(mul_div_ceil(1, 1, 0), None);
        assert_eq!(mul_div_ceil(0, 5, 3), Some(0));
        assert_eq!(mul_div_ceil(u64::MAX, u64::MAX, u64::MAX), Some(u64::MAX));
        assert_eq!(mul_div_ceil(u64::MAX, 2, 1), None);
        assert_eq!(protocol_fee(1, 1), Some(1));
        assert_eq!(protocol_fee(10_000, 30), Some(30));
    }

    fn arb_fee() -> impl Strategy<Value = TransferFee> {
        (0u16..=10_000, prop_oneof![Just(u64::MAX), 0u64..10_000]).prop_map(
            |(basis_points, maximum_fee)| TransferFee {
                epoch: 0,
                maximum_fee,
                basis_points,
            },
        )
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(2048))]

        /// Conservation and bounds for any successful fill.
        #[test]
        fn successful_fills_conserve_value(
            maker_amount in 1u64..=u64::MAX / 2,
            taker_amount in 1u64..=u32::MAX as u64,
            fill_frac in 1u64..=1_000,
            filled_frac in 0u64..1_000,
            bps in 0u16..=MAX_PROTOCOL_FEE_BPS,
            mfee in arb_fee(),
            tfee in arb_fee(),
        ) {
            let filled_before = maker_amount / 1_000 * filled_frac;
            let remaining = maker_amount - filled_before;
            let fill = (remaining / 1_000 * fill_frac).max(1).min(remaining);
            let i = SettleInputs {
                maker_amount, taker_amount, filled_before, fill,
                protocol_fee_bps: bps, maker_mint_fee: mfee, taker_mint_fee: tfee,
                min_out: 0, max_in: u64::MAX,
            };
            if let Ok(s) = compute_settlement(&i) {
                // Maker vault outflow is exactly the fill.
                prop_assert_eq!(s.taker_gross_out + s.protocol_fee, fill);
                // Taker never receives more than was sent to it.
                prop_assert!(s.taker_net_out <= s.taker_gross_out);
                // The maker nets at least the pro-rata price.
                prop_assert!(s.maker_net_in >= s.taker_net_owed);
                prop_assert!(s.taker_gross_in >= s.maker_net_in);
                // Price is at least the exact pro-rata value (rounding favours the maker).
                prop_assert!(u128::from(s.taker_net_owed) * u128::from(maker_amount)
                    >= u128::from(taker_amount) * u128::from(fill));
                // Fee cap.
                prop_assert!(u128::from(s.protocol_fee) * 10_000 < u128::from(fill) * u128::from(bps) + 10_000);
                prop_assert_eq!(s.filled_after, filled_before + fill);
                prop_assert_eq!(s.completes, s.filled_after == maker_amount);
            }
        }

        /// Splitting a quote into two fills never costs the maker: the sum of the
        /// parts' prices is at least the price of the whole.
        #[test]
        fn splitting_never_underpays_the_maker(
            maker_amount in 2u64..=1u64 << 40,
            taker_amount in 1u64..=1u64 << 40,
            split in 1u64..1_000,
        ) {
            let first = (maker_amount / 1_000 * split).clamp(1, maker_amount - 1);
            let whole = mul_div_ceil(taker_amount, maker_amount, maker_amount).expect("fits");
            let a = mul_div_ceil(taker_amount, first, maker_amount).expect("fits");
            let b = mul_div_ceil(taker_amount, maker_amount - first, maker_amount).expect("fits");
            prop_assert!(a + b >= whole);
        }

        /// Slippage bounds are exact: the computed amounts are the thresholds.
        #[test]
        fn slippage_thresholds_are_tight(
            maker_amount in 1u64..=1u64 << 50,
            taker_amount in 1u64..=1u64 << 50,
            bps in 0u16..=MAX_PROTOCOL_FEE_BPS,
            // A 100 % uncapped fee has no finite gross-up; it is covered by `error_paths`.
            tfee in arb_fee().prop_filter("finite gross-up", |f| f.basis_points < 10_000),
        ) {
            let i = SettleInputs {
                maker_amount, taker_amount, filled_before: 0, fill: maker_amount,
                protocol_fee_bps: bps, maker_mint_fee: TransferFee::ZERO, taker_mint_fee: tfee,
                min_out: 0, max_in: u64::MAX,
            };
            let s = compute_settlement(&i).expect("fits in u64");
            let exact = SettleInputs { min_out: s.taker_net_out, max_in: s.taker_gross_in, ..i };
            prop_assert_eq!(compute_settlement(&exact), Ok(s));
            if s.taker_gross_in > 0 {
                let tight_in = SettleInputs { max_in: s.taker_gross_in - 1, ..exact };
                prop_assert_eq!(compute_settlement(&tight_in), Err(RfqError::SlippageMaxIn));
            }
            let tight_out = SettleInputs { min_out: s.taker_net_out + 1, ..exact };
            prop_assert_eq!(compute_settlement(&tight_out), Err(RfqError::SlippageMinOut));
        }
    }
}
