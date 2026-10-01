// SPDX-License-Identifier: MIT
//! `close_quote_fill`: permissionless clean-up of dead partial-fill trackers.
//!
//! A `QuoteFill` is created (rent paid by the first filler) when a quote is
//! first filled. When the *payer* completes the quote, `settle` closes it
//! immediately. Otherwise the tracker outlives the fill that ended the quote —
//! because another taker completed it, or because the quote was cancelled
//! (`cancel_nonces` / `bump_min_nonce`) or simply expired part-way. This
//! instruction lets anyone close such a tracker and always refunds the rent to
//! the taker recorded as its payer, so tracker rent is never stranded nor
//! handed to a different taker.

use {
    crate::{
        error::RfqError,
        events::QuoteFillClosed,
        state::{Maker, NoncePage, Quote, QuoteFill},
    },
    anchor_lang::prelude::*,
    rfq_core::{nonce, seeds},
};

/// Accounts of `close_quote_fill`.
#[derive(Accounts)]
#[instruction(quote: Quote)]
pub struct CloseQuoteFill<'info> {
    /// Registry entry of `quote.maker` (its `min_nonce` bulk-cancels quotes).
    #[account(seeds = [seeds::MAKER, quote.maker.as_ref()], bump = maker.bump)]
    pub maker: Account<'info, Maker>,
    /// Nonce page holding `quote.nonce` (its bit is set once the quote is
    /// completed or cancelled).
    #[account(
        seeds = [seeds::NONCE_PAGE, quote.maker.as_ref(), &nonce::page_index(quote.nonce).to_le_bytes()],
        bump = nonce_page.bump
    )]
    pub nonce_page: Account<'info, NoncePage>,
    /// The tracker being closed.
    #[account(
        mut,
        seeds = [seeds::QUOTE_FILL, quote.maker.as_ref(), &quote.nonce.to_le_bytes()],
        bump = quote_fill.bump,
        has_one = payer @ RfqError::Unauthorized,
        close = payer
    )]
    pub quote_fill: Account<'info, QuoteFill>,
    /// CHECK: receives the rent; bound to the tracker's recorded payer by `has_one`.
    #[account(mut)]
    pub payer: UncheckedAccount<'info>,
}

/// Closes the tracker of a quote that can no longer be filled.
pub fn close_quote_fill(ctx: Context<CloseQuoteFill>, quote: Quote) -> Result<()> {
    let a = &ctx.accounts;
    let q = quote.to_core();
    // The caller must present the exact quote the tracker belongs to, so the
    // expiry it claims is the signed one.
    let message = q.message(&ctx.program_id.to_bytes());
    let quote_hash = solana_sha256_hasher::hashv(&[&message]).to_bytes();
    require!(
        a.quote_fill.quote_hash == quote_hash,
        RfqError::QuoteMismatch
    );
    let clock = Clock::get()?;
    let dead = nonce::is_used(&a.nonce_page.bits, q.nonce)
        || q.nonce < a.maker.min_nonce
        || clock.unix_timestamp > q.expiry;
    require!(dead, RfqError::QuoteStillLive);
    emit!(QuoteFillClosed {
        maker: quote.maker,
        nonce: q.nonce,
        payer: a.payer.key(),
        filled: a.quote_fill.filled,
    });
    Ok(())
}
