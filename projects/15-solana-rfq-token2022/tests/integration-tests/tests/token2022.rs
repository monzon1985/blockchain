// SPDX-License-Identifier: MIT
//! Token-2022 settlement: transfer-fee mints (gross-vs-net with slippage
//! bounds) and transfer-hook mints (on-chain `ExtraAccountMetaList` resolution
//! through the in-repo allowlist hook), on both programs — including the v0
//! transaction + address lookup table a hooked settlement needs to fit in a
//! packet, and the resolver's extra-meta bound.

#![allow(clippy::expect_used)]

use {
    integration_tests::*,
    rfq_client::{TEST_HOOK_PROGRAM_ID, pda},
    rfq_core::{Quote, hook::MAX_EXTRA_METAS},
    solana_address::Address as Pubkey,
    solana_instruction::AccountMeta,
    solana_signer::Signer,
    spl_tlv_account_resolution::{account::ExtraAccountMeta, state::ExtraAccountMetaList},
    spl_transfer_hook_interface::instruction::ExecuteInstruction,
};

#[test]
fn transfer_fee_mint_is_grossed_up_for_the_maker() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let payer = env.funded_keypair();
        // taker_mint has a 2.5% transfer fee, uncapped.
        let fee_mint = |env: &mut Env, payer| {
            env.create_token22_mint(
                payer,
                6,
                MintConfig {
                    transfer_fee: Some((250, u64::MAX)),
                    transfer_hook: None,
                },
            )
        };
        let maker_mint = env.create_token_mint(&payer, 6);
        let taker_mint = fee_mint(&mut env, &payer);
        let (market, base) = env.market(&payer, maker_mint, taker_mint, 1_000_000, 10_000_000);
        let quote = Quote {
            maker_amount: 1_000_000,
            taker_amount: 2_000_000,
            ..base
        };

        // The maker must NET 2_000_000; the taker sends gross = ceil(2e6 / 0.975).
        let start_src = env.token_balance(&market.taker_src);
        env.send_settle(&market, &settle_args(quote, 1_000_000, 0, u64::MAX))
            .unwrap_or_else(|e| panic!("{program:?}: {e:?}"));
        let sent = start_src - env.token_balance(&market.taker_src);
        assert_eq!(
            sent, 2_051_283,
            "{program:?}: taker sends the grossed-up amount"
        );
        assert!(
            env.token_balance(&market.maker.vault_in) >= 2_000_000,
            "{program:?}: the maker nets at least the quoted price"
        );

        // max_in one below the grossed-up amount is rejected as slippage.
        let payer2 = env.funded_keypair();
        let mm = env.create_token_mint(&payer2, 6);
        let tm = fee_mint(&mut env, &payer2);
        let (market2, base2) = env.market(&payer2, mm, tm, 1_000_000, 10_000_000);
        let q2 = Quote {
            maker_amount: 1_000_000,
            taker_amount: 2_000_000,
            ..base2
        };
        let err = env
            .send_settle(&market2, &settle_args(q2, 1_000_000, 0, 2_051_282))
            .expect_err("slippage");
        assert_custom(&err, rfq_core::RfqError::SlippageMaxIn);
    }
}

/// A market selling a hooked mint, with the taker, the vault authority and
/// the config (fee-vault owner) allowlisted unless `allow_taker` is false.
fn hooked_market(env: &mut Env, allow_taker: bool) -> (Market, Quote) {
    let payer = env.funded_keypair();
    let maker_mint = env.create_hooked_mint(&payer, 6);
    let taker_mint = env.create_token_mint(&payer, 6);
    let (market, base) = env.market(&payer, maker_mint, taker_mint, 1_000_000, 5_000_000);
    let va = pda::vault_authority(&env.program, &market.maker.owner_key()).0;
    let config = pda::config(&env.program).0;
    let mut allowed = vec![va, config];
    if allow_taker {
        allowed.push(market.taker.pubkey());
    }
    for wallet in allowed {
        env.set_hook_allowed(&payer, &market.maker_mint, &wallet, true);
    }
    (
        market,
        Quote {
            maker_amount: 1_000_000,
            taker_amount: 2_000_000,
            ..base
        },
    )
}

#[test]
fn transfer_hook_mint_settles_and_runs_the_hook() {
    for program in both() {
        let mut env = Env::new(program, 30);
        let (market, quote) = hooked_market(&mut env, true);
        let args = settle_args(quote, 1_000_000, 0, u64::MAX);
        let before = env.hook_counter(&market.maker_mint);
        let (ixs, remaining) = env.build_settle(&market, &args, false);
        assert!(!remaining.is_empty(), "{program:?}: hook extras present");
        let taker = market.taker.insecure_clone();
        let (res, size) = env.send_v0(&ixs, &[&taker]);
        res.unwrap_or_else(|e| panic!("{program:?}: {e:?}"));
        assert!(size <= PACKET_DATA_SIZE);

        // The hook ran once per maker-mint transfer (taker payout + fee).
        assert_eq!(
            env.hook_counter(&market.maker_mint) - before,
            2,
            "{program:?}"
        );
        assert_eq!(env.token_balance(&market.taker_dst), 997_000, "{program:?}");
    }
}

