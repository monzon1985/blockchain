// SPDX-License-Identifier: MIT
//! Binary layouts shared by both program implementations.
//!
//! Anchor serialises `#[account]` structs with borsh after an 8-byte
//! discriminator `sha256("account:<Name>")[..8]`. Every field used here is
//! fixed-size, so borsh output is a packed little-endian record and the
//! Pinocchio program reads and writes byte-identical records at fixed offsets
//! (the offsets are checked against Anchor's serialiser in
//! `programs/rfq/src/state.rs`).
//! Instruction data likewise is `sha256("global:<name>")[..8] || borsh(args)`
//! and events are `sha256("event:<Name>")[..8] || borsh(event)`.
//!
//! The discriminator constants are recomputed from their preimages in this
//! module's tests.

use crate::{Pubkey, quote::Quote, read_key, read_u64};

/// Instruction discriminators.
pub mod ix {
    /// `sha256("global:settle")[..8]` — strict (v2) settlement.
    pub const SETTLE: [u8; 8] = [175, 42, 185, 87, 144, 131, 102, 212];
    /// `sha256("global:settle_naive_v1")[..8]` — deliberately vulnerable v1.
    pub const SETTLE_NAIVE_V1: [u8; 8] = [172, 5, 32, 26, 87, 78, 119, 103];
}

/// Account discriminators.
pub mod disc {
    /// `sha256("account:Config")[..8]`.
    pub const CONFIG: [u8; 8] = [155, 12, 170, 224, 30, 250, 204, 130];
    /// `sha256("account:Maker")[..8]`.
    pub const MAKER: [u8; 8] = [31, 255, 232, 61, 38, 28, 189, 147];
    /// `sha256("account:NoncePage")[..8]`.
    pub const NONCE_PAGE: [u8; 8] = [87, 252, 122, 118, 210, 249, 197, 39];
    /// `sha256("account:QuoteFill")[..8]`.
    pub const QUOTE_FILL: [u8; 8] = [82, 71, 232, 67, 159, 6, 102, 210];
    /// `sha256("event:Settled")[..8]`.
    pub const SETTLED_EVENT: [u8; 8] = [232, 210, 40, 17, 142, 124, 145, 238];
}

/// `Config` (seeds `["config"]`): admin, pending_admin, fee_bps, paused, bump.
pub mod config {
    /// Admin key.
    pub const ADMIN: usize = 8;
    /// Pending admin (two-step transfer).
    pub const PENDING_ADMIN: usize = 40;
    /// Protocol fee in basis points (`u16`).
    pub const FEE_BPS: usize = 72;
    /// Pause flag (`bool`).
    pub const PAUSED: usize = 74;
    /// Canonical bump.
    pub const BUMP: usize = 75;
    /// Total length.
    pub const LEN: usize = 76;
}

/// `Maker` (seeds `["maker", owner]`).
pub mod maker {
    /// Owner wallet (withdraw authority, PDA seed).
    pub const OWNER: usize = 8;
    /// ed25519 key that signs quotes.
    pub const QUOTE_SIGNER: usize = 40;
    /// Quotes with `nonce < min_nonce` are cancelled.
    pub const MIN_NONCE: usize = 72;
    /// Active flag (`bool`).
    pub const ACTIVE: usize = 80;
    /// Canonical bump of the maker PDA.
    pub const BUMP: usize = 81;
    /// Canonical bump of the vault-authority PDA.
    pub const VAULT_AUTHORITY_BUMP: usize = 82;
    /// Total length.
    pub const LEN: usize = 83;
}

/// `NoncePage` (seeds `["nonces", owner, page_le]`).
pub mod nonce_page {
    /// Maker owner key.
    pub const MAKER: usize = 8;
    /// Page index (`u64`).
    pub const PAGE: usize = 40;
    /// 256-bit bitmap.
    pub const BITS: usize = 48;
    /// Canonical bump.
    pub const BUMP: usize = 80;
    /// Total length.
    pub const LEN: usize = 81;
}

