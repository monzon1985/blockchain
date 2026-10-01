// SPDX-License-Identifier: MIT
//! Command-line interface definition.

use clap::{Args, Parser, Subcommand, ValueEnum};
use std::path::PathBuf;

/// Keysmith: air-gapped HD wallet and typed-transaction signer.
///
/// This binary is the OFFLINE half. It contains no networking code (verified in CI by
/// `cargo xtask check-airgap`). Use `keysmith-relay` on an online machine to prepare
/// unsigned envelopes and to broadcast signed ones.
#[derive(Debug, Parser)]
#[command(name = "keysmith", bin_name = "keysmith", version, about, long_about = None, max_term_width = 100)]
pub struct Cli {
    /// Subcommand.
    #[command(subcommand)]
    pub command: Command,
}

/// Top-level subcommands.
#[derive(Debug, Subcommand)]
pub enum Command {
    /// Generate or validate BIP-39 mnemonics.
    #[command(subcommand)]
    Mnemonic(MnemonicCommand),
    /// Derive BIP-44 addresses (and optionally the account xpub) from a mnemonic.
    Derive(DeriveArgs),
    /// Print the address of a key source.
    Address(KeyArgs),
    /// Web3 Secret Storage v3 keystores (interoperable with `cast wallet`).
    #[command(subcommand)]
    Keystore(KeystoreCommand),
    /// Sign an unsigned transaction envelope (keysmith/unsigned-tx@1).
    Sign(SignArgs),
    /// Sign an EIP-7702 authorization tuple.
    SignAuth(SignAuthArgs),
    /// Sign a message with EIP-191 `personal_sign`.
    SignMessage(SignMessageArgs),
    /// Verify an EIP-191 `personal_sign` signature.
    VerifyMessage(VerifyMessageArgs),
    /// Sign EIP-712 typed data (eth_signTypedData_v4 JSON).
    SignTypedData(SignTypedDataArgs),
    /// Print the EIP-712 encodeType, domain separator, struct hash and digest.
    HashTypedData(HashTypedDataArgs),
    /// Sign an ERC-2612 permit.
    Permit(PermitArgs),
    /// Decode a raw signed transaction: type, signer, fees, intrinsic gas, findings.
    Decode(DecodeArgs),
}

/// `keysmith mnemonic ...`
#[derive(Debug, Subcommand)]
pub enum MnemonicCommand {
    /// Generate a new mnemonic from OS entropy.
    New {
        /// Number of words: 12, 15, 18, 21 or 24.
        #[arg(long, default_value_t = 24)]
        words: usize,
        /// Write the phrase to this file instead of stdout.
        #[arg(long, value_name = "FILE")]
        out: Option<PathBuf>,
    },
    /// Validate a mnemonic's words and checksum.
    Validate {
        /// File holding the phrase.
        #[arg(long, value_name = "FILE")]
        mnemonic_file: PathBuf,
    },
}

/// Mutually exclusive key sources.
#[derive(Debug, Args)]
#[group(id = "key-source", required = true, multiple = false)]
pub struct KeySourceSel {
    /// File containing a 32-byte hex private key.
    #[arg(long, value_name = "FILE")]
    pub private_key_file: Option<PathBuf>,
    /// File containing a BIP-39 mnemonic.
    #[arg(long, value_name = "FILE")]
    pub mnemonic_file: Option<PathBuf>,
    /// Web3 Secret Storage v3 keystore file.
    #[arg(long, value_name = "FILE")]
    pub keystore: Option<PathBuf>,
}

/// Key source plus its options.
///
/// Source-specific options use explicit `conflicts_with_all` against the other sources: clap
/// considers `requires = "mnemonic_file"` satisfied whenever `mnemonic_file` conflicts with a
/// present argument (the exclusive `key-source` group), which would let
/// `--private-key-file k --mnemonic-index 1` silently ignore the index.
#[derive(Debug, Args)]
pub struct KeyArgs {
    /// Where the key comes from.
    #[command(flatten)]
    pub source: KeySourceSel,
    /// BIP-44 index: derives m/44'/60'/0'/0/<index>.
    #[arg(
        long,
        value_name = "N",
        conflicts_with = "hd_path",
        conflicts_with_all = ["private_key_file", "keystore"],
        requires = "mnemonic_file"
    )]
    pub mnemonic_index: Option<u32>,
    /// Full derivation path (default m/44'/60'/0'/0/0).
    #[arg(
        long,
        value_name = "PATH",
        conflicts_with_all = ["private_key_file", "keystore"],
        requires = "mnemonic_file"
    )]
    pub hd_path: Option<String>,
    /// File containing the BIP-39 passphrase ("25th word").
    #[arg(
        long,
        value_name = "FILE",
        conflicts_with_all = ["private_key_file", "keystore"],
        requires = "mnemonic_file"
    )]
    pub passphrase_file: Option<PathBuf>,
    /// File containing the keystore password (prompted on the terminal if omitted).
    #[arg(
        long,
        value_name = "FILE",
        conflicts_with_all = ["private_key_file", "mnemonic_file"],
        requires = "keystore"
    )]
    pub password_file: Option<PathBuf>,
    /// Abort unless the key's address equals this.
    #[arg(long, value_name = "ADDRESS")]
    pub expect_address: Option<String>,
}

