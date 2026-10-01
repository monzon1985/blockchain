// SPDX-License-Identifier: MIT
//! Account-validation negatives and the remaining economic reverts, run
//! against BOTH programs with the same expected error.
//!
//! Covers expiry / pause / inactive maker / cancellation / restricted taker,
//! spoofed vaults, wrong and malformed mints, fake PDAs (byte-valid look-alikes
//! at a non-canonical or random address), wrong program ownership, wrong token
//! / system programs (the arbitrary-CPI vector), duplicate mutable accounts,
//! missing `mut`, and missing transfer-hook metas.

#![allow(clippy::expect_used)]

use {
    integration_tests::*,
    rfq_client::{TEST_HOOK_PROGRAM_ID, TOKEN_2022_PROGRAM_ID, TOKEN_PROGRAM_ID, pda},
    rfq_core::{
        Quote, RfqError, anchor_codes as ac, hook::codes as hook_codes,
        layout::settle_accounts as at,
    },
    solana_address::Address as Pubkey,
    solana_instruction::AccountMeta,
    solana_keypair::Keypair,
    solana_signer::Signer,
};

#[test]
fn expired_quote_is_rejected() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, base) = env.standard_market();
        env.set_unix_timestamp(10_000);
        let quote = Quote {
            expiry: 9_999,
            ..base
        };
        let err = env
            .send_settle(&market, &settle_args(quote, 1_000_000, 0, u64::MAX))
            .expect_err("expired");
        assert_custom(&err, RfqError::QuoteExpired);
        // The expiry is inclusive.
        let at_expiry = Quote {
            expiry: 10_000,
            ..base
        };
        env.send_settle(&market, &settle_args(at_expiry, 1_000_000, 0, u64::MAX))
            .expect("expiry is inclusive");
    }
}

#[test]
fn paused_program_rejects_settlement() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, quote) = env.standard_market();
        env.set_paused(true);
        let args = settle_args(quote, 1_000_000, 0, u64::MAX);
        let err = env.send_settle(&market, &args).expect_err("paused");
        assert_custom(&err, RfqError::Paused);
        env.set_paused(false);
        env.svm.expire_blockhash();
        env.send_settle(&market, &args).expect("resumed");
    }
}

#[test]
fn inactive_maker_cannot_be_filled() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, quote) = env.standard_market();
        env.set_maker_active(&market.maker, false);
        let err = env
            .send_settle(&market, &settle_args(quote, 1_000_000, 0, u64::MAX))
            .expect_err("inactive");
        assert_custom(&err, RfqError::MakerInactive);
    }
}

#[test]
fn bumped_min_nonce_and_cancel_mask_kill_quotes() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, base) = env.standard_market();

        // Cancel every quote below nonce 5.
        env.bump_min_nonce(&market.maker, 5);
        let args = settle_args(Quote { nonce: 3, ..base }, 1_000_000, 0, u64::MAX);
        let err = env.send_settle(&market, &args).expect_err("cancelled");
        assert_custom(&err, RfqError::NonceCancelled);

        // A specific nonce cancelled via mask (nonce 5 = bit 5 of byte 0).
        let mut mask = [0u8; 32];
        mask[0] = 1 << 5;
        env.cancel_nonces(&market.maker, 0, &mask);
        let args = settle_args(Quote { nonce: 5, ..base }, 1_000_000, 0, u64::MAX);
        let err = env.send_settle(&market, &args).expect_err("nonce used");
        assert_custom(&err, RfqError::NonceAlreadyUsed);

        // Neighbouring nonce 6 is untouched.
        let args = settle_args(Quote { nonce: 6, ..base }, 1_000_000, 0, u64::MAX);
        env.send_settle(&market, &args).expect("nonce 6 still live");
    }
}

#[test]
fn restricted_quote_rejects_the_wrong_taker_and_accepts_the_right_one() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, base) = env.standard_market();
        let stranger = Keypair::new();
        let quote = Quote {
            taker: stranger.pubkey().to_bytes(),
            ..base
        };
        let err = env
            .send_settle(&market, &settle_args(quote, 1_000_000, 0, u64::MAX))
            .expect_err("wrong taker");
        assert_custom(&err, RfqError::TakerNotAllowed);

        let mine = Quote {
            taker: market.taker.pubkey().to_bytes(),
            nonce: 1,
            ..base
        };
        env.send_settle(&market, &settle_args(mine, 1_000_000, 0, u64::MAX))
            .expect("named taker");
    }
}

