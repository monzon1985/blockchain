// SPDX-License-Identifier: MIT
//! Program-derived addresses (canonical bumps).

use {crate::Pubkey, rfq_core::seeds};

/// `["config"]`.
pub fn config(program: &Pubkey) -> (Pubkey, u8) {
    Pubkey::find_program_address(&[seeds::CONFIG], program)
}

/// `["maker", owner]`.
pub fn maker(program: &Pubkey, owner: &Pubkey) -> (Pubkey, u8) {
    Pubkey::find_program_address(&[seeds::MAKER, owner.as_ref()], program)
}

/// `["vault_authority", owner]`.
pub fn vault_authority(program: &Pubkey, owner: &Pubkey) -> (Pubkey, u8) {
    Pubkey::find_program_address(&[seeds::VAULT_AUTHORITY, owner.as_ref()], program)
}

/// `["vault", owner, mint]`.
pub fn vault(program: &Pubkey, owner: &Pubkey, mint: &Pubkey) -> (Pubkey, u8) {
    Pubkey::find_program_address(&[seeds::VAULT, owner.as_ref(), mint.as_ref()], program)
}

/// `["fee_vault", mint]`.
pub fn fee_vault(program: &Pubkey, mint: &Pubkey) -> (Pubkey, u8) {
    Pubkey::find_program_address(&[seeds::FEE_VAULT, mint.as_ref()], program)
}

/// `["nonces", owner, page_le]`.
pub fn nonce_page(program: &Pubkey, owner: &Pubkey, page: u64) -> (Pubkey, u8) {
    Pubkey::find_program_address(
        &[seeds::NONCE_PAGE, owner.as_ref(), &page.to_le_bytes()],
        program,
    )
}

/// `["fill", owner, nonce_le]`.
pub fn quote_fill(program: &Pubkey, owner: &Pubkey, nonce: u64) -> (Pubkey, u8) {
    Pubkey::find_program_address(
        &[seeds::QUOTE_FILL, owner.as_ref(), &nonce.to_le_bytes()],
        program,
    )
}

/// The transfer-hook validation account `["extra-account-metas", mint]`.
pub fn extra_account_metas(hook_program: &Pubkey, mint: &Pubkey) -> (Pubkey, u8) {
    Pubkey::find_program_address(
        &[rfq_core::hook::EXTRA_ACCOUNT_METAS_SEED, mint.as_ref()],
        hook_program,
    )
}

/// ProgramData account of an upgradeable program.
pub fn program_data(program: &Pubkey) -> Pubkey {
    const BPF_LOADER_UPGRADEABLE: Pubkey =
        solana_address::address!("BPFLoaderUpgradeab1e11111111111111111111111");
    Pubkey::find_program_address(&[program.as_ref()], &BPF_LOADER_UPGRADEABLE).0
}
