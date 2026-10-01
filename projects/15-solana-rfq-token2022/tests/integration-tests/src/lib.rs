// SPDX-License-Identifier: MIT
//! Shared LiteSVM harness for the RFQ integration tests.
//!
//! Loads the SBF artefacts built by `cargo build-sbf` (production builds from
//! `target/deploy`, `naive-v1` exploit builds from `target/deploy/naive`),
//! exposes helpers to create SPL Token / Token-2022 mints (plain, transfer-fee
//! and transfer-hook) and token accounts, and wraps both RFQ programs with
//! maker / taker fixtures so that every settle-path test runs against the
//! Anchor *and* the Pinocchio program.
//!
//! Every transaction the harness sends must fit the 1232-byte packet limit
//! (LiteSVM does not enforce it, a real cluster does): [`Env::send`] asserts
//! it for legacy transactions and [`Env::send_auto`] falls back to a v0
//! transaction over a freshly built address lookup table when a legacy one
//! would not fit.

#![allow(clippy::arithmetic_side_effects)]
// Test harness: panicking with context (`expect`) is the intended failure mode,
// and `FailedTransactionMetadata` is LiteSVM's own (large) error type, which
// the tests inspect field by field.
#![allow(clippy::expect_used, clippy::result_large_err)]

use {
    litesvm::{LiteSVM, types::TransactionMetadata},
    rfq_client::{
        RFQ_NAIVE_PROGRAM_ID, RFQ_PINOCCHIO_NAIVE_PROGRAM_ID, RFQ_PINOCCHIO_PROGRAM_ID,
        RFQ_PROGRAM_ID, TEST_HOOK_PROGRAM_ID, TOKEN_2022_PROGRAM_ID, TOKEN_PROGRAM_ID,
        hooks::AccountFetcher, ix, pda, sign, tx,
    },
    rfq_core::{Quote, RfqError, layout::SettleArgs as CoreArgs},
    solana_address::Address as Pubkey,
    solana_instruction::{AccountMeta, Instruction},
    solana_keypair::Keypair,
    solana_message::AddressLookupTableAccount,
    solana_program_pack::Pack,
    solana_signer::Signer,
    solana_transaction::{Transaction, versioned::VersionedTransaction},
    spl_token_2022_interface::{
        extension::ExtensionType,
        instruction as t22,
        state::{Account as TokenAccountState, Mint},
    },
    std::path::PathBuf,
};

pub use {
    litesvm::types::FailedTransactionMetadata, rfq_client::tx::PACKET_DATA_SIZE,
    solana_instruction_error::InstructionError, solana_transaction_error::TransactionError,
};

// ---------------------------------------------------------------------------
// Logs and errors
// ---------------------------------------------------------------------------

/// Parses the `Settled` event from `Program data:` logs.
pub fn settled_event(logs: &[String]) -> rfq_core::layout::SettledEvent {
    logs.iter()
        .filter_map(|line| line.strip_prefix("Program data: "))
        .filter_map(|b64| b64_decode(b64.trim()))
        .find_map(|bytes| rfq_core::layout::SettledEvent::decode(&bytes))
        .unwrap_or_else(|| panic!("no Settled event in logs: {logs:#?}"))
}

/// Minimal standard base64 decoder (no extra dependency for one log format);
/// `None` on a character outside the alphabet.
pub fn b64_decode(s: &str) -> Option<Vec<u8>> {
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut rev = [255u8; 256];
    for (i, c) in T.iter().enumerate() {
        rev[*c as usize] = i as u8;
    }
    let s = s.trim_end_matches('=').as_bytes();
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0u32);
    for &c in s {
        let v = rev[c as usize];
        if v == 255 {
            return None;
        }
        acc = (acc << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

/// The instruction error of a failed transaction (panics on other failures).
pub fn instruction_error(err: &FailedTransactionMetadata) -> InstructionError {
    match &err.err {
        TransactionError::InstructionError(_, ie) => ie.clone(),
        other => panic!(
            "expected an instruction error, got {other:?}\nlogs: {:#?}",
            err.meta.logs
        ),
    }
}

/// The custom error code of a failed transaction, if any.
pub fn custom_code_of(err: &FailedTransactionMetadata) -> Option<u32> {
    match &err.err {
        TransactionError::InstructionError(_, InstructionError::Custom(c)) => Some(*c),
        _ => None,
    }
}

/// Asserts a failed transaction's error is `Custom(code)`.
pub fn assert_code(err: &FailedTransactionMetadata, code: u32) {
    assert_eq!(
        custom_code_of(err),
        Some(code),
        "expected Custom({code}), got {:?}\nlogs: {:#?}",
        err.err,
        err.meta.logs
    );
}

/// Asserts a failed transaction's error is `ProgramError::Custom(expected.code())`.
pub fn assert_custom(err: &FailedTransactionMetadata, expected: RfqError) {
    assert_code(err, expected.code());
}

/// Asserts a failed transaction's instruction error equals `expected`.
pub fn assert_ix_error(err: &FailedTransactionMetadata, expected: InstructionError) {
    assert_eq!(
        instruction_error(err),
        expected,
        "logs: {:#?}",
        err.meta.logs
    );
}

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

/// Which program the harness drives.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Program {
    /// The idiomatic Anchor program (`rfq.so`).
    Anchor,
    /// The zero-copy Pinocchio program (`rfq_pinocchio.so`).
    Pinocchio,
}

/// Both programs, for parameterised tests.
pub fn both() -> [Program; 2] {
    [Program::Anchor, Program::Pinocchio]
}

/// Which artefact of a program is loaded.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Build {
    /// The default build (`target/deploy`): no `settle_naive_v1`.
    Production,
    /// The `naive-v1` exploit build (`target/deploy/naive`), at its own id.
    NaiveV1,
}

impl Program {
    /// The program id of `build`.
    pub fn id(self, build: Build) -> Pubkey {
        match (self, build) {
            (Program::Anchor, Build::Production) => RFQ_PROGRAM_ID,
            (Program::Anchor, Build::NaiveV1) => RFQ_NAIVE_PROGRAM_ID,
            (Program::Pinocchio, Build::Production) => RFQ_PINOCCHIO_PROGRAM_ID,
            (Program::Pinocchio, Build::NaiveV1) => RFQ_PINOCCHIO_NAIVE_PROGRAM_ID,
        }
    }

