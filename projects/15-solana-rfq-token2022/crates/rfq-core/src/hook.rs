// SPDX-License-Identifier: MIT AND Apache-2.0
//
// Portions of this file are derived from, and modified from:
//   * `spl-transfer-hook-interface` 2.1 (`onchain::add_extra_accounts_for_execute_cpi`),
//     https://github.com/solana-program/transfer-hook
//   * `spl-tlv-account-resolution` 0.11 (`ExtraAccountMetaList` parsing, seed and
//     pubkey-data resolution, privilege de-escalation),
//     https://github.com/solana-program/libraries
// Both are Copyright (c) Anza Maintainers <maintainers@anza.xyz> and licensed
// under the Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0).
// Modifications (this project, MIT): rewritten as a `no_std`, allocation-free,
// `unsafe`-free resolver over borrowed byte slices with fixed-size buffers and a
// bound of `MAX_EXTRA_METAS` extra metas; errors are returned as `HookError`
// values mirroring the upstream `ProgramError` codes.

//! Transfer-hook extra-account resolution (`ExtraAccountMetaList`), zero-copy
//! and allocation-free.
//!
//! When a mint has the Token-2022 `TransferHook` extension, a program that
//! CPIs `transfer_checked` must append the hook's extra accounts (declared in
//! the validation PDA `["extra-account-metas", mint]` of the hook program), the
//! validation account itself and the hook program id. The canonical on-chain
//! helper is `spl_transfer_hook_interface::onchain::add_extra_accounts_for_execute_cpi`,
//! which the Anchor program uses. This module is a port of that helper
//! (and of `spl_tlv_account_resolution`'s `ExtraAccountMetaList` parsing,
//! seed/pubkey-data resolution and privilege de-escalation) that the Pinocchio
//! program uses instead: same accounts, same order, same privileges and the same
//! `ProgramError` codes, verified differentially in this module's tests.
//!
//! Resolution order (mirrors the canonical helper):
//! 1. the hook program must be among the additional accounts, else
//!    `TransferHookError::IncorrectAccount`;
//! 2. if the validation PDA is absent, only the hook program is appended;
//! 3. otherwise each meta is resolved against the virtual `Execute`
//!    instruction `[source, mint, destination, authority, validation,
//!    extras...]` with data `EXECUTE_DISCRIMINATOR || amount`, de-escalated
//!    (never a signer; writable only if not already present read-only), and
//!    looked up among the additional accounts, else
//!    `AccountResolutionError::IncorrectAccount`;
//! 4. output: `extras..., validation (read-only), hook program (read-only)`.

use crate::Pubkey;

/// `sha256("spl-transfer-hook-interface:execute")[..8]`; also the TLV type of
/// the `ExtraAccountMetaList` entry.
pub const EXECUTE_DISCRIMINATOR: [u8; 8] = [105, 37, 101, 197, 75, 251, 102, 26];
/// Seed prefix of the validation PDA.
pub const EXTRA_ACCOUNT_METAS_SEED: &[u8] = b"extra-account-metas";
/// Size of one packed `ExtraAccountMeta`.
pub const EXTRA_ACCOUNT_META_LEN: usize = 35;
/// Upper bound on extra metas this resolver accepts (fixed-size buffers). A
/// hook declaring more is rejected with `ProgramError::InvalidArgument`
/// (`HookError::TooManyMetas`); the Anchor program enforces the same bound in
/// front of the canonical helper so both implementations agree.
pub const MAX_EXTRA_METAS: usize = 12;
/// Accounts the resolver may append for one transfer.
pub const MAX_RESOLVED: usize = MAX_EXTRA_METAS + 2;

