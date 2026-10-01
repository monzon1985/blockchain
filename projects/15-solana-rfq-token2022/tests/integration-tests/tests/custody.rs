// SPDX-License-Identifier: MIT
//! The Anchor program's lifecycle instructions — config, admin, maker
//! registry, PDA vault custody, fee withdrawal and tracker clean-up — happy
//! paths and every revert path, plus the custody-separation claims of the
//! threat model (the admin cannot touch maker inventory, a maker cannot touch
//! another maker's, withdrawals work while paused, the initializer cannot be
//! front-run). These instructions exist only in the Anchor program; the
//! settle-only Pinocchio program has no equivalent.

#![allow(clippy::expect_used)]

use {
    integration_tests::*,
    rfq_client::{ix, pda},
    rfq_core::{Quote, RfqError, anchor_codes as ac},
    solana_address::Address as Pubkey,
    solana_keypair::Keypair,
    solana_signer::Signer,
};

/// `SystemError::AccountAlreadyInUse`.
const ACCOUNT_ALREADY_IN_USE: u32 = 0;

#[test]
fn initialize_config_is_gated_on_the_upgrade_authority() {
    let mut env = Env::deploy(Program::Anchor, Build::Production);
    let p = env.program;
    let admin = env.admin.insecure_clone();

    // Anyone else trying to win the initialisation race is rejected.
    let intruder = env.funded_keypair();
    let err = env
        .send(
            &[ix::initialize_config(&p, &intruder.pubkey(), 10)],
            &[&intruder],
        )
        .expect_err("front-run");
    assert_custom(&err, RfqError::NotUpgradeAuthority);

    let err = env
        .send(
            &[ix::initialize_config(&p, &admin.pubkey(), 1_001)],
            &[&admin],
        )
        .expect_err("fee cap");
    assert_custom(&err, RfqError::FeeTooHigh);

    env.send(&[ix::initialize_config(&p, &admin.pubkey(), 10)], &[&admin])
        .expect("upgrade authority initialises");
    let config = env.data(&pda::config(&p).0);
    assert_eq!(config[8..40], admin.pubkey().to_bytes());

    env.svm.expire_blockhash();
    let err = env
        .send(&[ix::initialize_config(&p, &admin.pubkey(), 10)], &[&admin])
        .expect_err("only once");
    assert_code(&err, ACCOUNT_ALREADY_IN_USE);
}

#[test]
fn admin_two_step_transfer_and_fee_controls() {
    let mut env = Env::new(Program::Anchor, 10);
    let p = env.program;
    let config = pda::config(&p).0;
    let admin = env.admin.insecure_clone();
    let intruder = env.funded_keypair();

    let err = env
        .send(&[ix::set_fee(&p, &intruder.pubkey(), 5)], &[&intruder])
        .expect_err("non-admin fee");
    assert_custom(&err, RfqError::Unauthorized);
    let err = env
        .send(
            &[ix::set_paused(&p, &intruder.pubkey(), true)],
            &[&intruder],
        )
        .expect_err("non-admin pause");
    assert_custom(&err, RfqError::Unauthorized);

    env.send(&[ix::set_fee(&p, &admin.pubkey(), 50)], &[&admin])
        .expect("set fee");
    assert_eq!(env.data(&config)[rfq_core::layout::config::FEE_BPS], 50);
    let err = env
        .send(&[ix::set_fee(&p, &admin.pubkey(), 2_000)], &[&admin])
        .expect_err("fee cap");
    assert_custom(&err, RfqError::FeeTooHigh);

    // Two-step handover; a proposal can be cancelled with the default key.
    let new_admin = env.funded_keypair();
    env.send(
        &[ix::propose_admin(&p, &admin.pubkey(), &new_admin.pubkey())],
        &[&admin],
    )
    .expect("propose");
    let err = env
        .send(&[ix::accept_admin(&p, &intruder.pubkey())], &[&intruder])
        .expect_err("wrong acceptor");
    assert_custom(&err, RfqError::NotPendingAdmin);
    env.send(
        &[ix::propose_admin(&p, &admin.pubkey(), &Pubkey::default())],
        &[&admin],
    )
    .expect("cancel proposal");
    let err = env
        .send(&[ix::accept_admin(&p, &new_admin.pubkey())], &[&new_admin])
        .expect_err("cancelled");
    assert_custom(&err, RfqError::NotPendingAdmin);

    env.svm.expire_blockhash();
    env.send(
        &[ix::propose_admin(&p, &admin.pubkey(), &new_admin.pubkey())],
        &[&admin],
    )
    .expect("propose again");
    env.send(&[ix::accept_admin(&p, &new_admin.pubkey())], &[&new_admin])
        .expect("accept");
    env.svm.expire_blockhash();
    let err = env
        .send(&[ix::set_fee(&p, &admin.pubkey(), 1)], &[&admin])
        .expect_err("old admin");
    assert_custom(&err, RfqError::Unauthorized);
    env.send(&[ix::set_fee(&p, &new_admin.pubkey(), 1)], &[&new_admin])
        .expect("new admin controls");
}

