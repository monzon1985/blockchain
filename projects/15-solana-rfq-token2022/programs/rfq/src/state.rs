// SPDX-License-Identifier: MIT
//! Accounts and instruction argument types.
//!
//! Every account is fixed-size, so its borsh layout is exactly the packed
//! layout declared in `rfq_core::layout`, which the Pinocchio program reads and
//! writes at fixed offsets. Two guards keep them in lock-step:
//!
//! * the `const` assertions below fail the build if a struct's *size* drifts;
//! * `tests::borsh_layout_matches_core_offsets` serialises every account with a
//!   distinct sentinel per field and checks each `rfq_core::layout` offset, so a
//!   reordering of same-size fields (e.g. two `u64`s) is caught too.

use {anchor_lang::prelude::*, rfq_core::layout};

/// Global protocol configuration (PDA `["config"]`).
#[account]
#[derive(InitSpace, Debug)]
pub struct Config {
    /// Can change the fee, pause settlement, withdraw fees and hand over admin.
    pub admin: Pubkey,
    /// Proposed admin awaiting `accept_admin` (`Pubkey::default()` if none).
    pub pending_admin: Pubkey,
    /// Protocol fee in basis points, charged on the maker-mint leg.
    pub fee_bps: u16,
    /// When `true`, `settle` is rejected.
    pub paused: bool,
    /// Canonical PDA bump.
    pub bump: u8,
}

/// A registered maker (PDA `["maker", owner]`).
#[account]
#[derive(InitSpace, Debug)]
pub struct Maker {
    /// Wallet that controls the registry entry and the vaults.
    pub owner: Pubkey,
    /// ed25519 key whose signatures make quotes valid (may be a hot key).
    pub quote_signer: Pubkey,
    /// Quotes with `nonce < min_nonce` are cancelled.
    pub min_nonce: u64,
    /// Inactive makers cannot be filled.
    pub active: bool,
    /// Canonical bump of this PDA.
    pub bump: u8,
    /// Canonical bump of the vault-authority PDA `["vault_authority", owner]`.
    pub vault_authority_bump: u8,
}

/// 256 nonces of one maker (PDA `["nonces", owner, page_le]`).
#[account]
#[derive(InitSpace, Debug)]
pub struct NoncePage {
    /// Maker owner.
    pub maker: Pubkey,
    /// Page index: covers nonces `256·page ..= 256·page + 255`.
    pub page: u64,
    /// Bit set ⇒ quote dead (fully filled or cancelled).
    pub bits: [u8; 32],
    /// Canonical PDA bump.
    pub bump: u8,
}

/// Partial-fill tracker of one quote (PDA `["fill", owner, nonce_le]`).
/// Created on the first fill (rent paid by that taker, recorded as `payer`).
/// Closed by `settle` when the payer itself completes the quote; otherwise
/// closed by the permissionless `close_quote_fill` once the quote is dead,
/// always refunding `payer`.
#[account]
#[derive(InitSpace, Debug)]
pub struct QuoteFill {
    /// Maker owner.
    pub maker: Pubkey,
    /// Quote nonce.
    pub nonce: u64,
    /// `sha256` of the signed quote message; later fills must match it.
    pub quote_hash: [u8; 32],
    /// Cumulative `maker_mint` amount filled.
    pub filled: u64,
    /// Canonical PDA bump.
    pub bump: u8,
    /// Taker that paid this tracker's rent; the only possible refund target.
    pub payer: Pubkey,
}

const _: () = assert!(8 + Config::INIT_SPACE == layout::config::LEN);
const _: () = assert!(8 + Maker::INIT_SPACE == layout::maker::LEN);
const _: () = assert!(8 + NoncePage::INIT_SPACE == layout::nonce_page::LEN);
const _: () = assert!(8 + QuoteFill::INIT_SPACE == layout::quote_fill::LEN);

/// A maker quote as passed in instruction data (borsh-identical to
/// `rfq_core::Quote::encode`).
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub struct Quote {
    /// Maker owner (registry key).
    pub maker: Pubkey,
    /// Mint the maker sells.
    pub maker_mint: Pubkey,
    /// Mint the maker buys.
    pub taker_mint: Pubkey,
    /// Maximum `maker_mint` delivered across all fills.
    pub maker_amount: u64,
    /// `taker_mint` the maker must net for a full fill.
    pub taker_amount: u64,
    /// Replay-protection nonce.
    pub nonce: u64,
    /// Last valid unix timestamp (inclusive).
    pub expiry: i64,
    /// Restricted taker, or `Pubkey::default()` for an open quote.
    pub taker: Pubkey,
}

impl Quote {
    /// The shared core representation.
    pub fn to_core(&self) -> rfq_core::Quote {
        rfq_core::Quote {
            maker: self.maker.to_bytes(),
            maker_mint: self.maker_mint.to_bytes(),
            taker_mint: self.taker_mint.to_bytes(),
            maker_amount: self.maker_amount,
            taker_amount: self.taker_amount,
            nonce: self.nonce,
            expiry: self.expiry,
            taker: self.taker.to_bytes(),
        }
    }
}

/// Arguments of `settle` / `settle_naive_v1`.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub struct SettleArgs {
    /// The signed quote.
    pub quote: Quote,
    /// Gross `maker_mint` amount taken out of the maker vault by this fill.
    pub fill_amount: u64,
    /// Minimum `maker_mint` credited to the taker (after protocol and transfer fees).
    pub min_out: u64,
    /// Maximum `taker_mint` the taker sends (including transfer fees).
    pub max_in: u64,
}

