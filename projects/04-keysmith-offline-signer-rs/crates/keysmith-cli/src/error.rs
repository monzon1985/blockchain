// SPDX-License-Identifier: MIT
//! CLI error type and exit codes. Messages never include key material.

use keysmith_core::address::AddressError;
use keysmith_core::bip32::Bip32Error;
use keysmith_core::bip39::Bip39Error;
use keysmith_core::eip712::Eip712Error;
use keysmith_core::envelope::EnvelopeError;
use keysmith_core::keys::{KeyError, SignatureError};
use keysmith_core::keystore::KeystoreError;
use keysmith_core::permit::PermitError;
use keysmith_core::policy::PolicyError;
use keysmith_core::tx::TxError;
use keysmith_core::units::UnitsError;
use std::path::Path;

/// Exit code for ordinary failures.
pub const EXIT_ERROR: i32 = 1;
/// Exit code when signing was refused (invalid transaction or policy violation).
pub const EXIT_REFUSED: i32 = 3;

/// Everything that can go wrong in the CLI.
#[derive(Debug, thiserror::Error)]
pub enum CliError {
    /// Bad input from the user or a file.
    #[error("{0}")]
    Input(String),
    /// Signing refused by validation or policy.
    #[error("REFUSED: {0}")]
    Refused(String),
    /// Library error.
    #[error("{0}")]
    Core(String),
}

impl CliError {
    /// I/O error on a named file (the path is shown, the content never is).
    pub fn io(what: &str, path: &Path, e: &std::io::Error) -> Self {
        CliError::Input(format!("cannot read {what} file {}: {e}", path.display()))
    }

    /// Process exit code.
    pub fn exit_code(&self) -> i32 {
        match self {
            CliError::Refused(_) => EXIT_REFUSED,
            _ => EXIT_ERROR,
        }
    }
}

macro_rules! from_core {
    ($($t:ty),* $(,)?) => {
        $(impl From<$t> for CliError {
            fn from(e: $t) -> Self {
                CliError::Core(e.to_string())
            }
        })*
    };
}

from_core!(
    AddressError,
    Bip32Error,
    Bip39Error,
    Eip712Error,
    KeyError,
    SignatureError,
    KeystoreError,
    PermitError,
    PolicyError,
    TxError,
    UnitsError,
    keysmith_core::hex::HexError,
    keysmith_core::u256::ParseU256Error,
);

impl From<EnvelopeError> for CliError {
    fn from(e: EnvelopeError) -> Self {
        match e {
            EnvelopeError::Invalid(_) | EnvelopeError::PolicyViolation(_) => {
                CliError::Refused(e.to_string())
            }
            other => CliError::Core(other.to_string()),
        }
    }
}
