// SPDX-License-Identifier: MIT
//! Maker quotes and their domain-separated signing message.
//!
//! A quote is serialised exactly as Anchor/borsh serialises the `Quote` struct
//! in the instruction arguments (fixed-size fields, little-endian, no padding),
//! so the signed message can embed the argument bytes verbatim:
//!
//! ```text
//! message = QUOTE_DOMAIN (16) || program_id (32) || borsh(quote) (160)   = 208 bytes
//! borsh(quote) = maker | maker_mint | taker_mint | maker_amount | taker_amount
//!              | nonce | expiry | taker
//! ```
//!
//! Binding the program id prevents a quote signed for one deployment from being
//! replayed against another; the constant domain tag prevents the maker's key
//! from being tricked into signing a quote while believing it signs something
//! else. `taker == [0; 32]` marks an open quote that any taker may fill.

use crate::{Pubkey, RfqError, read_key, read_u64};

/// 16-byte domain-separation tag prefixed to every signed quote.
pub const QUOTE_DOMAIN: [u8; 16] = *b"SOLANA-RFQ:QUOTE";

/// A maker's firm offer: sell up to `maker_amount` of `maker_mint` for
/// `taker_amount` of `taker_mint` (pro-rata for partial fills).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Quote {
    /// Wallet that owns the maker registry entry and its vaults.
    pub maker: Pubkey,
    /// Mint the maker sells (leaves the maker vault).
    pub maker_mint: Pubkey,
    /// Mint the maker buys (enters the maker vault).
    pub taker_mint: Pubkey,
    /// Maximum gross amount of `maker_mint` the maker delivers across all fills.
    pub maker_amount: u64,
    /// Net amount of `taker_mint` the maker must receive for a full fill.
    pub taker_amount: u64,
    /// Replay-protection nonce (bit `nonce % 256` of page `nonce / 256`).
    pub nonce: u64,
    /// Last valid unix timestamp (inclusive).
    pub expiry: i64,
    /// Only this key may fill; `[0; 32]` means anyone.
    pub taker: Pubkey,
}

impl Quote {
    /// Length of the borsh encoding.
    pub const ENCODED_LEN: usize = 32 * 3 + 8 * 4 + 32;
    /// Length of the signed message.
    pub const MESSAGE_LEN: usize = QUOTE_DOMAIN.len() + 32 + Self::ENCODED_LEN;

    /// Borsh-compatible encoding (identical to Anchor's argument serialisation).
    pub fn encode(&self) -> [u8; Self::ENCODED_LEN] {
        let mut out = [0u8; Self::ENCODED_LEN];
        out[0..32].copy_from_slice(&self.maker);
        out[32..64].copy_from_slice(&self.maker_mint);
        out[64..96].copy_from_slice(&self.taker_mint);
        out[96..104].copy_from_slice(&self.maker_amount.to_le_bytes());
        out[104..112].copy_from_slice(&self.taker_amount.to_le_bytes());
        out[112..120].copy_from_slice(&self.nonce.to_le_bytes());
        out[120..128].copy_from_slice(&self.expiry.to_le_bytes());
        out[128..160].copy_from_slice(&self.taker);
        out
    }

    /// Decodes the borsh encoding; `None` if `bytes` is shorter than
    /// [`Self::ENCODED_LEN`].
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        Some(Self {
            maker: *read_key(bytes, 0)?,
            maker_mint: *read_key(bytes, 32)?,
            taker_mint: *read_key(bytes, 64)?,
            maker_amount: read_u64(bytes, 96)?,
            taker_amount: read_u64(bytes, 104)?,
            nonce: read_u64(bytes, 112)?,
            expiry: read_u64(bytes, 120)? as i64,
            taker: *read_key(bytes, 128)?,
        })
    }

    /// The exact bytes the maker's quote signer signs.
    pub fn message(&self, program_id: &Pubkey) -> [u8; Self::MESSAGE_LEN] {
        message_from_encoded(program_id, &self.encode())
    }

    /// `true` when any taker may fill the quote.
    #[inline(always)]
    pub fn is_open(&self) -> bool {
        self.taker == [0u8; 32]
    }

    /// Stateless sanity checks every settlement path runs first.
    pub fn validate(&self) -> Result<(), RfqError> {
        if self.maker_mint == self.taker_mint {
            return Err(RfqError::InvalidMintPair);
        }
        if self.maker_amount == 0 || self.taker_amount == 0 {
            return Err(RfqError::ZeroAmount);
        }
        Ok(())
    }
}