    /// The `.so` of `build`, relative to `target/deploy`.
    pub fn artefact(self, build: Build) -> &'static str {
        match (self, build) {
            (Program::Anchor, Build::Production) => "rfq.so",
            (Program::Anchor, Build::NaiveV1) => "naive/rfq.so",
            (Program::Pinocchio, Build::Production) => "rfq_pinocchio.so",
            (Program::Pinocchio, Build::NaiveV1) => "naive/rfq_pinocchio.so",
        }
    }
}

/// Directory of the SBF artefacts (`<crate>/../../target/deploy`).
fn deploy_dir() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../target/deploy");
    p
}

/// Reads an SBF artefact from `target/deploy`.
pub fn read_so(name: &str) -> Vec<u8> {
    let path = deploy_dir().join(name);
    std::fs::read(&path).unwrap_or_else(|e| {
        panic!(
            "missing {}: {e}. Build the programs first (see the README: \
             `cargo build-sbf` for the production and the `naive-v1` builds).",
            path.display()
        )
    })
}

/// A running RFQ test environment.
pub struct Env {
    /// The virtual machine.
    pub svm: LiteSVM,
    /// The RFQ program id under test.
    pub program: Pubkey,
    /// Which program is loaded.
    pub which: Program,
    /// Which build of it.
    pub build: Build,
    /// The admin keypair (also the program's upgrade authority).
    pub admin: Keypair,
    /// Fee vaults created for the settle-only Pinocchio program, by mint.
    fee_vaults: std::collections::HashMap<Pubkey, Pubkey>,
}

const LAMPORTS: u64 = 1_000_000_000;

impl Env {
    /// Boots the production build of `which` with its config initialised.
    pub fn new(which: Program, fee_bps: u16) -> Self {
        Self::with_build(which, Build::Production, fee_bps)
    }

    /// Boots the `naive-v1` exploit build of `which` with its config initialised.
    pub fn new_naive(which: Program, fee_bps: u16) -> Self {
        Self::with_build(which, Build::NaiveV1, fee_bps)
    }

    /// Boots `build` of `which` and initialises the config with `fee_bps`
    /// (`initialize_config` for Anchor; seeded bytes for the settle-only
    /// Pinocchio program).
    pub fn with_build(which: Program, build: Build, fee_bps: u16) -> Self {
        let mut env = Self::deploy(which, build);
        match which {
            Program::Anchor => {
                let admin = env.admin.insecure_clone();
                env.send(
                    &[ix::initialize_config(
                        &env.program,
                        &admin.pubkey(),
                        fee_bps,
                    )],
                    &[&admin],
                )
                .expect("initialize_config");
            }
            Program::Pinocchio => env.seed_config(fee_bps),
        }
        env
    }

    /// Boots a VM with `build` of `which` deployed (upgradeable, with
    /// [`Env::admin`] as upgrade authority), the test hook and both token
    /// programs — but no config yet.
    pub fn deploy(which: Program, build: Build) -> Self {
        let program = which.id(build);
        Self::deploy_at(which, build, program)
    }

    /// Like [`Env::deploy`] but at an arbitrary address (used to show a build
    /// refuses to run anywhere but its declared id).
    pub fn deploy_at(which: Program, build: Build, program: Pubkey) -> Self {
        let mut svm = LiteSVM::new();
        let admin = Keypair::new();
        svm.airdrop(&admin.pubkey(), 100 * LAMPORTS)
            .expect("airdrop");
        deploy_upgradeable(
            &mut svm,
            &program,
            &read_so(which.artefact(build)),
            &admin.pubkey(),
        );
        svm.add_program(TEST_HOOK_PROGRAM_ID, &read_so("test_hook.so"))
            .expect("hook");
        Self {
            svm,
            program,
            which,
            build,
            admin,
            fee_vaults: std::collections::HashMap::new(),
        }
    }

    /// Writes an account with the given owner, discriminator and body.
    pub fn seed_raw(&mut self, key: Pubkey, owner: Pubkey, disc: [u8; 8], body: &[u8], len: usize) {
        let mut data = vec![0u8; len];
        data[..8].copy_from_slice(&disc);
        data[8..8 + body.len()].copy_from_slice(body);
        self.svm
            .set_account(
                key,
                solana_account::Account {
                    lamports: self.svm.minimum_balance_for_rent_exemption(len),
                    data,
                    owner,
                    executable: false,
                    rent_epoch: 0,
                },
            )
            .expect("seed account");
    }

    /// Writes a program-owned data account with the given discriminator + body.
    fn seed_account(&mut self, key: Pubkey, disc: [u8; 8], body: &[u8], len: usize) {
        let owner = self.program;
        self.seed_raw(key, owner, disc, body, len);
    }

    fn seed_config(&mut self, fee_bps: u16) {
        use rfq_core::layout::{config, disc};
        let (key, bump) = pda::config(&self.program);
        let mut body = vec![0u8; config::LEN - 8];
        body[..32].copy_from_slice(self.admin.pubkey().as_ref()); // admin
        // pending_admin stays zero
        let o = config::FEE_BPS - 8;
        body[o..o + 2].copy_from_slice(&fee_bps.to_le_bytes());
        body[config::BUMP - 8] = bump;
        self.seed_account(key, disc::CONFIG, &body, config::LEN);
    }

    /// Mutates an existing account's data in place.
    pub fn patch(&mut self, key: &Pubkey, f: impl FnOnce(&mut [u8])) {
        let mut acct = self.svm.get_account(key).expect("account to patch");
        f(&mut acct.data);
        self.svm.set_account(*key, acct).expect("patch");
    }

    /// Airdrops and returns a fresh keypair.
    pub fn funded_keypair(&mut self) -> Keypair {
        let kp = Keypair::new();
        self.svm
            .airdrop(&kp.pubkey(), 100 * LAMPORTS)
            .expect("airdrop");
        kp
    }

