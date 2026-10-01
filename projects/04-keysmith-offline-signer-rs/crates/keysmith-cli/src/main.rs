// SPDX-License-Identifier: MIT
//! `keysmith`: the offline half of Keysmith.
//!
//! Derives keys, signs typed transactions, EIP-7702 authorizations, EIP-712 / EIP-191
//! messages and ERC-2612 permits, and decodes raw transactions. It has no networking code;
//! `cargo xtask check-airgap` proves that its dependency graph contains no networking crate.

mod cli;
mod commands;
mod error;
mod keysource;
mod render;

use clap::Parser;
use cli::{Cli, Command, KeystoreCommand, MnemonicCommand};
use error::CliError;
use std::io::Write;
use std::process::ExitCode;

fn run(cli: &Cli) -> Result<String, CliError> {
    match &cli.command {
        Command::Mnemonic(MnemonicCommand::New { words, out }) => {
            commands::mnemonic_new(*words, out.as_deref())
        }
        Command::Mnemonic(MnemonicCommand::Validate { mnemonic_file }) => {
            commands::mnemonic_validate(mnemonic_file)
        }
        Command::Derive(args) => commands::derive(args),
        Command::Address(args) => Ok(commands::address(&keysource::load_key(args)?)),
        Command::Keystore(KeystoreCommand::Export(args)) => commands::keystore_export(args),
        Command::Keystore(KeystoreCommand::Inspect { file }) => commands::keystore_inspect(file),
        Command::Sign(args) => commands::sign(args),
        Command::SignAuth(args) => commands::sign_auth(args),
        Command::SignMessage(args) => commands::sign_message(args),
        Command::VerifyMessage(args) => commands::verify_message(args),
        Command::SignTypedData(args) => commands::sign_typed_data(args),
        Command::HashTypedData(args) => commands::hash_typed_data(args),
        Command::Permit(args) => commands::permit(args),
        Command::Decode(args) => commands::decode(args),
    }
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(&cli) {
        Ok(out) => {
            let mut stdout = std::io::stdout().lock();
            if stdout.write_all(out.as_bytes()).is_err() {
                return ExitCode::from(1);
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("error: {e}");
            // Exit codes are small positive constants.
            ExitCode::from(u8::try_from(e.exit_code()).unwrap_or(1))
        }
    }
}
