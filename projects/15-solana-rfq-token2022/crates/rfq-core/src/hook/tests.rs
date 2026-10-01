// SPDX-License-Identifier: MIT
//! Differential tests: `resolve_transfer_hook_accounts` vs the canonical
//! `spl_transfer_hook_interface::onchain::add_extra_accounts_for_execute_cpi`.

use {
    super::*,
    proptest::prelude::*,
    solana_account_info::AccountInfo,
    solana_instruction::{AccountMeta, Instruction},
    solana_program_error::ProgramError,
    solana_pubkey::Pubkey as SdkPubkey,
    spl_discriminator::SplDiscriminate,
    spl_tlv_account_resolution::{
        account::ExtraAccountMeta, error::AccountResolutionError, pubkey_data::PubkeyData,
        seeds::Seed, state::ExtraAccountMetaList as SplList,
    },
    spl_transfer_hook_interface::{error::TransferHookError, instruction::ExecuteInstruction},
    std::{
        cell::RefCell,
        panic::{AssertUnwindSafe, catch_unwind},
        vec,
        vec::Vec,
    },
};

fn pda(seeds: &[&[u8]], program: &Pubkey) -> Pubkey {
    SdkPubkey::find_program_address(seeds, &SdkPubkey::new_from_array(*program))
        .0
        .to_bytes()
}

/// Deterministic account data for a key (so account-data seeds resolve).
fn synthetic(key: &Pubkey) -> Vec<u8> {
    let mut d = Vec::with_capacity(72);
    d.extend_from_slice(key);
    d.extend_from_slice(&key[..16]);
    d.extend_from_slice(key);
    d
}

struct Env<'a> {
    base: [&'a [u8]; 4],
    additional: &'a [(Pubkey, Vec<u8>)],
    missing: RefCell<Option<Pubkey>>,
}

impl<'a> Env<'a> {
    fn new(base: &'a [Vec<u8>; 4], additional: &'a [(Pubkey, Vec<u8>)]) -> Self {
        Self {
            base: [
                base[0].as_slice(),
                base[1].as_slice(),
                base[2].as_slice(),
                base[3].as_slice(),
            ],
            additional,
            missing: RefCell::new(None),
        }
    }
}

impl<'a> HookEnv<'a> for Env<'a> {
    fn base_data(&self, index: usize) -> Option<&'a [u8]> {
        self.base.get(index).copied()
    }
    fn find_additional(&self, key: &Pubkey) -> Option<&'a [u8]> {
        let found = self
            .additional
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, d)| d.as_slice());
        if found.is_none() {
            *self.missing.borrow_mut() = Some(*key);
        }
        found
    }
    fn find_pda(&self, seeds: &[&[u8]], program_id: &Pubkey) -> Pubkey {
        pda(seeds, program_id)
    }
}

/// Finds every extra account resolution asks for by repeatedly supplying the
/// account reported missing.
fn discover(
    hook: &Pubkey,
    keys: &[Pubkey; 4],
    base: &[Vec<u8>; 4],
    vdata: &[u8],
    amount: u64,
) -> Vec<Pubkey> {
    let validation = pda(&[EXTRA_ACCOUNT_METAS_SEED, &keys[1]], hook);
    let mut provided: Vec<(Pubkey, Vec<u8>)> =
        vec![(*hook, synthetic(hook)), (validation, vdata.to_vec())];
    for _ in 0..MAX_EXTRA_METAS + 2 {
        let (result, missing) = {
            let env = Env::new(base, &provided);
            let r = resolve_transfer_hook_accounts(
                hook, &keys[0], &keys[1], &keys[2], &keys[3], amount, &env,
            );
            (r, env.missing.take())
        };
        match (result, missing) {
            (Err(HookError::Custom(codes::RESOLUTION_INCORRECT_ACCOUNT)), Some(k))
                if !provided.iter().any(|(p, _)| *p == k) =>
            {
                provided.push((k, synthetic(&k)));
            }
            _ => break,
        }
    }
    provided.into_iter().skip(2).map(|(k, _)| k).collect()
}