/// Canonical error codes (`u32` inside `ProgramError::Custom`).
pub mod codes {
    /// `TransferHookError::IncorrectAccount` (hook program not provided).
    pub const HOOK_INCORRECT_ACCOUNT: u32 = 2_110_272_652;
    /// `AccountResolutionError::IncorrectAccount` (resolved account not provided).
    pub const RESOLUTION_INCORRECT_ACCOUNT: u32 = 2_724_315_840;
    /// `AccountResolutionError::InvalidBytesForSeed`.
    pub const INVALID_BYTES_FOR_SEED: u32 = 2_724_315_849;
    /// `AccountResolutionError::InstructionDataTooSmall`.
    pub const INSTRUCTION_DATA_TOO_SMALL: u32 = 2_724_315_851;
    /// `AccountResolutionError::AccountNotFound`.
    pub const ACCOUNT_NOT_FOUND: u32 = 2_724_315_852;
    /// `AccountResolutionError::AccountDataNotFound`.
    pub const ACCOUNT_DATA_NOT_FOUND: u32 = 2_724_315_854;
    /// `AccountResolutionError::AccountDataTooSmall`.
    pub const ACCOUNT_DATA_TOO_SMALL: u32 = 2_724_315_855;
    /// `TlvError::TypeNotFound`.
    pub const TLV_TYPE_NOT_FOUND: u32 = 1_202_666_432;
    /// `ListViewError::BufferTooSmall`.
    pub const LIST_BUFFER_TOO_SMALL: u32 = 1;
}

/// A resolution failure, shaped like the `ProgramError` the canonical
/// implementation returns.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HookError {
    /// `ProgramError::InvalidAccountData`.
    InvalidAccountData,
    /// `ProgramError::InvalidArgument`.
    InvalidArgument,
    /// `ProgramError::Custom(code)`.
    Custom(u32),
    /// More extra metas than [`MAX_EXTRA_METAS`] (rejected before any CPI).
    TooManyMetas,
}

/// One account to append to the `transfer_checked` CPI.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct ResolvedMeta {
    /// Account address.
    pub pubkey: Pubkey,
    /// Always `false` (de-escalated).
    pub is_signer: bool,
    /// Writable privilege after de-escalation.
    pub is_writable: bool,
}

/// Everything the resolver needs from its environment.
pub trait HookEnv<'a> {
    /// Data of the base accounts: 0 source, 1 mint, 2 destination, 3 authority.
    fn base_data(&self, index: usize) -> Option<&'a [u8]>;
    /// Looks up an *additional* account (the caller's remaining accounts) by
    /// key; `Some(data)` if it was provided.
    fn find_additional(&self, key: &Pubkey) -> Option<&'a [u8]>;
    /// `find_program_address(seeds, program_id).0`.
    fn find_pda(&self, seeds: &[&[u8]], program_id: &Pubkey) -> Pubkey;
}

/// The accounts to append, in order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Resolved {
    metas: [ResolvedMeta; MAX_RESOLVED],
    len: usize,
}

impl Resolved {
    /// The resolved accounts.
    pub fn as_slice(&self) -> &[ResolvedMeta] {
        &self.metas[..self.len]
    }

    fn push(&mut self, m: ResolvedMeta) -> Result<(), HookError> {
        let slot = self
            .metas
            .get_mut(self.len)
            .ok_or(HookError::TooManyMetas)?;
        *slot = m;
        self.len += 1;
        Ok(())
    }
}

/// `EXECUTE_DISCRIMINATOR || amount_le`, the data of the hook's `Execute`.
pub fn execute_ix_data(amount: u64) -> [u8; 16] {
    let mut d = [0u8; 16];
    d[..8].copy_from_slice(&EXECUTE_DISCRIMINATOR);
    d[8..].copy_from_slice(&amount.to_le_bytes());
    d
}

fn read_u32(data: &[u8], at: usize) -> Option<u32> {
    let bytes: [u8; 4] = data.get(at..at.checked_add(4)?)?.try_into().ok()?;
    Some(u32::from_le_bytes(bytes))
}

