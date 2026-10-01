// SPDX-License-Identifier: MIT
//! Allocation-free `transfer_checked` CPI with transfer-hook resolution.
//!
//! Builds the SPL `TransferChecked` instruction on the stack, resolves any
//! transfer-hook extra accounts with the shared [`rfq_core::hook`] resolver
//! (the same one the client and the differential tests use), matches each
//! resolved key to an [`AccountView`] from the remaining accounts, and invokes
//! the token program with bounded, zero-copy CPI.

use {
    core::mem::MaybeUninit,
    pinocchio::{
        AccountView, Address, ProgramResult,
        cpi::{Signer, invoke_signed_with_bounds},
        error::ProgramError,
        instruction::{InstructionAccount, InstructionView},
    },
    rfq_core::{
        Pubkey,
        hook::{self, HookEnv, MAX_RESOLVED, ResolvedMeta},
        token::MintView,
    },
};

/// `TransferChecked` SPL instruction tag.
const TRANSFER_CHECKED: u8 = 12;
/// Base accounts of a `transfer_checked` (source, mint, destination, authority).
const BASE_ACCOUNTS: usize = 4;
/// Upper bound on total CPI accounts. `MAX_RESOLVED` follows from
/// `rfq_core::hook::MAX_EXTRA_METAS` (12 extra metas + validation account +
/// hook program); a hook declaring more is rejected with `InvalidArgument` —
/// and so is it by the Anchor program, which enforces the same bound.
const MAX_CPI_ACCOUNTS: usize = BASE_ACCOUNTS + MAX_RESOLVED;

struct Env<'a> {
    base: [&'a [u8]; 4],
    remaining: &'a [AccountView],
}

impl<'a> HookEnv<'a> for Env<'a> {
    fn base_data(&self, index: usize) -> Option<&'a [u8]> {
        // Backed by live `Ref` guards held by `transfer_checked_with_hook`.
        self.base.get(index).copied()
    }
    fn find_additional(&self, key: &Pubkey) -> Option<&'a [u8]> {
        let view = self
            .remaining
            .iter()
            .find(|a| a.address().as_array() == key)?;
        // Same outcome as a failed `try_borrow`: the account is treated as
        // not provided.
        view.check_borrow().ok()?;
        // SAFETY: `borrow_unchecked` hands out the data without touching the
        // borrow flag, so it is sound only while nothing writes the account.
        // That holds for the whole lifetime `'a` of these slices:
        // * `check_borrow` above proved no mutable borrow is outstanding, and
        //   no code between here and the end of resolution takes one — the
        //   settle handler drops every `RefMut` before calling
        //   `transfer_checked_with_hook`, and resolution itself only reads;
        // * the slices cannot outlive resolution: `Env` is created inside the
        //   resolution block of `transfer_checked_with_hook` and
        //   `resolve_transfer_hook_accounts` returns owned `ResolvedMeta`
        //   copies, so every slice is dead before the token CPI (the only
        //   place account data can change) is invoked.
        // (A `Ref` guard cannot be kept instead: the resolver may look up any
        // number of remaining accounts, and storing an unbounded set of guards
        // would need an allocator.)
        Some(unsafe { view.borrow_unchecked() })
    }
    fn find_pda(&self, seeds: &[&[u8]], program_id: &Pubkey) -> Pubkey {
        Address::find_program_address(seeds, &Address::new_from_array(*program_id))
            .0
            .to_bytes()
    }
}