    /// Signs and sends a legacy transaction with `signers[0]` as fee payer.
    ///
    /// Every send uses a fresh blockhash, so re-sending identical instructions
    /// is a *new* transaction: the runtime's duplicate-transaction check
    /// (`AlreadyProcessed`) can never be what makes a test pass — replays are
    /// stopped (or not) by the programs themselves.
    ///
    /// Panics if the transaction would exceed the 1232-byte packet limit: a
    /// real cluster would drop it, so no test may rely on it.
    pub fn send(
        &mut self,
        ixs: &[Instruction],
        signers: &[&Keypair],
    ) -> Result<TransactionMetadata, FailedTransactionMetadata> {
        self.svm.expire_blockhash();
        let tx = self.legacy_tx(ixs, signers);
        let size = tx::serialized_len(&tx);
        assert!(
            size <= PACKET_DATA_SIZE,
            "legacy transaction is {size} bytes > {PACKET_DATA_SIZE}: a cluster would reject \
             it — use `send_auto`/`send_v0`"
        );
        self.svm.send_transaction(tx)
    }

    /// Signs a legacy transaction without sending it.
    pub fn legacy_tx(&self, ixs: &[Instruction], signers: &[&Keypair]) -> VersionedTransaction {
        let payer = signers[0].pubkey();
        VersionedTransaction::from(Transaction::new_signed_with_payer(
            ixs,
            Some(&payer),
            signers,
            self.svm.latest_blockhash(),
        ))
    }

    /// Builds an address lookup table holding every non-signer account of
    /// `ixs`, compiles a v0 transaction against it, asserts it fits a packet,
    /// and sends it. Returns the result and the wire size.
    pub fn send_v0(
        &mut self,
        ixs: &[Instruction],
        signers: &[&Keypair],
    ) -> (
        Result<TransactionMetadata, FailedTransactionMetadata>,
        usize,
    ) {
        let tx = self.v0_tx(ixs, signers);
        let size = tx::serialized_len(&tx);
        assert!(
            size <= PACKET_DATA_SIZE,
            "v0 transaction is {size} bytes > {PACKET_DATA_SIZE}"
        );
        (self.svm.send_transaction(tx), size)
    }

    /// Builds (and warms up) a lookup table for `ixs` and signs a v0
    /// transaction against it, without sending it.
    pub fn v0_tx(&mut self, ixs: &[Instruction], signers: &[&Keypair]) -> VersionedTransaction {
        self.svm.expire_blockhash();
        let signer_keys: Vec<Pubkey> = signers.iter().map(|k| k.pubkey()).collect();
        let mut addresses: Vec<Pubkey> = Vec::new();
        for meta in ixs.iter().flat_map(|i| i.accounts.iter()) {
            if !signer_keys.contains(&meta.pubkey) && !addresses.contains(&meta.pubkey) {
                addresses.push(meta.pubkey);
            }
        }
        let payer = signers[0].insecure_clone();
        let table = build_lookup_table(self, &payer, &addresses);
        tx::v0_transaction(
            signers[0],
            &signers[1..],
            ixs,
            &[table],
            self.svm.latest_blockhash(),
        )
        .expect("compile v0")
    }

    /// Sends `ixs` as a legacy transaction when it fits in a packet, otherwise
    /// as a v0 transaction over a lookup table (what a real client does for
    /// hooked settlements).
    pub fn send_auto(
        &mut self,
        ixs: &[Instruction],
        signers: &[&Keypair],
    ) -> Result<TransactionMetadata, FailedTransactionMetadata> {
        self.svm.expire_blockhash();
        let legacy = self.legacy_tx(ixs, signers);
        if tx::serialized_len(&legacy) <= PACKET_DATA_SIZE {
            self.svm.send_transaction(legacy)
        } else {
            self.send_v0(ixs, signers).0
        }
    }

    /// The account data of `key`, or an empty vec.
    pub fn data(&self, key: &Pubkey) -> Vec<u8> {
        self.svm
            .get_account(key)
            .map(|a| a.data)
            .unwrap_or_default()
    }

    /// Lamports of `key` (0 if absent).
    pub fn lamports(&self, key: &Pubkey) -> u64 {
        self.svm.get_balance(key).unwrap_or(0)
    }

    /// `true` if `key` holds no lamports and no data (never created or closed).
    pub fn is_closed(&self, key: &Pubkey) -> bool {
        self.svm
            .get_account(key)
            .map(|a| a.lamports == 0 && a.data.is_empty())
            .unwrap_or(true)
    }

    /// Reads a token account balance.
    pub fn token_balance(&self, account: &Pubkey) -> u64 {
        use spl_token_2022_interface::extension::StateWithExtensions;
        let data = self.data(account);
        StateWithExtensions::<TokenAccountState>::unpack(&data)
            .map(|a| a.base.amount)
            .unwrap_or(0)
    }

    /// Current epoch.
    pub fn epoch(&self) -> u64 {
        self.svm.get_sysvar::<solana_clock::Clock>().epoch
    }

    /// Sets the on-chain unix timestamp (for expiry tests).
    pub fn set_unix_timestamp(&mut self, ts: i64) {
        let mut clock = self.svm.get_sysvar::<solana_clock::Clock>();
        clock.unix_timestamp = ts;
        self.svm.set_sysvar(&clock);
    }

    /// Current slot.
    pub fn slot(&self) -> u64 {
        self.svm.get_sysvar::<solana_clock::Clock>().slot
    }

    /// Moves `lamports` from `from` to `to` with a System transfer.
    pub fn transfer_lamports(&mut self, from: &Keypair, to: &Pubkey, lamports: u64) {
        let mut data = 2u32.to_le_bytes().to_vec();
        data.extend_from_slice(&lamports.to_le_bytes());
        let ix = Instruction {
            program_id: rfq_client::SYSTEM_PROGRAM_ID,
            accounts: vec![
                AccountMeta::new(from.pubkey(), true),
                AccountMeta::new(*to, false),
            ],
            data,
        };
        self.send(&[ix], &[from]).expect("system transfer");
    }
}