#[test]
fn spoofed_maker_vault_of_a_different_authority_is_rejected() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, quote) = env.standard_market();
        let args = settle_args(quote, 1_000_000, 0, u64::MAX);
        // A token account of the right mint but owned by an attacker, in the
        // maker-vault slot, fails `token::authority = vault_authority`.
        let attacker = env.funded_keypair();
        let fake_vault =
            env.create_token_account(&attacker, &market.maker_mint, &attacker.pubkey());
        let ixs = env.build_settle_with(&market, &args, |m| {
            m[at::MAKER_VAULT_OUT] = AccountMeta::new(fake_vault, false)
        });
        let err = env.send_as_taker(&market, &ixs).expect_err("spoofed vault");
        assert_code(&err, ac::CONSTRAINT_TOKEN_OWNER);
        // A fee vault that is not the config PDA's.
        let ixs = env.build_settle_with(&market, &args, |m| {
            m[at::FEE_VAULT] = AccountMeta::new(fake_vault, false)
        });
        let err = env
            .send_as_taker(&market, &ixs)
            .expect_err("spoofed fee vault");
        assert_code(&err, ac::CONSTRAINT_TOKEN_OWNER);
    }
}

#[test]
fn wrong_and_malformed_mints_are_rejected() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, quote) = env.standard_market();
        let args = settle_args(quote, 1_000_000, 0, u64::MAX);
        // The taker mint in the maker-mint slot: `address = quote.maker_mint`.
        let taker_mint = market.taker_mint.key();
        let ixs = env.build_settle_with(&market, &args, |m| {
            m[at::MAKER_MINT] = AccountMeta::new_readonly(taker_mint, false)
        });
        let err = env.send_as_taker(&market, &ixs).expect_err("wrong mint");
        assert_custom(&err, RfqError::MintMismatch);

        // A token account in a mint slot fails to unpack as a mint.
        let not_a_mint = market.taker_src;
        let ixs = env.build_settle_with(&market, &args, |m| {
            m[at::MAKER_MINT] = AccountMeta::new_readonly(not_a_mint, false)
        });
        let err = env.send_as_taker(&market, &ixs).expect_err("not a mint");
        assert_ix_error(&err, InstructionError::InvalidAccountData);

        // A real mint under the other (valid) token program id.
        let ixs = env.build_settle_with(&market, &args, |m| {
            m[at::MAKER_TOKEN_PROGRAM] = AccountMeta::new_readonly(TOKEN_2022_PROGRAM_ID, false)
        });
        let err = env.send_as_taker(&market, &ixs).expect_err("mint program");
        assert_code(&err, ac::CONSTRAINT_MINT_TOKEN_PROGRAM);
    }
}

/// The critical arbitrary-CPI vector: every token CPI is signed by the
/// vault-authority PDA, so a substituted "token program" would act with the
/// maker's authority. Both programs must reject it before any CPI happens.
#[test]
fn substituted_token_and_system_programs_are_rejected_before_any_cpi() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, quote) = env.standard_market();
        let args = settle_args(quote, 1_000_000, 0, u64::MAX);
        let hook = TEST_HOOK_PROGRAM_ID;

        for slot in [at::MAKER_TOKEN_PROGRAM, at::TAKER_TOKEN_PROGRAM] {
            let ixs = env.build_settle_with(&market, &args, |m| {
                m[slot] = AccountMeta::new_readonly(hook, false)
            });
            let err = env
                .send_as_taker(&market, &ixs)
                .expect_err("fake token program");
            assert_code(&err, ac::INVALID_PROGRAM_ID);
            let hook_str = hook.to_string();
            assert!(
                !err.meta.logs.iter().any(|l| l.contains(&hook_str)),
                "{program:?}: the substituted program must never be invoked: {:#?}",
                err.meta.logs
            );
        }
        let ixs = env.build_settle_with(&market, &args, |m| {
            m[at::SYSTEM_PROGRAM] = AccountMeta::new_readonly(TOKEN_PROGRAM_ID, false)
        });
        let err = env
            .send_as_taker(&market, &ixs)
            .expect_err("fake system program");
        assert_code(&err, ac::INVALID_PROGRAM_ID);

        // The full reviewer PoC: a fake maker mint and fake token accounts all
        // owned by the attacker program, plus that program as token program.
        // The mint's owner is checked first (InterfaceAccount<Mint>).
        let fake = |env: &mut Env, len: usize| {
            let k = Pubkey::new_unique();
            env.seed_raw(k, hook, [0; 8], &[], len);
            k
        };
        let (fmint, fout, fdst, ffee) = (
            fake(&mut env, 82),
            fake(&mut env, 165),
            fake(&mut env, 165),
            fake(&mut env, 165),
        );
        let ixs = env.build_settle_with(&market, &args, |m| {
            m[at::MAKER_MINT] = AccountMeta::new_readonly(fmint, false);
            m[at::MAKER_VAULT_OUT] = AccountMeta::new(fout, false);
            m[at::TAKER_DST] = AccountMeta::new(fdst, false);
            m[at::FEE_VAULT] = AccountMeta::new(ffee, false);
            m[at::MAKER_TOKEN_PROGRAM] = AccountMeta::new_readonly(hook, false);
        });
        let err = env.send_as_taker(&market, &ixs).expect_err("PoC");
        assert_code(&err, ac::ACCOUNT_OWNED_BY_WRONG_PROGRAM);
        assert_eq!(env.token_balance(&market.maker.vault_out), 1_000_000);
    }
}

