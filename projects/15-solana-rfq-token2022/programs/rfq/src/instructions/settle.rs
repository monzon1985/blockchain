// SPDX-License-Identifier: MIT
//! `settle` (strict, v2) and `settle_naive_v1` (deliberately vulnerable).
//!
//! Both share every account constraint and every economic rule; they differ
//! only in how the quote signature is established:
//!
//! * **v2** loads the instruction *immediately preceding* `settle` from the
//!   instructions sysvar and requires it to be an ed25519 precompile
//!   instruction with exactly one signature, all three offset
//!   instruction-indices equal to `u16::MAX`, the maker's registered quote
//!   signer as public key and the domain-separated quote encoding as message.
//! * **v1** only checks that *some* instruction in the transaction targets the
//!   ed25519 program. Any valid signature — e.g. the attacker's own key over
//!   the attacker's own bytes — satisfies it (see the exploit test).

use {
    crate::{
        error::{RfqError, core_err},
        events::Settled,
        state::{Config, Maker, NoncePage, QuoteFill, SettleArgs},
        token_cpi,
    },
    anchor_lang::prelude::*,
    anchor_spl::token_interface::{Mint, TokenAccount, TokenInterface},
    rfq_core::{
        ed25519,
        ids::ED25519_PROGRAM,
        math::{SettleInputs, compute_settlement},
        nonce, seeds,
    },
    solana_instructions_sysvar::{load_current_index_checked, load_instruction_at_checked},
};

/// Which signature check `handler` performs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SigMode {
    /// Strict introspection of the preceding ed25519 instruction.
    Strict,
    /// "Some ed25519 instruction exists" — vulnerable by design.
    NaiveV1,
}

/// Accounts of `settle` / `settle_naive_v1`. The order is the ABI shared with
/// the Pinocchio implementation.
#[derive(Accounts)]
#[instruction(args: SettleArgs)]
pub struct Settle<'info> {
    /// Taker: signs, pays the `taker_mint` leg and (on a first fill) the
    /// `QuoteFill` rent.
    #[account(mut)]
    pub taker: Signer<'info>,
    /// Global config.
    #[account(seeds = [seeds::CONFIG], bump = config.bump)]
    pub config: Box<Account<'info, Config>>,
    /// Registry entry of `args.quote.maker`.
    #[account(seeds = [seeds::MAKER, args.quote.maker.as_ref()], bump = maker.bump)]
    pub maker: Box<Account<'info, Maker>>,
    /// CHECK: signer-only PDA of the maker, verified by seeds and the recorded bump.
    #[account(seeds = [seeds::VAULT_AUTHORITY, args.quote.maker.as_ref()], bump = maker.vault_authority_bump)]
    pub vault_authority: UncheckedAccount<'info>,
    /// Nonce page holding `args.quote.nonce`.
    #[account(
        mut,
        seeds = [seeds::NONCE_PAGE, args.quote.maker.as_ref(), &nonce::page_index(args.quote.nonce).to_le_bytes()],
        bump = nonce_page.bump
    )]
    pub nonce_page: Box<Account<'info, NoncePage>>,
    /// Fill tracker of this quote, created on first fill (also when its
    /// address was pre-funded: `init_if_needed` then tops up, allocates and
    /// assigns instead of `create_account`).
    #[account(
        init_if_needed,
        payer = taker,
        space = 8 + QuoteFill::INIT_SPACE,
        seeds = [seeds::QUOTE_FILL, args.quote.maker.as_ref(), &args.quote.nonce.to_le_bytes()],
        bump
    )]
    pub quote_fill: Box<Account<'info, QuoteFill>>,
    /// Mint the maker sells.
    #[account(address = args.quote.maker_mint @ RfqError::MintMismatch, mint::token_program = maker_token_program)]
    pub maker_mint: Box<InterfaceAccount<'info, Mint>>,
    /// Mint the maker buys.
    #[account(address = args.quote.taker_mint @ RfqError::MintMismatch, mint::token_program = taker_token_program)]
    pub taker_mint: Box<InterfaceAccount<'info, Mint>>,
    /// Maker `maker_mint` vault (any account owned by the vault authority).
    #[account(mut, token::mint = maker_mint, token::authority = vault_authority, token::token_program = maker_token_program)]
    pub maker_vault_out: Box<InterfaceAccount<'info, TokenAccount>>,
    /// Maker `taker_mint` vault (any account owned by the vault authority).
    #[account(mut, token::mint = taker_mint, token::authority = vault_authority, token::token_program = taker_token_program)]
    pub maker_vault_in: Box<InterfaceAccount<'info, TokenAccount>>,
    /// Taker's `taker_mint` account.
    #[account(mut, token::mint = taker_mint, token::authority = taker, token::token_program = taker_token_program)]
    pub taker_src: Box<InterfaceAccount<'info, TokenAccount>>,
    /// Receives the taker's `maker_mint` (any owner).
    #[account(mut, token::mint = maker_mint, token::token_program = maker_token_program)]
    pub taker_dst: Box<InterfaceAccount<'info, TokenAccount>>,
    /// Protocol fee vault for `maker_mint` (owned by the config PDA).
    #[account(mut, token::mint = maker_mint, token::authority = config, token::token_program = maker_token_program)]
    pub fee_vault: Box<InterfaceAccount<'info, TokenAccount>>,
    /// Token program of `maker_mint`.
    pub maker_token_program: Interface<'info, TokenInterface>,
    /// Token program of `taker_mint`.
    pub taker_token_program: Interface<'info, TokenInterface>,
    /// System program (for `QuoteFill` creation).
    pub system_program: Program<'info, System>,
    /// CHECK: address-constrained to the instructions sysvar.
    #[account(address = solana_instructions_sysvar::ID)]
    pub instructions: UncheckedAccount<'info>,
}

