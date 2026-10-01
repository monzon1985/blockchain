// SPDX-License-Identifier: MIT
//! Loading key material. Secrets are read from files (never from argv, which leaks into process
//! listings and shell history) or from an interactive terminal prompt, and are held in
//! zeroising buffers.

use crate::cli::KeyArgs;
use crate::error::CliError;
use keysmith_core::bip32::{self, DerivationPath};
use keysmith_core::bip39::Mnemonic;
use keysmith_core::keystore::{self, KdfLimits};
use keysmith_core::{Address, PrivateKey};
use std::path::Path;
use zeroize::Zeroizing;

/// Reads a whole file into a zeroising string.
pub fn read_secret_file(path: &Path, what: &str) -> Result<Zeroizing<String>, CliError> {
    let bytes = Zeroizing::new(std::fs::read(path).map_err(|e| CliError::io(what, path, &e))?);
    let text = std::str::from_utf8(&bytes)
        .map_err(|_| CliError::Input(format!("{what} file {} is not UTF-8", path.display())))?;
    Ok(Zeroizing::new(text.to_owned()))
}

/// Reads a password / passphrase file, stripping one trailing newline (`\n` or `\r\n`).
pub fn read_password_file(path: &Path, what: &str) -> Result<Zeroizing<String>, CliError> {
    let raw = read_secret_file(path, what)?;
    let trimmed = raw
        .strip_suffix("\r\n")
        .or_else(|| raw.strip_suffix('\n'))
        .unwrap_or(&raw);
    Ok(Zeroizing::new(trimmed.to_owned()))
}

/// Loads a mnemonic from a file.
pub fn load_mnemonic(path: &Path) -> Result<Mnemonic, CliError> {
    let phrase = read_secret_file(path, "mnemonic")?;
    Ok(Mnemonic::parse(&phrase)?)
}

/// Resolves the key described by `args`.
pub fn load_key(args: &KeyArgs) -> Result<PrivateKey, CliError> {
    let key = if let Some(path) = &args.source.private_key_file {
        let text = read_secret_file(path, "private key")?;
        PrivateKey::from_hex(&text)?
    } else if let Some(path) = &args.source.mnemonic_file {
        let mnemonic = load_mnemonic(path)?;
        let passphrase = match &args.passphrase_file {
            Some(p) => read_password_file(p, "passphrase")?,
            None => Zeroizing::new(String::new()),
        };
        let path = match (&args.hd_path, args.mnemonic_index) {
            (Some(p), _) => DerivationPath::parse(p)?,
            (None, Some(i)) => DerivationPath::ethereum(i)?,
            (None, None) => DerivationPath::ethereum(0)?,
        };
        bip32::derive_private_key(&mnemonic.to_seed(&passphrase), &path)?
    } else if let Some(path) = &args.source.keystore {
        let json = std::fs::read_to_string(path).map_err(|e| CliError::io("keystore", path, &e))?;
        let password = match &args.password_file {
            Some(p) => read_password_file(p, "password")?,
            None => Zeroizing::new(
                rpassword::prompt_password("Keystore password: ")
                    .map_err(|e| CliError::Input(format!("cannot read password: {e}")))?,
            ),
        };
        keystore::decrypt(&json, password.as_bytes(), &KdfLimits::default())?
    } else {
        // clap enforces that exactly one source is present.
        return Err(CliError::Input("no key source given".into()));
    };
    if let Some(expected) = &args.expect_address {
        let expected = Address::parse(expected)?;
        if key.address() != expected {
            return Err(CliError::Input(format!(
                "key address {} does not match --expect-address {expected}",
                key.address()
            )));
        }
    }
    Ok(key)
}