fn to_program_error(e: HookError) -> ProgramError {
    match e {
        HookError::InvalidAccountData => ProgramError::InvalidAccountData,
        HookError::InvalidArgument => ProgramError::InvalidArgument,
        HookError::Custom(c) => ProgramError::Custom(c),
        HookError::TooManyMetas => ProgramError::Custom(u32::MAX),
    }
}

/// Runs the canonical helper and returns the metas it appended.
#[allow(clippy::too_many_arguments)]
fn canonical(
    hook: &Pubkey,
    keys: [Pubkey; 4],
    base: [Vec<u8>; 4],
    additional: &[(Pubkey, Vec<u8>)],
    amount: u64,
) -> Result<Vec<AccountMeta>, ProgramError> {
    let owner = SdkPubkey::new_from_array([0xAA; 32]);
    let hook = SdkPubkey::new_from_array(*hook);
    let base_keys: Vec<SdkPubkey> = keys.iter().map(|k| SdkPubkey::new_from_array(*k)).collect();
    let mut base_lamports = [0u64; 4];
    let mut base_data = base;
    let add_keys: Vec<SdkPubkey> = additional
        .iter()
        .map(|(k, _)| SdkPubkey::new_from_array(*k))
        .collect();
    let mut add_lamports = vec![0u64; additional.len()];
    let mut add_data: Vec<Vec<u8>> = additional.iter().map(|(_, d)| d.clone()).collect();

    let mut base_infos: Vec<AccountInfo> = Vec::new();
    for ((k, l), d) in base_keys
        .iter()
        .zip(base_lamports.iter_mut())
        .zip(base_data.iter_mut())
    {
        base_infos.push(AccountInfo::new(
            k,
            false,
            true,
            l,
            d.as_mut_slice(),
            &owner,
            false,
        ));
    }
    let mut add_infos: Vec<AccountInfo> = Vec::new();
    for ((k, l), d) in add_keys
        .iter()
        .zip(add_lamports.iter_mut())
        .zip(add_data.iter_mut())
    {
        add_infos.push(AccountInfo::new(
            k,
            false,
            true,
            l,
            d.as_mut_slice(),
            &owner,
            false,
        ));
    }

    let mut ix = Instruction {
        program_id: SdkPubkey::new_from_array(crate::ids::TOKEN_2022_PROGRAM),
        accounts: vec![
            AccountMeta::new(base_keys[0], false),
            AccountMeta::new_readonly(base_keys[1], false),
            AccountMeta::new(base_keys[2], false),
            AccountMeta::new_readonly(base_keys[3], true),
        ],
        data: vec![],
    };
    let mut infos = base_infos.clone();
    spl_transfer_hook_interface::onchain::add_extra_accounts_for_execute_cpi(
        &mut ix,
        &mut infos,
        &hook,
        base_infos[0].clone(),
        base_infos[1].clone(),
        base_infos[2].clone(),
        base_infos[3].clone(),
        amount,
        &add_infos,
    )?;
    Ok(ix.accounts[4..].to_vec())
}

#[derive(Clone, Debug)]
enum MetaGen {
    Literal([u8; 32], bool),
    Seeds(Vec<SeedGen>, bool),
    External(u8, Vec<SeedGen>, bool),
    KeyData(u8, u8, u8, bool),
    Raw(u8, [u8; 32], bool),
}

#[derive(Clone, Debug)]
enum SeedGen {
    Lit(Vec<u8>),
    Ix(u8, u8),
    Key(u8),
    Data(u8, u8, u8),
}

fn seed_gen() -> impl Strategy<Value = SeedGen> {
    prop_oneof![
        proptest::collection::vec(any::<u8>(), 0..8).prop_map(SeedGen::Lit),
        (0u8..18, 0u8..=16).prop_map(|(i, l)| SeedGen::Ix(i, l)),
        (0u8..9).prop_map(SeedGen::Key),
        (0u8..9, 0u8..80, 0u8..=32).prop_map(|(a, d, l)| SeedGen::Data(a, d, l)),
    ]
}