/// Which signing policy applies.
///
/// Without either flag the default policy applies: the empty policy `{}`, whose booleans
/// deny contract creation, pre-EIP-155 legacy transactions and chainId-0 delegations.
#[derive(Debug, Args)]
pub struct PolicyArgs {
    /// Policy file; any violation aborts before signing (default: the built-in deny-by-default
    /// policy).
    #[arg(long, value_name = "FILE")]
    pub policy: Option<PathBuf>,
    /// Apply no policy at all (only consensus checks): allows contract creation, pre-EIP-155
    /// legacy transactions and chainId-0 delegations.
    #[arg(long, conflicts_with = "policy")]
    pub no_policy: bool,
}

/// Operator confirmation.
#[derive(Debug, Args)]
pub struct ConfirmArgs {
    /// Sign without asking. The review is still printed to stderr first. Without this flag
    /// keysmith asks for confirmation on the terminal and refuses when stdin is not a terminal.
    #[arg(long, short = 'y')]
    pub yes: bool,
}

/// `keysmith derive`
#[derive(Debug, Args)]
pub struct DeriveArgs {
    /// File containing a BIP-39 mnemonic.
    #[arg(long, value_name = "FILE")]
    pub mnemonic_file: PathBuf,
    /// File containing the BIP-39 passphrase.
    #[arg(long, value_name = "FILE")]
    pub passphrase_file: Option<PathBuf>,
    /// First BIP-44 index.
    #[arg(long, default_value_t = 0)]
    pub start: u32,
    /// Number of consecutive addresses.
    #[arg(long, default_value_t = 1)]
    pub count: u32,
    /// Also print the account-level extended public key (m/44'/60'/0') for watch-only use.
    #[arg(long)]
    pub xpub: bool,
    /// JSON output.
    #[arg(long)]
    pub json: bool,
}

/// `keysmith keystore ...`
#[derive(Debug, Subcommand)]
pub enum KeystoreCommand {
    /// Encrypt a key into a keystore file (scrypt + AES-128-CTR).
    Export(Box<KeystoreExportArgs>),
    /// Show a keystore's address and KDF parameters (no password needed).
    Inspect {
        /// Keystore file.
        file: PathBuf,
    },
}

/// `keysmith keystore export`
#[derive(Debug, Args)]
pub struct KeystoreExportArgs {
    /// Key to export.
    #[command(flatten)]
    pub key: KeyArgs,
    /// Output keystore file (refuses to overwrite).
    #[arg(long, value_name = "FILE")]
    pub out: PathBuf,
    /// File containing the new keystore password.
    #[arg(long, value_name = "FILE")]
    pub new_password_file: PathBuf,
    /// scrypt log2(N): 18 = geth standard (256 MiB); 12 = light (tests only).
    #[arg(long, default_value_t = 18, value_parser = clap::value_parser!(u8).range(10..=20))]
    pub scrypt_log_n: u8,
}

/// Output format of `sign`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum SignFormat {
    /// keysmith/signed-tx@1 JSON envelope.
    Json,
    /// Raw 0x-hex transaction only.
    Raw,
}

/// `keysmith sign`
#[derive(Debug, Args)]
pub struct SignArgs {
    /// Unsigned envelope file (`-` for stdin).
    #[arg(long, value_name = "FILE")]
    pub envelope: PathBuf,
    /// Signing key.
    #[command(flatten)]
    pub key: KeyArgs,
    /// Signing policy.
    #[command(flatten)]
    pub policy: PolicyArgs,
    /// Confirmation.
    #[command(flatten)]
    pub confirm: ConfirmArgs,
    /// Write the result to this file instead of stdout.
    #[arg(long, value_name = "FILE")]
    pub out: Option<PathBuf>,
    /// Output format.
    #[arg(long, value_enum, default_value_t = SignFormat::Json)]
    pub format: SignFormat,
}

/// Who submits the EIP-7702 transaction carrying an authorization.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum ExecutorArg {
    /// Another account sends the transaction (auth nonce = --nonce).
    Sponsor,
    /// The authority sends it itself (auth nonce = --nonce + 1).
    #[value(name = "self")]
    SelfExecuting,
}

