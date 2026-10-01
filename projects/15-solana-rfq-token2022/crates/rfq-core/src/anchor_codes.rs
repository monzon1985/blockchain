// SPDX-License-Identifier: MIT
//! Anchor framework error codes that the Pinocchio implementation reproduces.
//!
//! "Behaviourally identical" is enforced down to the error code: when an
//! account fails validation, `rfq-pinocchio` returns the same
//! `ProgramError::Custom(code)` that Anchor's generated `try_accounts` would.
//! The values below are copied from `anchor-lang-error 1.2.0` and pinned by a
//! unit test inside the Anchor program crate (`programs/rfq`), which compares
//! them with `anchor_lang::error::ErrorCode` directly.

/// `#[account(mut)]` on a non-writable account.
pub const CONSTRAINT_MUT: u32 = 2000;
/// PDA derivation mismatch (or `create_program_address` failure).
pub const CONSTRAINT_SEEDS: u32 = 2006;
/// `#[account(address = ...)]` mismatch.
pub const CONSTRAINT_ADDRESS: u32 = 2012;
/// `token::mint` mismatch.
pub const CONSTRAINT_TOKEN_MINT: u32 = 2014;
/// `token::authority` mismatch.
pub const CONSTRAINT_TOKEN_OWNER: u32 = 2015;
/// `init_if_needed` found an account whose data length differs from `space`.
pub const CONSTRAINT_SPACE: u32 = 2019;
/// `token::token_program` mismatch (token account owned by another token program).
pub const CONSTRAINT_TOKEN_TOKEN_PROGRAM: u32 = 2021;
/// `mint::token_program` mismatch (mint owned by another token program).
pub const CONSTRAINT_MINT_TOKEN_PROGRAM: u32 = 2022;
/// Two mutable, serialising accounts alias the same key.
pub const CONSTRAINT_DUPLICATE_MUTABLE_ACCOUNT: u32 = 2040;
/// `init_if_needed` found an account owned by another program.
pub const CONSTRAINT_OWNER: u32 = 2004;
/// `init_if_needed` found an account below the rent-exempt minimum.
pub const CONSTRAINT_RENT_EXEMPT: u32 = 2005;
/// Account data shorter than the 8-byte discriminator.
pub const ACCOUNT_DISCRIMINATOR_NOT_FOUND: u32 = 3001;
/// Account discriminator mismatch.
pub const ACCOUNT_DISCRIMINATOR_MISMATCH: u32 = 3002;
/// Account data could not be deserialized.
pub const ACCOUNT_DID_NOT_DESERIALIZE: u32 = 3003;
/// Fewer accounts than the instruction declares.
pub const ACCOUNT_NOT_ENOUGH_KEYS: u32 = 3005;
/// Account owned by a program other than the expected one.
pub const ACCOUNT_OWNED_BY_WRONG_PROGRAM: u32 = 3007;
/// A `Program` / `Interface` account has an unexpected key.
pub const INVALID_PROGRAM_ID: u32 = 3008;
/// A `Program` / `Interface` account is not executable.
pub const INVALID_PROGRAM_EXECUTABLE: u32 = 3009;
/// A `Signer` account did not sign.
pub const ACCOUNT_NOT_SIGNER: u32 = 3010;
/// A typed account is system-owned with zero lamports.
pub const ACCOUNT_NOT_INITIALIZED: u32 = 3012;
/// Instruction data shorter than 8 bytes.
pub const INSTRUCTION_MISSING: u32 = 100;
/// Unknown instruction discriminator (also data shorter than 8 bytes: Anchor
/// 1.2's dispatcher matches discriminators with `starts_with` and falls back).
pub const INSTRUCTION_FALLBACK_NOT_FOUND: u32 = 101;
/// Instruction arguments failed to deserialize.
pub const INSTRUCTION_DID_NOT_DESERIALIZE: u32 = 102;
/// The program was invoked at an address other than its declared id.
pub const DECLARED_PROGRAM_ID_MISMATCH: u32 = 4100;
/// `init` with the payer as the account being initialised.
pub const TRYING_TO_INIT_PAYER_AS_PROGRAM_ACCOUNT: u32 = 4101;
/// Instruction data starting with Anchor's event-CPI tag while the program
/// was built without the `event-cpi` feature.
pub const EVENT_INSTRUCTION_STUB: u32 = 1500;

/// `anchor_lang::event::EVENT_IX_TAG` (`0x1d9acb512ea545e4`) in little-endian:
/// the 8-byte prefix Anchor's dispatcher routes to its event-CPI handler.
pub const EVENT_IX_TAG_LE: [u8; 8] = 0x1d9a_cb51_2ea5_45e4u64.to_le_bytes();