/// `QuoteFill` (seeds `["fill", owner, nonce_le]`).
pub mod quote_fill {
    /// Maker owner key.
    pub const MAKER: usize = 8;
    /// Quote nonce (`u64`).
    pub const NONCE: usize = 40;
    /// `sha256(message)` of the quote being filled.
    pub const QUOTE_HASH: usize = 48;
    /// Cumulative filled amount (`u64`).
    pub const FILLED: usize = 80;
    /// Canonical bump.
    pub const BUMP: usize = 88;
    /// Taker that paid the tracker's rent (refunded when it closes).
    pub const PAYER: usize = 89;
    /// Total length.
    pub const LEN: usize = 121;
}

/// Account order of `settle` / `settle_naive_v1` (the ABI both programs share;
/// hook extras follow as remaining accounts).
pub mod settle_accounts {
    /// Taker (signer, writable).
    pub const TAKER: usize = 0;
    /// `Config` PDA.
    pub const CONFIG: usize = 1;
    /// `Maker` PDA.
    pub const MAKER: usize = 2;
    /// Vault-authority PDA.
    pub const VAULT_AUTHORITY: usize = 3;
    /// `NoncePage` PDA (writable).
    pub const NONCE_PAGE: usize = 4;
    /// `QuoteFill` PDA (writable, created on first fill).
    pub const QUOTE_FILL: usize = 5;
    /// Mint the maker sells.
    pub const MAKER_MINT: usize = 6;
    /// Mint the maker buys.
    pub const TAKER_MINT: usize = 7;
    /// Maker `maker_mint` vault (writable).
    pub const MAKER_VAULT_OUT: usize = 8;
    /// Maker `taker_mint` vault (writable).
    pub const MAKER_VAULT_IN: usize = 9;
    /// Taker `taker_mint` account (writable).
    pub const TAKER_SRC: usize = 10;
    /// Taker `maker_mint` account (writable).
    pub const TAKER_DST: usize = 11;
    /// Protocol fee vault (writable).
    pub const FEE_VAULT: usize = 12;
    /// Token program of `maker_mint`.
    pub const MAKER_TOKEN_PROGRAM: usize = 13;
    /// Token program of `taker_mint`.
    pub const TAKER_TOKEN_PROGRAM: usize = 14;
    /// System program.
    pub const SYSTEM_PROGRAM: usize = 15;
    /// Instructions sysvar.
    pub const INSTRUCTIONS: usize = 16;
    /// Number of fixed accounts.
    pub const FIXED: usize = 17;
    /// The mutable accounts Anchor's generated duplicate-mutable-account check
    /// covers (mutable fields of a type that serialises on exit), in field
    /// order: `nonce_page, quote_fill, maker_vault_out, maker_vault_in,
    /// taker_src, taker_dst, fee_vault`.
    pub const DUPLICATE_CHECKED: [usize; 7] = [
        NONCE_PAGE,
        QUOTE_FILL,
        MAKER_VAULT_OUT,
        MAKER_VAULT_IN,
        TAKER_SRC,
        TAKER_DST,
        FEE_VAULT,
    ];
}

/// Arguments of `settle` / `settle_naive_v1`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct SettleArgs {
    /// The signed quote.
    pub quote: Quote,
    /// Gross `maker_mint` amount to take out of the maker vault.
    pub fill_amount: u64,
    /// Minimum `maker_mint` the taker must be credited.
    pub min_out: u64,
    /// Maximum `taker_mint` the taker agrees to send.
    pub max_in: u64,
}

impl SettleArgs {
    /// Borsh length of the arguments.
    pub const ENCODED_LEN: usize = Quote::ENCODED_LEN + 24;
    /// Length of the full instruction data (discriminator + arguments).
    pub const IX_DATA_LEN: usize = 8 + Self::ENCODED_LEN;

    /// Borsh encoding.
    pub fn encode(&self) -> [u8; Self::ENCODED_LEN] {
        let mut out = [0u8; Self::ENCODED_LEN];
        out[..Quote::ENCODED_LEN].copy_from_slice(&self.quote.encode());
        out[160..168].copy_from_slice(&self.fill_amount.to_le_bytes());
        out[168..176].copy_from_slice(&self.min_out.to_le_bytes());
        out[176..184].copy_from_slice(&self.max_in.to_le_bytes());
        out
    }

