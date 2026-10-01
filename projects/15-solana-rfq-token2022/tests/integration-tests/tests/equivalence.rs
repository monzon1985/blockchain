// SPDX-License-Identifier: MIT
//! Anchor ⇄ Pinocchio behavioural equivalence on LiteSVM.
//!
//! Runs the same scenarios against both programs and asserts that the emitted
//! `Settled` event and the resulting balances are identical, and that the same
//! invalid input — including inputs with *several* faults at once, where only
//! the order of the checks decides the error — fails with the very same
//! `InstructionError`. (Most single-fault cases live in `negatives.rs`,
//! `exploit.rs` and `settle_flows.rs`, which also run on both programs; the
//! Mollusk compute-unit comparison lives in the `cu-bench` crate.)

#![allow(clippy::expect_used)]

use {
    integration_tests::*,
    rfq_client::{TEST_HOOK_PROGRAM_ID, pda},
    rfq_core::{
        Quote, RfqError, anchor_codes as ac, layout::SettledEvent, layout::settle_accounts as at,
    },
    solana_address::Address as Pubkey,
    solana_instruction::AccountMeta,
};

/// Runs a two-part fill and returns `(event, taker_out, maker_in, fee, cu)`.
fn run_scenario(
    program: Program,
    fee_bps: u16,
    fee_mint: bool,
) -> (SettledEvent, u64, u64, u64, u64) {
    let mut env = Env::new(program, fee_bps);
    let payer = env.funded_keypair();
    let maker_mint = env.create_token_mint(&payer, 6);
    let taker_mint = if fee_mint {
        env.create_token22_mint(
            &payer,
            6,
            MintConfig {
                transfer_fee: Some((250, 100_000)),
                transfer_hook: None,
            },
        )
    } else {
        env.create_token_mint(&payer, 6)
    };
    let (market, base) = env.market(&payer, maker_mint, taker_mint, 1_000_000, 20_000_000);
    let quote = Quote {
        maker_amount: 1_000_000,
        taker_amount: 2_000_000,
        nonce: 42,
        ..base
    };
    // Two partial fills, to exercise the tracker create + reuse + close.
    env.send_settle(&market, &settle_args(quote, 300_000, 0, u64::MAX))
        .expect("fill 1");
    let meta = env
        .send_settle(&market, &settle_args(quote, 700_000, 0, u64::MAX))
        .expect("fill 2");
    (
        settled_event(&meta.logs),
        env.token_balance(&market.taker_dst),
        env.token_balance(&market.maker.vault_in),
        env.token_balance(&env.fee_vault(&market.maker_mint)),
        meta.compute_units_consumed,
    )
}

#[test]
fn settle_results_are_identical_across_programs() {
    for (fee_bps, fee_mint) in [(0u16, false), (30, false), (30, true), (1000, true)] {
        let anchor = run_scenario(Program::Anchor, fee_bps, fee_mint);
        let pinocchio = run_scenario(Program::Pinocchio, fee_bps, fee_mint);
        // Maker/taker keys are random per run; compare the economic fields.
        let strip = |e: SettledEvent| SettledEvent {
            maker: [0; 32],
            taker: [0; 32],
            ..e
        };
        let tag = format!("fee_bps={fee_bps}, fee_mint={fee_mint}");
        assert_eq!(strip(anchor.0), strip(pinocchio.0), "event ({tag})");
        assert_eq!(anchor.1, pinocchio.1, "taker out ({tag})");
        assert_eq!(anchor.2, pinocchio.2, "maker in ({tag})");
        assert_eq!(anchor.3, pinocchio.3, "protocol fee ({tag})");
        // The zero-copy program is cheaper on every scenario.
        assert!(
            pinocchio.4 < anchor.4,
            "CU ({tag}): {} vs {}",
            pinocchio.4,
            anchor.4
        );
    }
}

