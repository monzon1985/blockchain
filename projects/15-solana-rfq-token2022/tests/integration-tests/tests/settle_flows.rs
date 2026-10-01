// SPDX-License-Identifier: MIT
//! Full settlement flows against both programs: happy path, replay, partial
//! fills and their tracker (creation, pre-funded address, quote binding,
//! rent refund), and the signer requirement.

#![allow(clippy::expect_used)]

use {
    integration_tests::*,
    rfq_core::{Quote, RfqError, anchor_codes as ac},
    solana_signer::Signer,
};

#[test]
fn full_fill_moves_exact_amounts_and_cannot_be_replayed() {
    for program in both() {
        let mut env = Env::new(program, 30); // 0.30 %
        let (market, quote) = env.standard_market();
        let args = settle_args(quote, 1_000_000, 0, u64::MAX);

        let vault_out = market.maker.vault_out;
        let vault_in = market.maker.vault_in;
        let fee_vault = env.fee_vault(&market.maker_mint);
        let (start_src, start_dst) = (
            env.token_balance(&market.taker_src),
            env.token_balance(&market.taker_dst),
        );

        let (ixs, _) = env.build_settle(&market, &args, false);
        let meta = env.send_as_taker(&market, &ixs).expect("settle");

        // Invariant 3 (conservation): the vault loses exactly the fill, which is
        // split between the taker and the fee vault; the taker pays the price.
        assert_eq!(env.token_balance(&vault_out), 0, "{program:?}");
        assert_eq!(env.token_balance(&vault_in), 2_000_000, "{program:?}");
        assert_eq!(env.token_balance(&fee_vault), 3_000, "{program:?}");
        assert_eq!(
            start_src - env.token_balance(&market.taker_src),
            2_000_000,
            "{program:?}"
        );
        assert_eq!(
            env.token_balance(&market.taker_dst) - start_dst,
            997_000,
            "{program:?}"
        );
        // A one-shot fill by its payer closes the tracker in the same tx.
        assert!(env.is_closed(&env.quote_fill_key(&quote)), "{program:?}");

        let ev = settled_event(&meta.logs);
        assert_eq!(ev.fill_amount, 1_000_000);
        assert_eq!(ev.protocol_fee, 3_000);
        assert_eq!(ev.taker_net_out, 997_000);
        assert_eq!(ev.filled_total, 1_000_000);
        assert_eq!(ev.maker, market.maker.owner_key().to_bytes());

        // Invariant 5 (replay): the *same* signed quote cannot settle twice.
        // A fresh blockhash makes the replay a new transaction, so the
        // runtime's duplicate-signature check cannot be what stops it — the
        // nonce bitmap does.
        env.svm.expire_blockhash();
        let (ixs, _) = env.build_settle(&market, &args, false);
        let err = env.send_as_taker(&market, &ixs).expect_err("replay");
        assert_custom(&err, RfqError::NonceAlreadyUsed);
        assert_eq!(env.token_balance(&vault_in), 2_000_000, "{program:?}");
    }
}

#[test]
fn partial_fills_accumulate_and_close_on_completion() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let payer = env.funded_keypair();
        let maker_mint = env.create_token_mint(&payer, 6);
        let taker_mint = env.create_token_mint(&payer, 6);
        let (market, base) = env.market(&payer, maker_mint, taker_mint, 1_000_000, 10_000_000);
        let quote = Quote {
            maker_amount: 1_000_000,
            taker_amount: 3_000_000,
            ..base
        };
        let fill_pda = env.quote_fill_key(&quote);

        // First partial fill of 400_000.
        env.send_settle(&market, &settle_args(quote, 400_000, 0, u64::MAX))
            .expect("partial 1");
        assert_eq!(
            env.quote_fill_state(&quote),
            Some((400_000, market.taker.pubkey())),
            "tracker records the fill and its rent payer ({program:?})"
        );

        // Overfilling the remaining 600_000 is rejected.
        let err = env
            .send_settle(&market, &settle_args(quote, 600_001, 0, u64::MAX))
            .expect_err("overfill");
        assert_custom(&err, RfqError::FillExceedsRemaining);

        // The completing fill by the same taker closes the tracker and refunds
        // its rent to that taker.
        let taker_before = env.lamports(&market.taker.pubkey());
        let tracker_rent = env.lamports(&fill_pda);
        let meta = env
            .send_settle(&market, &settle_args(quote, 600_000, 0, u64::MAX))
            .expect("partial 2");
        assert!(env.is_closed(&fill_pda), "tracker closed ({program:?})");
        assert_eq!(
            env.lamports(&market.taker.pubkey()),
            taker_before + tracker_rent - meta.fee,
            "rent refunded to the payer ({program:?})"
        );

        // Invariant 4: ceil pricing never underpays the maker.
        assert!(
            env.token_balance(&market.maker.vault_in) >= 3_000_000,
            "{program:?}"
        );
    }
}

#[test]
fn a_tracker_is_bound_to_its_quote_hash() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, quote) = env.standard_market();
        env.send_settle(&market, &settle_args(quote, 100_000, 0, u64::MAX))
            .expect("partial fill of quote A");

        // Quote B: the maker's signer, the same nonce, different terms. Its
        // signature is valid, but the open tracker belongs to quote A.
        let quote_b = Quote {
            taker_amount: 1_000_000,
            ..quote
        };
        let err = env
            .send_settle(&market, &settle_args(quote_b, 100_000, 0, u64::MAX))
            .expect_err("different quote, same nonce");
        assert_custom(&err, RfqError::QuoteMismatch);
    }
}

