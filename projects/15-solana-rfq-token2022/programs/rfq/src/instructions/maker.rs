// SPDX-License-Identifier: MIT
//! Maker instructions: registry, key rotation, vaults and nonce management.

use {
    crate::{
        error::RfqError,
        events::*,
        state::{Maker, NoncePage},
        token_cpi,
    },
    anchor_lang::prelude::*,
    anchor_spl::token_interface::{Mint, TokenAccount, TokenInterface},
    rfq_core::{nonce, seeds},
};

/// Accounts of `register_maker`.
#[derive(Accounts)]
pub struct RegisterMaker<'info> {
    /// Maker owner (pays rent).
    #[account(mut)]
    pub owner: Signer<'info>,
    /// The maker registry entry being created.
    #[account(init, payer = owner, space = 8 + Maker::INIT_SPACE, seeds = [seeds::MAKER, owner.key().as_ref()], bump)]
    pub maker: Account<'info, Maker>,
    /// CHECK: data-less PDA used only as a CPI signer; its canonical bump is recorded.
    #[account(seeds = [seeds::VAULT_AUTHORITY, owner.key().as_ref()], bump)]
    pub vault_authority: UncheckedAccount<'info>,
    /// System program.
    pub system_program: Program<'info, System>,
}

/// Registers a maker with an ed25519 quote-signing key.
pub fn register_maker(ctx: Context<RegisterMaker>, quote_signer: Pubkey) -> Result<()> {
    let maker = &mut ctx.accounts.maker;
    maker.owner = ctx.accounts.owner.key();
    maker.quote_signer = quote_signer;
    maker.min_nonce = 0;
    maker.active = true;
    maker.bump = ctx.bumps.maker;
    maker.vault_authority_bump = ctx.bumps.vault_authority;
    emit!(MakerRegistered {
        owner: maker.owner,
        quote_signer
    });
    Ok(())
}

/// Accounts of owner-only maker mutations.
#[derive(Accounts)]
pub struct MakerOnly<'info> {
    /// Maker owner.
    pub owner: Signer<'info>,
    /// Maker registry entry.
    #[account(mut, seeds = [seeds::MAKER, owner.key().as_ref()], bump = maker.bump, has_one = owner @ RfqError::Unauthorized)]
    pub maker: Account<'info, Maker>,
}

/// Rotates the quote-signing key; quotes signed by the old key stop settling.
pub fn set_quote_signer(ctx: Context<MakerOnly>, quote_signer: Pubkey) -> Result<()> {
    let maker = &mut ctx.accounts.maker;
    let old_signer = maker.quote_signer;
    maker.quote_signer = quote_signer;
    emit!(QuoteSignerRotated {
        owner: maker.owner,
        old_signer,
        new_signer: quote_signer
    });
    Ok(())
}

/// Activates or deactivates the maker.
pub fn set_maker_active(ctx: Context<MakerOnly>, active: bool) -> Result<()> {
    let maker = &mut ctx.accounts.maker;
    maker.active = active;
    emit!(MakerActiveSet {
        owner: maker.owner,
        active
    });
    Ok(())
}

/// Cancels every outstanding quote with `nonce < min_nonce`.
pub fn bump_min_nonce(ctx: Context<MakerOnly>, min_nonce: u64) -> Result<()> {
    let maker = &mut ctx.accounts.maker;
    require!(min_nonce > maker.min_nonce, RfqError::NonceNotIncreasing);
    maker.min_nonce = min_nonce;
    emit!(MinNonceBumped {
        owner: maker.owner,
        min_nonce
    });
    Ok(())
}

/// Accounts of `init_vault`.
#[derive(Accounts)]
pub struct InitVault<'info> {
    /// Maker owner (pays rent).
    #[account(mut)]
    pub owner: Signer<'info>,
    /// Maker registry entry.
    #[account(seeds = [seeds::MAKER, owner.key().as_ref()], bump = maker.bump, has_one = owner @ RfqError::Unauthorized)]
    pub maker: Account<'info, Maker>,
    /// CHECK: signer-only PDA, verified by seeds and the recorded bump.
    #[account(seeds = [seeds::VAULT_AUTHORITY, owner.key().as_ref()], bump = maker.vault_authority_bump)]
    pub vault_authority: UncheckedAccount<'info>,
    /// Mint of the vault.
    #[account(mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,
    /// Vault token account being created (`["vault", owner, mint]`).
    #[account(
        init,
        payer = owner,
        seeds = [seeds::VAULT, owner.key().as_ref(), mint.key().as_ref()],
        bump,
        token::mint = mint,
        token::authority = vault_authority,
        token::token_program = token_program
    )]
    pub vault: InterfaceAccount<'info, TokenAccount>,
    /// SPL Token or Token-2022.
    pub token_program: Interface<'info, TokenInterface>,
    /// System program.
    pub system_program: Program<'info, System>,
}

/// Creates a vault (Token-2022 account extensions are sized by Anchor).
pub fn init_vault(ctx: Context<InitVault>) -> Result<()> {
    emit!(VaultCreated {
        owner: ctx.accounts.owner.key(),
        mint: ctx.accounts.mint.key(),
        vault: ctx.accounts.vault.key(),
    });
    Ok(())
}