/// Installs `bytes` as an upgradeable program with `authority` as upgrade
/// authority. LiteSVM's own loader sets no authority, which the
/// upgrade-authority-gated `initialize_config` needs, so the ProgramData
/// account is patched afterwards.
fn deploy_upgradeable(svm: &mut LiteSVM, program: &Pubkey, bytes: &[u8], authority: &Pubkey) {
    let loader = solana_sdk_ids::bpf_loader_upgradeable::ID;
    // Loads + verifies the ELF and creates program + programdata accounts.
    svm.add_program_with_loader(*program, bytes, loader)
        .expect("load program");
    let (programdata, _) = Pubkey::find_program_address(&[program.as_ref()], &loader);
    let mut pd = svm.get_account(&programdata).expect("programdata created");
    // ProgramData metadata: enum tag u32 [0..4]=3 | slot u64 [4..12] |
    // Option<Pubkey> tag [12] | pubkey [13..45].
    pd.data[12] = 1;
    pd.data[13..45].copy_from_slice(authority.as_ref());
    svm.set_account(programdata, pd)
        .expect("patch upgrade authority");
}

// ---------------------------------------------------------------------------
// Mints and token accounts
// ---------------------------------------------------------------------------

/// A mint fixture.
pub struct MintFixture {
    /// Mint keypair.
    pub mint: Keypair,
    /// Token program that owns it.
    pub token_program: Pubkey,
    /// Decimals.
    pub decimals: u8,
}

impl MintFixture {
    /// Mint address.
    pub fn key(&self) -> Pubkey {
        self.mint.pubkey()
    }
}

/// Extensions a Token-2022 mint is created with.
#[derive(Clone, Copy, Debug, Default)]
pub struct MintConfig {
    /// `(basis_points, maximum_fee)` of a transfer-fee extension.
    pub transfer_fee: Option<(u16, u64)>,
    /// A transfer-hook program id.
    pub transfer_hook: Option<Pubkey>,
}

impl Env {
    /// Creates a legacy SPL Token mint.
    pub fn create_token_mint(&mut self, payer: &Keypair, decimals: u8) -> MintFixture {
        self.create_mint_inner(payer, TOKEN_PROGRAM_ID, decimals, MintConfig::default())
    }

    /// Creates a Token-2022 mint with the given extensions.
    pub fn create_token22_mint(
        &mut self,
        payer: &Keypair,
        decimals: u8,
        cfg: MintConfig,
    ) -> MintFixture {
        self.create_mint_inner(payer, TOKEN_2022_PROGRAM_ID, decimals, cfg)
    }

    /// Creates a Token-2022 mint whose transfer hook is the in-repo test hook,
    /// with its `ExtraAccountMetaList` initialised.
    pub fn create_hooked_mint(&mut self, payer: &Keypair, decimals: u8) -> MintFixture {
        let mint = self.create_token22_mint(
            payer,
            decimals,
            MintConfig {
                transfer_fee: None,
                transfer_hook: Some(TEST_HOOK_PROGRAM_ID),
            },
        );
        self.init_hook(payer, &mint);
        mint
    }

    fn create_mint_inner(
        &mut self,
        payer: &Keypair,
        token_program: Pubkey,
        decimals: u8,
        cfg: MintConfig,
    ) -> MintFixture {
        let mint = Keypair::new();
        let authority = payer.pubkey();
        let mut ext_types = Vec::new();
        if cfg.transfer_fee.is_some() {
            ext_types.push(ExtensionType::TransferFeeConfig);
        }
        if cfg.transfer_hook.is_some() {
            ext_types.push(ExtensionType::TransferHook);
        }
        let space = if token_program == TOKEN_2022_PROGRAM_ID {
            ExtensionType::try_calculate_account_len::<Mint>(&ext_types).expect("mint len")
        } else {
            Mint::LEN
        };
        let mut ixs = vec![solana_system_create_account(
            &authority,
            &mint.pubkey(),
            self.svm.minimum_balance_for_rent_exemption(space),
            space as u64,
            &token_program,
        )];
        if let Some((bps, max)) = cfg.transfer_fee {
            ixs.push(
                spl_token_2022_interface::extension::transfer_fee::instruction::initialize_transfer_fee_config(
                    &token_program, &mint.pubkey(), Some(&authority), Some(&authority), bps, max,
                )
                .expect("fee ix"),
            );
        }
        if let Some(hook) = cfg.transfer_hook {
            ixs.push(
                spl_token_2022_interface::extension::transfer_hook::instruction::initialize(
                    &token_program,
                    &mint.pubkey(),
                    Some(authority),
                    Some(hook),
                )
                .expect("hook ix"),
            );
        }
        ixs.push(
            t22::initialize_mint2(&token_program, &mint.pubkey(), &authority, None, decimals)
                .expect("init mint"),
        );
        self.send(&ixs, &[payer, &mint]).expect("create mint");
        MintFixture {
            mint,
            token_program,
            decimals,
        }
    }

    /// Creates a token account for `owner` at a fresh address and returns it.
    pub fn create_token_account(
        &mut self,
        payer: &Keypair,
        mint: &MintFixture,
        owner: &Pubkey,
    ) -> Pubkey {
        let account = Keypair::new();
        let space = token_account_space(mint.token_program, &self.data(&mint.key()));
        let ixs = vec![
            solana_system_create_account(
                &payer.pubkey(),
                &account.pubkey(),
                self.svm.minimum_balance_for_rent_exemption(space),
                space as u64,
                &mint.token_program,
            ),
            t22::initialize_account3(&mint.token_program, &account.pubkey(), &mint.key(), owner)
                .expect("init acct"),
        ];
        self.send(&ixs, &[payer, &account])
            .expect("create token account");
        account.pubkey()
    }

    /// Mints `amount` into `account`.
    pub fn mint_to(&mut self, payer: &Keypair, mint: &MintFixture, account: &Pubkey, amount: u64) {
        let ix = t22::mint_to(
            &mint.token_program,
            &mint.key(),
            account,
            &payer.pubkey(),
            &[],
            amount,
        )
        .expect("mint_to");
        self.send(&[ix], &[payer]).expect("mint_to send");
    }
}