fn meta_gen() -> impl Strategy<Value = MetaGen> {
    prop_oneof![
        3 => (any::<[u8; 32]>(), any::<bool>()).prop_map(|(k, w)| MetaGen::Literal(k, w)),
        4 => (proptest::collection::vec(seed_gen(), 0..4), any::<bool>()).prop_map(|(s, w)| MetaGen::Seeds(s, w)),
        2 => (0u8..9, proptest::collection::vec(seed_gen(), 0..3), any::<bool>()).prop_map(|(p, s, w)| MetaGen::External(p, s, w)),
        2 => (0u8..4, 0u8..9, 0u8..60, any::<bool>()).prop_map(|(k, a, d, w)| MetaGen::KeyData(k, a, d, w)),
        1 => (any::<u8>(), any::<[u8; 32]>(), any::<bool>()).prop_map(|(d, c, w)| MetaGen::Raw(d, c, w)),
    ]
}

fn to_seed(s: &SeedGen) -> Seed {
    match s {
        SeedGen::Lit(b) => Seed::Literal { bytes: b.clone() },
        SeedGen::Ix(index, length) => Seed::InstructionData {
            index: *index,
            length: *length,
        },
        SeedGen::Key(index) => Seed::AccountKey { index: *index },
        SeedGen::Data(a, d, l) => Seed::AccountData {
            account_index: *a,
            data_index: *d,
            length: *l,
        },
    }
}

fn to_meta(m: &MetaGen) -> Option<ExtraAccountMeta> {
    let seeds = |v: &Vec<SeedGen>| v.iter().map(to_seed).collect::<Vec<_>>();
    match m {
        MetaGen::Literal(k, w) => {
            ExtraAccountMeta::new_with_pubkey(&SdkPubkey::new_from_array(*k), false, *w).ok()
        }
        MetaGen::Seeds(s, w) => ExtraAccountMeta::new_with_seeds(&seeds(s), false, *w).ok(),
        MetaGen::External(p, s, w) => {
            ExtraAccountMeta::new_external_pda_with_seeds(*p, &seeds(s), false, *w).ok()
        }
        MetaGen::KeyData(kind, a, d, w) => {
            let data = match kind {
                0 => PubkeyData::InstructionData { index: *d % 20 },
                _ => PubkeyData::AccountData {
                    account_index: *a,
                    data_index: *d,
                },
            };
            ExtraAccountMeta::new_with_pubkey_data(&data, false, *w).ok()
        }
        MetaGen::Raw(d, c, w) => Some(ExtraAccountMeta {
            discriminator: *d,
            address_config: *c,
            is_signer: false.into(),
            is_writable: (*w).into(),
        }),
    }
}

fn validation_data(metas: &[ExtraAccountMeta]) -> Vec<u8> {
    let mut data = vec![0u8; SplList::size_of(metas.len()).expect("size")];
    SplList::init::<ExecuteInstruction>(&mut data, metas).expect("init");
    data
}