/// `transfer_checked(amount)` from `from` to `to`, resolving hook accounts from
/// `remaining` when `mint` has a transfer hook. A zero amount is a no-op.
#[allow(clippy::too_many_arguments)]
pub fn transfer_checked_with_hook(
    token_program: &AccountView,
    from: &AccountView,
    mint: &AccountView,
    to: &AccountView,
    authority: &AccountView,
    remaining: &[AccountView],
    amount: u64,
    decimals: u8,
    seeds: &[Signer],
) -> ProgramResult {
    if amount == 0 {
        return Ok(());
    }

    // Resolve hook accounts (if any) before borrowing account data for the CPI.
    let mut resolved = [ResolvedMeta::default(); MAX_RESOLVED];
    let resolved = {
        let hook_program = {
            let data = mint.try_borrow()?;
            MintView::parse(&data)
                .map_err(|_| ProgramError::InvalidAccountData)?
                .transfer_hook_program()
                .map_err(|_| ProgramError::InvalidAccountData)?
        };
        match hook_program {
            None => &resolved[..0],
            Some(hook_program) => {
                let src = from.try_borrow()?;
                let mnt = mint.try_borrow()?;
                let dst = to.try_borrow()?;
                let ath = authority.try_borrow()?;
                let env = Env {
                    base: [&src, &mnt, &dst, &ath],
                    remaining,
                };
                let out = hook::resolve_transfer_hook_accounts(
                    &hook_program,
                    &from.address().to_bytes(),
                    &mint.address().to_bytes(),
                    &to.address().to_bytes(),
                    &authority.address().to_bytes(),
                    amount,
                    &env,
                )
                .map_err(hook_error)?;
                let n = out.as_slice().len();
                resolved[..n].copy_from_slice(out.as_slice());
                drop((src, mnt, dst, ath));
                &resolved[..n]
            }
        }
    };

    // Instruction data: [12, amount_le(8), decimals(1)].
    let mut data = [0u8; 10];
    data[0] = TRANSFER_CHECKED;
    data[1..9].copy_from_slice(&amount.to_le_bytes());
    data[9] = decimals;

    // Account metas and matching views, in CPI order.
    let mut metas: [MaybeUninit<InstructionAccount>; MAX_CPI_ACCOUNTS] =
        [const { MaybeUninit::uninit() }; MAX_CPI_ACCOUNTS];
    let mut views: [MaybeUninit<&AccountView>; MAX_CPI_ACCOUNTS] =
        [const { MaybeUninit::uninit() }; MAX_CPI_ACCOUNTS];

    let base = [
        InstructionAccount::writable(from.address()),
        InstructionAccount::readonly(mint.address()),
        InstructionAccount::writable(to.address()),
        InstructionAccount::readonly_signer(authority.address()),
    ];
    let base_views = [from, mint, to, authority];
    for i in 0..BASE_ACCOUNTS {
        metas[i].write(base[i].clone());
        views[i].write(base_views[i]);
    }
    let mut len = BASE_ACCOUNTS;
    for meta in resolved {
        let view = remaining
            .iter()
            .find(|a| a.address().to_bytes() == meta.pubkey)
            .ok_or(ProgramError::Custom(
                hook::codes::RESOLUTION_INCORRECT_ACCOUNT,
            ))?;
        let ia = if meta.is_writable {
            InstructionAccount::writable(view.address())
        } else {
            InstructionAccount::readonly(view.address())
        };
        metas[len].write(ia);
        views[len].write(view);
        len += 1;
    }

    // SAFETY: the first `len` entries of both arrays are initialised above.
    let metas_init: &[InstructionAccount] =
        unsafe { core::slice::from_raw_parts(metas.as_ptr() as *const InstructionAccount, len) };
    let views_init: &[&AccountView] =
        unsafe { core::slice::from_raw_parts(views.as_ptr() as *const &AccountView, len) };

    let ix = InstructionView {
        program_id: token_program.address(),
        accounts: metas_init,
        data: &data,
    };
    invoke_signed_with_bounds::<MAX_CPI_ACCOUNTS, &AccountView>(&ix, views_init, seeds)
}

fn hook_error(e: hook::HookError) -> ProgramError {
    match e {
        hook::HookError::InvalidAccountData => ProgramError::InvalidAccountData,
        hook::HookError::InvalidArgument => ProgramError::InvalidArgument,
        hook::HookError::Custom(c) => ProgramError::Custom(c),
        hook::HookError::TooManyMetas => ProgramError::InvalidArgument,
    }
}

/// The transfer fee of `mint` at `epoch` (`ZERO` for legacy / no-extension mints).
pub fn epoch_transfer_fee(
    mint: &AccountView,
    epoch: u64,
) -> Result<rfq_core::transfer_fee::TransferFee, ProgramError> {
    let data = mint.try_borrow()?;
    let view = MintView::parse(&data).map_err(|_| ProgramError::InvalidAccountData)?;
    Ok(view
        .transfer_fee_config()
        .map_err(|_| ProgramError::InvalidAccountData)?
        .map(|c| c.epoch_fee(epoch))
        .unwrap_or(rfq_core::transfer_fee::TransferFee::ZERO))
}
