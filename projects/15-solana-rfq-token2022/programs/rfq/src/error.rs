// SPDX-License-Identifier: MIT
//! Program errors. The variant order is the ABI: it must match
//! `rfq_core::RfqError` (checked by `tests::codes_match_core`).

use anchor_lang::prelude::*;

/// Custom errors (codes 6000..).
#[error_code]
pub enum RfqError {
    #[msg("Settlement is paused")]
    Paused,
    #[msg("Maker is inactive")]
    MakerInactive,
    #[msg("Quote sells and buys the same mint")]
    InvalidMintPair,
    #[msg("Mint account does not match the quote")]
    MintMismatch,
    #[msg("Quote expired")]
    QuoteExpired,
    #[msg("Quote is restricted to another taker")]
    TakerNotAllowed,
    #[msg("Nonce is below the maker's minimum (cancelled)")]
    NonceCancelled,
    #[msg("Nonce already used or cancelled")]
    NonceAlreadyUsed,
    #[msg("A partial fill exists for different quote terms")]
    QuoteMismatch,
    #[msg("Amount must be positive")]
    ZeroAmount,
    #[msg("Fill exceeds the remaining quote size")]
    FillExceedsRemaining,
    #[msg("Taker would pay more than max_in")]
    SlippageMaxIn,
    #[msg("Taker would receive less than min_out")]
    SlippageMinOut,
    #[msg("Arithmetic overflow")]
    MathOverflow,
    #[msg("No signature instruction precedes settle")]
    MissingSignatureInstruction,
    #[msg("Preceding instruction is not an ed25519 verification")]
    NotEd25519Instruction,
    #[msg("Malformed ed25519 instruction")]
    MalformedEd25519Instruction,
    #[msg("ed25519 offsets must reference the ed25519 instruction itself")]
    Ed25519OffsetsNotInline,
    #[msg("Quote was not signed by the maker's quote signer")]
    SignerMismatch,
    #[msg("Signed message does not match the quote")]
    MessageMismatch,
    #[msg("Protocol fee above the hard cap")]
    FeeTooHigh,
    #[msg("Only the pending admin can accept")]
    NotPendingAdmin,
    #[msg("New minimum nonce must be greater than the current one")]
    NonceNotIncreasing,
    #[msg("Instructions sysvar could not be parsed")]
    MalformedInstructionsSysvar,
    #[msg("Signer is not the program upgrade authority")]
    NotUpgradeAuthority,
    #[msg("Signer is not authorized for this account")]
    Unauthorized,
    #[msg("Quote can still be filled; its tracker cannot be closed")]
    QuoteStillLive,
}

impl From<rfq_core::RfqError> for RfqError {
    fn from(e: rfq_core::RfqError) -> Self {
        use rfq_core::RfqError as C;
        match e {
            C::Paused => Self::Paused,
            C::MakerInactive => Self::MakerInactive,
            C::InvalidMintPair => Self::InvalidMintPair,
            C::MintMismatch => Self::MintMismatch,
            C::QuoteExpired => Self::QuoteExpired,
            C::TakerNotAllowed => Self::TakerNotAllowed,
            C::NonceCancelled => Self::NonceCancelled,
            C::NonceAlreadyUsed => Self::NonceAlreadyUsed,
            C::QuoteMismatch => Self::QuoteMismatch,
            C::ZeroAmount => Self::ZeroAmount,
            C::FillExceedsRemaining => Self::FillExceedsRemaining,
            C::SlippageMaxIn => Self::SlippageMaxIn,
            C::SlippageMinOut => Self::SlippageMinOut,
            C::MathOverflow => Self::MathOverflow,
            C::MissingSignatureInstruction => Self::MissingSignatureInstruction,
            C::NotEd25519Instruction => Self::NotEd25519Instruction,
            C::MalformedEd25519Instruction => Self::MalformedEd25519Instruction,
            C::Ed25519OffsetsNotInline => Self::Ed25519OffsetsNotInline,
            C::SignerMismatch => Self::SignerMismatch,
            C::MessageMismatch => Self::MessageMismatch,
            C::FeeTooHigh => Self::FeeTooHigh,
            C::NotPendingAdmin => Self::NotPendingAdmin,
            C::NonceNotIncreasing => Self::NonceNotIncreasing,
            C::MalformedInstructionsSysvar => Self::MalformedInstructionsSysvar,
            C::NotUpgradeAuthority => Self::NotUpgradeAuthority,
            C::Unauthorized => Self::Unauthorized,
            C::QuoteStillLive => Self::QuoteStillLive,
        }
    }
}

