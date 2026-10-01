// SPDX-License-Identifier: MIT
//! Protocol error codes.
//!
//! The numeric values are part of the on-chain ABI: the Anchor program declares
//! the same variants in the same order with `#[error_code]` (which numbers them
//! from 6000) and the Pinocchio program returns `ProgramError::Custom(code)`. The
//! integration and equivalence suites assert both programs return these exact
//! codes.

/// Every custom error either program can return.
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RfqError {
    /// Settlement is paused by the admin.
    Paused = 6000,
    /// The maker deactivated its registry entry.
    MakerInactive,
    /// The quote sells and buys the same mint.
    InvalidMintPair,
    /// A mint account does not match the signed quote.
    MintMismatch,
    /// `Clock::unix_timestamp` is past the quote's expiry.
    QuoteExpired,
    /// The quote is restricted to a different taker.
    TakerNotAllowed,
    /// The quote's nonce is below the maker's `min_nonce` (bulk-cancelled).
    NonceCancelled,
    /// The quote's nonce bit is already set (fully filled or cancelled).
    NonceAlreadyUsed,
    /// A partial fill exists for this nonce but for different quote terms.
    QuoteMismatch,
    /// A zero amount was supplied where a positive one is required.
    ZeroAmount,
    /// `fill_amount` exceeds what is left of the quote.
    FillExceedsRemaining,
    /// The taker would have to pay more than `max_in`.
    SlippageMaxIn,
    /// The taker would receive less than `min_out` after all fees.
    SlippageMinOut,
    /// Checked arithmetic overflowed.
    MathOverflow,
    /// No instruction precedes `settle`, or (v1) no ed25519 instruction exists.
    MissingSignatureInstruction,
    /// The preceding instruction is not addressed to the ed25519 precompile.
    NotEd25519Instruction,
    /// The ed25519 instruction data is malformed or carries != 1 signature.
    MalformedEd25519Instruction,
    /// An ed25519 offset points into another instruction (`index != u16::MAX`).
    Ed25519OffsetsNotInline,
    /// The verified public key is not the maker's registered quote signer.
    SignerMismatch,
    /// The verified message is not the domain-separated encoding of the quote.
    MessageMismatch,
    /// The requested protocol fee exceeds [`crate::math::MAX_PROTOCOL_FEE_BPS`].
    FeeTooHigh,
    /// Only the pending admin may accept an admin transfer.
    NotPendingAdmin,
    /// A new minimum nonce must be strictly greater than the current one.
    NonceNotIncreasing,
    /// The instructions sysvar data could not be parsed.
    MalformedInstructionsSysvar,
    /// `initialize_config` must be signed by the program's upgrade authority.
    NotUpgradeAuthority,
    /// The signer is not the admin / maker owner this instruction requires.
    Unauthorized,
    /// `close_quote_fill` on a quote that can still be filled: its nonce bit is
    /// clear, it is not below the maker's `min_nonce` and it has not expired.
    QuoteStillLive,
}

impl RfqError {
    /// The code carried by `ProgramError::Custom`.
    #[inline(always)]
    pub const fn code(self) -> u32 {
        self as u32
    }

    /// All variants in declaration order (used to pin the ABI in tests).
    pub const ALL: [RfqError; 27] = [
        RfqError::Paused,
        RfqError::MakerInactive,
        RfqError::InvalidMintPair,
        RfqError::MintMismatch,
        RfqError::QuoteExpired,
        RfqError::TakerNotAllowed,
        RfqError::NonceCancelled,
        RfqError::NonceAlreadyUsed,
        RfqError::QuoteMismatch,
        RfqError::ZeroAmount,
        RfqError::FillExceedsRemaining,
        RfqError::SlippageMaxIn,
        RfqError::SlippageMinOut,
        RfqError::MathOverflow,
        RfqError::MissingSignatureInstruction,
        RfqError::NotEd25519Instruction,
        RfqError::MalformedEd25519Instruction,
        RfqError::Ed25519OffsetsNotInline,
        RfqError::SignerMismatch,
        RfqError::MessageMismatch,
        RfqError::FeeTooHigh,
        RfqError::NotPendingAdmin,
        RfqError::NonceNotIncreasing,
        RfqError::MalformedInstructionsSysvar,
        RfqError::NotUpgradeAuthority,
        RfqError::Unauthorized,
        RfqError::QuoteStillLive,
    ];
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_are_dense_from_6000() {
        for (i, e) in RfqError::ALL.iter().enumerate() {
            assert_eq!(e.code(), 6000 + i as u32, "{e:?}");
        }
    }
}