/// v2: strict introspection of the instruction immediately before `settle`.
fn verify_strict(ix_sysvar: &AccountInfo, signer: &Pubkey, message: &[u8]) -> Result<()> {
    let current = load_current_index_checked(ix_sysvar)
        .map_err(|_| error!(RfqError::MalformedInstructionsSysvar))?;
    require!(current > 0, RfqError::MissingSignatureInstruction);
    let ix = load_instruction_at_checked(usize::from(current - 1), ix_sysvar)
        .map_err(|_| error!(RfqError::MalformedInstructionsSysvar))?;
    require!(
        ix.program_id.to_bytes() == ED25519_PROGRAM,
        RfqError::NotEd25519Instruction
    );
    ed25519::verify_inline_single(&ix.data, &signer.to_bytes(), |m| m == message).map_err(core_err)
}

/// v1: **vulnerable** — accepts if any instruction targets the ed25519 program.
fn verify_naive(ix_sysvar: &AccountInfo) -> Result<()> {
    let mut i = 0usize;
    while let Ok(ix) = load_instruction_at_checked(i, ix_sysvar) {
        if ix.program_id.to_bytes() == ED25519_PROGRAM {
            return Ok(());
        }
        i += 1;
    }
    err!(RfqError::MissingSignatureInstruction)
}