/// Converts a core error into an Anchor error (keeps Anchor's error logging).
pub fn core_err(e: rfq_core::RfqError) -> anchor_lang::error::Error {
    anchor_lang::error::Error::from(RfqError::from(e))
}

#[cfg(test)]
mod tests {
    use {super::*, anchor_lang::error::ErrorCode as A, rfq_core::anchor_codes as C};

    /// The custom-error ABI is identical to `rfq-core`'s.
    #[test]
    fn codes_match_core() {
        for e in rfq_core::RfqError::ALL {
            assert_eq!(u32::from(RfqError::from(e)), e.code(), "{e:?}");
        }
    }

    /// The Anchor framework codes the Pinocchio program reproduces.
    #[test]
    fn anchor_codes_are_pinned() {
        let pairs = [
            (A::ConstraintMut, C::CONSTRAINT_MUT),
            (A::ConstraintOwner, C::CONSTRAINT_OWNER),
            (A::ConstraintRentExempt, C::CONSTRAINT_RENT_EXEMPT),
            (A::ConstraintSeeds, C::CONSTRAINT_SEEDS),
            (A::ConstraintAddress, C::CONSTRAINT_ADDRESS),
            (A::ConstraintTokenMint, C::CONSTRAINT_TOKEN_MINT),
            (A::ConstraintTokenOwner, C::CONSTRAINT_TOKEN_OWNER),
            (A::ConstraintSpace, C::CONSTRAINT_SPACE),
            (
                A::ConstraintTokenTokenProgram,
                C::CONSTRAINT_TOKEN_TOKEN_PROGRAM,
            ),
            (
                A::ConstraintMintTokenProgram,
                C::CONSTRAINT_MINT_TOKEN_PROGRAM,
            ),
            (
                A::ConstraintDuplicateMutableAccount,
                C::CONSTRAINT_DUPLICATE_MUTABLE_ACCOUNT,
            ),
            (
                A::AccountDiscriminatorNotFound,
                C::ACCOUNT_DISCRIMINATOR_NOT_FOUND,
            ),
            (
                A::AccountDiscriminatorMismatch,
                C::ACCOUNT_DISCRIMINATOR_MISMATCH,
            ),
            (A::AccountDidNotDeserialize, C::ACCOUNT_DID_NOT_DESERIALIZE),
            (A::AccountNotEnoughKeys, C::ACCOUNT_NOT_ENOUGH_KEYS),
            (
                A::AccountOwnedByWrongProgram,
                C::ACCOUNT_OWNED_BY_WRONG_PROGRAM,
            ),
            (A::InvalidProgramId, C::INVALID_PROGRAM_ID),
            (A::InvalidProgramExecutable, C::INVALID_PROGRAM_EXECUTABLE),
            (A::AccountNotSigner, C::ACCOUNT_NOT_SIGNER),
            (A::AccountNotInitialized, C::ACCOUNT_NOT_INITIALIZED),
            (A::InstructionMissing, C::INSTRUCTION_MISSING),
            (
                A::InstructionFallbackNotFound,
                C::INSTRUCTION_FALLBACK_NOT_FOUND,
            ),
            (
                A::InstructionDidNotDeserialize,
                C::INSTRUCTION_DID_NOT_DESERIALIZE,
            ),
            (
                A::TryingToInitPayerAsProgramAccount,
                C::TRYING_TO_INIT_PAYER_AS_PROGRAM_ACCOUNT,
            ),
            (A::EventInstructionStub, C::EVENT_INSTRUCTION_STUB),
            (
                A::DeclaredProgramIdMismatch,
                C::DECLARED_PROGRAM_ID_MISMATCH,
            ),
        ];
        for (anchor, core) in pairs {
            assert_eq!(u32::from(anchor), core, "{anchor:?}");
        }
        assert_eq!(C::EVENT_IX_TAG_LE, anchor_lang::event::EVENT_IX_TAG_LE);
    }
}