#[test]
fn a_pre_funded_tracker_address_cannot_block_a_quote() {
    // The tracker PDA is predictable; anyone can send it lamports before the
    // first fill. Both programs must then fund-allocate-assign instead of
    // `create_account` (which would fail with AccountAlreadyInUse).
    for program in both() {
        for donation in [890_880u64, 50_000_000] {
            let mut env = Env::new(program, 0);
            let (market, quote) = env.standard_market();
            let griefer = env.funded_keypair();
            let fill_pda = env.quote_fill_key(&quote);
            env.transfer_lamports(&griefer, &fill_pda, donation);

            env.send_settle(&market, &settle_args(quote, 400_000, 0, u64::MAX))
                .unwrap_or_else(|e| panic!("{program:?} donation {donation}: {e:?}"));
            assert_eq!(
                env.quote_fill_state(&quote),
                Some((400_000, market.taker.pubkey())),
                "{program:?}"
            );
            let rent = env
                .svm
                .minimum_balance_for_rent_exemption(rfq_core::layout::quote_fill::LEN);
            assert_eq!(env.lamports(&fill_pda), rent.max(donation), "{program:?}");
            assert_eq!(env.token_balance(&market.taker_dst), 400_000, "{program:?}");
        }
    }
}

#[test]
fn completion_by_another_taker_leaves_the_rent_to_its_payer() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, quote) = env.standard_market();
        // Taker A opens the tracker (and pays its rent).
        env.send_settle(&market, &settle_args(quote, 300_000, 0, u64::MAX))
            .expect("A fills part");
        let fill_pda = env.quote_fill_key(&quote);
        let rent = env.lamports(&fill_pda);

        // Taker B completes the quote: the tracker is NOT handed to B; it stays
        // (nonce bit set) until `close_quote_fill` refunds A.
        let (b, b_src, b_dst) = env.extra_taker(&market, 5_000_000);
        let mut accounts = env.settle_accounts(&market);
        accounts.taker = b.pubkey();
        accounts.taker_src = b_src;
        accounts.taker_dst = b_dst;
        let args = settle_args(quote, 700_000, 0, u64::MAX);
        let ixs = vec![
            signed_quote(&env.program, &market.maker.quote_signer, &quote),
            rfq_client::ix::settle(&env.program, &accounts, &args, &[]),
        ];
        env.send(&ixs, &[&b]).expect("B completes");
        assert_eq!(env.token_balance(&b_dst), 700_000, "{program:?}");
        assert_eq!(
            env.quote_fill_state(&quote),
            Some((1_000_000, market.taker.pubkey())),
            "{program:?}"
        );
        assert_eq!(env.lamports(&fill_pda), rent, "{program:?}");

        // The quote is dead either way.
        env.svm.expire_blockhash();
        let err = env
            .send_settle(&market, &settle_args(quote, 1, 0, u64::MAX))
            .expect_err("dead quote");
        assert_custom(&err, RfqError::NonceAlreadyUsed);
    }
}

#[test]
fn the_taker_must_sign() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, quote) = env.standard_market();
        let args = settle_args(quote, 1_000_000, 0, u64::MAX);
        // Someone else pays the fee and the taker's meta is not a signer.
        let relayer = env.funded_keypair();
        let ixs = env.build_settle_with(&market, &args, |metas| metas[0].is_signer = false);
        let err = env
            .send_auto(&ixs, &[&relayer])
            .expect_err("unsigned taker");
        assert_code(&err, ac::ACCOUNT_NOT_SIGNER);
        assert_eq!(
            env.token_balance(&market.taker_src),
            5_000_000,
            "{program:?}"
        );
    }
}

#[test]
fn invalid_mint_pair_and_zero_amounts_are_rejected() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, quote) = env.standard_market();
        // A quote that sells and buys the same mint. The accounts are made
        // individually valid (the maker's vault_in, the taker's source are all
        // `maker_mint` accounts) so the handler's own check is what fires.
        let payer = market.payer.insecure_clone();
        let va = rfq_client::pda::vault_authority(&env.program, &market.maker.owner_key()).0;
        let vault_in = env.create_token_account(&payer, &market.maker_mint, &va);
        let src = env.create_token_account(&payer, &market.maker_mint, &market.taker.pubkey());
        let same = Quote {
            taker_mint: quote.maker_mint,
            ..quote
        };
        let mut accounts = env.settle_accounts(&market);
        accounts.taker_mint = market.maker_mint.key();
        accounts.maker_vault_in = vault_in;
        accounts.taker_src = src;
        let args = settle_args(same, 1_000_000, 0, u64::MAX);
        let ixs = vec![
            signed_quote(&env.program, &market.maker.quote_signer, &same),
            rfq_client::ix::settle(&env.program, &accounts, &args, &[]),
        ];
        let err = env.send_as_taker(&market, &ixs).expect_err("same mint");
        assert_custom(&err, RfqError::InvalidMintPair);

        // A zero-sized quote.
        let zero = Quote {
            taker_amount: 0,
            ..quote
        };
        let err = env
            .send_settle(&market, &settle_args(zero, 1, 0, u64::MAX))
            .expect_err("zero taker amount");
        assert_custom(&err, RfqError::ZeroAmount);
    }
}
