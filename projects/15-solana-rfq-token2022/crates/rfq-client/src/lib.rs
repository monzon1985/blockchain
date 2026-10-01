// SPDX-License-Identifier: MIT
//! # rfq-client
//!
//! Everything an off-chain taker, maker or keeper needs to talk to the RFQ
//! programs:
//!
//! * [`pda`] — every program-derived address,
//! * [`ix`] — instruction builders for every instruction (Anchor ABI, which
//!   the Pinocchio `settle` shares byte for byte),
//! * [`sign`] — quote signing and the ed25519 precompile instruction,
//! * [`hooks`] — transfer-hook extra-account resolution (the same
//!   `rfq-core` resolver the Pinocchio program runs on-chain) and settlement
//!   planning,
//! * [`tx`] — compute budget and **v0 transactions with an address lookup
//!   table**, which is what makes hooked settlements fit in 1232 bytes.

#![warn(missing_docs)]

pub mod hooks;
pub mod ix;
pub mod pda;
pub mod sign;
pub mod tx;

pub use {rfq_core, solana_address::Address as Pubkey};

/// Program id of the Anchor program.
pub const RFQ_PROGRAM_ID: Pubkey = Pubkey::new_from_array(rfq_core::ids::RFQ_PROGRAM);
/// Program id of the Pinocchio program.
pub const RFQ_PINOCCHIO_PROGRAM_ID: Pubkey =
    Pubkey::new_from_array(rfq_core::ids::RFQ_PINOCCHIO_PROGRAM);
/// Program id of the Anchor program's `naive-v1` exploit build.
pub const RFQ_NAIVE_PROGRAM_ID: Pubkey = Pubkey::new_from_array(rfq_core::ids::RFQ_NAIVE_PROGRAM);
/// Program id of the Pinocchio program's `naive-v1` exploit build.
pub const RFQ_PINOCCHIO_NAIVE_PROGRAM_ID: Pubkey =
    Pubkey::new_from_array(rfq_core::ids::RFQ_PINOCCHIO_NAIVE_PROGRAM);
/// Program id of the in-repo allowlist transfer hook.
pub const TEST_HOOK_PROGRAM_ID: Pubkey = Pubkey::new_from_array(rfq_core::ids::TEST_HOOK_PROGRAM);
/// SPL Token program id.
pub const TOKEN_PROGRAM_ID: Pubkey = Pubkey::new_from_array(rfq_core::ids::TOKEN_PROGRAM);
/// SPL Token-2022 program id.
pub const TOKEN_2022_PROGRAM_ID: Pubkey = Pubkey::new_from_array(rfq_core::ids::TOKEN_2022_PROGRAM);
/// System program id.
pub const SYSTEM_PROGRAM_ID: Pubkey = Pubkey::new_from_array(rfq_core::ids::SYSTEM_PROGRAM);
/// ed25519 precompile id.
pub const ED25519_PROGRAM_ID: Pubkey = Pubkey::new_from_array(rfq_core::ids::ED25519_PROGRAM);
/// Instructions sysvar id.
pub const INSTRUCTIONS_SYSVAR_ID: Pubkey =
    Pubkey::new_from_array(rfq_core::ids::INSTRUCTIONS_SYSVAR);

/// Client-side errors.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ClientError {
    /// A settlement rule would reject the fill.
    #[error("settlement rejected: {0:?}")]
    Settlement(rfq_core::RfqError),
    /// Transfer-hook resolution failed.
    #[error("transfer-hook resolution failed: {0:?}")]
    Hook(rfq_core::hook::HookError),
    /// A required account is missing or malformed.
    #[error("account {0} missing or malformed")]
    Account(Pubkey),
    /// v0 message compilation failed.
    #[error("message compilation failed: {0}")]
    Compile(String),
    /// Signing failed.
    #[error("signing failed: {0}")]
    Signing(String),
}