/// Accounts of `deposit`.
#[derive(Accounts)]
pub struct Deposit<'info> {
    /// Maker owner.
    pub owner: Signer<'info>,
    /// Maker registry entry.
    #[account(seeds = [seeds::MAKER, owner.key().as_ref()], bump = maker.bump, has_one = owner @ RfqError::Unauthorized)]
    pub maker: Account<'info, Maker>,
    /// CHECK: signer-only PDA, verified by seeds and the recorded bump.
    #[account(seeds = [seeds::VAULT_AUTHORITY, owner.key().as_ref()], bump = maker.vault_authority_bump)]
    pub vault_authority: UncheckedAccount<'info>,
    /// Mint.
    #[account(mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,
    /// Owner's token account.
    #[account(mut, token::mint = mint, token::authority = owner, token::token_program = token_program)]
    pub source: InterfaceAccount<'info, TokenAccount>,
    /// Destination vault (any account owned by the vault authority).
    #[account(mut, token::mint = mint, token::authority = vault_authority, token::token_program = token_program)]
    pub vault: InterfaceAccount<'info, TokenAccount>,
    /// SPL Token or Token-2022.
    pub token_program: Interface<'info, TokenInterface>,
}

/// Deposits `amount` (gross) into the vault.
pub fn deposit<'info>(ctx: Context<'info, Deposit<'info>>, amount: u64) -> Result<()> {
    require!(amount > 0, RfqError::ZeroAmount);
    let a = &ctx.accounts;
    token_cpi::transfer_checked_with_hook(
        &a.token_program.to_account_info(),
        &a.source.to_account_info(),
        &a.mint.to_account_info(),
        &a.vault.to_account_info(),
        &a.owner.to_account_info(),
        ctx.remaining_accounts,
        amount,
        a.mint.decimals,
        &[],
    )?;
    emit!(Deposited {
        owner: a.owner.key(),
        mint: a.mint.key(),
        amount
    });
    Ok(())
}

/// Accounts of `withdraw`.
#[derive(Accounts)]
pub struct Withdraw<'info> {
    /// Maker owner.
    pub owner: Signer<'info>,
    /// Maker registry entry.
    #[account(seeds = [seeds::MAKER, owner.key().as_ref()], bump = maker.bump, has_one = owner @ RfqError::Unauthorized)]
    pub maker: Account<'info, Maker>,
    /// CHECK: signer-only PDA, verified by seeds and the recorded bump.
    #[account(seeds = [seeds::VAULT_AUTHORITY, owner.key().as_ref()], bump = maker.vault_authority_bump)]
    pub vault_authority: UncheckedAccount<'info>,
    /// Mint.
    #[account(mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,
    /// Any token account owned by the vault authority (settlement may credit
    /// such accounts, so the maker must always be able to sweep them).
    #[account(mut, token::mint = mint, token::authority = vault_authority, token::token_program = token_program)]
    pub vault: InterfaceAccount<'info, TokenAccount>,
    /// Destination token account.
    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub destination: InterfaceAccount<'info, TokenAccount>,
    /// SPL Token or Token-2022.
    pub token_program: Interface<'info, TokenInterface>,
}

/// Withdraws `amount` (gross) from the vault. Works while paused.
pub fn withdraw<'info>(ctx: Context<'info, Withdraw<'info>>, amount: u64) -> Result<()> {
    require!(amount > 0, RfqError::ZeroAmount);
    let a = &ctx.accounts;
    let owner = a.owner.key();
    let bump = [a.maker.vault_authority_bump];
    let signer: &[&[u8]] = &[seeds::VAULT_AUTHORITY, owner.as_ref(), &bump];
    token_cpi::transfer_checked_with_hook(
        &a.token_program.to_account_info(),
        &a.vault.to_account_info(),
        &a.mint.to_account_info(),
        &a.destination.to_account_info(),
        &a.vault_authority.to_account_info(),
        ctx.remaining_accounts,
        amount,
        a.mint.decimals,
        &[signer],
    )?;
    emit!(Withdrawn {
        owner,
        mint: a.mint.key(),
        amount
    });
    Ok(())
}

/// Accounts of `init_nonce_page`.
#[derive(Accounts)]
#[instruction(page: u64)]
pub struct InitNoncePage<'info> {
    /// Maker owner (pays rent).
    #[account(mut)]
    pub owner: Signer<'info>,
    /// Maker registry entry.
    #[account(seeds = [seeds::MAKER, owner.key().as_ref()], bump = maker.bump, has_one = owner @ RfqError::Unauthorized)]
    pub maker: Account<'info, Maker>,
    /// The page being created.
    #[account(
        init,
        payer = owner,
        space = 8 + NoncePage::INIT_SPACE,
        seeds = [seeds::NONCE_PAGE, owner.key().as_ref(), &page.to_le_bytes()],
        bump
    )]
    pub nonce_page: Account<'info, NoncePage>,
    /// System program.
    pub system_program: Program<'info, System>,
}

/// Creates a nonce page.
pub fn init_nonce_page(ctx: Context<InitNoncePage>, page: u64) -> Result<()> {
    let p = &mut ctx.accounts.nonce_page;
    p.maker = ctx.accounts.owner.key();
    p.page = page;
    p.bits = [0; 32];
    p.bump = ctx.bumps.nonce_page;
    emit!(NoncePageCreated {
        owner: p.maker,
        page
    });
    Ok(())
}

/// Accounts of `cancel_nonces`.
#[derive(Accounts)]
#[instruction(page: u64)]
pub struct CancelNonces<'info> {
    /// Maker owner.
    pub owner: Signer<'info>,
    /// The page (seeds bind it to `owner` and `page`).
    #[account(mut, seeds = [seeds::NONCE_PAGE, owner.key().as_ref(), &page.to_le_bytes()], bump = nonce_page.bump)]
    pub nonce_page: Account<'info, NoncePage>,
}

/// Cancels the quotes selected by `mask` (bitwise OR into the page).
pub fn cancel_nonces(ctx: Context<CancelNonces>, page: u64, mask: [u8; 32]) -> Result<()> {
    nonce::cancel_mask(&mut ctx.accounts.nonce_page.bits, &mask);
    emit!(NoncesCancelled {
        owner: ctx.accounts.owner.key(),
        page,
        mask
    });
    Ok(())
}