fn token_account_space(token_program: Pubkey, mint_data: &[u8]) -> usize {
    if token_program != TOKEN_2022_PROGRAM_ID {
        return TokenAccountState::LEN;
    }
    use spl_token_2022_interface::extension::{BaseStateWithExtensions, StateWithExtensions};
    let mint = StateWithExtensions::<Mint>::unpack(mint_data).expect("mint");
    let mint_exts = mint.get_extension_types().expect("ext types");
    let required = ExtensionType::get_required_init_account_extensions(&mint_exts);
    ExtensionType::try_calculate_account_len::<TokenAccountState>(&required).expect("acct len")
}

fn solana_system_create_account(
    from: &Pubkey,
    to: &Pubkey,
    lamports: u64,
    space: u64,
    owner: &Pubkey,
) -> Instruction {
    // System `CreateAccount` (tag 0), encoded by hand to avoid an extra dependency.
    let mut data = Vec::with_capacity(52);
    data.extend_from_slice(&0u32.to_le_bytes());
    data.extend_from_slice(&lamports.to_le_bytes());
    data.extend_from_slice(&space.to_le_bytes());
    data.extend_from_slice(owner.as_ref());
    Instruction {
        program_id: rfq_client::SYSTEM_PROGRAM_ID,
        accounts: vec![AccountMeta::new(*from, true), AccountMeta::new(*to, true)],
        data,
    }
}

// ---------------------------------------------------------------------------
// Makers, protocol state, hooks
// ---------------------------------------------------------------------------

/// A registered maker with funded vaults for the two quote mints.
pub struct MakerFixture {
    /// Owner wallet.
    pub owner: Keypair,
    /// Quote-signing key.
    pub quote_signer: Keypair,
    /// Maker-mint vault (owned by the vault-authority PDA).
    pub vault_out: Pubkey,
    /// Taker-mint vault (owned by the vault-authority PDA).
    pub vault_in: Pubkey,
}

impl MakerFixture {
    /// Owner address.
    pub fn owner_key(&self) -> Pubkey {
        self.owner.pubkey()
    }
}

impl Env {
    /// Registers a maker (via the Anchor instruction, or by seeding the account
    /// for the settle-only Pinocchio program) and creates its two vaults as
    /// token accounts owned by the maker's vault-authority PDA, funding the
    /// maker-mint vault. Settle constrains vaults by authority + mint, not by
    /// seeds, so the same setup drives both programs; the Anchor custody
    /// instructions (`init_vault` / `deposit` / `withdraw`) are exercised
    /// separately in `custody.rs`.
    pub fn register_maker(
        &mut self,
        payer: &Keypair,
        maker_mint: &MintFixture,
        taker_mint: &MintFixture,
        fund_out: u64,
    ) -> MakerFixture {
        let owner = self.funded_keypair();
        let quote_signer = Keypair::new();
        self.register_owner(&owner, &quote_signer.pubkey());
        let vault_authority = pda::vault_authority(&self.program, &owner.pubkey()).0;
        let vault_out = self.create_token_account(payer, maker_mint, &vault_authority);
        let vault_in = self.create_token_account(payer, taker_mint, &vault_authority);
        self.mint_to(payer, maker_mint, &vault_out, fund_out);
        MakerFixture {
            owner,
            quote_signer,
            vault_out,
            vault_in,
        }
    }

    /// Creates the `Maker` registry entry of `owner`.
    pub fn register_owner(&mut self, owner: &Keypair, quote_signer: &Pubkey) {
        match self.which {
            Program::Anchor => {
                self.send(
                    &[ix::register_maker(
                        &self.program,
                        &owner.pubkey(),
                        quote_signer,
                    )],
                    &[owner],
                )
                .expect("register");
            }
            Program::Pinocchio => {
                use rfq_core::layout::{disc, maker};
                let (key, bump) = pda::maker(&self.program, &owner.pubkey());
                let va_bump = pda::vault_authority(&self.program, &owner.pubkey()).1;
                let mut body = vec![0u8; maker::LEN - 8];
                body[..32].copy_from_slice(owner.pubkey().as_ref());
                let o = maker::QUOTE_SIGNER - 8;
                body[o..o + 32].copy_from_slice(quote_signer.as_ref());
                body[maker::ACTIVE - 8] = 1;
                body[maker::BUMP - 8] = bump;
                body[maker::VAULT_AUTHORITY_BUMP - 8] = va_bump;
                self.seed_account(key, disc::MAKER, &body, maker::LEN);
            }
        }
    }

    /// Creates the protocol fee vault for `mint` (a token account owned by the
    /// config PDA).
    pub fn init_fee_vault(&mut self, mint: &MintFixture) {
        match self.which {
            Program::Anchor => {
                let admin = self.admin.insecure_clone();
                self.send(
                    &[ix::init_fee_vault(
                        &self.program,
                        &admin.pubkey(),
                        &mint.key(),
                        &mint.token_program,
                    )],
                    &[&admin],
                )
                .expect("fee vault");
            }
            Program::Pinocchio => {
                // A fee vault at an arbitrary address owned by the config PDA
                // (settle constrains it by authority + mint).
                let payer = self.funded_keypair();
                let config = pda::config(&self.program).0;
                let vault = self.create_token_account(&payer, mint, &config);
                self.fee_vaults.insert(mint.key(), vault);
            }
        }
    }

    /// The fee-vault address for a mint.
    pub fn fee_vault(&self, mint: &MintFixture) -> Pubkey {
        match self.which {
            Program::Anchor => pda::fee_vault(&self.program, &mint.key()).0,
            Program::Pinocchio => *self.fee_vaults.get(&mint.key()).expect("fee vault created"),
        }
    }

