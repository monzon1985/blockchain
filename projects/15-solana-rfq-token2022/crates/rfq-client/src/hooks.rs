// SPDX-License-Identifier: MIT
//! Transfer-hook extra accounts and settlement planning.
//!
//! The client resolves hook accounts with the *same* `rfq-core` resolver the
//! Pinocchio program runs on-chain (itself differentially tested against the
//! SPL implementation), feeding it account data from any [`AccountFetcher`].

use {
    crate::{ClientError, Pubkey, ix::SettleAccounts, pda},
    rfq_core::{
        hook::{self, HookEnv},
        layout,
        math::{SettleInputs, Settlement, compute_settlement},
        token::MintView,
        transfer_fee::TransferFee,
    },
    solana_instruction::AccountMeta,
    std::{cell::RefCell, collections::HashMap},
};

/// Read access to account data (an RPC client, a LiteSVM instance, ...).
pub trait AccountFetcher {
    /// Data of `key`, or `None` if the account does not exist.
    fn account_data(&self, key: &Pubkey) -> Option<Vec<u8>>;
}

struct CachedEnv<'a> {
    base: [&'a [u8]; 4],
    cache: &'a HashMap<[u8; 32], Vec<u8>>,
    missing: RefCell<Vec<[u8; 32]>>,
}

impl<'a> HookEnv<'a> for CachedEnv<'a> {
    fn base_data(&self, index: usize) -> Option<&'a [u8]> {
        self.base.get(index).copied()
    }
    fn find_additional(&self, key: &[u8; 32]) -> Option<&'a [u8]> {
        match self.cache.get(key) {
            Some(d) => Some(d.as_slice()),
            None => {
                self.missing.borrow_mut().push(*key);
                // Off-chain every address can be supplied; empty data until fetched.
                Some(&[])
            }
        }
    }
    fn find_pda(&self, seeds: &[&[u8]], program_id: &[u8; 32]) -> [u8; 32] {
        Pubkey::find_program_address(seeds, &Pubkey::new_from_array(*program_id))
            .0
            .to_bytes()
    }
}

/// Extra accounts a `transfer_checked` of `amount` of `mint` needs (empty for
/// mints without a transfer hook). Iterates until every account the resolver
/// looked at has real data, so account-data seeds of extra accounts resolve.
pub fn transfer_hook_accounts(
    fetcher: &impl AccountFetcher,
    mint: &Pubkey,
    source: &Pubkey,
    destination: &Pubkey,
    authority: &Pubkey,
    amount: u64,
) -> Result<Vec<AccountMeta>, ClientError> {
    let mint_data = fetcher
        .account_data(mint)
        .ok_or(ClientError::Account(*mint))?;
    let hook_program = MintView::parse(&mint_data)
        .map_err(|_| ClientError::Account(*mint))?
        .transfer_hook_program()
        .map_err(|_| ClientError::Account(*mint))?;
    let Some(hook_program) = hook_program else {
        return Ok(Vec::new());
    };
    let base = [
        fetcher.account_data(source).unwrap_or_default(),
        mint_data.clone(),
        fetcher.account_data(destination).unwrap_or_default(),
        fetcher.account_data(authority).unwrap_or_default(),
    ];
    let mut cache: HashMap<[u8; 32], Vec<u8>> = HashMap::new();
    for _ in 0..=hook::MAX_RESOLVED + 1 {
        let (result, missing) = {
            let env = CachedEnv {
                base: [&base[0], &base[1], &base[2], &base[3]],
                cache: &cache,
                missing: RefCell::new(Vec::new()),
            };
            let r = hook::resolve_transfer_hook_accounts(
                &hook_program,
                &source.to_bytes(),
                &mint.to_bytes(),
                &destination.to_bytes(),
                &authority.to_bytes(),
                amount,
                &env,
            );
            (r, env.missing.take())
        };
        if missing.is_empty() {
            let resolved = result.map_err(ClientError::Hook)?;
            return Ok(resolved
                .as_slice()
                .iter()
                .map(|m| {
                    if m.is_writable {
                        AccountMeta::new(Pubkey::new_from_array(m.pubkey), false)
                    } else {
                        AccountMeta::new_readonly(Pubkey::new_from_array(m.pubkey), false)
                    }
                })
                .collect());
        }
        for key in missing {
            let data = fetcher
                .account_data(&Pubkey::new_from_array(key))
                .unwrap_or_default();
            cache.insert(key, data);
        }
    }
    Err(ClientError::Hook(hook::HookError::TooManyMetas))
}

/// De-duplicates metas, keeping the strongest privileges.
pub fn merge_metas(lists: &[Vec<AccountMeta>]) -> Vec<AccountMeta> {
    let mut out: Vec<AccountMeta> = Vec::new();
    for meta in lists.iter().flatten() {
        match out.iter_mut().find(|m| m.pubkey == meta.pubkey) {
            Some(m) => {
                m.is_writable |= meta.is_writable;
                m.is_signer |= meta.is_signer;
            }
            None => out.push(meta.clone()),
        }
    }
    out
}