#[test]
fn duplicate_mutable_accounts_are_rejected() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, quote) = env.standard_market();
        let args = settle_args(quote, 1_000_000, 0, u64::MAX);
        let vault_out = market.maker.vault_out;
        let taker_dst = market.taker_dst;
        // The taker "receives" into the maker's own vault: without the check
        // the taker would pay in full and receive nothing.
        let ixs = env.build_settle_with(&market, &args, |m| {
            m[at::TAKER_DST] = AccountMeta::new(vault_out, false)
        });
        let err = env.send_as_taker(&market, &ixs).expect_err("dup");
        assert_code(&err, ac::CONSTRAINT_DUPLICATE_MUTABLE_ACCOUNT);
        // The taker's own account as the fee vault.
        let ixs = env.build_settle_with(&market, &args, |m| {
            m[at::FEE_VAULT] = AccountMeta::new(taker_dst, false)
        });
        let err = env.send_as_taker(&market, &ixs).expect_err("dup fee vault");
        assert_code(&err, ac::CONSTRAINT_DUPLICATE_MUTABLE_ACCOUNT);
        assert_eq!(
            env.token_balance(&market.taker_src),
            5_000_000,
            "{program:?}"
        );
    }
}

#[test]
fn mutable_accounts_must_be_writable() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, quote) = env.standard_market();
        let args = settle_args(quote, 1_000_000, 0, u64::MAX);
        for slot in [
            at::NONCE_PAGE,
            at::MAKER_VAULT_OUT,
            at::TAKER_SRC,
            at::FEE_VAULT,
        ] {
            let ixs = env.build_settle_with(&market, &args, |m| m[slot].is_writable = false);
            let err = env.send_as_taker(&market, &ixs).expect_err("read-only");
            assert_code(&err, ac::CONSTRAINT_MUT);
        }
    }
}

#[test]
fn uninitialised_account_in_the_config_slot_is_rejected() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, quote) = env.standard_market();
        let args = settle_args(quote, 1_000_000, 0, u64::MAX);
        let random = Pubkey::new_unique();
        let ixs = env.build_settle_with(&market, &args, |m| {
            m[at::CONFIG] = AccountMeta::new_readonly(random, false)
        });
        let err = env.send_as_taker(&market, &ixs).expect_err("uninitialised");
        assert_code(&err, ac::ACCOUNT_NOT_INITIALIZED);
        // A program-owned account of another type: discriminator mismatch.
        let maker_pda = pda::maker(&env.program, &market.maker.owner_key()).0;
        let ixs = env.build_settle_with(&market, &args, |m| {
            m[at::CONFIG] = AccountMeta::new_readonly(maker_pda, false)
        });
        let err = env.send_as_taker(&market, &ixs).expect_err("wrong type");
        assert_code(&err, ac::ACCOUNT_DISCRIMINATOR_MISMATCH);
    }
}

/// Copies a real program account's bytes to `key`, owned by `owner`.
fn look_alike(env: &mut Env, real: &Pubkey, key: Pubkey, owner: Pubkey) {
    let mut acct = env.svm.get_account(real).expect("real account");
    acct.owner = owner;
    env.svm.set_account(key, acct).expect("seed look-alike");
}

/// A non-canonical PDA of `seeds` (a lower bump that is still off-curve).
fn non_canonical(seeds: &[&[u8]], program: &Pubkey) -> Pubkey {
    let (_, canonical) = Pubkey::find_program_address(seeds, program);
    (0..canonical)
        .rev()
        .find_map(|b| {
            let mut s = seeds.to_vec();
            let bump = [b];
            s.push(&bump);
            Pubkey::create_program_address(&s, program).ok()
        })
        .expect("a non-canonical bump")
}

