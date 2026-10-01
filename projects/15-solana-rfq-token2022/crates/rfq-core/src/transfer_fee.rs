// SPDX-License-Identifier: MIT
//! Token-2022 transfer-fee arithmetic, ported bit-for-bit.
//!
//! Settlement must know, before it moves anything, how much the recipient of a
//! `transfer_checked` will actually be credited. Token-2022 withholds
//! `ceil(amount * bps / 10_000)` (capped at `maximum_fee`) in the destination
//! account. These functions reproduce `spl_token_2022_interface`'s
//! `TransferFee::{calculate_fee, calculate_post_fee_amount,
//! calculate_pre_fee_amount}` exactly; the tests run them differentially
//! against the canonical implementation.

#![deny(clippy::arithmetic_side_effects)]

/// Basis points in 100 %.
pub const ONE_IN_BASIS_POINTS: u128 = 10_000;

/// Length of the `TransferFeeConfig` extension value.
pub const TRANSFER_FEE_CONFIG_LEN: usize = 108;

/// One epoch's fee schedule (`older_transfer_fee` / `newer_transfer_fee`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct TransferFee {
    /// First epoch where this fee applies.
    pub epoch: u64,
    /// Absolute cap per transfer, in base units.
    pub maximum_fee: u64,
    /// Fee rate in basis points.
    pub basis_points: u16,
}

fn ceil_div(numerator: u128, denominator: u128) -> Option<u128> {
    numerator
        .checked_add(denominator)?
        .checked_sub(1)?
        .checked_div(denominator)
}

impl TransferFee {
    /// A zero fee (legacy SPL Token mints, Token-2022 mints without the extension).
    pub const ZERO: TransferFee = TransferFee {
        epoch: 0,
        maximum_fee: 0,
        basis_points: 0,
    };

    /// Fee withheld when `pre_fee_amount` is transferred.
    pub fn calculate_fee(&self, pre_fee_amount: u64) -> Option<u64> {
        let bps = u128::from(self.basis_points);
        if bps == 0 || pre_fee_amount == 0 {
            Some(0)
        } else {
            let numerator = u128::from(pre_fee_amount).checked_mul(bps)?;
            let raw_fee: u64 = ceil_div(numerator, ONE_IN_BASIS_POINTS)?.try_into().ok()?;
            Some(raw_fee.min(self.maximum_fee))
        }
    }

    /// Amount credited to the recipient when `pre_fee_amount` is sent.
    pub fn calculate_post_fee_amount(&self, pre_fee_amount: u64) -> Option<u64> {
        pre_fee_amount.checked_sub(self.calculate_fee(pre_fee_amount)?)
    }

    /// Smallest gross amount whose post-fee amount is `post_fee_amount`
    /// (Token-2022's `calculate_pre_fee_amount`).
    pub fn calculate_pre_fee_amount(&self, post_fee_amount: u64) -> Option<u64> {
        let maximum_fee = self.maximum_fee;
        let bps = u128::from(self.basis_points);
        match (bps, post_fee_amount) {
            (0, _) => Some(post_fee_amount),
            (_, 0) => Some(0),
            (ONE_IN_BASIS_POINTS, _) => maximum_fee.checked_add(post_fee_amount),
            _ => {
                let numerator = u128::from(post_fee_amount).checked_mul(ONE_IN_BASIS_POINTS)?;
                let denominator = ONE_IN_BASIS_POINTS.checked_sub(bps)?;
                let raw_pre_fee_amount = ceil_div(numerator, denominator)?;
                if raw_pre_fee_amount.checked_sub(u128::from(post_fee_amount))?
                    >= u128::from(maximum_fee)
                {
                    post_fee_amount.checked_add(maximum_fee)
                } else {
                    u64::try_from(raw_pre_fee_amount).ok()
                }
            }
        }
    }

    /// Gross amount a sender must transfer so the recipient is credited **at
    /// least** `net`: `calculate_pre_fee_amount`, bumped by one unit in the
    /// rare rounding cases where the canonical inverse falls short.
    pub fn gross_for_net(&self, net: u64) -> Option<u64> {
        let mut gross = self.calculate_pre_fee_amount(net)?;
        // `calculate_pre_fee_amount` is exact for every fee schedule the test
        // suite could find; the loop is a cheap, provably-terminating guard.
        for _ in 0..2 {
            if self.calculate_post_fee_amount(gross)? >= net {
                return Some(gross);
            }
            gross = gross.checked_add(1)?;
        }
        None
    }
}

/// Zero-copy view of a mint's `TransferFeeConfig` extension value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TransferFeeConfig {
    /// Fee used while `epoch < newer.epoch`.
    pub older: TransferFee,
    /// Fee used from `newer.epoch` onwards.
    pub newer: TransferFee,
}

impl TransferFeeConfig {
    /// Parses the 108-byte extension value
    /// (`authority | withdraw_authority | withheld | older | newer`).
    pub fn parse(value: &[u8]) -> Option<Self> {
        if value.len() != TRANSFER_FEE_CONFIG_LEN {
            return None;
        }
        let fee_at = |o: usize| -> Option<TransferFee> {
            Some(TransferFee {
                epoch: crate::read_u64(value, o)?,
                maximum_fee: crate::read_u64(value, o.checked_add(8)?)?,
                basis_points: crate::read_u16(value, o.checked_add(16)?)?,
            })
        };
        Some(Self {
            older: fee_at(72)?,
            newer: fee_at(90)?,
        })
    }