    /// Creates nonce page `page` for a maker (instruction for Anchor, seeded
    /// for Pinocchio).
    pub fn init_nonce_page(&mut self, maker: &MakerFixture, page: u64) {
        match self.which {
            Program::Anchor => {
                self.send(
                    &[ix::init_nonce_page(&self.program, &maker.owner_key(), page)],
                    &[&maker.owner],
                )
                .expect("nonce page");
            }
            Program::Pinocchio => {
                use rfq_core::layout::{disc, nonce_page};
                let owner = maker.owner_key();
                let (key, bump) = pda::nonce_page(&self.program, &owner, page);
                let mut body = vec![0u8; nonce_page::LEN - 8];
                body[..32].copy_from_slice(owner.as_ref());
                let o = nonce_page::PAGE - 8;
                body[o..o + 8].copy_from_slice(&page.to_le_bytes());
                body[nonce_page::BUMP - 8] = bump;
                self.seed_account(key, disc::NONCE_PAGE, &body, nonce_page::LEN);
            }
        }
    }

    // The settle-only Pinocchio program has no admin / maker instructions; for
    // it, the state those instructions would write is written directly, in
    // the byte-identical layout (see `programs/rfq/src/state.rs` tests).

    /// Pauses or resumes settlement (`set_paused` / config byte).
    pub fn set_paused(&mut self, paused: bool) {
        match self.which {
            Program::Anchor => {
                let admin = self.admin.insecure_clone();
                self.send(
                    &[ix::set_paused(&self.program, &admin.pubkey(), paused)],
                    &[&admin],
                )
                .expect("set_paused");
            }
            Program::Pinocchio => {
                let key = pda::config(&self.program).0;
                self.patch(&key, |d| {
                    d[rfq_core::layout::config::PAUSED] = u8::from(paused)
                });
            }
        }
    }

    /// Activates or deactivates a maker.
    pub fn set_maker_active(&mut self, maker: &MakerFixture, active: bool) {
        match self.which {
            Program::Anchor => {
                self.send(
                    &[ix::set_maker_active(
                        &self.program,
                        &maker.owner_key(),
                        active,
                    )],
                    &[&maker.owner],
                )
                .expect("set_maker_active");
            }
            Program::Pinocchio => {
                let key = pda::maker(&self.program, &maker.owner_key()).0;
                self.patch(&key, |d| {
                    d[rfq_core::layout::maker::ACTIVE] = u8::from(active)
                });
            }
        }
    }

    /// Bulk-cancels every quote below `min_nonce`.
    pub fn bump_min_nonce(&mut self, maker: &MakerFixture, min_nonce: u64) {
        match self.which {
            Program::Anchor => {
                self.send(
                    &[ix::bump_min_nonce(
                        &self.program,
                        &maker.owner_key(),
                        min_nonce,
                    )],
                    &[&maker.owner],
                )
                .expect("bump_min_nonce");
            }
            Program::Pinocchio => {
                use rfq_core::layout::maker::MIN_NONCE;
                let key = pda::maker(&self.program, &maker.owner_key()).0;
                self.patch(&key, |d| {
                    d[MIN_NONCE..MIN_NONCE + 8].copy_from_slice(&min_nonce.to_le_bytes())
                });
            }
        }
    }

    /// Cancels the nonces selected by `mask` on `page`.
    pub fn cancel_nonces(&mut self, maker: &MakerFixture, page: u64, mask: &[u8; 32]) {
        match self.which {
            Program::Anchor => {
                self.send(
                    &[ix::cancel_nonces(
                        &self.program,
                        &maker.owner_key(),
                        page,
                        mask,
                    )],
                    &[&maker.owner],
                )
                .expect("cancel_nonces");
            }
            Program::Pinocchio => {
                use rfq_core::layout::nonce_page::BITS;
                let key = pda::nonce_page(&self.program, &maker.owner_key(), page).0;
                self.patch(&key, |d| {
                    for (b, m) in d[BITS..BITS + 32].iter_mut().zip(mask) {
                        *b |= m;
                    }
                });
            }
        }
    }

    /// Rotates the maker's quote-signing key to `new_signer`.
    pub fn set_quote_signer(&mut self, maker: &MakerFixture, new_signer: &Pubkey) {
        match self.which {
            Program::Anchor => {
                self.send(
                    &[ix::set_quote_signer(
                        &self.program,
                        &maker.owner_key(),
                        new_signer,
                    )],
                    &[&maker.owner],
                )
                .expect("set_quote_signer");
            }
            Program::Pinocchio => {
                use rfq_core::layout::maker::QUOTE_SIGNER;
                let key = pda::maker(&self.program, &maker.owner_key()).0;
                self.patch(&key, |d| {
                    d[QUOTE_SIGNER..QUOTE_SIGNER + 32].copy_from_slice(new_signer.as_ref())
                });
            }
        }
    }

    /// Initialises the test hook's `ExtraAccountMetaList` and counter for a mint.
    pub fn init_hook(&mut self, payer: &Keypair, mint: &MintFixture) {
        let hook = TEST_HOOK_PROGRAM_ID;
        let validation = pda::extra_account_metas(&hook, &mint.key()).0;
        let counter = Pubkey::find_program_address(&[b"counter", mint.key().as_ref()], &hook).0;
        let data = test_hook_init_data();
        let ix = Instruction {
            program_id: hook,
            accounts: vec![
                AccountMeta::new(validation, false),
                AccountMeta::new_readonly(mint.key(), false),
                AccountMeta::new(payer.pubkey(), true),
                AccountMeta::new_readonly(rfq_client::SYSTEM_PROGRAM_ID, false),
                AccountMeta::new(counter, false),
            ],
            data,
        };
        self.send(&[ix], &[payer]).expect("init hook");
    }

    /// Allows or disallows `wallet` on the test hook's per-mint allowlist.
    pub fn set_hook_allowed(
        &mut self,
        payer: &Keypair,
        mint: &MintFixture,
        wallet: &Pubkey,
        allowed: bool,
    ) {
        let hook = TEST_HOOK_PROGRAM_ID;
        let allow =
            Pubkey::find_program_address(&[b"allow", mint.key().as_ref(), wallet.as_ref()], &hook)
                .0;
        // The test hook's 8-byte ASCII tag `thk:allw` (set-allowed instruction).
        let mut data = [0x74, 0x68, 0x6b, 0x3a, 0x61, 0x6c, 0x6c, 0x77].to_vec();
        data.push(u8::from(allowed));
        let ix = Instruction {
            program_id: hook,
            accounts: vec![
                AccountMeta::new(allow, false),
                AccountMeta::new_readonly(mint.key(), false),
                AccountMeta::new(payer.pubkey(), true),
                AccountMeta::new_readonly(*wallet, false),
                AccountMeta::new_readonly(rfq_client::SYSTEM_PROGRAM_ID, false),
            ],
            data,
        };
        self.send(&[ix], &[payer]).expect("set allowed");
    }

