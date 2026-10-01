// SPDX-License-Identifier: MIT
//! Token CPIs that work for SPL Token, Token-2022, transfer-fee mints and
//! transfer-hook mints alike.
//!
//! `anchor_spl::token_interface::transfer_checked` does not forward the extra
//! accounts a transfer-hook mint requires, so transfers are built with
//! `spl_token_2022_interface::instruction::transfer_checked` and, for hooked
//! mints, completed by the canonical
//! `spl_transfer_hook_interface::onchain::add_extra_accounts_for_execute_cpi`,
//! which resolves the mint's `ExtraAccountMetaList` on-chain and picks the
//! required accounts out of `remaining_accounts`. In front of it,
//! [`enforce_extra_meta_bound`] applies the zero-copy resolver's
//! `MAX_EXTRA_METAS` bound so the Anchor and Pinocchio programs accept exactly
//! the same hook mints.

use {
    anchor_lang::{prelude::*, solana_program::program::invoke_signed},
    anchor_spl::token_2022::spl_token_2022::{
        self,
        extension::{
            BaseStateWithExtensions, StateWithExtensions, transfer_fee::TransferFeeConfig,
            transfer_hook,
        },
    },
    rfq_core::{
        hook::{EXTRA_ACCOUNT_METAS_SEED, ExtraMetaList, MAX_EXTRA_METAS},
        transfer_fee::TransferFee,
    },
    spl_transfer_hook_interface::onchain::add_extra_accounts_for_execute_cpi,
};

/// `transfer_checked` of `amount` (no-op for zero), resolving transfer-hook
/// extra accounts from `remaining` when the mint has a hook.
#[allow(clippy::too_many_arguments)]
pub fn transfer_checked_with_hook<'info>(
    token_program: &AccountInfo<'info>,
    from: &AccountInfo<'info>,
    mint: &AccountInfo<'info>,
    to: &AccountInfo<'info>,
    authority: &AccountInfo<'info>,
    remaining: &[AccountInfo<'info>],
    amount: u64,
    decimals: u8,
    signer_seeds: &[&[&[u8]]],
) -> Result<()> {
    if amount == 0 {
        return Ok(());
    }
    let mut ix = spl_token_2022::instruction::transfer_checked(
        token_program.key,
        from.key,
        mint.key,
        to.key,
        authority.key,
        &[],
        amount,
        decimals,
    )?;
    let mut infos = vec![from.clone(), mint.clone(), to.clone(), authority.clone()];
    let hook_program = {
        let data = mint.try_borrow_data()?;
        let state = StateWithExtensions::<spl_token_2022::state::Mint>::unpack(&data)?;
        transfer_hook::get_program_id(&state)
    };
    if let Some(hook_program) = hook_program {
        enforce_extra_meta_bound(&hook_program, mint.key, remaining)?;
        add_extra_accounts_for_execute_cpi(
            &mut ix,
            &mut infos,
            &hook_program,
            from.clone(),
            mint.clone(),
            to.clone(),
            authority.clone(),
            amount,
            remaining,
        )?;
    }
    invoke_signed(&ix, &infos, signer_seeds)?;
    Ok(())
}

/// Rejects (`InvalidArgument`) a hook whose `ExtraAccountMetaList` declares
/// more than [`MAX_EXTRA_METAS`] accounts — the fixed bound of the
/// allocation-free resolver the Pinocchio program uses. Every other case
/// (missing hook program, missing or malformed validation account) is left to
/// the canonical helper, which reports it exactly as the resolver does, so the
/// two programs return identical errors in every case.
fn enforce_extra_meta_bound(
    hook_program: &Pubkey,
    mint: &Pubkey,
    remaining: &[AccountInfo],
) -> Result<()> {
    if !remaining.iter().any(|a| a.key == hook_program) {
        return Ok(());
    }
    let validation =
        Pubkey::find_program_address(&[EXTRA_ACCOUNT_METAS_SEED, mint.as_ref()], hook_program).0;
    let Some(info) = remaining.iter().find(|a| *a.key == validation) else {
        return Ok(());
    };
    let data = info.try_borrow_data()?;
    if let Ok(list) = ExtraMetaList::parse(&data)
        && list.len() > MAX_EXTRA_METAS
    {
        return Err(ProgramError::InvalidArgument.into());
    }
    Ok(())
}

/// The mint's transfer fee in force at `epoch` (zero for legacy mints and
/// Token-2022 mints without the extension).
pub fn epoch_transfer_fee(mint: &AccountInfo, epoch: u64) -> Result<TransferFee> {
    let data = mint.try_borrow_data()?;
    let state = StateWithExtensions::<spl_token_2022::state::Mint>::unpack(&data)?;
    Ok(match state.get_extension::<TransferFeeConfig>() {
        Ok(cfg) => {
            let fee = cfg.get_epoch_fee(epoch);
            TransferFee {
                epoch: fee.epoch.into(),
                maximum_fee: fee.maximum_fee.into(),
                basis_points: fee.transfer_fee_basis_points.into(),
            }
        }
        Err(_) => TransferFee::ZERO,
    })
}