/// Validates the whole TLV area (`TlvStateBorrowed::unpack`) and returns the
/// value of the first `ExtraAccountMetaList` entry (`get_first_bytes`).
fn tlv_execute_value(data: &[u8]) -> Result<&[u8], HookError> {
    // check_data: every entry must be well-formed up to the first empty slot.
    let mut start = 0usize;
    while start < data.len() {
        if data.len() < start + 8 {
            if data[start..].iter().all(|b| *b == 0) {
                break;
            }
            return Err(HookError::InvalidAccountData);
        }
        if data[start..start + 8] == [0u8; 8] {
            break;
        }
        let len = read_u32(data, start + 8).ok_or(HookError::InvalidAccountData)?;
        let end = (start + 12).saturating_add(len as usize);
        if end > data.len() {
            return Err(HookError::InvalidAccountData);
        }
        start = end;
    }
    // get_indices(repetition 0)
    let mut start = 0usize;
    while start < data.len() {
        let value_start = start + 12;
        if data.len() < value_start {
            return Err(HookError::InvalidAccountData);
        }
        let d = &data[start..start + 8];
        let len = read_u32(data, start + 8).ok_or(HookError::InvalidAccountData)? as usize;
        if d == EXECUTE_DISCRIMINATOR {
            let end = value_start.saturating_add(len);
            return data
                .get(value_start..end)
                .ok_or(HookError::InvalidAccountData);
        } else if d == [0u8; 8] {
            return Err(HookError::Custom(codes::TLV_TYPE_NOT_FOUND));
        }
        start = value_start.saturating_add(len);
    }
    Err(HookError::InvalidAccountData)
}

/// A borrowed, validated `ExtraAccountMetaList` (`ListView<ExtraAccountMeta, u32>`).
#[derive(Clone, Copy, Debug)]
pub struct ExtraMetaList<'a> {
    items: &'a [u8],
    count: usize,
}

impl<'a> ExtraMetaList<'a> {
    /// Parses the validation account's data.
    pub fn parse(validation_data: &'a [u8]) -> Result<Self, HookError> {
        let bytes = tlv_execute_value(validation_data)?;
        if bytes.len() < 4 {
            return Err(HookError::Custom(codes::LIST_BUFFER_TOO_SMALL));
        }
        let count = read_u32(bytes, 0).ok_or(HookError::InvalidAccountData)? as usize;
        let items = &bytes[4..];
        if items.len() % EXTRA_ACCOUNT_META_LEN != 0 {
            return Err(HookError::InvalidArgument);
        }
        if count > items.len() / EXTRA_ACCOUNT_META_LEN {
            return Err(HookError::Custom(codes::LIST_BUFFER_TOO_SMALL));
        }
        Ok(Self { items, count })
    }

    /// Number of metas.
    pub fn len(&self) -> usize {
        self.count
    }

    /// `true` when the list declares no extra accounts.
    pub fn is_empty(&self) -> bool {
        self.count == 0
    }

    fn get(&self, i: usize) -> &'a [u8] {
        &self.items[i * EXTRA_ACCOUNT_META_LEN..(i + 1) * EXTRA_ACCOUNT_META_LEN]
    }
}

/// The growing virtual `Execute` account list used for index-based lookups.
struct ExecList<'a, const N: usize> {
    keys: [Pubkey; N],
    data: [Option<&'a [u8]>; N],
    writable: [bool; N],
    len: usize,
}

impl<'a, const N: usize> ExecList<'a, N> {
    fn push(
        &mut self,
        key: Pubkey,
        data: Option<&'a [u8]>,
        writable: bool,
    ) -> Result<(), HookError> {
        if self.len >= N {
            return Err(HookError::TooManyMetas);
        }
        self.keys[self.len] = key;
        self.data[self.len] = data;
        self.writable[self.len] = writable;
        self.len += 1;
        Ok(())
    }

    fn key(&self, i: usize) -> Result<&Pubkey, HookError> {
        if i < self.len {
            Ok(&self.keys[i])
        } else {
            Err(HookError::Custom(codes::ACCOUNT_NOT_FOUND))
        }
    }

    fn account_data(&self, i: usize) -> Result<&'a [u8], HookError> {
        if i >= self.len {
            return Err(HookError::Custom(codes::ACCOUNT_NOT_FOUND));
        }
        self.data[i].ok_or(HookError::Custom(codes::ACCOUNT_DATA_NOT_FOUND))
    }
}

/// One parsed seed of an `address_config` (`spl_tlv_account_resolution::seeds::Seed`).
#[derive(Clone, Copy)]
enum SeedSpec {
    Literal {
        start: usize,
        len: usize,
    },
    InstructionData {
        index: u8,
        length: u8,
    },
    AccountKey {
        index: u8,
    },
    AccountData {
        account_index: u8,
        data_index: u8,
        length: u8,
    },
}

