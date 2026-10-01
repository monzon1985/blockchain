// SPDX-License-Identifier: MIT
//! Mollusk compute-unit benchmark and equivalence check.
//!
//! Runs the *same* `[ed25519, settle]` transaction, over the *same* shared
//! account fixture, against the Anchor and Pinocchio production `.so` files,
//! and:
//!
//! 1. asserts both succeed and leave an identical state transition: the
//!    tracker is closed (no lamports, no data), the nonce bit is set, every
//!    token balance matches, and the `Settled` event each program actually
//!    logged (`Program data:`, parsed from the captured logs) is the same;
//! 2. pins the README's compute-unit table: each program's CU must be within
//!    ±5% of [`EXPECTED_ANCHOR_CU`] / [`EXPECTED_PINOCCHIO_CU`], and the
//!    zero-copy implementation must be cheaper.
//!
//! The pinned values are specific to the toolchain that produced the `.so`
//! files and the runtime that executes them: platform-tools v1.57 (Agave 4.3
//! `cargo-build-sbf`) and Mollusk 0.15.1 linking the Agave 4.2.2 program
//! runtime. A toolchain bump that moves either number by more than 5% fails
//! here and the table must be re-measured.

use {
    ed25519_dalek::{Signer as _, SigningKey},
    mollusk_svm::Mollusk,
    mollusk_svm_programs_token::token,
    rfq_core::{
        Quote, ed25519, ids,
        layout::{self, SettleArgs, SettledEvent, disc, ix as ixd},
        nonce, seeds,
    },
    solana_account::Account,
    solana_instruction::{AccountMeta, Instruction},
    solana_pubkey::Pubkey,
    solana_svm_log_collector::LogCollector,
    spl_token_interface::state::{Account as TokenAccountState, AccountState, Mint},
    std::path::PathBuf,
};

/// Transaction CU of the Anchor settle fixture (ed25519 verification included).
const EXPECTED_ANCHOR_CU: u64 = 36_037;
/// Transaction CU of the Pinocchio settle fixture (ed25519 verification included).
const EXPECTED_PINOCCHIO_CU: u64 = 21_263;
/// Allowed relative drift of either number, in percent.
const TOLERANCE_PCT: u64 = 5;

const SYSTEM: Pubkey = Pubkey::new_from_array(ids::SYSTEM_PROGRAM);
const FEE_BPS: u16 = 30;
const MAKER_AMOUNT: u64 = 1_000_000;
const TAKER_AMOUNT: u64 = 2_000_000;
const NONCE: u64 = 7;

fn deploy_dir() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../target/deploy");
    p
}

fn read_so(name: &str) -> Vec<u8> {
    let path = deploy_dir().join(name);
    std::fs::read(&path).unwrap_or_else(|e| {
        panic!(
            "missing {}: {e}. Run `cargo build-sbf` first.",
            path.display()
        )
    })
}

fn pda(seeds: &[&[u8]], program: &Pubkey) -> (Pubkey, u8) {
    Pubkey::find_program_address(seeds, program)
}

fn program_owned(program: &Pubkey, disc: [u8; 8], body: &[u8], len: usize) -> Account {
    let mut data = vec![0u8; len];
    data[..8].copy_from_slice(&disc);
    data[8..8 + body.len()].copy_from_slice(body);
    Account {
        lamports: 5_000_000,
        data,
        owner: *program,
        executable: false,
        rent_epoch: 0,
    }
}

fn spl_mint(authority: Pubkey, decimals: u8) -> Account {
    token::create_account_for_mint(Mint {
        mint_authority: Some(authority).into(),
        supply: 0,
        decimals,
        is_initialized: true,
        freeze_authority: None.into(),
    })
}

fn spl_token_account(mint: Pubkey, owner: Pubkey, amount: u64) -> Account {
    token::create_account_for_token_account(TokenAccountState {
        mint,
        owner,
        amount,
        delegate: None.into(),
        state: AccountState::Initialized,
        is_native: None.into(),
        delegated_amount: 0,
        close_authority: None.into(),
    })
}

struct Fixture {
    ed_instruction: Instruction,
    instruction: Instruction,
    accounts: Vec<(Pubkey, Account)>,
    payer: Pubkey,
    keys: Keys,
}

struct Keys {
    quote_fill: Pubkey,
    nonce_page: Pubkey,
    maker_vault_out: Pubkey,
    maker_vault_in: Pubkey,
    taker_dst: Pubkey,
    fee_vault: Pubkey,
}