/// Cross-check of the Mollusk CU table (`cu-bench`, Agave 4.2.2 runtime) on
/// the Agave 4.3 runtime LiteSVM links: the same one-shot, fee-bearing full
/// fill (tracker created and closed in the same transaction). Not pinned:
/// LiteSVM fixtures use random keys, so the PDA bump searches — and with them
/// the CU — vary by a few hundred units from run to run.
#[test]
fn one_shot_fill_compute_units_on_litesvm() {
    let cu = |program| {
        let mut env = Env::new(program, 30);
        let (market, quote) = env.standard_market();
        env.send_settle(&market, &settle_args(quote, 1_000_000, 0, u64::MAX))
            .expect("settle")
            .compute_units_consumed
    };
    let (anchor, pinocchio) = (cu(Program::Anchor), cu(Program::Pinocchio));
    println!("LiteSVM (Agave 4.3) one-shot fill, tx CU: Anchor {anchor} / Pinocchio {pinocchio}");
    assert!(pinocchio < anchor, "{pinocchio} vs {anchor}");
}

/// One way to break a settlement: a state change and/or an account edit.
struct Fault {
    name: &'static str,
    state: fn(&mut Env, &Market),
    quote: fn(Quote) -> Quote,
    metas: fn(&Env, &Market, &mut Vec<AccountMeta>),
}

fn no_state(_: &mut Env, _: &Market) {}
fn no_quote(q: Quote) -> Quote {
    q
}
fn no_metas(_: &Env, _: &Market, _: &mut Vec<AccountMeta>) {}

/// Runs `faults` together on `program` and returns the instruction error.
fn run_faults(program: Program, faults: &[&Fault]) -> InstructionError {
    let mut env = Env::new(program, 0);
    let (market, quote) = env.standard_market();
    let mut q = quote;
    for f in faults {
        (f.state)(&mut env, &market);
        q = (f.quote)(q);
    }
    let args = settle_args(q, 1_000_000, 0, u64::MAX);
    let mut ixs = env.build_settle_with(&market, &args, |_| {});
    for f in faults {
        (f.metas)(&env, &market, &mut ixs[1].accounts);
    }
    let err = env.send_as_taker(&market, &ixs).expect_err("rejected");
    instruction_error(&err)
}

fn faults() -> Vec<Fault> {
    vec![
        Fault {
            name: "paused",
            state: |env, _| env.set_paused(true),
            quote: no_quote,
            metas: no_metas,
        },
        Fault {
            name: "expired",
            state: |env, _| env.set_unix_timestamp(1_000),
            quote: |q| Quote { expiry: 999, ..q },
            metas: no_metas,
        },
        Fault {
            name: "inactive maker",
            state: |env, m| env.set_maker_active(&m.maker, false),
            quote: no_quote,
            metas: no_metas,
        },
        Fault {
            name: "wrong taker",
            state: no_state,
            quote: |q| Quote {
                taker: [7; 32],
                ..q
            },
            metas: no_metas,
        },
        Fault {
            name: "overfill",
            state: no_state,
            quote: |q| Quote {
                maker_amount: 999_999,
                ..q
            },
            metas: no_metas,
        },
        Fault {
            name: "config in the maker slot",
            state: no_state,
            quote: no_quote,
            metas: |env, _, metas| {
                metas[at::MAKER] = AccountMeta::new_readonly(pda::config(&env.program).0, false)
            },
        },
        Fault {
            name: "rotated quote signer",
            state: |env, m| env.set_quote_signer(&m.maker, &Pubkey::new_unique()),
            quote: no_quote,
            metas: no_metas,
        },
        Fault {
            name: "wrong mint",
            state: no_state,
            quote: no_quote,
            metas: |_, m, metas| {
                metas[at::MAKER_MINT] = AccountMeta::new_readonly(m.taker_mint.key(), false)
            },
        },
        Fault {
            name: "substituted token program",
            state: no_state,
            quote: no_quote,
            metas: |_, _, metas| {
                metas[at::MAKER_TOKEN_PROGRAM] =
                    AccountMeta::new_readonly(TEST_HOOK_PROGRAM_ID, false)
            },
        },
        Fault {
            name: "duplicate mutable",
            state: no_state,
            quote: no_quote,
            metas: |_, m, metas| metas[at::TAKER_DST] = AccountMeta::new(m.maker.vault_out, false),
        },
        Fault {
            name: "read-only taker_src",
            state: no_state,
            quote: no_quote,
            metas: |_, _, metas| metas[at::TAKER_SRC].is_writable = false,
        },
        Fault {
            name: "fake sysvar",
            state: no_state,
            quote: no_quote,
            metas: |_, _, metas| {
                metas[at::INSTRUCTIONS] = AccountMeta::new_readonly(Pubkey::new_unique(), false)
            },
        },
    ]
}