    /// The fee schedule in force at `epoch` (Token-2022's `get_epoch_fee`).
    pub fn epoch_fee(&self, epoch: u64) -> TransferFee {
        if epoch >= self.newer.epoch {
            self.newer
        } else {
            self.older
        }
    }
}

#[cfg(test)]
#[allow(clippy::arithmetic_side_effects)]
mod tests {
    use {
        super::*, proptest::prelude::*,
        spl_token_2022_interface::extension::transfer_fee::TransferFee as SplTransferFee,
    };

    fn spl(fee: &TransferFee) -> SplTransferFee {
        SplTransferFee {
            epoch: fee.epoch.into(),
            maximum_fee: fee.maximum_fee.into(),
            transfer_fee_basis_points: fee.basis_points.into(),
        }
    }

    fn arb_fee() -> impl Strategy<Value = TransferFee> {
        (
            any::<u64>(),
            prop_oneof![Just(0u64), 0u64..1_000_000, any::<u64>(), Just(u64::MAX)],
            prop_oneof![
                Just(0u16),
                1u16..=10_000,
                Just(10_000u16),
                Just(1u16),
                any::<u16>()
            ],
        )
            .prop_map(|(epoch, maximum_fee, basis_points)| TransferFee {
                epoch,
                maximum_fee,
                basis_points,
            })
    }

    fn arb_amount() -> impl Strategy<Value = u64> {
        prop_oneof![
            Just(0u64),
            1u64..10_000,
            any::<u64>(),
            Just(u64::MAX),
            Just(u64::MAX - 1)
        ]
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(4096))]

        /// Differential: fee, post-fee and pre-fee amounts equal Token-2022's.
        #[test]
        fn matches_token_2022(fee in arb_fee(), amount in arb_amount()) {
            let canonical = spl(&fee);
            prop_assert_eq!(fee.calculate_fee(amount), canonical.calculate_fee(amount));
            prop_assert_eq!(
                fee.calculate_post_fee_amount(amount),
                canonical.calculate_post_fee_amount(amount)
            );
            prop_assert_eq!(
                fee.calculate_pre_fee_amount(amount),
                canonical.calculate_pre_fee_amount(amount)
            );
        }

        /// The gross-up is sufficient: the recipient is credited at least `net`,
        /// and it is minimal: one unit less would credit strictly less.
        #[test]
        fn gross_for_net_is_sufficient_and_minimal(fee in arb_fee(), net in arb_amount()) {
            prop_assume!(fee.basis_points <= 10_000);
            if let Some(gross) = fee.gross_for_net(net) {
                let credited = fee.calculate_post_fee_amount(gross).expect("gross >= fee");
                prop_assert!(credited >= net);
                if gross > net {
                    let less = fee.calculate_post_fee_amount(gross - 1).expect("valid");
                    prop_assert!(less < net || (fee.basis_points == 10_000));
                }
            }
        }

        /// The fee never exceeds either the cap or the amount itself.
        #[test]
        fn fee_is_bounded(fee in arb_fee(), amount in arb_amount()) {
            prop_assume!(fee.basis_points <= 10_000);
            let f = fee.calculate_fee(amount).expect("no overflow for bps <= 100%");
            prop_assert!(f <= fee.maximum_fee);
            prop_assert!(f <= amount);
        }
    }

    #[test]
    fn epoch_selection() {
        let cfg = TransferFeeConfig {
            older: TransferFee {
                epoch: 0,
                maximum_fee: 1,
                basis_points: 10,
            },
            newer: TransferFee {
                epoch: 5,
                maximum_fee: 2,
                basis_points: 20,
            },
        };
        assert_eq!(cfg.epoch_fee(4), cfg.older);
        assert_eq!(cfg.epoch_fee(5), cfg.newer);
        assert_eq!(cfg.epoch_fee(u64::MAX), cfg.newer);
    }

    #[test]
    fn parse_rejects_wrong_length() {
        assert!(TransferFeeConfig::parse(&[0u8; 107]).is_none());
        assert!(TransferFeeConfig::parse(&[0u8; 109]).is_none());
        assert!(TransferFeeConfig::parse(&[0u8; 108]).is_some());
    }

    #[test]
    fn known_values() {
        // 1% capped at 5 units.
        let fee = TransferFee {
            epoch: 0,
            maximum_fee: 5,
            basis_points: 100,
        };
        assert_eq!(fee.calculate_fee(100), Some(1));
        assert_eq!(fee.calculate_fee(101), Some(2)); // ceil(1.01)
        assert_eq!(fee.calculate_fee(1_000_000), Some(5)); // capped
        assert_eq!(fee.gross_for_net(99), Some(100));
        assert_eq!(fee.gross_for_net(1_000_000), Some(1_000_005));
        assert_eq!(TransferFee::ZERO.gross_for_net(42), Some(42));
    }
}
