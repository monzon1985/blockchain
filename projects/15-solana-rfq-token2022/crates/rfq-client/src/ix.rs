// SPDX-License-Identifier: MIT
//! Instruction builders. Account order and argument encoding follow the
//! Anchor program exactly (`#[derive(Accounts)]` field order, borsh args,
//! `sha256("global:<name>")[..8]` discriminators).

use {
    crate::{INSTRUCTIONS_SYSVAR_ID, Pubkey, SYSTEM_PROGRAM_ID, pda},
    rfq_core::layout::{SettleArgs, ix as disc},
    sha2::{Digest, Sha256},
    solana_instruction::{AccountMeta, Instruction},
};

/// Anchor instruction discriminator `sha256("global:<name>")[..8]`.
pub fn discriminator(name: &str) -> [u8; 8] {
    let h = Sha256::digest(format!("global:{name}").as_bytes());
    let mut d = [0u8; 8];
    d.copy_from_slice(&h[..8]);
    d
}

fn build(program: &Pubkey, name: &str, args: &[u8], accounts: Vec<AccountMeta>) -> Instruction {
    let mut data = discriminator(name).to_vec();
    data.extend_from_slice(args);
    Instruction {
        program_id: *program,
        accounts,
        data,
    }
}

/// `initialize_config(fee_bps)`.
pub fn initialize_config(program: &Pubkey, admin: &Pubkey, fee_bps: u16) -> Instruction {
    build(
        program,
        "initialize_config",
        &fee_bps.to_le_bytes(),
        vec![
            AccountMeta::new(*admin, true),
            AccountMeta::new(pda::config(program).0, false),
            AccountMeta::new_readonly(*program, false),
            AccountMeta::new_readonly(pda::program_data(program), false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
        ],
    )
}

fn admin_only(program: &Pubkey, admin: &Pubkey, name: &str, args: &[u8]) -> Instruction {
    build(
        program,
        name,
        args,
        vec![
            AccountMeta::new_readonly(*admin, true),
            AccountMeta::new(pda::config(program).0, false),
        ],
    )
}

/// `set_fee(fee_bps)`.
pub fn set_fee(program: &Pubkey, admin: &Pubkey, fee_bps: u16) -> Instruction {
    admin_only(program, admin, "set_fee", &fee_bps.to_le_bytes())
}

/// `set_paused(paused)`.
pub fn set_paused(program: &Pubkey, admin: &Pubkey, paused: bool) -> Instruction {
    admin_only(program, admin, "set_paused", &[u8::from(paused)])
}

/// `propose_admin(new_admin)`.
pub fn propose_admin(program: &Pubkey, admin: &Pubkey, new_admin: &Pubkey) -> Instruction {
    admin_only(program, admin, "propose_admin", new_admin.as_ref())
}

/// `accept_admin()`.
pub fn accept_admin(program: &Pubkey, new_admin: &Pubkey) -> Instruction {
    build(
        program,
        "accept_admin",
        &[],
        vec![
            AccountMeta::new_readonly(*new_admin, true),
            AccountMeta::new(pda::config(program).0, false),
        ],
    )
}

/// `init_fee_vault()` for `mint`.
pub fn init_fee_vault(
    program: &Pubkey,
    admin: &Pubkey,
    mint: &Pubkey,
    token_program: &Pubkey,
) -> Instruction {
    build(
        program,
        "init_fee_vault",
        &[],
        vec![
            AccountMeta::new(*admin, true),
            AccountMeta::new_readonly(pda::config(program).0, false),
            AccountMeta::new_readonly(*mint, false),
            AccountMeta::new(pda::fee_vault(program, mint).0, false),
            AccountMeta::new_readonly(*token_program, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
        ],
    )
}

/// `withdraw_fees(amount)`; `remaining` carries transfer-hook extras.
#[allow(clippy::too_many_arguments)]
pub fn withdraw_fees(
    program: &Pubkey,
    admin: &Pubkey,
    mint: &Pubkey,
    fee_vault: &Pubkey,
    destination: &Pubkey,
    token_program: &Pubkey,
    amount: u64,
    remaining: &[AccountMeta],
) -> Instruction {
    let mut accounts = vec![
        AccountMeta::new_readonly(*admin, true),
        AccountMeta::new_readonly(pda::config(program).0, false),
        AccountMeta::new_readonly(*mint, false),
        AccountMeta::new(*fee_vault, false),
        AccountMeta::new(*destination, false),
        AccountMeta::new_readonly(*token_program, false),
    ];
    accounts.extend_from_slice(remaining);
    build(program, "withdraw_fees", &amount.to_le_bytes(), accounts)
}

/// `register_maker(quote_signer)`.
pub fn register_maker(program: &Pubkey, owner: &Pubkey, quote_signer: &Pubkey) -> Instruction {
    build(
        program,
        "register_maker",
        quote_signer.as_ref(),
        vec![
            AccountMeta::new(*owner, true),
            AccountMeta::new(pda::maker(program, owner).0, false),
            AccountMeta::new_readonly(pda::vault_authority(program, owner).0, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
        ],
    )
}

fn maker_only(program: &Pubkey, owner: &Pubkey, name: &str, args: &[u8]) -> Instruction {
    build(
        program,
        name,
        args,
        vec![
            AccountMeta::new_readonly(*owner, true),
            AccountMeta::new(pda::maker(program, owner).0, false),
        ],
    )
}

/// `set_quote_signer(quote_signer)`.
pub fn set_quote_signer(program: &Pubkey, owner: &Pubkey, quote_signer: &Pubkey) -> Instruction {
    maker_only(program, owner, "set_quote_signer", quote_signer.as_ref())
}

/// `set_maker_active(active)`.
pub fn set_maker_active(program: &Pubkey, owner: &Pubkey, active: bool) -> Instruction {
    maker_only(program, owner, "set_maker_active", &[u8::from(active)])
}

/// `bump_min_nonce(min_nonce)`.
pub fn bump_min_nonce(program: &Pubkey, owner: &Pubkey, min_nonce: u64) -> Instruction {
    maker_only(program, owner, "bump_min_nonce", &min_nonce.to_le_bytes())
}

/// `init_vault()` for `mint`.
pub fn init_vault(
    program: &Pubkey,
    owner: &Pubkey,
    mint: &Pubkey,
    token_program: &Pubkey,
) -> Instruction {
    build(
        program,
        "init_vault",
        &[],
        vec![
            AccountMeta::new(*owner, true),
            AccountMeta::new_readonly(pda::maker(program, owner).0, false),
            AccountMeta::new_readonly(pda::vault_authority(program, owner).0, false),
            AccountMeta::new_readonly(*mint, false),
            AccountMeta::new(pda::vault(program, owner, mint).0, false),
            AccountMeta::new_readonly(*token_program, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
        ],
    )
}

/// `deposit(amount)` from `source` into the maker's PDA vault.
pub fn deposit(
    program: &Pubkey,
    owner: &Pubkey,
    mint: &Pubkey,
    source: &Pubkey,
    token_program: &Pubkey,
    amount: u64,
    remaining: &[AccountMeta],
) -> Instruction {
    let mut accounts = vec![
        AccountMeta::new_readonly(*owner, true),
        AccountMeta::new_readonly(pda::maker(program, owner).0, false),
        AccountMeta::new_readonly(pda::vault_authority(program, owner).0, false),
        AccountMeta::new_readonly(*mint, false),
        AccountMeta::new(*source, false),
        AccountMeta::new(pda::vault(program, owner, mint).0, false),
        AccountMeta::new_readonly(*token_program, false),
    ];
    accounts.extend_from_slice(remaining);
    build(program, "deposit", &amount.to_le_bytes(), accounts)
}

/// `withdraw(amount)` from `vault` (any vault-authority-owned account).
#[allow(clippy::too_many_arguments)]
pub fn withdraw(
    program: &Pubkey,
    owner: &Pubkey,
    mint: &Pubkey,
    vault: &Pubkey,
    destination: &Pubkey,
    token_program: &Pubkey,
    amount: u64,
    remaining: &[AccountMeta],
) -> Instruction {
    let mut accounts = vec![
        AccountMeta::new_readonly(*owner, true),
        AccountMeta::new_readonly(pda::maker(program, owner).0, false),
        AccountMeta::new_readonly(pda::vault_authority(program, owner).0, false),
        AccountMeta::new_readonly(*mint, false),
        AccountMeta::new(*vault, false),
        AccountMeta::new(*destination, false),
        AccountMeta::new_readonly(*token_program, false),
    ];
    accounts.extend_from_slice(remaining);
    build(program, "withdraw", &amount.to_le_bytes(), accounts)
}

/// `init_nonce_page(page)`.
pub fn init_nonce_page(program: &Pubkey, owner: &Pubkey, page: u64) -> Instruction {
    build(
        program,
        "init_nonce_page",
        &page.to_le_bytes(),
        vec![
            AccountMeta::new(*owner, true),
            AccountMeta::new_readonly(pda::maker(program, owner).0, false),
            AccountMeta::new(pda::nonce_page(program, owner, page).0, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
        ],
    )
}

/// `cancel_nonces(page, mask)`.
pub fn cancel_nonces(program: &Pubkey, owner: &Pubkey, page: u64, mask: &[u8; 32]) -> Instruction {
    let mut args = page.to_le_bytes().to_vec();
    args.extend_from_slice(mask);
    build(
        program,
        "cancel_nonces",
        &args,
        vec![
            AccountMeta::new_readonly(*owner, true),
            AccountMeta::new(pda::nonce_page(program, owner, page).0, false),
        ],
    )
}

/// The caller-chosen accounts of a settlement; PDAs are derived.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SettleAccounts {
    /// Taker (signer, fee payer of the `QuoteFill` rent).
    pub taker: Pubkey,
    /// Maker owner (`quote.maker`).
    pub maker_owner: Pubkey,
    /// Mint the maker sells.
    pub maker_mint: Pubkey,
    /// Mint the maker buys.
    pub taker_mint: Pubkey,
    /// Maker's `maker_mint` vault.
    pub maker_vault_out: Pubkey,
    /// Maker's `taker_mint` vault.
    pub maker_vault_in: Pubkey,
    /// Taker's `taker_mint` account.
    pub taker_src: Pubkey,
    /// Taker's `maker_mint` account.
    pub taker_dst: Pubkey,
    /// Protocol fee vault for `maker_mint`.
    pub fee_vault: Pubkey,
    /// Token program of `maker_mint`.
    pub maker_token_program: Pubkey,
    /// Token program of `taker_mint`.
    pub taker_token_program: Pubkey,
}

impl SettleAccounts {
    /// Account metas in the program's order, before any remaining accounts.
    pub fn metas(&self, program: &Pubkey, nonce: u64) -> Vec<AccountMeta> {
        let owner = &self.maker_owner;
        vec![
            AccountMeta::new(self.taker, true),
            AccountMeta::new_readonly(pda::config(program).0, false),
            AccountMeta::new_readonly(pda::maker(program, owner).0, false),
            AccountMeta::new_readonly(pda::vault_authority(program, owner).0, false),
            AccountMeta::new(
                pda::nonce_page(program, owner, rfq_core::nonce::page_index(nonce)).0,
                false,
            ),
            AccountMeta::new(pda::quote_fill(program, owner, nonce).0, false),
            AccountMeta::new_readonly(self.maker_mint, false),
            AccountMeta::new_readonly(self.taker_mint, false),
            AccountMeta::new(self.maker_vault_out, false),
            AccountMeta::new(self.maker_vault_in, false),
            AccountMeta::new(self.taker_src, false),
            AccountMeta::new(self.taker_dst, false),
            AccountMeta::new(self.fee_vault, false),
            AccountMeta::new_readonly(self.maker_token_program, false),
            AccountMeta::new_readonly(self.taker_token_program, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
            AccountMeta::new_readonly(INSTRUCTIONS_SYSVAR_ID, false),
        ]
    }
}

fn settle_with(
    discriminator: [u8; 8],
    program: &Pubkey,
    accounts: &SettleAccounts,
    args: &SettleArgs,
    remaining: &[AccountMeta],
) -> Instruction {
    let mut metas = accounts.metas(program, args.quote.nonce);
    metas.extend_from_slice(remaining);
    Instruction {
        program_id: *program,
        accounts: metas,
        data: args.ix_data(discriminator).to_vec(),
    }
}

/// `settle(args)` — strict v2. Works for both implementations (same ABI).
pub fn settle(
    program: &Pubkey,
    accounts: &SettleAccounts,
    args: &SettleArgs,
    remaining: &[AccountMeta],
) -> Instruction {
    settle_with(disc::SETTLE, program, accounts, args, remaining)
}

/// `settle_naive_v1(args)` — the deliberately vulnerable v1. Only the
/// `naive-v1` exploit builds (at their own program ids) contain it; production
/// builds answer `InstructionFallbackNotFound`.
pub fn settle_naive_v1(
    program: &Pubkey,
    accounts: &SettleAccounts,
    args: &SettleArgs,
    remaining: &[AccountMeta],
) -> Instruction {
    settle_with(disc::SETTLE_NAIVE_V1, program, accounts, args, remaining)
}

/// `close_quote_fill(quote)` — permissionless; refunds the tracker's rent to
/// `payer`, the taker recorded in the tracker.
pub fn close_quote_fill(program: &Pubkey, quote: &rfq_core::Quote, payer: &Pubkey) -> Instruction {
    let owner = Pubkey::new_from_array(quote.maker);
    build(
        program,
        "close_quote_fill",
        &quote.encode(),
        vec![
            AccountMeta::new_readonly(pda::maker(program, &owner).0, false),
            AccountMeta::new_readonly(
                pda::nonce_page(program, &owner, rfq_core::nonce::page_index(quote.nonce)).0,
                false,
            ),
            AccountMeta::new(pda::quote_fill(program, &owner, quote.nonce).0, false),
            AccountMeta::new(*payer, false),
        ],
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settle_discriminators_match_core() {
        assert_eq!(discriminator("settle"), disc::SETTLE);
        assert_eq!(discriminator("settle_naive_v1"), disc::SETTLE_NAIVE_V1);
    }

    #[test]
    fn close_quote_fill_shape() {
        let q = rfq_core::Quote {
            maker: [2; 32],
            nonce: 300,
            ..rfq_core::Quote::default()
        };
        let payer = Pubkey::new_from_array([5; 32]);
        let ix = close_quote_fill(&crate::RFQ_PROGRAM_ID, &q, &payer);
        assert_eq!(ix.data[..8], discriminator("close_quote_fill"));
        assert_eq!(ix.data[8..], q.encode());
        let owner = Pubkey::new_from_array([2; 32]);
        assert_eq!(
            ix.accounts[2].pubkey,
            pda::quote_fill(&crate::RFQ_PROGRAM_ID, &owner, 300).0
        );
        assert!(ix.accounts[2].is_writable && ix.accounts[3].is_writable);
        assert_eq!(ix.accounts[3].pubkey, payer);
    }

    #[test]
    fn settle_account_order_is_stable() {
        let k = |b: u8| Pubkey::new_from_array([b; 32]);
        let a = SettleAccounts {
            taker: k(1),
            maker_owner: k(2),
            maker_mint: k(3),
            taker_mint: k(4),
            maker_vault_out: k(5),
            maker_vault_in: k(6),
            taker_src: k(7),
            taker_dst: k(8),
            fee_vault: k(9),
            maker_token_program: k(10),
            taker_token_program: k(11),
        };
        let metas = a.metas(&crate::RFQ_PROGRAM_ID, 300);
        assert_eq!(metas.len(), 17);
        assert!(metas[0].is_signer && metas[0].is_writable);
        assert_eq!(
            metas[4].pubkey,
            pda::nonce_page(&crate::RFQ_PROGRAM_ID, &k(2), 1).0
        );
        assert_eq!(metas[16].pubkey, INSTRUCTIONS_SYSVAR_ID);
        let writable: Vec<usize> = metas
            .iter()
            .enumerate()
            .filter(|(_, m)| m.is_writable)
            .map(|(i, _)| i)
            .collect();
        assert_eq!(writable, vec![0, 4, 5, 8, 9, 10, 11, 12]);
    }
}