/// Every single fault and every PAIR of faults yields the same error on both
/// programs — so the two implementations run their checks in the same order,
/// not merely the same checks.
#[test]
fn single_and_double_faults_fail_identically() {
    let faults = faults();
    let mut cases: Vec<Vec<&Fault>> = faults.iter().map(|f| vec![f]).collect();
    for i in 0..faults.len() {
        for j in (i + 1)..faults.len() {
            cases.push(vec![&faults[i], &faults[j]]);
        }
    }
    for case in &cases {
        let names: Vec<&str> = case.iter().map(|f| f.name).collect();
        let a = run_faults(Program::Anchor, case);
        let p = run_faults(Program::Pinocchio, case);
        assert_eq!(a, p, "programs disagree on {names:?}");
    }
}

/// Spot checks of which fault wins, pinned to the expected code.
#[test]
fn account_constraints_are_checked_before_handler_rules() {
    let f = faults();
    let by = |n: &str| f.iter().find(|x| x.name == n).expect("fault");
    let code = |e: InstructionError| match e {
        InstructionError::Custom(c) => c,
        other => panic!("{other:?}"),
    };
    for program in both() {
        // Paused (handler) + wrong account type in the maker slot (account
        // deserialisation): the account check wins.
        let e = run_faults(program, &[by("paused"), by("config in the maker slot")]);
        assert_eq!(code(e), ac::ACCOUNT_DISCRIMINATOR_MISMATCH, "{program:?}");
        // Expired (handler) + wrong mint (constraint): MintMismatch wins.
        let e = run_faults(program, &[by("expired"), by("wrong mint")]);
        assert_eq!(code(e), RfqError::MintMismatch.code(), "{program:?}");
        // Inactive maker + substituted token program: InvalidProgramId.
        let e = run_faults(
            program,
            &[by("inactive maker"), by("substituted token program")],
        );
        assert_eq!(code(e), ac::INVALID_PROGRAM_ID, "{program:?}");
        // Paused + duplicate mutable accounts: the duplicate check wins.
        let e = run_faults(program, &[by("paused"), by("duplicate mutable")]);
        assert_eq!(
            code(e),
            ac::CONSTRAINT_DUPLICATE_MUTABLE_ACCOUNT,
            "{program:?}"
        );
        // Expired + overfill: handler order (expiry first).
        let e = run_faults(program, &[by("expired"), by("overfill")]);
        assert_eq!(code(e), RfqError::QuoteExpired.code(), "{program:?}");
        // Rotated signer + overfill: the signature is checked before the math.
        let e = run_faults(program, &[by("rotated quote signer"), by("overfill")]);
        assert_eq!(code(e), RfqError::SignerMismatch.code(), "{program:?}");
    }
}

/// The remaining economic rejections, same code on both programs.
#[test]
fn economic_rejections_use_identical_error_codes() {
    for (fill, min_out, max_in, expected) in [
        (1_000_001, 0, u64::MAX, RfqError::FillExceedsRemaining),
        (1_000_000, 999_999_999, u64::MAX, RfqError::SlippageMinOut),
        (1_000_000, 0, 1, RfqError::SlippageMaxIn),
        (0, 0, u64::MAX, RfqError::ZeroAmount),
    ] {
        for program in both() {
            let mut env = Env::new(program, 0);
            let (market, quote) = env.standard_market();
            let err = env
                .send_settle(&market, &settle_args(quote, fill, min_out, max_in))
                .expect_err("rejected");
            assert_custom(&err, expected);
        }
    }
}