/// Shared settlement logic.
pub fn handler<'info>(
    ctx: Context<'info, Settle<'info>>,
    args: SettleArgs,
    mode: SigMode,
) -> Result<()> {
    let program_id = *ctx.program_id;
    let remaining = ctx.remaining_accounts;
    let quote_fill_bump = ctx.bumps.quote_fill;
    let a = ctx.accounts;
    let quote = args.quote.to_core();

    // --- Checks -----------------------------------------------------------
    require!(!a.config.paused, RfqError::Paused);
    quote.validate().map_err(core_err)?;
    require!(a.maker.active, RfqError::MakerInactive);
    let clock = Clock::get()?;
    require!(clock.unix_timestamp <= quote.expiry, RfqError::QuoteExpired);
    require!(
        quote.is_open() || quote.taker == a.taker.key().to_bytes(),
        RfqError::TakerNotAllowed
    );
    require!(quote.nonce >= a.maker.min_nonce, RfqError::NonceCancelled);
    require!(
        !nonce::is_used(&a.nonce_page.bits, quote.nonce),
        RfqError::NonceAlreadyUsed
    );

    let message = quote.message(&program_id.to_bytes());
    match mode {
        SigMode::Strict => verify_strict(&a.instructions, &a.maker.quote_signer, &message)?,
        SigMode::NaiveV1 => verify_naive(&a.instructions)?,
    }

    let quote_hash = solana_sha256_hasher::hashv(&[&message]).to_bytes();
    if a.quote_fill.filled == 0 {
        a.quote_fill.maker = args.quote.maker;
        a.quote_fill.nonce = quote.nonce;
        a.quote_fill.quote_hash = quote_hash;
        a.quote_fill.bump = quote_fill_bump;
        a.quote_fill.payer = a.taker.key();
    } else {
        require!(
            a.quote_fill.quote_hash == quote_hash,
            RfqError::QuoteMismatch
        );
    }

    let s = compute_settlement(&SettleInputs {
        maker_amount: quote.maker_amount,
        taker_amount: quote.taker_amount,
        filled_before: a.quote_fill.filled,
        fill: args.fill_amount,
        protocol_fee_bps: a.config.fee_bps,
        maker_mint_fee: token_cpi::epoch_transfer_fee(
            &a.maker_mint.to_account_info(),
            clock.epoch,
        )?,
        taker_mint_fee: token_cpi::epoch_transfer_fee(
            &a.taker_mint.to_account_info(),
            clock.epoch,
        )?,
        min_out: args.min_out,
        max_in: args.max_in,
    })
    .map_err(core_err)?;

    // --- Effects ----------------------------------------------------------
    a.quote_fill.filled = s.filled_after;
    if s.completes {
        nonce::mark_used(&mut a.nonce_page.bits, quote.nonce);
    }
    // Anchor would only serialise `Account<T>` state in `exit()`, after the
    // CPIs below. Persist it now so checks-effects-interactions also holds at
    // the data level: any program the token CPIs reach (a transfer hook) that
    // reads the nonce page or the tracker already sees this fill.
    a.nonce_page.exit(&program_id)?;
    a.quote_fill.exit(&program_id)?;

    // --- Interactions -------------------------------------------------------
    token_cpi::transfer_checked_with_hook(
        &a.taker_token_program.to_account_info(),
        &a.taker_src.to_account_info(),
        &a.taker_mint.to_account_info(),
        &a.maker_vault_in.to_account_info(),
        &a.taker.to_account_info(),
        remaining,
        s.taker_gross_in,
        a.taker_mint.decimals,
        &[],
    )?;
    let bump = [a.maker.vault_authority_bump];
    let vault_signer: &[&[u8]] = &[seeds::VAULT_AUTHORITY, args.quote.maker.as_ref(), &bump];
    token_cpi::transfer_checked_with_hook(
        &a.maker_token_program.to_account_info(),
        &a.maker_vault_out.to_account_info(),
        &a.maker_mint.to_account_info(),
        &a.taker_dst.to_account_info(),
        &a.vault_authority.to_account_info(),
        remaining,
        s.taker_gross_out,
        a.maker_mint.decimals,
        &[vault_signer],
    )?;
    token_cpi::transfer_checked_with_hook(
        &a.maker_token_program.to_account_info(),
        &a.maker_vault_out.to_account_info(),
        &a.maker_mint.to_account_info(),
        &a.fee_vault.to_account_info(),
        &a.vault_authority.to_account_info(),
        remaining,
        s.protocol_fee,
        a.maker_mint.decimals,
        &[vault_signer],
    )?;

    // An exhausted quote's tracker is closed right away when the taker that
    // paid its rent completes it (the nonce bit now guards against replay).
    // If another taker completes it, the tracker stays until the permissionless
    // `close_quote_fill` refunds the original payer.
    if s.completes && a.quote_fill.payer == a.taker.key() {
        a.quote_fill.close(a.taker.to_account_info())?;
    }

    emit!(Settled {
        maker: args.quote.maker,
        taker: a.taker.key(),
        nonce: quote.nonce,
        fill_amount: args.fill_amount,
        taker_gross_in: s.taker_gross_in,
        maker_net_in: s.maker_net_in,
        taker_net_out: s.taker_net_out,
        protocol_fee: s.protocol_fee,
        filled_total: s.filled_after,
    });
    Ok(())
}