fn mint_fee(
    fetcher: &impl AccountFetcher,
    mint: &Pubkey,
    epoch: u64,
) -> Result<TransferFee, ClientError> {
    let data = fetcher
        .account_data(mint)
        .ok_or(ClientError::Account(*mint))?;
    let view = MintView::parse(&data).map_err(|_| ClientError::Account(*mint))?;
    Ok(view
        .transfer_fee_config()
        .map_err(|_| ClientError::Account(*mint))?
        .map(|c| c.epoch_fee(epoch))
        .unwrap_or(TransferFee::ZERO))
}

/// Predicts the amounts a settlement will move, from on-chain state, exactly as
/// the programs compute them.
pub fn plan_settlement(
    fetcher: &impl AccountFetcher,
    program: &Pubkey,
    args: &layout::SettleArgs,
    epoch: u64,
) -> Result<Settlement, ClientError> {
    let config_key = pda::config(program).0;
    let config = fetcher
        .account_data(&config_key)
        .ok_or(ClientError::Account(config_key))?;
    let fee_bps = config
        .get(layout::config::FEE_BPS..layout::config::FEE_BPS + 2)
        .map(|b| u16::from_le_bytes([b[0], b[1]]))
        .ok_or(ClientError::Account(config_key))?;
    let q = &args.quote;
    let fill_key = pda::quote_fill(program, &Pubkey::new_from_array(q.maker), q.nonce).0;
    let filled_before = fetcher
        .account_data(&fill_key)
        .and_then(|d| {
            d.get(layout::quote_fill::FILLED..layout::quote_fill::FILLED + 8)
                .map(|b| u64::from_le_bytes(b.try_into().unwrap_or([0; 8])))
        })
        .unwrap_or(0);
    compute_settlement(&SettleInputs {
        maker_amount: q.maker_amount,
        taker_amount: q.taker_amount,
        filled_before,
        fill: args.fill_amount,
        protocol_fee_bps: fee_bps,
        maker_mint_fee: mint_fee(fetcher, &Pubkey::new_from_array(q.maker_mint), epoch)?,
        taker_mint_fee: mint_fee(fetcher, &Pubkey::new_from_array(q.taker_mint), epoch)?,
        min_out: args.min_out,
        max_in: args.max_in,
    })
    .map_err(ClientError::Settlement)
}

/// Remaining accounts of a settlement: the union of the hook accounts of its
/// (up to) three transfers, computed with the planned amounts.
pub fn settle_remaining_accounts(
    fetcher: &impl AccountFetcher,
    program: &Pubkey,
    accounts: &SettleAccounts,
    plan: &Settlement,
) -> Result<Vec<AccountMeta>, ClientError> {
    let vault_authority = pda::vault_authority(program, &accounts.maker_owner).0;
    let mut lists = Vec::new();
    if plan.taker_gross_in > 0 {
        lists.push(transfer_hook_accounts(
            fetcher,
            &accounts.taker_mint,
            &accounts.taker_src,
            &accounts.maker_vault_in,
            &accounts.taker,
            plan.taker_gross_in,
        )?);
    }
    if plan.taker_gross_out > 0 {
        lists.push(transfer_hook_accounts(
            fetcher,
            &accounts.maker_mint,
            &accounts.maker_vault_out,
            &accounts.taker_dst,
            &vault_authority,
            plan.taker_gross_out,
        )?);
    }
    if plan.protocol_fee > 0 {
        lists.push(transfer_hook_accounts(
            fetcher,
            &accounts.maker_mint,
            &accounts.maker_vault_out,
            &accounts.fee_vault,
            &vault_authority,
            plan.protocol_fee,
        )?);
    }
    Ok(merge_metas(&lists))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merge_keeps_strongest_privileges() {
        let k = Pubkey::new_from_array([1; 32]);
        let j = Pubkey::new_from_array([2; 32]);
        let merged = merge_metas(&[
            vec![AccountMeta::new_readonly(k, false)],
            vec![
                AccountMeta::new(k, false),
                AccountMeta::new_readonly(j, false),
            ],
        ]);
        assert_eq!(
            merged,
            vec![
                AccountMeta::new(k, false),
                AccountMeta::new_readonly(j, false)
            ]
        );
    }

    struct NoAccounts;
    impl AccountFetcher for NoAccounts {
        fn account_data(&self, _: &Pubkey) -> Option<Vec<u8>> {
            None
        }
    }

    #[test]
    fn missing_mint_is_reported() {
        let mint = Pubkey::new_from_array([3; 32]);
        let err = transfer_hook_accounts(&NoAccounts, &mint, &mint, &mint, &mint, 1);
        assert_eq!(err, Err(ClientError::Account(mint)));
    }
}