/// A maker set up entirely through the Anchor custody instructions: PDA
/// vaults created by `init_vault`, funded by `deposit`.
struct PdaMaker {
    owner: Keypair,
    quote_signer: Keypair,
    owner_maker_ata: Pubkey,
    vault_out: Pubkey,
    vault_in: Pubkey,
}

fn pda_market(env: &mut Env) -> (Market, Quote, PdaMaker) {
    let p = env.program;
    let payer = env.funded_keypair();
    let maker_mint = env.create_token_mint(&payer, 6);
    let taker_mint = env.create_token_mint(&payer, 6);
    env.init_fee_vault(&maker_mint);

    let owner = env.funded_keypair();
    let quote_signer = Keypair::new();
    env.register_owner(&owner, &quote_signer.pubkey());
    for mint in [&maker_mint, &taker_mint] {
        env.send(
            &[ix::init_vault(
                &p,
                &owner.pubkey(),
                &mint.key(),
                &mint.token_program,
            )],
            &[&owner],
        )
        .expect("init_vault");
    }
    let vault_out = pda::vault(&p, &owner.pubkey(), &maker_mint.key()).0;
    let vault_in = pda::vault(&p, &owner.pubkey(), &taker_mint.key()).0;
    let owner_maker_ata = env.create_token_account(&payer, &maker_mint, &owner.pubkey());
    env.mint_to(&payer, &maker_mint, &owner_maker_ata, 3_000_000);

    let err = env
        .send(
            &[ix::deposit(
                &p,
                &owner.pubkey(),
                &maker_mint.key(),
                &owner_maker_ata,
                &maker_mint.token_program,
                0,
                &[],
            )],
            &[&owner],
        )
        .expect_err("zero deposit");
    assert_custom(&err, RfqError::ZeroAmount);
    env.send(
        &[ix::deposit(
            &p,
            &owner.pubkey(),
            &maker_mint.key(),
            &owner_maker_ata,
            &maker_mint.token_program,
            1_000_000,
            &[],
        )],
        &[&owner],
    )
    .expect("deposit");
    assert_eq!(env.token_balance(&vault_out), 1_000_000);

    let fixture = MakerFixture {
        owner: owner.insecure_clone(),
        quote_signer: quote_signer.insecure_clone(),
        vault_out,
        vault_in,
    };
    env.init_nonce_page(&fixture, 0);
    let taker = env.funded_keypair();
    let taker_src = env.create_token_account(&payer, &taker_mint, &taker.pubkey());
    let taker_dst = env.create_token_account(&payer, &maker_mint, &taker.pubkey());
    env.mint_to(&payer, &taker_mint, &taker_src, 5_000_000);
    let quote = Quote {
        maker: owner.pubkey().to_bytes(),
        maker_mint: maker_mint.key().to_bytes(),
        taker_mint: taker_mint.key().to_bytes(),
        maker_amount: 1_000_000,
        taker_amount: 2_000_000,
        nonce: 0,
        expiry: i64::MAX,
        taker: [0; 32],
    };
    (
        Market {
            maker_mint,
            taker_mint,
            maker: fixture,
            taker,
            taker_src,
            taker_dst,
            payer,
        },
        quote,
        PdaMaker {
            owner,
            quote_signer,
            owner_maker_ata,
            vault_out,
            vault_in,
        },
    )
}