/// `keysmith sign-auth`
#[derive(Debug, Args)]
pub struct SignAuthArgs {
    /// Chain id (0 = valid on every chain; warned and policy-gated).
    #[arg(long)]
    pub chain_id: String,
    /// Delegation target contract.
    #[arg(long)]
    pub address: String,
    /// The authority's CURRENT account nonce.
    #[arg(long)]
    pub nonce: u64,
    /// Who will submit the type-4 transaction.
    #[arg(long, value_enum, default_value_t = ExecutorArg::Sponsor)]
    pub executor: ExecutorArg,
    /// Signing key (the authority).
    #[command(flatten)]
    pub key: KeyArgs,
    /// Signing policy (`allowedChainIds`, `allowedDelegates`, `allowAnyChainAuthorizations`).
    #[command(flatten)]
    pub policy: PolicyArgs,
    /// Confirmation.
    #[command(flatten)]
    pub confirm: ConfirmArgs,
    /// JSON output (default prints the RLP hex, as `cast wallet sign-auth` does).
    #[arg(long)]
    pub json: bool,
}

/// Message input for EIP-191.
#[derive(Debug, Args)]
#[group(id = "message-input", required = true, multiple = false)]
pub struct MessageInput {
    /// UTF-8 message text.
    #[arg(long)]
    pub message: Option<String>,
    /// File whose raw bytes are the message.
    #[arg(long, value_name = "FILE")]
    pub message_file: Option<PathBuf>,
    /// Message given as 0x-hex bytes.
    #[arg(long, value_name = "HEX")]
    pub hex: Option<String>,
}

/// `keysmith sign-message`
#[derive(Debug, Args)]
pub struct SignMessageArgs {
    /// Message.
    #[command(flatten)]
    pub input: MessageInput,
    /// Signing key.
    #[command(flatten)]
    pub key: KeyArgs,
    /// Confirmation.
    #[command(flatten)]
    pub confirm: ConfirmArgs,
}

/// `keysmith verify-message`
#[derive(Debug, Args)]
pub struct VerifyMessageArgs {
    /// Message.
    #[command(flatten)]
    pub input: MessageInput,
    /// Expected signer.
    #[arg(long)]
    pub address: String,
    /// 65-byte r||s||v signature (0x-hex).
    #[arg(long)]
    pub signature: String,
}

/// `keysmith sign-typed-data`
#[derive(Debug, Args)]
pub struct SignTypedDataArgs {
    /// Typed-data JSON file.
    #[arg(long, value_name = "FILE")]
    pub file: PathBuf,
    /// Signing key.
    #[command(flatten)]
    pub key: KeyArgs,
    /// Signing policy (`allowedChainIds`, `allowedVerifyingContracts`, `allowedSpenders`,
    /// `maxPermitValue`).
    #[command(flatten)]
    pub policy: PolicyArgs,
    /// Confirmation.
    #[command(flatten)]
    pub confirm: ConfirmArgs,
    /// Print digest and components as JSON.
    #[arg(long)]
    pub json: bool,
}

/// `keysmith hash-typed-data`
#[derive(Debug, Args)]
pub struct HashTypedDataArgs {
    /// Typed-data JSON file.
    #[arg(long, value_name = "FILE")]
    pub file: PathBuf,
}

/// `keysmith permit`
#[derive(Debug, Args)]
pub struct PermitArgs {
    /// Token contract (EIP-712 verifyingContract).
    #[arg(long)]
    pub token: String,
    /// Token name (EIP-712 domain name).
    #[arg(long)]
    pub name: String,
    /// EIP-712 domain version.
    #[arg(long, default_value = "1")]
    pub version: String,
    /// Chain id.
    #[arg(long)]
    pub chain_id: String,
    /// Spender receiving the allowance.
    #[arg(long)]
    pub spender: String,
    /// Allowance in token base units.
    #[arg(long)]
    pub value: String,
    /// The owner's current `nonces(owner)`.
    #[arg(long)]
    pub nonce: String,
    /// Unix timestamp deadline.
    #[arg(long)]
    pub deadline: String,
    /// Signing key (the owner).
    #[command(flatten)]
    pub key: KeyArgs,
    /// Signing policy (`allowedChainIds`, `allowedVerifyingContracts`, `allowedSpenders`,
    /// `maxPermitValue`).
    #[command(flatten)]
    pub policy: PolicyArgs,
    /// Confirmation.
    #[command(flatten)]
    pub confirm: ConfirmArgs,
    /// JSON output.
    #[arg(long)]
    pub json: bool,
}

/// `keysmith decode`
#[derive(Debug, Args)]
pub struct DecodeArgs {
    /// Raw 0x-hex transaction (or use --file).
    #[arg(required_unless_present = "file", conflicts_with = "file")]
    pub raw: Option<String>,
    /// File containing the raw hex or a keysmith/signed-tx@1 envelope.
    #[arg(long, value_name = "FILE")]
    pub file: Option<PathBuf>,
    /// Base fee per gas (wei, or with a unit, e.g. 7gwei) for the effective gas price.
    #[arg(long)]
    pub base_fee: Option<String>,
    /// JSON output.
    #[arg(long)]
    pub json: bool,
}
