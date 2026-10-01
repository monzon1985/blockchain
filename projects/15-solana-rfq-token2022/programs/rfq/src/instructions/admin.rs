// SPDX-License-Identifier: MIT
//! Admin instructions: config lifecycle, fee, pause, two-step admin transfer
//! and protocol fee vaults.

use {
    crate::{error::RfqError, events::*, state::Config, token_cpi},
    anchor_lang::prelude::*,
    anchor_spl::token_interface::{Mint, TokenAccount, TokenInterface},
    rfq_core::{math::MAX_PROTOCOL_FEE_BPS, seeds},
};

/// Accounts of `initialize_config`.
#[derive(Accounts)]
pub struct InitializeConfig<'info> {
    /// Upgrade authority of this program; becomes the admin and pays rent.
    #[account(mut)]
    pub admin: Signer<'info>,
    /// The config PDA being created.
    #[account(init, payer = admin, space = 8 + Config::INIT_SPACE, seeds = [seeds::CONFIG], bump)]
    pub config: Account<'info, Config>,
    /// This program (its `programdata_address` must be `program_data`).
    #[account(constraint = program.programdata_address()? == Some(program_data.key()) @ RfqError::NotUpgradeAuthority)]
    pub program: Program<'info, crate::program::Rfq>,
    /// This program's ProgramData; its upgrade authority must be `admin`.
    #[account(constraint = program_data.upgrade_authority_address == Some(admin.key()) @ RfqError::NotUpgradeAuthority)]
    pub program_data: Account<'info, ProgramData>,
    /// System program.
    pub system_program: Program<'info, System>,
}

/// Creates the config. Gating on the upgrade authority prevents the classic
/// "first caller becomes admin" front-run of an unprotected initializer.
pub fn initialize_config(ctx: Context<InitializeConfig>, fee_bps: u16) -> Result<()> {
    require!(fee_bps <= MAX_PROTOCOL_FEE_BPS, RfqError::FeeTooHigh);
    let config = &mut ctx.accounts.config;
    config.admin = ctx.accounts.admin.key();
    config.pending_admin = Pubkey::default();
    config.fee_bps = fee_bps;
    config.paused = false;
    config.bump = ctx.bumps.config;
    emit!(ConfigInitialized {
        admin: config.admin,
        fee_bps
    });
    Ok(())
}

/// Accounts of admin-only config mutations.
#[derive(Accounts)]
pub struct AdminOnly<'info> {
    /// Current admin.
    pub admin: Signer<'info>,
    /// Config PDA.
    #[account(mut, seeds = [seeds::CONFIG], bump = config.bump, has_one = admin @ RfqError::Unauthorized)]
    pub config: Account<'info, Config>,
}

/// Updates the protocol fee.
pub fn set_fee(ctx: Context<AdminOnly>, fee_bps: u16) -> Result<()> {
    require!(fee_bps <= MAX_PROTOCOL_FEE_BPS, RfqError::FeeTooHigh);
    let config = &mut ctx.accounts.config;
    let old_bps = config.fee_bps;
    config.fee_bps = fee_bps;
    emit!(FeeUpdated {
        old_bps,
        new_bps: fee_bps
    });
    Ok(())
}

/// Pauses or resumes settlement (deposits and withdrawals stay open so
/// makers can always exit).
pub fn set_paused(ctx: Context<AdminOnly>, paused: bool) -> Result<()> {
    ctx.accounts.config.paused = paused;
    emit!(PausedSet { paused });
    Ok(())
}

/// Proposes a new admin (`Pubkey::default()` cancels a pending proposal).
pub fn propose_admin(ctx: Context<AdminOnly>, new_admin: Pubkey) -> Result<()> {
    let config = &mut ctx.accounts.config;
    config.pending_admin = new_admin;
    emit!(AdminProposed {
        admin: config.admin,
        pending_admin: new_admin
    });
    Ok(())
}