/// `Seed::unpack_address_config`: all seeds are unpacked (and unpack errors
/// reported) before any of them is resolved.
fn parse_seeds(config: &[u8; 32]) -> Result<([SeedSpec; 16], usize), HookError> {
    let bad = HookError::Custom(codes::INVALID_BYTES_FOR_SEED);
    let mut specs = [SeedSpec::AccountKey { index: 0 }; 16];
    let mut n = 0usize;
    let mut i = 0usize;
    while i < 32 {
        let rest = &config[i..];
        let (spec, size) = match rest[0] {
            0 => break,
            1 => {
                let len = *rest.get(1).ok_or(bad)? as usize;
                if rest.len() < 2 + len {
                    return Err(bad);
                }
                (SeedSpec::Literal { start: i + 2, len }, 2 + len)
            }
            2 => match (rest.get(1), rest.get(2)) {
                (Some(&index), Some(&length)) => (SeedSpec::InstructionData { index, length }, 3),
                _ => return Err(bad),
            },
            3 => (
                SeedSpec::AccountKey {
                    index: *rest.get(1).ok_or(bad)?,
                },
                2,
            ),
            4 => match (rest.get(1), rest.get(2), rest.get(3)) {
                (Some(&account_index), Some(&data_index), Some(&length)) => (
                    SeedSpec::AccountData {
                        account_index,
                        data_index,
                        length,
                    },
                    4,
                ),
                _ => return Err(bad),
            },
            _ => return Err(HookError::InvalidAccountData),
        };
        // At most 16 seeds fit in 32 bytes (the smallest seed is 2 bytes).
        let slot = specs.get_mut(n).ok_or(HookError::InvalidAccountData)?;
        *slot = spec;
        n += 1;
        i += size;
    }
    Ok((specs, n))
}

/// `resolve_pda`: turns parsed seeds into byte slices and derives the PDA.
fn resolve_seeds<'a, const N: usize, E: HookEnv<'a>>(
    config: &[u8; 32],
    ix_data: &[u8],
    program_id: &Pubkey,
    list: &ExecList<'a, N>,
    env: &E,
) -> Result<Pubkey, HookError> {
    let (specs, n) = parse_seeds(config)?;
    let mut seeds: [&[u8]; 16] = [&[]; 16];
    for (slot, spec) in seeds.iter_mut().zip(specs.iter()).take(n) {
        *slot = match *spec {
            SeedSpec::Literal { start, len } => &config[start..start + len],
            SeedSpec::InstructionData { index, length } => {
                let start = index as usize;
                let end = start + length as usize;
                ix_data
                    .get(start..end)
                    .ok_or(HookError::Custom(codes::INSTRUCTION_DATA_TOO_SMALL))?
            }
            SeedSpec::AccountKey { index } => &list.key(index as usize)?[..],
            SeedSpec::AccountData {
                account_index,
                data_index,
                length,
            } => {
                let data = list.account_data(account_index as usize)?;
                let start = data_index as usize;
                let end = start + length as usize;
                data.get(start..end)
                    .ok_or(HookError::Custom(codes::ACCOUNT_DATA_TOO_SMALL))?
            }
        };
    }
    Ok(env.find_pda(&seeds[..n], program_id))
}

/// Resolves a `PubkeyData` address config (discriminator 2).
fn resolve_pubkey_data<'a, const N: usize>(
    config: &[u8; 32],
    ix_data: &[u8],
    list: &ExecList<'a, N>,
) -> Result<Pubkey, HookError> {
    let too_small_ix = HookError::Custom(codes::INSTRUCTION_DATA_TOO_SMALL);
    match config[0] {
        1 => {
            let start = config[1] as usize;
            let key = ix_data.get(start..start + 32).ok_or(too_small_ix)?;
            let mut out = [0u8; 32];
            out.copy_from_slice(key);
            Ok(out)
        }
        2 => {
            let data = list.account_data(config[1] as usize)?;
            let start = config[2] as usize;
            let key = data
                .get(start..start + 32)
                .ok_or(HookError::Custom(codes::ACCOUNT_DATA_TOO_SMALL))?;
            let mut out = [0u8; 32];
            out.copy_from_slice(key);
            Ok(out)
        }
        _ => Err(HookError::InvalidAccountData),
    }
}

