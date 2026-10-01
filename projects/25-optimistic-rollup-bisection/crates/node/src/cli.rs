// SPDX-License-Identifier: MIT
//! Command-line pieces shared by the service binaries.

use std::path::PathBuf;

use alloy::signers::local::PrivateKeySigner;
use tokio::sync::watch;

use crate::util::{signer_from_env, signer_from_keystore};

/// Arguments every service takes.
#[derive(Debug, Clone, clap::Args)]
pub struct CommonArgs {
    /// L1 JSON-RPC endpoint.
    #[arg(long, env = "ROLLUP_RPC_URL")]
    pub rpc_url: String,
    /// Deployment descriptor written by `rollup-cli deploy`.
    #[arg(long, env = "ROLLUP_DEPLOYMENT", default_value = "deployment.json")]
    pub deployment: PathBuf,
    /// Poll interval in milliseconds.
    #[arg(long, default_value_t = 500)]
    pub poll_ms: u64,
}

/// Where the signing key comes from: an encrypted keystore (with its password in an environment variable) or, for
/// local devnets, a raw hex key in an environment variable. Keys never travel on the command line.
#[derive(Debug, Clone, clap::Args)]
pub struct KeyArgs {
    /// Encrypted JSON keystore (e.g. from `cast wallet import`); takes precedence over `--key-env`.
    #[arg(long)]
    pub keystore: Option<PathBuf>,
    /// Environment variable holding the keystore password.
    #[arg(long, default_value = "ROLLUP_KEYSTORE_PASSWORD")]
    pub password_env: String,
}

impl KeyArgs {
    /// Loads the signer from the keystore if one was given, else from the raw key in `key_env` (devnet only).
    ///
    /// # Errors
    /// See [`signer_from_keystore`] and [`signer_from_env`].
    pub fn signer(&self, key_env: &str) -> anyhow::Result<PrivateKeySigner> {
        match &self.keystore {
            Some(path) => signer_from_keystore(path, &self.password_env),
            None => signer_from_env(key_env),
        }
    }
}

/// Shutdown channel flipped by Ctrl-C.
pub fn ctrl_c_shutdown() -> watch::Receiver<bool> {
    let (tx, rx) = watch::channel(false);
    tokio::spawn(async move {
        let _ = tokio::signal::ctrl_c().await;
        let _ = tx.send(true);
    });
    rx
}