    /// Decodes borsh arguments (Anchor ignores trailing bytes, and so do we).
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        Some(Self {
            quote: Quote::decode(bytes)?,
            fill_amount: read_u64(bytes, 160)?,
            min_out: read_u64(bytes, 168)?,
            max_in: read_u64(bytes, 176)?,
        })
    }

    /// Full instruction data for `discriminator`.
    pub fn ix_data(&self, discriminator: [u8; 8]) -> [u8; Self::IX_DATA_LEN] {
        let mut out = [0u8; Self::IX_DATA_LEN];
        out[..8].copy_from_slice(&discriminator);
        out[8..].copy_from_slice(&self.encode());
        out
    }
}

/// The `Settled` event both programs emit via `sol_log_data`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct SettledEvent {
    /// Maker owner.
    pub maker: Pubkey,
    /// Taker.
    pub taker: Pubkey,
    /// Quote nonce.
    pub nonce: u64,
    /// Gross `maker_mint` taken from the maker vault.
    pub fill_amount: u64,
    /// Gross `taker_mint` sent by the taker.
    pub taker_gross_in: u64,
    /// `taker_mint` credited to the maker vault.
    pub maker_net_in: u64,
    /// `maker_mint` credited to the taker.
    pub taker_net_out: u64,
    /// `maker_mint` sent to the fee vault.
    pub protocol_fee: u64,
    /// Cumulative fill of the quote after this settlement.
    pub filled_total: u64,
}

impl SettledEvent {
    /// Length including the discriminator.
    pub const LEN: usize = 8 + 32 * 2 + 8 * 7;

    /// Discriminator-prefixed borsh encoding (what Anchor's `emit!` logs).
    pub fn encode(&self) -> [u8; Self::LEN] {
        let mut out = [0u8; Self::LEN];
        out[..8].copy_from_slice(&disc::SETTLED_EVENT);
        out[8..40].copy_from_slice(&self.maker);
        out[40..72].copy_from_slice(&self.taker);
        let words = [
            self.nonce,
            self.fill_amount,
            self.taker_gross_in,
            self.maker_net_in,
            self.taker_net_out,
            self.protocol_fee,
            self.filled_total,
        ];
        for (i, w) in words.iter().enumerate() {
            out[72 + i * 8..80 + i * 8].copy_from_slice(&w.to_le_bytes());
        }
        out
    }

    /// Decodes a logged event (with discriminator).
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        if bytes.len() != Self::LEN || bytes[..8] != disc::SETTLED_EVENT {
            return None;
        }
        let w = |i: usize| read_u64(bytes, 72 + i * 8);
        Some(Self {
            maker: *read_key(bytes, 8)?,
            taker: *read_key(bytes, 40)?,
            nonce: w(0)?,
            fill_amount: w(1)?,
            taker_gross_in: w(2)?,
            maker_net_in: w(3)?,
            taker_net_out: w(4)?,
            protocol_fee: w(5)?,
            filled_total: w(6)?,
        })
    }
}

/// Checks length and discriminator of an account owned by the RFQ program,
/// mirroring Anchor's `AccountDiscriminatorNotFound` / `...Mismatch` order.
pub fn check_discriminator(data: &[u8], expected: &[u8; 8]) -> Result<(), u32> {
    if data.len() < 8 {
        return Err(crate::anchor_codes::ACCOUNT_DISCRIMINATOR_NOT_FOUND);
    }
    if data[..8] != expected[..] {
        return Err(crate::anchor_codes::ACCOUNT_DISCRIMINATOR_MISMATCH);
    }
    Ok(())
}