/// A hooked settlement does not fit a legacy transaction (17 fixed accounts,
/// the hook extras, a 320-byte ed25519 instruction and 192 bytes of settle
/// data); compiled as v0 against an address lookup table it does, and settles.
#[test]
fn hooked_settlement_needs_a_v0_transaction_with_a_lookup_table() {
    for program in both() {
        let mut env = Env::new(program, 30);
        let (market, quote) = hooked_market(&mut env, true);
        let args = settle_args(quote, 1_000_000, 0, u64::MAX);
        let (ixs, remaining) = env.build_settle(&market, &args, false);
        let taker = market.taker.insecure_clone();

        let legacy =
            rfq_client::tx::legacy_transaction(&taker, &[], &ixs, env.svm.latest_blockhash())
                .expect("legacy");
        let legacy_len = serialized_len(&legacy);
        assert!(
            legacy_len > PACKET_DATA_SIZE,
            "{program:?}: legacy hooked settle is {legacy_len} bytes"
        );

        // The client's own lookup-table recipe.
        let accounts = env.settle_accounts(&market);
        let addresses = rfq_client::tx::settle_lookup_addresses(
            &env.program,
            &accounts,
            quote.nonce,
            &remaining,
        );
        let table = build_lookup_table(&mut env, &taker, &addresses);
        let tx =
            v0_transaction(&taker, &[], &ixs, &[table], env.svm.latest_blockhash()).expect("v0");
        let v0_len = serialized_len(&tx);
        assert!(
            v0_len <= PACKET_DATA_SIZE,
            "{program:?}: v0 is {v0_len} bytes"
        );
        println!("{program:?}: hooked settle legacy {legacy_len} B -> v0+ALT {v0_len} B");
        env.svm
            .send_transaction(tx)
            .unwrap_or_else(|e| panic!("{program:?}: {e:?}"));
        assert_eq!(env.token_balance(&market.taker_dst), 997_000, "{program:?}");
    }
}

#[test]
fn transfer_hook_blocks_a_non_allowlisted_taker() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, quote) = hooked_market(&mut env, false);
        let err = env
            .send_settle(&market, &settle_args(quote, 1_000_000, 0, u64::MAX))
            .expect_err("hook must block");
        // The test hook's NotAllowlisted custom code.
        assert_code(&err, 7001);
        assert_eq!(
            env.token_balance(&market.maker.vault_out),
            1_000_000,
            "{program:?}: nothing moved"
        );
    }
}

/// A hook declaring more extra accounts than the zero-copy resolver's bound
/// is rejected identically by both programs (`InvalidArgument`), before the
/// hook is ever invoked.
#[test]
fn hooks_with_too_many_extra_metas_are_rejected_by_both() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, quote) = hooked_market(&mut env, true);
        // Overwrite the validation account with a list of 13 literal metas.
        let validation =
            pda::extra_account_metas(&TEST_HOOK_PROGRAM_ID, &market.maker_mint.key()).0;
        let extras: Vec<Pubkey> = (0..=MAX_EXTRA_METAS)
            .map(|_| Pubkey::new_unique())
            .collect();
        let metas: Vec<ExtraAccountMeta> = extras
            .iter()
            .map(|k| ExtraAccountMeta::new_with_pubkey(k, false, false).expect("meta"))
            .collect();
        let len = ExtraAccountMetaList::size_of(metas.len()).expect("size");
        let mut data = vec![0u8; len];
        ExtraAccountMetaList::init::<ExecuteInstruction>(&mut data, &metas).expect("init");
        let mut acct = env.svm.get_account(&validation).expect("validation");
        acct.data = data;
        acct.lamports = env.svm.minimum_balance_for_rent_exemption(len);
        env.svm.set_account(validation, acct).expect("set");

        let args = settle_args(quote, 1_000_000, 0, u64::MAX);
        let mut remaining: Vec<AccountMeta> = extras
            .iter()
            .map(|k| AccountMeta::new_readonly(*k, false))
            .collect();
        remaining.push(AccountMeta::new_readonly(validation, false));
        remaining.push(AccountMeta::new_readonly(TEST_HOOK_PROGRAM_ID, false));
        let ixs = env.build_settle_with(&market, &args, |m| m.extend(remaining));
        let before = env.hook_counter(&market.maker_mint);
        let err = env
            .send_as_taker(&market, &ixs)
            .expect_err("too many metas");
        assert_ix_error(&err, InstructionError::InvalidArgument);
        assert_eq!(env.hook_counter(&market.maker_mint), before, "{program:?}");
    }
}