/// Fake PDAs: byte-valid copies of the real Config / Maker / NoncePage at an
/// address the seeds do not derive (random, or a non-canonical bump with the
/// canonical bump stored) fail the seeds check; the same bytes owned by
/// another program fail the owner check.
#[test]
fn fake_pdas_and_wrong_owners_are_rejected() {
    for program in both() {
        let mut env = Env::new(program, 0);
        let (market, quote) = env.standard_market();
        let args = settle_args(quote, 1_000_000, 0, u64::MAX);
        let p = env.program;
        let owner = market.maker.owner_key();
        let page = 0u64.to_le_bytes();
        let cases: [(usize, Pubkey, Vec<&[u8]>); 3] = [
            (at::CONFIG, pda::config(&p).0, vec![rfq_core::seeds::CONFIG]),
            (
                at::MAKER,
                pda::maker(&p, &owner).0,
                vec![rfq_core::seeds::MAKER, owner.as_ref()],
            ),
            (
                at::NONCE_PAGE,
                pda::nonce_page(&p, &owner, 0).0,
                vec![rfq_core::seeds::NONCE_PAGE, owner.as_ref(), &page],
            ),
        ];
        for (slot, real, seeds) in cases {
            let writable = slot == at::NONCE_PAGE;
            let meta = |k: Pubkey| {
                if writable {
                    AccountMeta::new(k, false)
                } else {
                    AccountMeta::new_readonly(k, false)
                }
            };
            for fake_key in [Pubkey::new_unique(), non_canonical(&seeds, &p)] {
                look_alike(&mut env, &real, fake_key, p);
                let ixs = env.build_settle_with(&market, &args, |m| m[slot] = meta(fake_key));
                let err = env.send_as_taker(&market, &ixs).expect_err("fake PDA");
                assert_code(&err, ac::CONSTRAINT_SEEDS);
            }
            let foreign = Pubkey::new_unique();
            look_alike(&mut env, &real, foreign, TEST_HOOK_PROGRAM_ID);
            let ixs = env.build_settle_with(&market, &args, |m| m[slot] = meta(foreign));
            let err = env.send_as_taker(&market, &ixs).expect_err("wrong owner");
            assert_code(&err, ac::ACCOUNT_OWNED_BY_WRONG_PROGRAM);
        }
        // A look-alike vault authority (any other address) fails its seeds.
        let ixs = env.build_settle_with(&market, &args, |m| {
            m[at::VAULT_AUTHORITY] = AccountMeta::new_readonly(Pubkey::new_unique(), false)
        });
        let err = env
            .send_as_taker(&market, &ixs)
            .expect_err("fake vault authority");
        assert_code(&err, ac::CONSTRAINT_SEEDS);
        // The instructions-sysvar slot is address-constrained.
        let ixs = env.build_settle_with(&market, &args, |m| {
            m[at::INSTRUCTIONS] = AccountMeta::new_readonly(Pubkey::new_unique(), false)
        });
        let err = env.send_as_taker(&market, &ixs).expect_err("fake sysvar");
        assert_code(&err, ac::CONSTRAINT_ADDRESS);
        // A tracker address that is not the quote's PDA.
        let ixs = env.build_settle_with(&market, &args, |m| {
            m[at::QUOTE_FILL] = AccountMeta::new(Pubkey::new_unique(), false)
        });
        let err = env.send_as_taker(&market, &ixs).expect_err("fake tracker");
        assert_code(&err, ac::CONSTRAINT_SEEDS);
    }
}

#[test]
fn missing_hook_extra_metas_are_rejected() {
    for program in both() {
        let mut env = Env::new(program, 30);
        let payer = env.funded_keypair();
        let maker_mint = env.create_hooked_mint(&payer, 6);
        let taker_mint = env.create_token_mint(&payer, 6);
        let (market, base) = env.market(&payer, maker_mint, taker_mint, 1_000_000, 5_000_000);
        let va = pda::vault_authority(&env.program, &market.maker.owner_key()).0;
        let config = pda::config(&env.program).0;
        for wallet in [market.taker.pubkey(), va, config] {
            env.set_hook_allowed(&payer, &market.maker_mint, &wallet, true);
        }
        let quote = Quote {
            maker_amount: 1_000_000,
            taker_amount: 2_000_000,
            ..base
        };
        // Settle WITHOUT the resolved hook accounts: resolution cannot find the
        // hook program among the remaining accounts.
        let args = settle_args(quote, 1_000_000, 0, u64::MAX);
        let ixs = env.build_settle_with(&market, &args, |_| {});
        let err = env.send_as_taker(&market, &ixs).expect_err("missing metas");
        assert_code(&err, hook_codes::HOOK_INCORRECT_ACCOUNT);
        assert_eq!(
            env.token_balance(&market.maker.vault_out),
            1_000_000,
            "{program:?}: nothing moved"
        );
    }
}