/// Accounts of `accept_admin`.
#[derive(Accounts)]
pub struct AcceptAdmin<'info> {
    /// The pending admin.
    pub new_admin: Signer<'info>,
    /// Config PDA.
    #[account(
        mut,
        seeds = [seeds::CONFIG],
        bump = config.bump,
        constraint = config.pending_admin == new_admin.key() @ RfqError::NotPendingAdmin
    )]
    pub config: Account<'info, Config>,
}

/// Completes the admin transfer.
pub fn accept_admin(ctx: Context<AcceptAdmin>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    let old_admin = config.admin;
    config.admin = ctx.accounts.new_admin.key();
    config.pending_admin = Pubkey::default();
    emit!(AdminAccepted {
        old_admin,
        new_admin: config.admin
    });
    Ok(())
}

/// Accounts of `init_fee_vault`.
#[derive(Accounts)]
pub struct InitFeeVault<'info> {
    /// Admin (pays rent).
    #[account(mut)]
    pub admin: Signer<'info>,
    /// Config PDA (the fee vault's authority).
    #[account(seeds = [seeds::CONFIG], bump = config.bump, has_one = admin @ RfqError::Unauthorized)]
    pub config: Account<'info, Config>,
    /// Mint of the vault.
    #[account(mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,
    /// The fee vault being created (`["fee_vault", mint]`).
    #[account(
        init,
        payer = admin,
        seeds = [seeds::FEE_VAULT, mint.key().as_ref()],
        bump,
        token::mint = mint,
        token::authority = config,
        token::token_program = token_program
    )]
    pub fee_vault: InterfaceAccount<'info, TokenAccount>,
    /// SPL Token or Token-2022.
    pub token_program: Interface<'info, TokenInterface>,
    /// System program.
    pub system_program: Program<'info, System>,
}

/// Creates a fee vault for `mint`.
pub fn init_fee_vault(ctx: Context<InitFeeVault>) -> Result<()> {
    emit!(FeeVaultCreated {
        mint: ctx.accounts.mint.key(),
        vault: ctx.accounts.fee_vault.key()
    });
    Ok(())
}

/// Accounts of `withdraw_fees`.
#[derive(Accounts)]
pub struct WithdrawFees<'info> {
    /// Admin.
    pub admin: Signer<'info>,
    /// Config PDA (signs as the vault authority).
    #[account(seeds = [seeds::CONFIG], bump = config.bump, has_one = admin @ RfqError::Unauthorized)]
    pub config: Account<'info, Config>,
    /// Fee mint.
    #[account(mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,
    /// Any token account owned by the config PDA.
    #[account(mut, token::mint = mint, token::authority = config, token::token_program = token_program)]
    pub fee_vault: InterfaceAccount<'info, TokenAccount>,
    /// Destination token account.
    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub destination: InterfaceAccount<'info, TokenAccount>,
    /// SPL Token or Token-2022.
    pub token_program: Interface<'info, TokenInterface>,
}

/// Withdraws `amount` of accrued fees (transfer-hook extras in remaining accounts).
pub fn withdraw_fees<'info>(ctx: Context<'info, WithdrawFees<'info>>, amount: u64) -> Result<()> {
    require!(amount > 0, RfqError::ZeroAmount);
    let a = &ctx.accounts;
    let bump = [a.config.bump];
    let signer: &[&[u8]] = &[seeds::CONFIG, &bump];
    token_cpi::transfer_checked_with_hook(
        &a.token_program.to_account_info(),
        &a.fee_vault.to_account_info(),
        &a.mint.to_account_info(),
        &a.destination.to_account_info(),
        &a.config.to_account_info(),
        ctx.remaining_accounts,
        amount,
        a.mint.decimals,
        &[signer],
    )?;
    emit!(FeesWithdrawn {
        mint: a.mint.key(),
        destination: a.destination.key(),
        amount
    });
    Ok(())
}