#[test]
fn maker_custody_round_trip_through_pda_vaults() {
    let mut env = Env::new(Program::Anchor, 30);
    let p = env.program;
    let (market, quote, m) = pda_market(&mut env);
    let _ = &m.quote_signer;

    env.send_settle(&market, &settle_args(quote, 1_000_000, 0, u64::MAX))
        .expect("settle against PDA vaults");
    assert_eq!(env.token_balance(&m.vault_out), 0);
    assert_eq!(env.token_balance(&m.vault_in), 2_000_000);

    // The maker sweeps its proceeds — even while settlement is paused.
    env.set_paused(true);
    let owner_taker_ata = {
        let payer = market.payer.insecure_clone();
        env.create_token_account(&payer, &market.taker_mint, &m.owner.pubkey())
    };
    let withdraw = |amount| {
        ix::withdraw(
            &p,
            &m.owner.pubkey(),
            &market.taker_mint.key(),
            &m.vault_in,
            &owner_taker_ata,
            &market.taker_mint.token_program,
            amount,
            &[],
        )
    };
    let err = env.send(&[withdraw(0)], &[&m.owner]).expect_err("zero");
    assert_custom(&err, RfqError::ZeroAmount);
    env.send(&[withdraw(2_000_000)], &[&m.owner])
        .expect("withdraw while paused");
    assert_eq!(env.token_balance(&owner_taker_ata), 2_000_000);
    assert_eq!(env.token_balance(&m.vault_in), 0);

    // Deposits stay open while paused too.
    env.send(
        &[ix::deposit(
            &p,
            &m.owner.pubkey(),
            &market.maker_mint.key(),
            &m.owner_maker_ata,
            &market.maker_mint.token_program,
            500_000,
            &[],
        )],
        &[&m.owner],
    )
    .expect("deposit while paused");
    assert_eq!(env.token_balance(&m.vault_out), 500_000);
}

#[test]
fn nobody_else_can_move_maker_inventory() {
    let mut env = Env::new(Program::Anchor, 0);
    let p = env.program;
    let (market, _, m) = pda_market(&mut env);
    let payer = market.payer.insecure_clone();

    // An unregistered wallet: its maker PDA does not exist.
    let intruder = env.funded_keypair();
    let intruder_ata = env.create_token_account(&payer, &market.maker_mint, &intruder.pubkey());
    let steal = |env: &mut Env, who: &Keypair| {
        let ix = ix::withdraw(
            &p,
            &who.pubkey(),
            &market.maker_mint.key(),
            &m.vault_out,
            &intruder_ata,
            &market.maker_mint.token_program,
            1,
            &[],
        );
        env.send(&[ix], &[who]).expect_err("must not withdraw")
    };
    let err = steal(&mut env, &intruder);
    assert_code(&err, ac::ACCOUNT_NOT_INITIALIZED);

    // A registered maker naming the victim's vault: wrong vault authority.
    env.register_owner(&intruder, &intruder.pubkey());
    let err = steal(&mut env, &intruder);
    assert_code(&err, ac::CONSTRAINT_TOKEN_OWNER);

    // The admin has no maker registry entry and no authority over vaults.
    let admin = env.admin.insecure_clone();
    let err = steal(&mut env, &admin);
    assert_code(&err, ac::ACCOUNT_NOT_INITIALIZED);
    // ...and `withdraw_fees` only accepts token accounts owned by the config.
    let ix = ix::withdraw_fees(
        &p,
        &admin.pubkey(),
        &market.maker_mint.key(),
        &m.vault_out,
        &intruder_ata,
        &market.maker_mint.token_program,
        1,
        &[],
    );
    let err = env
        .send(&[ix], &[&admin])
        .expect_err("admin vs maker vault");
    assert_code(&err, ac::CONSTRAINT_TOKEN_OWNER);
    assert_eq!(env.token_balance(&m.vault_out), 1_000_000, "nothing moved");
}