/// Runs both implementations on one scenario and asserts equal outcomes.
#[allow(clippy::too_many_arguments)]
fn check_equivalent(
    hook: Pubkey,
    keys: [Pubkey; 4],
    base: [Vec<u8>; 4],
    vdata: Vec<u8>,
    amount: u64,
    include_hook: bool,
    include_validation: bool,
    drop_index: Option<usize>,
    distractors: Vec<Pubkey>,
) -> Result<Outcome, TestCaseError> {
    let mint = keys[1];
    let validation = pda(&[EXTRA_ACCOUNT_METAS_SEED, &mint], &hook);

    // Seeds longer than 32 bytes make `find_program_address` abort (panic on
    // the host, `ProgramFailedToComplete` on-chain) in *both* implementations;
    // such cases are compared as "both abort".
    let requested = catch_unwind(AssertUnwindSafe(|| {
        discover(&hook, &keys, &base, &vdata, amount)
    }))
    .unwrap_or_default();

    let mut additional: Vec<(Pubkey, Vec<u8>)> = Vec::new();
    if include_hook {
        additional.push((hook, synthetic(&hook)));
    }
    if include_validation {
        additional.push((validation, vdata.clone()));
    }
    for (i, k) in requested.iter().enumerate() {
        if Some(i) == drop_index.map(|d| d % requested.len().max(1)) {
            continue;
        }
        if !additional.iter().any(|(a, _)| a == k) {
            additional.push((*k, synthetic(k)));
        }
    }
    for d in distractors {
        additional.push((d, synthetic(&d)));
    }

    let ours = catch_unwind(AssertUnwindSafe(|| {
        let env = Env::new(&base, &additional);
        resolve_transfer_hook_accounts(&hook, &keys[0], &keys[1], &keys[2], &keys[3], amount, &env)
    }));
    let theirs = catch_unwind(AssertUnwindSafe(|| {
        canonical(&hook, keys, base.clone(), &additional, amount)
    }));
    let (ours, theirs) = match (ours, theirs) {
        (Ok(o), Ok(t)) => (o, t),
        (Err(_), Err(_)) => return Ok(Outcome::Aborted),
        (o, t) => {
            prop_assert!(
                false,
                "abort divergence: ours_ok={} canonical_ok={}",
                o.is_ok(),
                t.is_ok()
            );
            unreachable!()
        }
    };

    let outcome = match (&ours, &theirs) {
        (Ok(_), Ok(_)) => Outcome::Resolved,
        _ => Outcome::Rejected,
    };
    match (ours, theirs) {
        (Ok(ours), Ok(theirs)) => {
            prop_assert_eq!(ours.as_slice().len(), theirs.len());
            for (o, t) in ours.as_slice().iter().zip(theirs.iter()) {
                prop_assert_eq!(o.pubkey, t.pubkey.to_bytes());
                prop_assert_eq!(o.is_signer, t.is_signer);
                prop_assert_eq!(o.is_writable, t.is_writable);
            }
        }
        (Err(e), Err(t)) => prop_assert_eq!(to_program_error(e), t),
        (o, t) => prop_assert!(false, "divergence: ours={o:?} canonical={t:?}"),
    }
    Ok(outcome)
}

/// What a differential case exercised.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Outcome {
    Resolved,
    Rejected,
    Aborted,
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 768, ..ProptestConfig::default() })]

    /// Corrupted validation-account data yields the same error (or success).
    #[test]
    fn corrupted_validation_data_matches_canonical(
        hook in any::<[u8; 32]>(),
        keys in any::<[[u8; 32]; 4]>(),
        metas in proptest::collection::vec(meta_gen(), 0..4),
        flips in proptest::collection::vec((any::<usize>(), any::<u8>()), 1..4),
        truncate in proptest::option::of(any::<usize>()),
        extend in 0usize..20,
    ) {
        let metas: Vec<ExtraAccountMeta> = metas.iter().filter_map(to_meta).collect();
        let mut vdata = validation_data(&metas);
        for (i, v) in flips {
            let n = vdata.len();
            vdata[i % n] = v;
        }
        if let Some(t) = truncate {
            let n = vdata.len();
            vdata.truncate(t % (n + 1));
        }
        vdata.extend(std::iter::repeat_n(0u8, extend));
        let base = [vec![1u8; 165], vec![2u8; 82], vec![3u8; 165], vec![]];
        check_equivalent(hook, keys, base, vdata, 7, true, true, None, vec![])?;
    }
}