    /// Reads the test hook's per-mint execution counter.
    pub fn hook_counter(&self, mint: &MintFixture) -> u64 {
        let counter =
            Pubkey::find_program_address(&[b"counter", mint.key().as_ref()], &TEST_HOOK_PROGRAM_ID)
                .0;
        let d = self.data(&counter);
        d.get(..8)
            .map(|b| u64::from_le_bytes(b.try_into().unwrap_or([0; 8])))
            .unwrap_or(0)
    }

    /// Hook extra accounts for a single transfer (empty for non-hook mints).
    pub fn hook_accounts(
        &self,
        mint: &MintFixture,
        source: &Pubkey,
        destination: &Pubkey,
        authority: &Pubkey,
        amount: u64,
    ) -> Vec<AccountMeta> {
        rfq_client::hooks::transfer_hook_accounts(
            &Fetcher(self),
            &mint.key(),
            source,
            destination,
            authority,
            amount,
        )
        .expect("hook accounts")
    }
}

/// An [`AccountFetcher`] backed by the live VM.
pub struct Fetcher<'a>(pub &'a Env);
impl AccountFetcher for Fetcher<'_> {
    fn account_data(&self, key: &Pubkey) -> Option<Vec<u8>> {
        self.0.svm.get_account(key).map(|a| a.data)
    }
}

/// InitializeExtraAccountMetaList data for the test hook (the metas are ignored
/// by the hook, which writes its own list, but the wire format must parse).
fn test_hook_init_data() -> Vec<u8> {
    spl_transfer_hook_interface::instruction::initialize_extra_account_meta_list(
        &TEST_HOOK_PROGRAM_ID,
        &pda::extra_account_metas(&TEST_HOOK_PROGRAM_ID, &Pubkey::new_unique()).0,
        &Pubkey::new_unique(),
        &Pubkey::new_unique(),
        &[],
    )
    .data
}

// ---------------------------------------------------------------------------
// Markets and settlement
// ---------------------------------------------------------------------------

/// Builds the ed25519 instruction of a quote signed by `signer` for `program`.
pub fn signed_quote(program: &Pubkey, signer: &Keypair, quote: &Quote) -> Instruction {
    sign::signed_quote_instruction(signer, program, quote)
}

/// Convenience: a [`Quote`] + amounts as `SettleArgs`.
pub fn settle_args(quote: Quote, fill: u64, min_out: u64, max_in: u64) -> CoreArgs {
    CoreArgs {
        quote,
        fill_amount: fill,
        min_out,
        max_in,
    }
}

/// A quote plus the two token mints it trades, with the maker/taker token
/// accounts already created.
pub struct Market {
    /// Maker mint (sold by the maker).
    pub maker_mint: MintFixture,
    /// Taker mint (bought by the maker).
    pub taker_mint: MintFixture,
    /// The registered maker.
    pub maker: MakerFixture,
    /// Taker keypair.
    pub taker: Keypair,
    /// Taker's `taker_mint` account (funded).
    pub taker_src: Pubkey,
    /// Taker's `maker_mint` account (receives).
    pub taker_dst: Pubkey,
    /// Funds the fixtures (mint authority of both mints).
    pub payer: Keypair,
}

impl Env {
    /// Sets up a maker (funded with `maker_liquidity` of the maker mint), a
    /// funded taker, both token accounts and the fee vault. Returns the market
    /// and a base quote (open, far expiry, nonce 0, zero amounts) the caller
    /// adjusts.
    pub fn market(
        &mut self,
        payer: &Keypair,
        maker_mint: MintFixture,
        taker_mint: MintFixture,
        maker_liquidity: u64,
        taker_funding: u64,
    ) -> (Market, Quote) {
        self.init_fee_vault(&maker_mint);
        let maker = self.register_maker(payer, &maker_mint, &taker_mint, maker_liquidity);
        // The maker needs a nonce page for nonce 0.
        self.init_nonce_page(&maker, 0);

        let taker = self.funded_keypair();
        let taker_src = self.create_token_account(payer, &taker_mint, &taker.pubkey());
        let taker_dst = self.create_token_account(payer, &maker_mint, &taker.pubkey());
        self.mint_to(payer, &taker_mint, &taker_src, taker_funding);

        let quote = Quote {
            maker: maker.owner_key().to_bytes(),
            maker_mint: maker_mint.key().to_bytes(),
            taker_mint: taker_mint.key().to_bytes(),
            maker_amount: 0,
            taker_amount: 0,
            nonce: 0,
            expiry: i64::MAX,
            taker: [0u8; 32],
        };
        (
            Market {
                maker_mint,
                taker_mint,
                maker,
                taker,
                taker_src,
                taker_dst,
                payer: payer.insecure_clone(),
            },
            quote,
        )
    }

    /// The standard plain-SPL market: maker sells 1,000,000 (6 dp) of its
    /// mint for 2,000,000 of the taker mint; the taker holds 5,000,000.
    pub fn standard_market(&mut self) -> (Market, Quote) {
        let payer = self.funded_keypair();
        let maker_mint = self.create_token_mint(&payer, 6);
        let taker_mint = self.create_token_mint(&payer, 6);
        let (market, base) = self.market(&payer, maker_mint, taker_mint, 1_000_000, 5_000_000);
        (
            market,
            Quote {
                maker_amount: 1_000_000,
                taker_amount: 2_000_000,
                ..base
            },
        )
    }

    /// Creates and funds a second taker for `market` (own token accounts).
    pub fn extra_taker(&mut self, market: &Market, funding: u64) -> (Keypair, Pubkey, Pubkey) {
        let taker = self.funded_keypair();
        let payer = market.payer.insecure_clone();
        let src = self.create_token_account(&payer, &market.taker_mint, &taker.pubkey());
        let dst = self.create_token_account(&payer, &market.maker_mint, &taker.pubkey());
        self.mint_to(&payer, &market.taker_mint, &src, funding);
        (taker, src, dst)
    }