#[test]
fn fees_are_withdrawable_by_the_admin_only() {
    let mut env = Env::new(Program::Anchor, 30);
    let p = env.program;
    let (market, quote) = env.standard_market();
    env.send_settle(&market, &settle_args(quote, 1_000_000, 0, u64::MAX))
        .expect("settle");
    let fee_vault = env.fee_vault(&market.maker_mint);
    assert_eq!(env.token_balance(&fee_vault), 3_000);

    let admin = env.admin.insecure_clone();
    let payer = market.payer.insecure_clone();
    let admin_ata = env.create_token_account(&payer, &market.maker_mint, &admin.pubkey());
    let wf = |who: &Pubkey, amount| {
        ix::withdraw_fees(
            &p,
            who,
            &market.maker_mint.key(),
            &fee_vault,
            &admin_ata,
            &market.maker_mint.token_program,
            amount,
            &[],
        )
    };
    let intruder = env.funded_keypair();
    let err = env
        .send(&[wf(&intruder.pubkey(), 3_000)], &[&intruder])
        .expect_err("non-admin");
    assert_custom(&err, RfqError::Unauthorized);
    let err = env
        .send(&[wf(&admin.pubkey(), 0)], &[&admin])
        .expect_err("zero");
    assert_custom(&err, RfqError::ZeroAmount);
    env.send(&[wf(&admin.pubkey(), 3_000)], &[&admin])
        .expect("admin withdraws fees");
    assert_eq!(env.token_balance(&admin_ata), 3_000);
    assert_eq!(env.token_balance(&fee_vault), 0);

    // Fee vaults are admin-created.
    let mint2 = env.create_token_mint(&payer, 6);
    let err = env
        .send(
            &[ix::init_fee_vault(
                &p,
                &intruder.pubkey(),
                &mint2.key(),
                &mint2.token_program,
            )],
            &[&intruder],
        )
        .expect_err("non-admin fee vault");
    assert_custom(&err, RfqError::Unauthorized);
}

#[test]
fn rotating_the_quote_signer_kills_quotes_signed_by_the_old_key() {
    let mut env = Env::new(Program::Anchor, 0);
    let p = env.program;
    let (market, quote) = env.standard_market();
    let owner = market.maker.owner.insecure_clone();

    let intruder = env.funded_keypair();
    let err = env
        .send(
            &[ix::set_quote_signer(
                &p,
                &intruder.pubkey(),
                &intruder.pubkey(),
            )],
            &[&intruder],
        )
        .expect_err("not the owner");
    assert_code(&err, ac::ACCOUNT_NOT_INITIALIZED);

    let new_signer = Keypair::new();
    env.send(
        &[ix::set_quote_signer(
            &p,
            &owner.pubkey(),
            &new_signer.pubkey(),
        )],
        &[&owner],
    )
    .expect("rotate");
    // A quote signed by the old (possibly compromised) key no longer settles.
    let err = env
        .send_settle(&market, &settle_args(quote, 1_000_000, 0, u64::MAX))
        .expect_err("old key");
    assert_custom(&err, RfqError::SignerMismatch);
    // The new key's quotes do.
    let args = settle_args(quote, 1_000_000, 0, u64::MAX);
    let accounts = env.settle_accounts(&market);
    let ixs = vec![
        signed_quote(&p, &new_signer, &quote),
        ix::settle(&p, &accounts, &args, &[]),
    ];
    env.send_as_taker(&market, &ixs).expect("new key");
}