/// Main differential fuzz: random meta lists (literal keys, PDAs from every
/// seed kind, pubkey-data, external PDAs, raw garbage), random base-account
/// data, and randomly incomplete account sets. The runner also asserts its own
/// coverage so a generator regression cannot silently turn it into a no-op.
#[test]
fn resolution_matches_canonical() {
    use proptest::test_runner::{Config, TestRunner};
    let strategy = (
        (any::<[u8; 32]>(), any::<[[u8; 32]; 4]>(), any::<u64>()),
        (
            proptest::collection::vec(any::<u8>(), 0..170),
            proptest::collection::vec(any::<u8>(), 0..90),
            proptest::collection::vec(any::<u8>(), 0..170),
            proptest::collection::vec(any::<u8>(), 0..8),
        ),
        proptest::collection::vec(meta_gen(), 0..7),
        (
            prop::bool::weighted(0.92),
            prop::bool::weighted(0.92),
            proptest::option::weighted(0.25, any::<usize>()),
            proptest::collection::vec(any::<[u8; 32]>(), 0..3),
        ),
    );
    let counts = RefCell::new([0usize; 3]);
    let mut runner = TestRunner::new(Config {
        cases: 1024,
        ..Config::default()
    });
    runner
        .run(
            &strategy,
            |((hook, keys, amount), (src, mint, dst, auth), metas, (ih, iv, drop, distractors))| {
                let metas: Vec<ExtraAccountMeta> = metas.iter().filter_map(to_meta).collect();
                let vdata = validation_data(&metas);
                let o = check_equivalent(
                    hook,
                    keys,
                    [src, mint, dst, auth],
                    vdata,
                    amount,
                    ih,
                    iv,
                    drop,
                    distractors,
                )?;
                counts.borrow_mut()[o as usize] += 1;
                Ok(())
            },
        )
        .expect("resolution diverged from the canonical implementation");
    let [resolved, rejected, aborted] = *counts.borrow();
    std::eprintln!(
        "hook differential: {resolved} resolved, {rejected} rejected, {aborted} aborted"
    );
    assert!(
        resolved >= 150,
        "too few successful resolutions exercised: {resolved}"
    );
    assert!(rejected >= 150, "too few rejections exercised: {rejected}");
}

#[test]
fn constants_match_canonical() {
    assert_eq!(
        EXECUTE_DISCRIMINATOR,
        <ExecuteInstruction as SplDiscriminate>::SPL_DISCRIMINATOR_SLICE
    );
    assert_eq!(
        codes::HOOK_INCORRECT_ACCOUNT,
        TransferHookError::IncorrectAccount as u32
    );
    assert_eq!(
        codes::RESOLUTION_INCORRECT_ACCOUNT,
        AccountResolutionError::IncorrectAccount as u32
    );
    assert_eq!(
        codes::INVALID_BYTES_FOR_SEED,
        AccountResolutionError::InvalidBytesForSeed as u32
    );
    assert_eq!(
        codes::INSTRUCTION_DATA_TOO_SMALL,
        AccountResolutionError::InstructionDataTooSmall as u32
    );
    assert_eq!(
        codes::ACCOUNT_NOT_FOUND,
        AccountResolutionError::AccountNotFound as u32
    );
    assert_eq!(
        codes::ACCOUNT_DATA_NOT_FOUND,
        AccountResolutionError::AccountDataNotFound as u32
    );
    assert_eq!(
        codes::ACCOUNT_DATA_TOO_SMALL,
        AccountResolutionError::AccountDataTooSmall as u32
    );
    assert_eq!(
        ProgramError::Custom(codes::TLV_TYPE_NOT_FOUND),
        ProgramError::from(spl_type_length_value::error::TlvError::TypeNotFound)
    );
    assert_eq!(
        core::mem::size_of::<ExtraAccountMeta>(),
        EXTRA_ACCOUNT_META_LEN
    );
}