    /// Full [`ix::SettleAccounts`] for a market.
    pub fn settle_accounts(&self, market: &Market) -> ix::SettleAccounts {
        ix::SettleAccounts {
            taker: market.taker.pubkey(),
            maker_owner: market.maker.owner_key(),
            maker_mint: market.maker_mint.key(),
            taker_mint: market.taker_mint.key(),
            maker_vault_out: market.maker.vault_out,
            maker_vault_in: market.maker.vault_in,
            taker_src: market.taker_src,
            taker_dst: market.taker_dst,
            fee_vault: self.fee_vault(&market.maker_mint),
            maker_token_program: market.maker_mint.token_program,
            taker_token_program: market.taker_mint.token_program,
        }
    }

    /// Transfer-hook remaining accounts the client planner resolves for a
    /// settlement (empty when the plan itself fails, e.g. an overfill — the
    /// program then rejects the instruction).
    pub fn settle_remaining(
        &self,
        accounts: &ix::SettleAccounts,
        args: &CoreArgs,
    ) -> Vec<AccountMeta> {
        match rfq_client::hooks::plan_settlement(&Fetcher(self), &self.program, args, self.epoch())
        {
            Ok(plan) => rfq_client::hooks::settle_remaining_accounts(
                &Fetcher(self),
                &self.program,
                accounts,
                &plan,
            )
            .expect("remaining"),
            Err(_) => Vec::new(),
        }
    }

    /// `[ed25519(quote by the maker's signer), settle]` for a market, with the
    /// hook remaining accounts resolved by the client planner.
    pub fn build_settle(
        &self,
        market: &Market,
        args: &CoreArgs,
        naive: bool,
    ) -> (Vec<Instruction>, Vec<AccountMeta>) {
        let accounts = self.settle_accounts(market);
        let remaining = self.settle_remaining(&accounts, args);
        let ed = signed_quote(&self.program, &market.maker.quote_signer, &args.quote);
        let settle = if naive {
            ix::settle_naive_v1(&self.program, &accounts, args, &remaining)
        } else {
            ix::settle(&self.program, &accounts, args, &remaining)
        };
        (vec![ed, settle], remaining)
    }

    /// Like [`Env::build_settle`] (strict, no hook extras), but lets the test
    /// rewrite the settle instruction's account metas.
    pub fn build_settle_with(
        &self,
        market: &Market,
        args: &CoreArgs,
        edit: impl FnOnce(&mut Vec<AccountMeta>),
    ) -> Vec<Instruction> {
        let accounts = self.settle_accounts(market);
        let mut settle = ix::settle(&self.program, &accounts, args, &[]);
        edit(&mut settle.accounts);
        let ed = signed_quote(&self.program, &market.maker.quote_signer, &args.quote);
        vec![ed, settle]
    }

    /// Signs `[ed25519, settle]` with the market's taker and sends it (v0 +
    /// lookup table when a legacy transaction would not fit).
    pub fn send_settle(
        &mut self,
        market: &Market,
        args: &CoreArgs,
    ) -> Result<TransactionMetadata, FailedTransactionMetadata> {
        let (ixs, _) = self.build_settle(market, args, false);
        let taker = market.taker.insecure_clone();
        self.send_auto(&ixs, &[&taker])
    }

    /// Sends prepared instructions signed by the market's taker.
    pub fn send_as_taker(
        &mut self,
        market: &Market,
        ixs: &[Instruction],
    ) -> Result<TransactionMetadata, FailedTransactionMetadata> {
        let taker = market.taker.insecure_clone();
        self.send_auto(ixs, &[&taker])
    }

    /// The `QuoteFill` PDA of a quote.
    pub fn quote_fill_key(&self, quote: &Quote) -> Pubkey {
        pda::quote_fill(
            &self.program,
            &Pubkey::new_from_array(quote.maker),
            quote.nonce,
        )
        .0
    }

    /// The `(filled, payer)` recorded in a quote's tracker, if it exists.
    pub fn quote_fill_state(&self, quote: &Quote) -> Option<(u64, Pubkey)> {
        use rfq_core::layout::quote_fill::{FILLED, LEN, PAYER};
        let d = self.data(&self.quote_fill_key(quote));
        (d.len() == LEN).then(|| {
            let mut f = [0u8; 8];
            f.copy_from_slice(&d[FILLED..FILLED + 8]);
            let mut p = [0u8; 32];
            p.copy_from_slice(&d[PAYER..PAYER + 32]);
            (u64::from_le_bytes(f), Pubkey::new_from_array(p))
        })
    }
}

/// Builds an on-chain address lookup table holding `addresses`, warms it up and
/// returns it. Each table gets a fresh authority, so any number of tables can
/// be derived from the one recent slot LiteSVM's `SlotHashes` holds.
pub fn build_lookup_table(
    env: &mut Env,
    payer: &Keypair,
    addresses: &[Pubkey],
) -> AddressLookupTableAccount {
    let authority = Keypair::new();
    let recent_slot = env
        .svm
        .get_sysvar::<solana_slot_hashes::SlotHashes>()
        .first()
        .map(|(slot, _)| *slot)
        .expect("a recent slot");
    let (create_ix, table) =
        tx::create_lookup_table(authority.pubkey(), payer.pubkey(), recent_slot);
    env.send(&[create_ix], &[payer]).expect("create table");
    for chunk in addresses.chunks(20) {
        let ext = tx::extend_lookup_table(
            table,
            authority.pubkey(),
            Some(payer.pubkey()),
            chunk.to_vec(),
        );
        env.send(&[ext], &[payer, &authority])
            .expect("extend table");
    }
    // Addresses become usable the slot after they were added.
    let slot = env.slot();
    env.svm.warp_to_slot(slot + 1);
    AddressLookupTableAccount {
        key: table,
        addresses: addresses.to_vec(),
    }
}

/// Re-exports for tests building transactions by hand.
pub use tx::{compute_unit_limit, serialized_len, v0_transaction};