#[test]
fn maker_instructions_are_owner_only() {
    let mut env = Env::new(Program::Anchor, 0);
    let p = env.program;
    let (market, _) = env.standard_market();
    let owner = market.maker.owner.insecure_clone();
    let intruder = env.funded_keypair();
    let i = intruder.pubkey();
    let mint = market.maker_mint.key();
    let tp = market.maker_mint.token_program;
    for ix in [
        ix::set_maker_active(&p, &i, false),
        ix::bump_min_nonce(&p, &i, 9),
        ix::init_nonce_page(&p, &i, 1),
        ix::init_vault(&p, &i, &mint, &tp),
        ix::cancel_nonces(&p, &i, 0, &[0xFF; 32]),
    ] {
        let err = env.send(&[ix], &[&intruder]).expect_err("intruder");
        assert_code(&err, ac::ACCOUNT_NOT_INITIALIZED);
    }
    // min_nonce is strictly increasing.
    env.send(&[ix::bump_min_nonce(&p, &owner.pubkey(), 5)], &[&owner])
        .expect("bump");
    env.svm.expire_blockhash();
    let err = env
        .send(&[ix::bump_min_nonce(&p, &owner.pubkey(), 5)], &[&owner])
        .expect_err("not increasing");
    assert_custom(&err, RfqError::NonceNotIncreasing);
}

#[test]
fn dead_quote_trackers_are_closed_to_their_payer() {
    // How each case kills the quote after taker A's partial fill.
    #[derive(Clone, Copy, Debug)]
    enum Death {
        Cancelled,
        MinNonce,
        Expired,
        CompletedByAnother,
    }
    for death in [
        Death::Cancelled,
        Death::MinNonce,
        Death::Expired,
        Death::CompletedByAnother,
    ] {
        let mut env = Env::new(Program::Anchor, 0);
        env.set_unix_timestamp(100);
        let p = env.program;
        let (market, base) = env.standard_market();
        let quote = Quote {
            expiry: 1_000_000,
            ..base
        };
        env.send_settle(&market, &settle_args(quote, 300_000, 0, u64::MAX))
            .expect("A fills part");
        let a = market.taker.pubkey();
        let tracker = env.quote_fill_key(&quote);
        let rent = env.lamports(&tracker);
        let closer = env.funded_keypair();

        // While the quote is live, nobody can close the tracker.
        let err = env
            .send(&[ix::close_quote_fill(&p, &quote, &a)], &[&closer])
            .expect_err("live");
        assert_custom(&err, RfqError::QuoteStillLive);

        match death {
            Death::Cancelled => {
                let mut mask = [0u8; 32];
                mask[0] = 1;
                env.cancel_nonces(&market.maker, 0, &mask);
            }
            Death::MinNonce => env.bump_min_nonce(&market.maker, 1),
            Death::Expired => env.set_unix_timestamp(1_000_001),
            Death::CompletedByAnother => {
                let (b, b_src, b_dst) = env.extra_taker(&market, 5_000_000);
                let mut accounts = env.settle_accounts(&market);
                accounts.taker = b.pubkey();
                accounts.taker_src = b_src;
                accounts.taker_dst = b_dst;
                let args = settle_args(quote, 700_000, 0, u64::MAX);
                let ixs = vec![
                    signed_quote(&p, &market.maker.quote_signer, &quote),
                    ix::settle(&p, &accounts, &args, &[]),
                ];
                env.send(&ixs, &[&b]).expect("B completes");
            }
        }

        // The refund can only go to the recorded payer, for the exact quote.
        let err = env
            .send(
                &[ix::close_quote_fill(&p, &quote, &closer.pubkey())],
                &[&closer],
            )
            .expect_err("wrong payer");
        assert_custom(&err, RfqError::Unauthorized);
        let other = Quote {
            taker_amount: 1,
            ..quote
        };
        let err = env
            .send(&[ix::close_quote_fill(&p, &other, &a)], &[&closer])
            .expect_err("wrong quote");
        assert_custom(&err, RfqError::QuoteMismatch);

        let a_before = env.lamports(&a);
        env.send(&[ix::close_quote_fill(&p, &quote, &a)], &[&closer])
            .unwrap_or_else(|e| panic!("{death:?}: {e:?}"));
        assert!(env.is_closed(&tracker), "{death:?}");
        assert_eq!(env.lamports(&a), a_before + rent, "{death:?}: A refunded");
    }
}
