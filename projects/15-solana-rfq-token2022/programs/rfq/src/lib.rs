// SPDX-License-Identifier: MIT
//! # rfq — atomic settlement of maker-signed RFQ quotes (Anchor 1.2)
//!
//! Makers register an ed25519 *quote signer*, fund per-mint vaults owned by a
//! per-maker PDA and publish quotes off-chain. A taker settles a quote by
//! sending a transaction whose instruction immediately preceding `settle` is an
//! `Ed25519SigVerify111…` precompile instruction over the quote message; the
//! program introspects it through the instructions sysvar, then moves
//! `taker → maker vault` and `maker vault → taker` (+ protocol fee) atomically.
//!
//! * Replay protection: per-maker 256-nonce bitmap pages, a bulk
//!   `min_nonce` cancel, expiry via `Clock`, and per-quote fill tracking.
//! * Token-2022: transfer-fee mints are settled gross-vs-net with explicit
//!   slippage bounds; transfer-hook mints are settled with on-chain
//!   `ExtraAccountMetaList` resolution.
//! * `settle_naive_v1` (opt-in feature `naive-v1`, off by default) reproduces
//!   the classic "some ed25519 instruction exists" bug for the exploit test.
//!   The feature also moves the program to a distinct id, so the vulnerable
//!   artefact can never share the production address.
//!
//! The hot path is re-implemented zero-copy in `programs/rfq-pinocchio`;
//! both implementations share `rfq-core` and are tested for identical
//! behaviour.

pub mod error;
pub mod events;
pub mod instructions;
pub mod state;
pub mod token_cpi;

use {
    anchor_lang::prelude::*,
    instructions::*,
    state::{Quote, SettleArgs},
};

#[cfg(not(feature = "naive-v1"))]
declare_id!("RFQU3KiXMzdvdjrxx369DDnBx7jhGaJkCdPDvmrcJCk");
// The exploit build (`--features naive-v1`) lives at its own address.
#[cfg(feature = "naive-v1")]
declare_id!("RFQNaiveV1Exp1oitDemo1111111111111111111111");

/// Instruction handlers.
#[program]
pub mod rfq {
    use super::*;

    /// Creates the global config. Must be signed by the program's upgrade
    /// authority, which becomes the admin.
    pub fn initialize_config(ctx: Context<InitializeConfig>, fee_bps: u16) -> Result<()> {
        admin::initialize_config(ctx, fee_bps)
    }

    /// Sets the protocol fee (≤ `MAX_PROTOCOL_FEE_BPS`).
    pub fn set_fee(ctx: Context<AdminOnly>, fee_bps: u16) -> Result<()> {
        admin::set_fee(ctx, fee_bps)
    }

    /// Pauses or resumes settlement.
    pub fn set_paused(ctx: Context<AdminOnly>, paused: bool) -> Result<()> {
        admin::set_paused(ctx, paused)
    }

    /// Step 1 of the two-step admin transfer.
    pub fn propose_admin(ctx: Context<AdminOnly>, new_admin: Pubkey) -> Result<()> {
        admin::propose_admin(ctx, new_admin)
    }

    /// Step 2 of the two-step admin transfer, signed by the proposed admin.
    pub fn accept_admin(ctx: Context<AcceptAdmin>) -> Result<()> {
        admin::accept_admin(ctx)
    }

    /// Creates the protocol fee vault for a mint (owned by the config PDA).
    pub fn init_fee_vault(ctx: Context<InitFeeVault>) -> Result<()> {
        admin::init_fee_vault(ctx)
    }

    /// Withdraws accrued protocol fees.
    pub fn withdraw_fees<'info>(
        ctx: Context<'info, WithdrawFees<'info>>,
        amount: u64,
    ) -> Result<()> {
        admin::withdraw_fees(ctx, amount)
    }

    /// Registers the signer as a maker with the given quote-signing key.
    pub fn register_maker(ctx: Context<RegisterMaker>, quote_signer: Pubkey) -> Result<()> {
        maker::register_maker(ctx, quote_signer)
    }

    /// Rotates the maker's quote-signing key (invalidates unsigned-by-new-key quotes).
    pub fn set_quote_signer(ctx: Context<MakerOnly>, quote_signer: Pubkey) -> Result<()> {
        maker::set_quote_signer(ctx, quote_signer)
    }

    /// Activates or deactivates the maker.
    pub fn set_maker_active(ctx: Context<MakerOnly>, active: bool) -> Result<()> {
        maker::set_maker_active(ctx, active)
    }

    /// Cancels every quote with `nonce < min_nonce` (monotonic).
    pub fn bump_min_nonce(ctx: Context<MakerOnly>, min_nonce: u64) -> Result<()> {
        maker::bump_min_nonce(ctx, min_nonce)
    }

    /// Creates the maker's vault token account for a mint.
    pub fn init_vault(ctx: Context<InitVault>) -> Result<()> {
        maker::init_vault(ctx)
    }

    /// Deposits into a maker vault.
    pub fn deposit<'info>(ctx: Context<'info, Deposit<'info>>, amount: u64) -> Result<()> {
        maker::deposit(ctx, amount)
    }

    /// Withdraws from any token account owned by the maker's vault authority.
    pub fn withdraw<'info>(ctx: Context<'info, Withdraw<'info>>, amount: u64) -> Result<()> {
        maker::withdraw(ctx, amount)
    }

    /// Creates the nonce bitmap page `page` (nonces `256·page .. 256·page+255`).
    pub fn init_nonce_page(ctx: Context<InitNoncePage>, page: u64) -> Result<()> {
        maker::init_nonce_page(ctx, page)
    }

    /// Cancels the quotes whose bits are set in `mask` on page `page`.
    pub fn cancel_nonces(ctx: Context<CancelNonces>, page: u64, mask: [u8; 32]) -> Result<()> {
        maker::cancel_nonces(ctx, page, mask)
    }

    /// Permissionless: closes the fill tracker of a dead quote (nonce used or
    /// cancelled, below `min_nonce`, or expired) and refunds its rent to the
    /// taker that paid it.
    pub fn close_quote_fill(ctx: Context<CloseQuoteFill>, quote: Quote) -> Result<()> {
        quote_fill::close_quote_fill(ctx, quote)
    }

    /// Settles (a part of) a maker-signed quote with strict ed25519
    /// introspection.
    pub fn settle<'info>(ctx: Context<'info, Settle<'info>>, args: SettleArgs) -> Result<()> {
        settle::handler(ctx, args, settle::SigMode::Strict)
    }

    /// **Deliberately vulnerable.** Identical to `settle` except that it only
    /// checks that *some* ed25519 instruction exists in the transaction.
    #[cfg(feature = "naive-v1")]
    pub fn settle_naive_v1<'info>(
        ctx: Context<'info, Settle<'info>>,
        args: SettleArgs,
    ) -> Result<()> {
        settle::handler(ctx, args, settle::SigMode::NaiveV1)
    }
}
