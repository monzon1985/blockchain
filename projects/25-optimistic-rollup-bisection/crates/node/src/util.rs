// SPDX-License-Identifier: MIT
//! Small L1 helpers shared by the services.

use std::{future::Future, path::Path, time::Duration};

use alloy::{
    contract::{CallBuilder, CallDecoder},
    eips::BlockNumberOrTag,
    primitives::Address,
    providers::Provider,
    rpc::types::TransactionReceipt,
    signers::local::PrivateKeySigner,
};
use tokio::sync::watch;
use tracing::warn;

use crate::error::{NodeError, Result};

/// Timestamp of the latest L1 block (the clock every protocol deadline is measured against).
///
/// # Errors
/// RPC failure.
pub async fn l1_now<P: Provider>(provider: &P) -> Result<u64> {
    let block = provider
        .get_block_by_number(BlockNumberOrTag::Latest)
        .await?
        .ok_or_else(|| NodeError::Derivation("no latest block".into()))?;
    Ok(block.header.inner.timestamp)
}

/// Sends a contract transaction from `from`, waits for its receipt and fails if it reverted.
///
/// Gas is estimated explicitly and padded by 25% + 50k: the estimate is taken against the latest block, but the
/// transaction executes in the next one, where `block.timestamp` differs. The dispute game's chess-clock writes then
/// cost more than estimated (a slot written with a different value instead of the same one), which would otherwise
/// make moves run out of gas intermittently.
///
/// # Errors
/// Reverts surface either from gas estimation ([`NodeError::Contract`], with the decoded custom error) or from the
/// receipt ([`NodeError::Reverted`]).
pub async fn send<P: Provider, D: CallDecoder>(call: CallBuilder<P, D>, from: Address) -> Result<TransactionReceipt> {
    let call = call.from(from);
    let estimate = call.estimate_gas().await?;
    let receipt = call.gas(estimate + estimate / 4 + 50_000).send().await?.get_receipt().await?;
    if !receipt.status() {
        return Err(NodeError::Reverted(receipt.transaction_hash));
    }
    Ok(receipt)
}

/// Reads a hex private key from the environment variable `var`. Keys never travel on the command line. This is the
/// devnet path (anvil's well-known keys); anything holding value should use [`signer_from_keystore`].
///
/// # Errors
/// Missing variable or malformed key.
pub fn signer_from_env(var: &str) -> anyhow::Result<PrivateKeySigner> {
    let raw = std::env::var(var).map_err(|_| anyhow::anyhow!("environment variable {var} is not set"))?;
    raw.trim().parse::<PrivateKeySigner>().map_err(|e| anyhow::anyhow!("{var} is not a valid private key: {e}"))
}

/// Decrypts an encrypted JSON keystore (the Web3 Secret Storage format written by `cast wallet import` and geth) with
/// the password held in the environment variable `password_env`.
///
/// # Errors
/// Missing password variable, unreadable file, or a wrong password.
pub fn signer_from_keystore(path: &Path, password_env: &str) -> anyhow::Result<PrivateKeySigner> {
    let password = std::env::var(password_env)
        .map_err(|_| anyhow::anyhow!("environment variable {password_env} (keystore password) is not set"))?;
    keystore_signer(path, &password)
}

/// Decrypts an encrypted JSON keystore with `password`.
///
/// # Errors
/// Unreadable file or a wrong password.
pub fn keystore_signer(path: &Path, password: &str) -> anyhow::Result<PrivateKeySigner> {
    PrivateKeySigner::decrypt_keystore(path, password)
        .map_err(|e| anyhow::anyhow!("cannot decrypt keystore {}: {e}", path.display()))
}

/// Runs one stage of a service tick. A failure is logged with the stage's name and never stops the next stage, so
/// one persistent error (say, a balance too low for a new bond) cannot starve the stages that would fix it.
pub async fn stage<F: Future<Output = Result<()>>>(service: &str, name: &str, fut: F) -> bool {
    match fut.await {
        Ok(()) => true,
        Err(e) => {
            warn!(service, stage = name, error = %e, "stage failed; continuing with the next one");
            false
        }
    }
}

/// Sleeps for `poll` or until shutdown is requested; returns `true` when the service should stop.
pub async fn wait_or_stop(poll: Duration, shutdown: &mut watch::Receiver<bool>) -> bool {
    if *shutdown.borrow() {
        return true;
    }
    tokio::select! {
        () = tokio::time::sleep(poll) => *shutdown.borrow(),
        changed = shutdown.changed() => changed.is_err() || *shutdown.borrow(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::B256;

    #[test]
    fn keystores_decrypt_with_the_right_password_only() {
        let dir = std::env::temp_dir().join(format!("rollup-node-keystore-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let key = B256::repeat_byte(7);
        let (expected, _) =
            PrivateKeySigner::encrypt_keystore(&dir, &mut rand::thread_rng(), key, "pw", Some("k.json")).unwrap();
        let path = dir.join("k.json");
        assert_eq!(keystore_signer(&path, "pw").unwrap().address(), expected.address());
        assert!(keystore_signer(&path, "nope").unwrap_err().to_string().contains("cannot decrypt keystore"));
        let e = signer_from_keystore(&path, "ROLLUP_TEST_UNSET_PASSWORD").unwrap_err().to_string();
        assert!(e.contains("ROLLUP_TEST_UNSET_PASSWORD (keystore password) is not set"), "{e}");
        assert!(signer_from_env("ROLLUP_TEST_UNSET_KEY").unwrap_err().to_string().contains("is not set"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
