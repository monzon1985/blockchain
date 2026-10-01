// SPDX-License-Identifier: MIT
//! # test-hook — an allowlist transfer hook for Token-2022
//!
//! A deliberately small, native (no framework) implementation of the
//! `spl-transfer-hook-interface`, used by the RFQ test-suites to exercise
//! transfer-hook mints end to end. Every transfer of a hooked mint:
//!
//! * must happen inside a real Token-2022 transfer (the source account's
//!   `TransferHookAccount.transferring` flag is set),
//! * must present exactly the extra accounts declared in the mint's
//!   `ExtraAccountMetaList` (`check_account_infos`),
//! * succeeds only if the **destination owner** is allowlisted: the extra
//!   account `["allow", mint, destination.owner]` is resolved from the
//!   destination token account's *data* (an `AccountData` seed), which is the
//!   part of account resolution that callers most often get wrong,
//! * increments a writable per-mint counter `["counter", mint]`, which lets the
//!   tests assert how many times the hook actually ran.
//!
//! This program exists for testing only; it is not part of the RFQ protocol.

#![deny(missing_docs)]

use {
    solana_account_info::{AccountInfo, next_account_info},
    solana_cpi::invoke_signed,
    solana_program_error::{ProgramError, ProgramResult},
    solana_pubkey::Pubkey,
    solana_system_interface_v2::instruction as system_instruction,
    solana_sysvar::{Sysvar, rent::Rent},
    spl_tlv_account_resolution::{
        account::ExtraAccountMeta, seeds::Seed, state::ExtraAccountMetaList,
    },
    spl_token_2022_interface::{
        extension::{
            BaseStateWithExtensions, StateWithExtensions, transfer_hook::TransferHookAccount,
        },
        state::{Account, Mint},
    },
    spl_transfer_hook_interface::{
        collect_extra_account_metas_signer_seeds,
        error::TransferHookError,
        get_extra_account_metas_address_and_bump_seed,
        instruction::{ExecuteInstruction, TransferHookInstruction},
    },
};

solana_pubkey::declare_id!("HookikRw7r4TWeG9qC8AnE9c3uVYQea8bpt6yqdxXvSW");

#[cfg(not(feature = "no-entrypoint"))]
solana_program_entrypoint::entrypoint!(process_instruction);

/// Seed prefix of per-(mint, wallet) allowlist entries.
pub const ALLOW_SEED: &[u8] = b"allow";
/// Seed prefix of the per-mint execution counter.
pub const COUNTER_SEED: &[u8] = b"counter";
/// Discriminator of the program-specific `SetAllowed` instruction (ASCII
/// `thk:allw`; it cannot collide with the interface's sha256-derived ones).
pub const SET_ALLOWED_DISCRIMINATOR: [u8; 8] = [0x74, 0x68, 0x6b, 0x3a, 0x61, 0x6c, 0x6c, 0x77];

/// Custom errors (`ProgramError::Custom`).
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HookError {
    /// The destination owner is not on the mint's allowlist.
    NotAllowlisted = 7001,
    /// Signer is not the mint authority.
    NotMintAuthority = 7002,
    /// An account does not have the expected address.
    WrongAccount = 7003,
    /// The counter overflowed.
    CounterOverflow = 7004,
}

impl From<HookError> for ProgramError {
    fn from(e: HookError) -> Self {
        ProgramError::Custom(e as u32)
    }
}

/// The two extra accounts every transfer must carry.
pub fn extra_account_metas() -> Result<[ExtraAccountMeta; 2], ProgramError> {
    Ok([
        // ["allow", mint, destination.owner] — owner read from the destination
        // token account's data at offset 32.
        ExtraAccountMeta::new_with_seeds(
            &[
                Seed::Literal {
                    bytes: ALLOW_SEED.to_vec(),
                },
                Seed::AccountKey { index: 1 },
                Seed::AccountData {
                    account_index: 2,
                    data_index: 32,
                    length: 32,
                },
            ],
            false,
            false,
        )?,
        // ["counter", mint], writable.
        ExtraAccountMeta::new_with_seeds(
            &[
                Seed::Literal {
                    bytes: COUNTER_SEED.to_vec(),
                },
                Seed::AccountKey { index: 1 },
            ],
            false,
            true,
        )?,
    ])
}

/// Program entrypoint.
pub fn process_instruction(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    data: &[u8],
) -> ProgramResult {
    if data.len() >= 8 && data[..8] == SET_ALLOWED_DISCRIMINATOR {
        let allowed = *data.get(8).ok_or(ProgramError::InvalidInstructionData)? != 0;
        return set_allowed(program_id, accounts, allowed);
    }
    match TransferHookInstruction::unpack(data)? {
        TransferHookInstruction::Execute { amount } => execute(program_id, accounts, amount),
        TransferHookInstruction::InitializeExtraAccountMetaList { .. } => {
            initialize(program_id, accounts)
        }
        TransferHookInstruction::UpdateExtraAccountMetaList { .. } => {
            Err(ProgramError::InvalidInstructionData)
        }
    }
}

fn check_mint_authority(mint: &AccountInfo, authority: &AccountInfo) -> ProgramResult {
    if !authority.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    let data = mint.try_borrow_data()?;
    let state = StateWithExtensions::<Mint>::unpack(&data)?;
    match state.base.mint_authority {
        solana_program_option::COption::Some(a) if a == *authority.key => Ok(()),
        _ => Err(HookError::NotMintAuthority.into()),
    }
}