/// The first index pair of equal keys in `keys`, if any (the rule behind
/// Anchor's `ConstraintDuplicateMutableAccount`).
pub fn first_duplicate(keys: &[&Pubkey]) -> Option<(usize, usize)> {
    for i in 0..keys.len() {
        for j in (i + 1)..keys.len() {
            if keys[i] == keys[j] {
                return Some((i, j));
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use {
        super::*,
        proptest::prelude::*,
        sha2::{Digest, Sha256},
    };

    fn d(preimage: &str) -> [u8; 8] {
        let h = Sha256::digest(preimage.as_bytes());
        h[..8].try_into().expect("8 bytes")
    }

    #[test]
    fn discriminators_match_anchor_scheme() {
        assert_eq!(ix::SETTLE, d("global:settle"));
        assert_eq!(ix::SETTLE_NAIVE_V1, d("global:settle_naive_v1"));
        assert_eq!(disc::CONFIG, d("account:Config"));
        assert_eq!(disc::MAKER, d("account:Maker"));
        assert_eq!(disc::NONCE_PAGE, d("account:NoncePage"));
        assert_eq!(disc::QUOTE_FILL, d("account:QuoteFill"));
        assert_eq!(disc::SETTLED_EVENT, d("event:Settled"));
    }

    #[test]
    fn layout_lengths() {
        assert_eq!(config::LEN, 8 + 32 + 32 + 2 + 1 + 1);
        assert_eq!(maker::LEN, 8 + 32 + 32 + 8 + 1 + 1 + 1);
        assert_eq!(nonce_page::LEN, 8 + 32 + 8 + 32 + 1);
        assert_eq!(quote_fill::LEN, 8 + 32 + 8 + 32 + 8 + 1 + 32);
        assert_eq!(quote_fill::PAYER + 32, quote_fill::LEN);
        assert_eq!(settle_accounts::FIXED, settle_accounts::INSTRUCTIONS + 1);
        assert_eq!(SettleArgs::ENCODED_LEN, 184);
        assert_eq!(SettleArgs::IX_DATA_LEN, 192);
        assert_eq!(SettledEvent::LEN, 128);
    }

    #[test]
    fn discriminator_check_order() {
        use crate::anchor_codes::*;
        assert_eq!(
            check_discriminator(&[1, 2, 3], &disc::MAKER),
            Err(ACCOUNT_DISCRIMINATOR_NOT_FOUND)
        );
        assert_eq!(
            check_discriminator(&[0u8; 83], &disc::MAKER),
            Err(ACCOUNT_DISCRIMINATOR_MISMATCH)
        );
        let mut m = [0u8; 83];
        m[..8].copy_from_slice(&disc::MAKER);
        assert_eq!(check_discriminator(&m, &disc::MAKER), Ok(()));
    }

    #[test]
    fn duplicates() {
        let (a, b, c) = ([1u8; 32], [2u8; 32], [1u8; 32]);
        assert_eq!(first_duplicate(&[&a, &b]), None);
        assert_eq!(first_duplicate(&[&a, &b, &c]), Some((0, 2)));
        assert_eq!(first_duplicate(&[]), None);
    }

    proptest! {
        #[test]
        fn settle_args_roundtrip(fill in any::<u64>(), min_out in any::<u64>(), max_in in any::<u64>(), nonce in any::<u64>(), maker in any::<[u8; 32]>()) {
            let a = SettleArgs {
                quote: Quote { maker, nonce, ..Quote::default() },
                fill_amount: fill,
                min_out,
                max_in,
            };
            prop_assert_eq!(SettleArgs::decode(&a.encode()), Some(a));
            let data = a.ix_data(ix::SETTLE);
            prop_assert_eq!(&data[..8], &ix::SETTLE[..]);
            prop_assert_eq!(SettleArgs::decode(&data[8..]), Some(a));
        }

        #[test]
        fn event_roundtrip(maker in any::<[u8; 32]>(), taker in any::<[u8; 32]>(), words in any::<[u64; 7]>()) {
            let e = SettledEvent {
                maker, taker, nonce: words[0], fill_amount: words[1], taker_gross_in: words[2],
                maker_net_in: words[3], taker_net_out: words[4], protocol_fee: words[5], filled_total: words[6],
            };
            prop_assert_eq!(SettledEvent::decode(&e.encode()), Some(e));
        }
    }

    #[test]
    fn decode_rejects_short_args_and_bad_event() {
        assert_eq!(SettleArgs::decode(&[0u8; 183]), None);
        assert_eq!(SettledEvent::decode(&[0u8; SettledEvent::LEN]), None);
        assert_eq!(SettledEvent::decode(&[0u8; 3]), None);
    }
}