/// The configuration the in-repo allowlist hook actually uses: an allow-list
/// PDA derived from the destination owner, plus a writable counter PDA.
#[test]
fn allowlist_hook_configuration() {
    let hook = crate::ids::TEST_HOOK_PROGRAM;
    let metas = [
        ExtraAccountMeta::new_with_seeds(
            &[
                Seed::Literal {
                    bytes: b"allow".to_vec(),
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
        )
        .expect("meta"),
        ExtraAccountMeta::new_with_seeds(
            &[
                Seed::Literal {
                    bytes: b"counter".to_vec(),
                },
                Seed::AccountKey { index: 1 },
            ],
            false,
            true,
        )
        .expect("meta"),
    ];
    let vdata = validation_data(&metas);
    let keys = [[1u8; 32], [2u8; 32], [3u8; 32], [4u8; 32]];
    let mut dst = vec![0u8; 165];
    dst[32..64].copy_from_slice(&[9u8; 32]);
    let base = [vec![0u8; 165], vec![0u8; 82], dst, vec![]];
    let allow = pda(&[b"allow", &keys[1], &[9u8; 32]], &hook);
    let counter = pda(&[b"counter", &keys[1]], &hook);
    let validation = pda(&[EXTRA_ACCOUNT_METAS_SEED, &keys[1]], &hook);
    let additional = vec![
        (hook, vec![]),
        (validation, vdata.clone()),
        (allow, vec![1]),
        (counter, vec![0; 8]),
    ];
    let env = Env::new(&base, &additional);
    let got =
        resolve_transfer_hook_accounts(&hook, &keys[0], &keys[1], &keys[2], &keys[3], 5, &env)
            .expect("resolves");
    let expect = [
        ResolvedMeta {
            pubkey: allow,
            is_signer: false,
            is_writable: false,
        },
        ResolvedMeta {
            pubkey: counter,
            is_signer: false,
            is_writable: true,
        },
        ResolvedMeta {
            pubkey: validation,
            is_signer: false,
            is_writable: false,
        },
        ResolvedMeta {
            pubkey: hook,
            is_signer: false,
            is_writable: false,
        },
    ];
    assert_eq!(got.as_slice(), &expect);
    let canon = canonical(&hook, keys, base.clone(), &additional, 5).expect("canonical resolves");
    assert_eq!(canon.len(), 4);

    // Missing counter -> AccountResolutionError::IncorrectAccount, like the canonical path.
    let missing: Vec<_> = additional
        .iter()
        .filter(|(k, _)| *k != counter)
        .cloned()
        .collect();
    let env = Env::new(&base, &missing);
    assert_eq!(
        resolve_transfer_hook_accounts(&hook, &keys[0], &keys[1], &keys[2], &keys[3], 5, &env),
        Err(HookError::Custom(codes::RESOLUTION_INCORRECT_ACCOUNT))
    );
    assert_eq!(
        canonical(&hook, keys, base.clone(), &missing, 5),
        Err(ProgramError::Custom(codes::RESOLUTION_INCORRECT_ACCOUNT))
    );

    // Missing hook program -> TransferHookError::IncorrectAccount.
    let no_hook: Vec<_> = additional
        .iter()
        .filter(|(k, _)| *k != hook)
        .cloned()
        .collect();
    let env = Env::new(&base, &no_hook);
    assert_eq!(
        resolve_transfer_hook_accounts(&hook, &keys[0], &keys[1], &keys[2], &keys[3], 5, &env),
        Err(HookError::Custom(codes::HOOK_INCORRECT_ACCOUNT))
    );

    // Parsed list inspection helper.
    let list = ExtraMetaList::parse(&vdata).expect("parses");
    assert_eq!(list.len(), 2);
    assert!(!list.is_empty());
    assert_eq!(meta_at(&list, 1).map(|m| m.3), Some(true));
    assert_eq!(meta_at(&list, 2), None);
}

#[test]
fn execute_data_layout() {
    let d = execute_ix_data(0x0102_0304_0506_0708);
    assert_eq!(&d[..8], &EXECUTE_DISCRIMINATOR);
    assert_eq!(&d[8..], &0x0102_0304_0506_0708u64.to_le_bytes());
}