/// Builds the signed message from an already-encoded quote (zero re-encoding on
/// the Pinocchio hot path, which slices the encoding straight out of the
/// instruction data).
pub fn message_from_encoded(
    program_id: &Pubkey,
    encoded: &[u8; Quote::ENCODED_LEN],
) -> [u8; Quote::MESSAGE_LEN] {
    let mut msg = [0u8; Quote::MESSAGE_LEN];
    msg[..16].copy_from_slice(&QUOTE_DOMAIN);
    msg[16..48].copy_from_slice(program_id);
    msg[48..].copy_from_slice(encoded);
    msg
}

/// Compares a candidate message with the expected encoding without building
/// the expected message (three slice comparisons, no copy).
pub fn message_matches(
    candidate: &[u8],
    program_id: &Pubkey,
    encoded: &[u8; Quote::ENCODED_LEN],
) -> bool {
    candidate.len() == Quote::MESSAGE_LEN
        && candidate[..16] == QUOTE_DOMAIN
        && candidate[16..48] == program_id[..]
        && candidate[48..] == encoded[..]
}

#[cfg(test)]
mod tests {
    use {super::*, proptest::prelude::*};

    fn arb_quote() -> impl Strategy<Value = Quote> {
        (
            any::<[u8; 32]>(),
            any::<[u8; 32]>(),
            any::<[u8; 32]>(),
            any::<u64>(),
            any::<u64>(),
            any::<u64>(),
            any::<i64>(),
            any::<[u8; 32]>(),
        )
            .prop_map(
                |(
                    maker,
                    maker_mint,
                    taker_mint,
                    maker_amount,
                    taker_amount,
                    nonce,
                    expiry,
                    taker,
                )| {
                    Quote {
                        maker,
                        maker_mint,
                        taker_mint,
                        maker_amount,
                        taker_amount,
                        nonce,
                        expiry,
                        taker,
                    }
                },
            )
    }

    proptest! {
        #[test]
        fn encode_decode_roundtrip(q in arb_quote()) {
            prop_assert_eq!(Quote::decode(&q.encode()), Some(q));
        }

        #[test]
        fn message_layout_and_matcher_agree(q in arb_quote(), pid in any::<[u8; 32]>(), other in any::<[u8; 32]>()) {
            let enc = q.encode();
            let msg = q.message(&pid);
            prop_assert_eq!(&msg[..16], &QUOTE_DOMAIN[..]);
            prop_assert_eq!(&msg[16..48], &pid[..]);
            prop_assert_eq!(&msg[48..], &enc[..]);
            prop_assert!(message_matches(&msg, &pid, &enc));
            // Any other program id yields a different message (domain separation).
            prop_assume!(other != pid);
            prop_assert!(!message_matches(&msg, &other, &enc));
        }

        #[test]
        fn any_single_byte_flip_breaks_the_match(q in arb_quote(), pid in any::<[u8; 32]>(), idx in 0usize..Quote::MESSAGE_LEN, bit in 0u8..8) {
            let enc = q.encode();
            let mut msg = q.message(&pid);
            msg[idx] ^= 1 << bit;
            prop_assert!(!message_matches(&msg, &pid, &enc));
        }
    }

    #[test]
    fn decode_rejects_short_input() {
        assert_eq!(Quote::decode(&[0u8; Quote::ENCODED_LEN - 1]), None);
    }

    #[test]
    fn matcher_rejects_wrong_length() {
        let q = Quote::default();
        let enc = q.encode();
        let msg = q.message(&[7; 32]);
        assert!(!message_matches(
            &msg[..Quote::MESSAGE_LEN - 1],
            &[7; 32],
            &enc
        ));
    }

    #[test]
    fn validate_rules() {
        let mut q = Quote {
            maker_mint: [1; 32],
            taker_mint: [2; 32],
            maker_amount: 1,
            taker_amount: 1,
            ..Quote::default()
        };
        assert_eq!(q.validate(), Ok(()));
        q.taker_mint = q.maker_mint;
        assert_eq!(q.validate(), Err(RfqError::InvalidMintPair));
        q.taker_mint = [2; 32];
        q.maker_amount = 0;
        assert_eq!(q.validate(), Err(RfqError::ZeroAmount));
        q.maker_amount = 1;
        q.taker_amount = 0;
        assert_eq!(q.validate(), Err(RfqError::ZeroAmount));
    }

    #[test]
    fn open_quote_flag() {
        let mut q = Quote::default();
        assert!(q.is_open());
        q.taker[31] = 1;
        assert!(!q.is_open());
    }

    #[test]
    fn sizes() {
        assert_eq!(Quote::ENCODED_LEN, 160);
        assert_eq!(Quote::MESSAGE_LEN, 208);
    }
}