fn create_pda<'a>(
    program_id: &Pubkey,
    payer: &AccountInfo<'a>,
    target: &AccountInfo<'a>,
    system_program: &AccountInfo<'a>,
    space: usize,
    seeds: &[&[u8]],
) -> ProgramResult {
    let lamports = Rent::get()?.minimum_balance(space);
    invoke_signed(
        &system_instruction::create_account(
            payer.key,
            target.key,
            lamports,
            space as u64,
            program_id,
        ),
        &[payer.clone(), target.clone(), system_program.clone()],
        &[seeds],
    )
}

/// `InitializeExtraAccountMetaList`: accounts `[validation (w), mint,
/// mint_authority (s, w), system_program, counter (w)]`. The meta list written
/// is always [`extra_account_metas`]; the list in the instruction is ignored.
fn initialize(program_id: &Pubkey, accounts: &[AccountInfo]) -> ProgramResult {
    let it = &mut accounts.iter();
    let validation = next_account_info(it)?;
    let mint = next_account_info(it)?;
    let authority = next_account_info(it)?;
    let system_program = next_account_info(it)?;
    let counter = next_account_info(it)?;
    check_mint_authority(mint, authority)?;

    let (expected, bump) = get_extra_account_metas_address_and_bump_seed(mint.key, program_id);
    if expected != *validation.key {
        return Err(HookError::WrongAccount.into());
    }
    let metas = extra_account_metas()?;
    let size = ExtraAccountMetaList::size_of(metas.len())?;
    let bump_seed = [bump];
    let seeds = collect_extra_account_metas_signer_seeds(mint.key, &bump_seed);
    create_pda(
        program_id,
        authority,
        validation,
        system_program,
        size,
        &seeds,
    )?;
    ExtraAccountMetaList::init::<ExecuteInstruction>(
        &mut validation.try_borrow_mut_data()?,
        &metas,
    )?;

    let (expected, bump) =
        Pubkey::find_program_address(&[COUNTER_SEED, mint.key.as_ref()], program_id);
    if expected != *counter.key {
        return Err(HookError::WrongAccount.into());
    }
    create_pda(
        program_id,
        authority,
        counter,
        system_program,
        8,
        &[COUNTER_SEED, mint.key.as_ref(), &[bump]],
    )
}

/// `SetAllowed`: accounts `[allow (w), mint, mint_authority (s, w), wallet,
/// system_program]`; data `discriminator || allowed (u8)`.
fn set_allowed(program_id: &Pubkey, accounts: &[AccountInfo], allowed: bool) -> ProgramResult {
    let it = &mut accounts.iter();
    let allow = next_account_info(it)?;
    let mint = next_account_info(it)?;
    let authority = next_account_info(it)?;
    let wallet = next_account_info(it)?;
    let system_program = next_account_info(it)?;
    check_mint_authority(mint, authority)?;

    let seeds: [&[u8]; 3] = [ALLOW_SEED, mint.key.as_ref(), wallet.key.as_ref()];
    let (expected, bump) = Pubkey::find_program_address(&seeds, program_id);
    if expected != *allow.key {
        return Err(HookError::WrongAccount.into());
    }
    if allow.owner != program_id {
        create_pda(
            program_id,
            authority,
            allow,
            system_program,
            1,
            &[ALLOW_SEED, mint.key.as_ref(), wallet.key.as_ref(), &[bump]],
        )?;
    }
    allow.try_borrow_mut_data()?[0] = u8::from(allowed);
    Ok(())
}

/// `Execute`: accounts `[source, mint, destination, authority, validation,
/// allow, counter]`.
fn execute(program_id: &Pubkey, accounts: &[AccountInfo], amount: u64) -> ProgramResult {
    let it = &mut accounts.iter();
    let source = next_account_info(it)?;
    let _mint = next_account_info(it)?;
    let _destination = next_account_info(it)?;
    let _authority = next_account_info(it)?;
    let validation = next_account_info(it)?;

    // Only callable from inside a Token-2022 transfer.
    {
        let data = source.try_borrow_data()?;
        let state = StateWithExtensions::<Account>::unpack(&data)?;
        let ext = state.get_extension::<TransferHookAccount>()?;
        if !bool::from(ext.transferring) {
            return Err(TransferHookError::ProgramCalledOutsideOfTransfer.into());
        }
    }

    // The extra accounts must be exactly the declared ones, in order.
    let ix_data = TransferHookInstruction::Execute { amount }.pack();
    ExtraAccountMetaList::check_account_infos::<ExecuteInstruction>(
        accounts,
        &ix_data,
        program_id,
        &validation.try_borrow_data()?,
    )?;

    let allow = next_account_info(it)?;
    let counter = next_account_info(it)?;
    let allowed = allow.owner == program_id && allow.try_borrow_data()?.first() == Some(&1);
    if !allowed {
        return Err(HookError::NotAllowlisted.into());
    }

    let mut data = counter.try_borrow_mut_data()?;
    if counter.owner != program_id || data.len() != 8 {
        return Err(HookError::WrongAccount.into());
    }
    let mut raw = [0u8; 8];
    raw.copy_from_slice(&data);
    let next = u64::from_le_bytes(raw)
        .checked_add(1)
        .ok_or(HookError::CounterOverflow)?;
    data.copy_from_slice(&next.to_le_bytes());
    Ok(())
}
