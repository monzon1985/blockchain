// SPDX-License-Identifier: MIT
//! # rfq-pinocchio — the RFQ `settle` hot path, zero-copy
//!
//! A re-implementation of the Anchor program's `settle` (and, behind the
//! opt-in `naive-v1` feature, the deliberately vulnerable `settle_naive_v1`)
//! with [Pinocchio](https://github.com/anza-xyz/pinocchio): no allocator, no
//! framework, `AccountView`s parsed in place. It shares the Anchor program's
//! **byte-identical account layouts and instruction ABI** (both go through
//! [`rfq_core`]) and returns the same error codes, check for check, so a
//! Mollusk harness can drive identical instructions against both and compare
//! compute units, and a LiteSVM harness can assert identical results.
//!
//! It is **settle-only and not deployable on its own**: it owner-checks and
//! derives PDAs against its *own* program id, so it never operates on the
//! Anchor program's accounts, and it has no instructions to create its config,
//! maker registry or nonce pages. The test harnesses seed those accounts
//! directly (LiteSVM / Mollusk) using the shared `rfq_core` layouts.
//!
//! Account order (identical to the Anchor `Settle` context):
//! `taker, config, maker, vault_authority, nonce_page, quote_fill, maker_mint,
//! taker_mint, maker_vault_out, maker_vault_in, taker_src, taker_dst,
//! fee_vault, maker_token_program, taker_token_program, system_program,
//! instructions_sysvar, [hook extras…]`.

#![no_std]
#![deny(missing_docs)]

mod settle;
mod token;

use pinocchio::{AccountView, Address, ProgramResult, error::ProgramError};

pinocchio::nostd_panic_handler!();

#[cfg(not(feature = "no-entrypoint"))]
pinocchio::program_entrypoint!(process_instruction);
#[cfg(not(feature = "no-entrypoint"))]
pinocchio::no_allocator!();

/// The program id (`RFPK8mcExbXUku6ikQ4HS4rLQDy1XJpASxmqg2EyLnv`).
#[cfg(not(feature = "naive-v1"))]
pub const ID: Address = Address::new_from_array(rfq_core::ids::RFQ_PINOCCHIO_PROGRAM);
/// The exploit build's program id (`RFPNaiveV1Exp1oitDemo111…`): the
/// vulnerable artefact never shares the production address.
#[cfg(feature = "naive-v1")]
pub const ID: Address = Address::new_from_array(rfq_core::ids::RFQ_PINOCCHIO_NAIVE_PROGRAM);

/// Program entrypoint, mirroring Anchor 1.2's generated `entry`: reject a
/// deployment at any address other than [`ID`] (`DeclaredProgramIdMismatch`),
/// then dispatch on the 8-byte discriminator (prefix match, then the event-CPI
/// stub, then `InstructionFallbackNotFound` — also for data shorter than 8
/// bytes).
pub fn process_instruction(
    program_id: &Address,
    accounts: &mut [AccountView],
    data: &[u8],
) -> ProgramResult {
    use rfq_core::{anchor_codes as ac, layout::ix};
    if program_id != &ID {
        return Err(ProgramError::Custom(ac::DECLARED_PROGRAM_ID_MISMATCH));
    }
    if let Some(args) = data.strip_prefix(&ix::SETTLE) {
        return settle::handler(program_id, accounts, args, settle::SigMode::Strict);
    }
    #[cfg(feature = "naive-v1")]
    if let Some(args) = data.strip_prefix(&ix::SETTLE_NAIVE_V1) {
        return settle::handler(program_id, accounts, args, settle::SigMode::NaiveV1);
    }
    if data.starts_with(&ac::EVENT_IX_TAG_LE) {
        return Err(ProgramError::Custom(ac::EVENT_INSTRUCTION_STUB));
    }
    Err(ProgramError::Custom(ac::INSTRUCTION_FALLBACK_NOT_FOUND))
}