/// Builds the settle fixture for `program`.
fn build_fixture(program: Pubkey) -> Fixture {
    let signer = SigningKey::from_bytes(&[7u8; 32]);
    let quote_signer = signer.verifying_key().to_bytes();
    let maker_owner = Pubkey::new_from_array([2u8; 32]);
    let taker = Pubkey::new_from_array([9u8; 32]);

    let (config, config_bump) = pda(&[seeds::CONFIG], &program);
    let (maker, maker_bump) = pda(&[seeds::MAKER, maker_owner.as_ref()], &program);
    let (vault_authority, va_bump) = pda(&[seeds::VAULT_AUTHORITY, maker_owner.as_ref()], &program);
    let (nonce_page, np_bump) = pda(
        &[
            seeds::NONCE_PAGE,
            maker_owner.as_ref(),
            &nonce::page_index(NONCE).to_le_bytes(),
        ],
        &program,
    );
    let (quote_fill, _) = pda(
        &[
            seeds::QUOTE_FILL,
            maker_owner.as_ref(),
            &NONCE.to_le_bytes(),
        ],
        &program,
    );

    let maker_mint = Pubkey::new_from_array([20u8; 32]);
    let taker_mint = Pubkey::new_from_array([21u8; 32]);
    let maker_vault_out = Pubkey::new_from_array([30u8; 32]);
    let maker_vault_in = Pubkey::new_from_array([31u8; 32]);
    let taker_src = Pubkey::new_from_array([32u8; 32]);
    let taker_dst = Pubkey::new_from_array([33u8; 32]);
    let fee_vault = Pubkey::new_from_array([34u8; 32]);

    let mut config_body = vec![0u8; layout::config::LEN - 8];
    config_body[..32].copy_from_slice([1u8; 32].as_ref()); // admin (arbitrary)
    let o = layout::config::FEE_BPS - 8;
    config_body[o..o + 2].copy_from_slice(&FEE_BPS.to_le_bytes());
    config_body[layout::config::BUMP - 8] = config_bump;

    let mut maker_body = vec![0u8; layout::maker::LEN - 8];
    maker_body[..32].copy_from_slice(maker_owner.as_ref());
    let o = layout::maker::QUOTE_SIGNER - 8;
    maker_body[o..o + 32].copy_from_slice(&quote_signer);
    maker_body[layout::maker::ACTIVE - 8] = 1;
    maker_body[layout::maker::BUMP - 8] = maker_bump;
    maker_body[layout::maker::VAULT_AUTHORITY_BUMP - 8] = va_bump;

    let mut np_body = vec![0u8; layout::nonce_page::LEN - 8];
    np_body[..32].copy_from_slice(maker_owner.as_ref());
    np_body[layout::nonce_page::BUMP - 8] = np_bump;

    let quote = Quote {
        maker: maker_owner.to_bytes(),
        maker_mint: maker_mint.to_bytes(),
        taker_mint: taker_mint.to_bytes(),
        maker_amount: MAKER_AMOUNT,
        taker_amount: TAKER_AMOUNT,
        nonce: NONCE,
        expiry: i64::MAX,
        taker: [0u8; 32],
    };
    let message = quote.message(&program.to_bytes());
    let sig = signer.sign(&message).to_bytes();
    let mut ed_data = vec![0u8; ed25519::encoded_len(message.len())];
    ed25519::encode_single(&quote_signer, &sig, &message, &mut ed_data).expect("ed encode");

    let ed_instruction = Instruction {
        program_id: Pubkey::new_from_array(ids::ED25519_PROGRAM),
        accounts: vec![],
        data: ed_data,
    };
    let args = SettleArgs {
        quote,
        fill_amount: MAKER_AMOUNT,
        min_out: 0,
        max_in: u64::MAX,
    };
    let data = args.ix_data(ixd::SETTLE).to_vec();

    let metas = vec![
        AccountMeta::new(taker, true),
        AccountMeta::new_readonly(config, false),
        AccountMeta::new_readonly(maker, false),
        AccountMeta::new_readonly(vault_authority, false),
        AccountMeta::new(nonce_page, false),
        AccountMeta::new(quote_fill, false),
        AccountMeta::new_readonly(maker_mint, false),
        AccountMeta::new_readonly(taker_mint, false),
        AccountMeta::new(maker_vault_out, false),
        AccountMeta::new(maker_vault_in, false),
        AccountMeta::new(taker_src, false),
        AccountMeta::new(taker_dst, false),
        AccountMeta::new(fee_vault, false),
        AccountMeta::new_readonly(token::ID, false),
        AccountMeta::new_readonly(token::ID, false),
        AccountMeta::new_readonly(SYSTEM, false),
        AccountMeta::new_readonly(ids::INSTRUCTIONS_SYSVAR.into(), false),
    ];

    let system_account = |lamports| Account {
        lamports,
        data: vec![],
        owner: SYSTEM,
        executable: false,
        rent_epoch: 0,
    };
    let accounts = vec![
        (taker, system_account(1_000_000_000)),
        (
            config,
            program_owned(&program, disc::CONFIG, &config_body, layout::config::LEN),
        ),
        (
            maker,
            program_owned(&program, disc::MAKER, &maker_body, layout::maker::LEN),
        ),
        (vault_authority, system_account(1)),
        (
            nonce_page,
            program_owned(
                &program,
                disc::NONCE_PAGE,
                &np_body,
                layout::nonce_page::LEN,
            ),
        ),
        (quote_fill, system_account(0)),
        (maker_mint, spl_mint(maker_owner, 6)),
        (taker_mint, spl_mint(maker_owner, 6)),
        (
            maker_vault_out,
            spl_token_account(maker_mint, vault_authority, MAKER_AMOUNT),
        ),
        (
            maker_vault_in,
            spl_token_account(taker_mint, vault_authority, 0),
        ),
        (taker_src, spl_token_account(taker_mint, taker, 5_000_000)),
        (taker_dst, spl_token_account(maker_mint, taker, 0)),
        (fee_vault, spl_token_account(maker_mint, config, 0)),
        token::keyed_account(),
        mollusk_svm::program::keyed_account_for_system_program(),
    ];

    Fixture {
        ed_instruction,
        instruction: Instruction {
            program_id: program,
            accounts: metas,
            data,
        },
        accounts,
        payer: taker,
        keys: Keys {
            quote_fill,
            nonce_page,
            maker_vault_out,
            maker_vault_in,
            taker_dst,
            fee_vault,
        },
    }
}