#[cfg(test)]
mod tests {
    use {super::*, rfq_core::layout as l};

    fn ser<T: AccountSerialize>(account: &T) -> Vec<u8> {
        let mut out = Vec::new();
        account.try_serialize(&mut out).expect("serialize");
        out
    }

    fn key(b: u8) -> Pubkey {
        Pubkey::new_from_array([b; 32])
    }

    /// Every field lands at the offset the Pinocchio program reads, with a
    /// distinct sentinel per field (same-size field swaps are detected).
    #[test]
    fn borsh_layout_matches_core_offsets() {
        let d = ser(&Config {
            admin: key(1),
            pending_admin: key(2),
            fee_bps: 0x0304,
            paused: true,
            bump: 5,
        });
        assert_eq!(d.len(), l::config::LEN);
        assert_eq!(d[..8], l::disc::CONFIG);
        assert_eq!(d[l::config::ADMIN..l::config::ADMIN + 32], [1; 32]);
        assert_eq!(
            d[l::config::PENDING_ADMIN..l::config::PENDING_ADMIN + 32],
            [2; 32]
        );
        assert_eq!(d[l::config::FEE_BPS..l::config::FEE_BPS + 2], [4, 3]);
        assert_eq!(d[l::config::PAUSED], 1);
        assert_eq!(d[l::config::BUMP], 5);

        let d = ser(&Maker {
            owner: key(6),
            quote_signer: key(7),
            min_nonce: 0x0807_0605_0403_0201,
            active: true,
            bump: 9,
            vault_authority_bump: 10,
        });
        assert_eq!(d.len(), l::maker::LEN);
        assert_eq!(d[..8], l::disc::MAKER);
        assert_eq!(d[l::maker::OWNER..l::maker::OWNER + 32], [6; 32]);
        assert_eq!(
            d[l::maker::QUOTE_SIGNER..l::maker::QUOTE_SIGNER + 32],
            [7; 32]
        );
        assert_eq!(
            d[l::maker::MIN_NONCE..l::maker::MIN_NONCE + 8],
            [1, 2, 3, 4, 5, 6, 7, 8]
        );
        assert_eq!(d[l::maker::ACTIVE], 1);
        assert_eq!(d[l::maker::BUMP], 9);
        assert_eq!(d[l::maker::VAULT_AUTHORITY_BUMP], 10);

        let mut bits = [0u8; 32];
        bits[0] = 0xAB;
        bits[31] = 0xCD;
        let d = ser(&NoncePage {
            maker: key(11),
            page: 0x1112_1314_1516_1718,
            bits,
            bump: 12,
        });
        assert_eq!(d.len(), l::nonce_page::LEN);
        assert_eq!(d[..8], l::disc::NONCE_PAGE);
        assert_eq!(d[l::nonce_page::MAKER..l::nonce_page::MAKER + 32], [11; 32]);
        assert_eq!(
            d[l::nonce_page::PAGE..l::nonce_page::PAGE + 8],
            0x1112_1314_1516_1718u64.to_le_bytes()
        );
        assert_eq!(d[l::nonce_page::BITS..l::nonce_page::BITS + 32], bits);
        assert_eq!(d[l::nonce_page::BUMP], 12);

        let d = ser(&QuoteFill {
            maker: key(13),
            nonce: 0x2122_2324_2526_2728,
            quote_hash: [14; 32],
            filled: 0x3132_3334_3536_3738,
            bump: 15,
            payer: key(16),
        });
        assert_eq!(d.len(), l::quote_fill::LEN);
        assert_eq!(d[..8], l::disc::QUOTE_FILL);
        assert_eq!(d[l::quote_fill::MAKER..l::quote_fill::MAKER + 32], [13; 32]);
        assert_eq!(
            d[l::quote_fill::NONCE..l::quote_fill::NONCE + 8],
            0x2122_2324_2526_2728u64.to_le_bytes()
        );
        assert_eq!(
            d[l::quote_fill::QUOTE_HASH..l::quote_fill::QUOTE_HASH + 32],
            [14; 32]
        );
        assert_eq!(
            d[l::quote_fill::FILLED..l::quote_fill::FILLED + 8],
            0x3132_3334_3536_3738u64.to_le_bytes()
        );
        assert_eq!(d[l::quote_fill::BUMP], 15);
        assert_eq!(d[l::quote_fill::PAYER..l::quote_fill::PAYER + 32], [16; 32]);
    }

    /// Instruction arguments are borsh-identical to `rfq_core`'s encoding.
    #[test]
    fn settle_args_encoding_matches_core() {
        let core = rfq_core::layout::SettleArgs {
            quote: rfq_core::Quote {
                maker: [1; 32],
                maker_mint: [2; 32],
                taker_mint: [3; 32],
                maker_amount: 4,
                taker_amount: 5,
                nonce: 6,
                expiry: -7,
                taker: [8; 32],
            },
            fill_amount: 9,
            min_out: 10,
            max_in: 11,
        };
        let ours = SettleArgs {
            quote: Quote {
                maker: key(1),
                maker_mint: key(2),
                taker_mint: key(3),
                maker_amount: 4,
                taker_amount: 5,
                nonce: 6,
                expiry: -7,
                taker: key(8),
            },
            fill_amount: 9,
            min_out: 10,
            max_in: 11,
        };
        let mut bytes = Vec::new();
        ours.serialize(&mut bytes).expect("borsh");
        assert_eq!(bytes, core.encode());
        assert_eq!(ours.quote.to_core(), core.quote);
    }
}