/// Resolves the accounts a `transfer_checked` CPI must append for a
/// transfer-hook mint. See the module docs for the exact algorithm.
#[allow(clippy::too_many_arguments)]
pub fn resolve_transfer_hook_accounts<'a, E: HookEnv<'a>>(
    hook_program: &Pubkey,
    source: &Pubkey,
    mint: &Pubkey,
    destination: &Pubkey,
    authority: &Pubkey,
    amount: u64,
    env: &E,
) -> Result<Resolved, HookError> {
    let mut out = Resolved {
        metas: [ResolvedMeta::default(); MAX_RESOLVED],
        len: 0,
    };
    let hook_meta = ResolvedMeta {
        pubkey: *hook_program,
        is_signer: false,
        is_writable: false,
    };

    if env.find_additional(hook_program).is_none() {
        return Err(HookError::Custom(codes::HOOK_INCORRECT_ACCOUNT));
    }
    let validation = env.find_pda(&[EXTRA_ACCOUNT_METAS_SEED, mint], hook_program);
    let Some(validation_data) = env.find_additional(&validation) else {
        out.push(hook_meta)?;
        return Ok(out);
    };

    let list = ExtraMetaList::parse(validation_data)?;
    if list.len() > MAX_EXTRA_METAS {
        return Err(HookError::TooManyMetas);
    }
    let ix_data = execute_ix_data(amount);
    let mut exec: ExecList<'a, { 5 + MAX_EXTRA_METAS }> = ExecList {
        keys: [[0u8; 32]; 5 + MAX_EXTRA_METAS],
        data: [None; 5 + MAX_EXTRA_METAS],
        writable: [false; 5 + MAX_EXTRA_METAS],
        len: 0,
    };
    for (i, key) in [source, mint, destination, authority]
        .into_iter()
        .enumerate()
    {
        exec.push(*key, env.base_data(i), false)?;
    }
    exec.push(validation, Some(validation_data), false)?;

    for i in 0..list.len() {
        let raw = list.get(i);
        let disc = raw[0];
        let mut config = [0u8; 32];
        config.copy_from_slice(&raw[1..33]);
        let is_writable = raw[34] != 0;
        let pubkey = match disc {
            0 => config,
            1 => resolve_seeds(&config, &ix_data, hook_program, &exec, env)?,
            2 => resolve_pubkey_data(&config, &ix_data, &exec)?,
            d if d >= 128 => {
                let program = *exec.key((d - 128) as usize)?;
                resolve_seeds(&config, &ix_data, &program, &exec, env)?
            }
            _ => return Err(HookError::InvalidAccountData),
        };
        // de_escalate_account_meta: if the key already appears and none of its
        // occurrences is writable, the new meta cannot be writable either.
        let mut seen = false;
        let mut any_writable = false;
        for j in 0..exec.len {
            if exec.keys[j] == pubkey {
                seen = true;
                any_writable |= exec.writable[j];
            }
        }
        let is_writable = if seen && !any_writable {
            false
        } else {
            is_writable
        };
        let data = env
            .find_additional(&pubkey)
            .ok_or(HookError::Custom(codes::RESOLUTION_INCORRECT_ACCOUNT))?;
        exec.push(pubkey, Some(data), is_writable)?;
        out.push(ResolvedMeta {
            pubkey,
            is_signer: false,
            is_writable,
        })?;
    }
    out.push(ResolvedMeta {
        pubkey: validation,
        is_signer: false,
        is_writable: false,
    })?;
    out.push(hook_meta)?;
    Ok(out)
}

/// Reads an `ExtraAccountMeta`'s discriminator and address config, for
/// off-chain inspection.
pub fn meta_at(list: &ExtraMetaList<'_>, i: usize) -> Option<(u8, [u8; 32], bool, bool)> {
    if i >= list.len() {
        return None;
    }
    let raw = list.get(i);
    let mut config = [0u8; 32];
    config.copy_from_slice(&raw[1..33]);
    Some((raw[0], config, raw[33] != 0, raw[34] != 0))
}

#[cfg(test)]
mod tests;