fn token_amount(account: &Account) -> u64 {
    let mut b = [0u8; 8];
    b.copy_from_slice(&account.data[64..72]);
    u64::from_le_bytes(b)
}

/// Minimal base64 decoder for `Program data:` log lines.
fn b64_decode(s: &str) -> Option<Vec<u8>> {
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let (mut acc, mut bits, mut out) = (0u32, 0u32, Vec::new());
    for c in s.trim().trim_end_matches('=').bytes() {
        let v = T.iter().position(|t| *t == c)? as u32;
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

#[derive(Debug)]
struct Outcome {
    /// Transaction CU, ed25519 verification included.
    cu: u64,
    /// CU of the same transaction's ed25519 instruction alone.
    ed25519_cu: u64,
    tracker_closed: bool,
    nonce_used: bool,
    vault_out: u64,
    vault_in: u64,
    taker_dst: u64,
    fee: u64,
    event: SettledEvent,
}

fn run(program: Pubkey, so: &str) -> Outcome {
    let mut mollusk = Mollusk::default();
    mollusk.add_program_with_loader_and_elf(
        &program,
        &mollusk_svm::program::loader_keys::LOADER_V3,
        &read_so(so),
    );
    token::add_program(&mut mollusk);

    let Fixture {
        ed_instruction,
        instruction,
        accounts,
        payer,
        keys,
    } = build_fixture(program);

    let ed_only = mollusk.process_transaction_instructions(
        std::slice::from_ref(&ed_instruction),
        &accounts,
        Some(&payer),
    );
    assert!(ed_only.program_result.is_ok(), "ed25519 alone");

    let logs = LogCollector::new_ref();
    mollusk.logger = Some(logs.clone());
    let result = mollusk.process_transaction_instructions(
        &[ed_instruction, instruction],
        &accounts,
        Some(&payer),
    );
    assert!(
        result.program_result.is_ok(),
        "settle failed for {so}: {:?}\n{:#?}",
        result.program_result,
        result.raw_result
    );
    let event = logs
        .borrow()
        .get_recorded_content()
        .iter()
        .filter_map(|l| l.strip_prefix("Program data: "))
        .filter_map(b64_decode)
        .find_map(|bytes| SettledEvent::decode(&bytes))
        .unwrap_or_else(|| panic!("{so}: no Settled event logged"));

    let get = |k: &Pubkey| result.get_account(k).cloned().unwrap_or_default();
    let tracker = get(&keys.quote_fill);
    let np = get(&keys.nonce_page);
    let mut bits = [0u8; 32];
    bits.copy_from_slice(&np.data[layout::nonce_page::BITS..layout::nonce_page::BITS + 32]);

    Outcome {
        cu: result.compute_units_consumed,
        ed25519_cu: ed_only.compute_units_consumed,
        tracker_closed: tracker.lamports == 0 && tracker.data.is_empty(),
        nonce_used: nonce::is_used(&bits, NONCE),
        vault_out: token_amount(&get(&keys.maker_vault_out)),
        vault_in: token_amount(&get(&keys.maker_vault_in)),
        taker_dst: token_amount(&get(&keys.taker_dst)),
        fee: token_amount(&get(&keys.fee_vault)),
        event,
    }
}

fn within_tolerance(measured: u64, expected: u64) -> bool {
    measured.abs_diff(expected) * 100 <= expected * TOLERANCE_PCT
}

#[test]
fn anchor_and_pinocchio_settle_are_equivalent_and_the_cu_table_holds() {
    let anchor = run(Pubkey::new_from_array(ids::RFQ_PROGRAM), "rfq.so");
    let pinocchio = run(
        Pubkey::new_from_array(ids::RFQ_PINOCCHIO_PROGRAM),
        "rfq_pinocchio.so",
    );

    // Behavioural equivalence: identical state transition, asserted on each
    // program's own resulting accounts and logs.
    for o in [&anchor, &pinocchio] {
        assert!(
            o.tracker_closed,
            "a one-shot fill closes its tracker: {o:?}"
        );
        assert!(
            o.nonce_used,
            "the completing fill sets the nonce bit: {o:?}"
        );
        assert_eq!(o.vault_out, 0);
        assert_eq!(o.vault_in, TAKER_AMOUNT);
        assert_eq!(o.fee, 3_000);
        assert_eq!(o.taker_dst, MAKER_AMOUNT - 3_000);
    }
    assert_eq!(anchor.event, pinocchio.event, "logged Settled events");
    assert_eq!(
        anchor.event,
        SettledEvent {
            maker: [2u8; 32],
            taker: [9u8; 32],
            nonce: NONCE,
            fill_amount: MAKER_AMOUNT,
            taker_gross_in: TAKER_AMOUNT,
            maker_net_in: TAKER_AMOUNT,
            taker_net_out: MAKER_AMOUNT - 3_000,
            protocol_fee: 3_000,
            filled_total: MAKER_AMOUNT,
        }
    );
    assert_eq!(anchor.ed25519_cu, pinocchio.ed25519_cu);

    let saved = anchor.cu.saturating_sub(pinocchio.cu);
    let pct = 100.0 * saved as f64 / anchor.cu as f64;
    println!("\n=== settle compute units (Mollusk 0.15.1 / Agave 4.2.2 runtime) ===");
    println!("  ed25519 verification alone : {:>6} CU", anchor.ed25519_cu);
    println!(
        "  Anchor    : {:>6} CU  (settle instruction ~{} CU)",
        anchor.cu,
        anchor.cu - anchor.ed25519_cu
    );
    println!(
        "  Pinocchio : {:>6} CU  (settle instruction ~{} CU)",
        pinocchio.cu,
        pinocchio.cu - pinocchio.ed25519_cu
    );
    println!("  saved     : {saved} CU ({pct:.1} %)\n");
    let _ = std::fs::write(
        deploy_dir().join("../cu_report.txt"),
        format!(
            "anchor={} pinocchio={} ed25519={} saved={} pct={:.1}\n",
            anchor.cu, pinocchio.cu, anchor.ed25519_cu, saved, pct
        ),
    );

    // The pinned table.
    assert!(
        within_tolerance(anchor.cu, EXPECTED_ANCHOR_CU),
        "Anchor settle: {} CU, README pins {EXPECTED_ANCHOR_CU} ±{TOLERANCE_PCT}%",
        anchor.cu
    );
    assert!(
        within_tolerance(pinocchio.cu, EXPECTED_PINOCCHIO_CU),
        "Pinocchio settle: {} CU, README pins {EXPECTED_PINOCCHIO_CU} ±{TOLERANCE_PCT}%",
        pinocchio.cu
    );
    assert!(
        pinocchio.cu < anchor.cu,
        "the zero-copy settle must be cheaper ({} vs {})",
        pinocchio.cu,
        anchor.cu
    );
}

#[test]
fn tolerance_band_is_five_percent() {
    assert!(within_tolerance(105, 100));
    assert!(within_tolerance(95, 100));
    assert!(!within_tolerance(106, 100));
    assert!(!within_tolerance(94, 100));
}
