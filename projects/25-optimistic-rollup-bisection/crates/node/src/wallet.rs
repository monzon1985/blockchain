// SPDX-License-Identifier: MIT
//! User-side helpers: signing L2 transactions and the L1 actions a user can take without the sequencer.

use alloy::{
    primitives::{Address, U256},
    providers::DynProvider,
    signers::{SignerSync, local::PrivateKeySigner},
};
use rollup_l1::{Contracts, bindings};
use rollup_stf::{Kind, L2Tx, MAX_QUEUE_PER_BATCH, Record};

use crate::{
    chain::{Chain, WithdrawalProof},
    error::{NodeError, Result},
    util::send,
};

/// Signs an L2 transfer or withdrawal with an alloy local signer (raw digest, no EIP-191 prefix).
///
/// # Errors
/// Signing failure.
pub fn sign_tx(
    signer: &PrivateKeySigner,
    kind: Kind,
    to: Address,
    amount: U256,
    nonce: U256,
    domain: alloy::primitives::B256,
) -> anyhow::Result<Record> {
    let tx = L2Tx { kind, from: signer.address(), to, amount, nonce };
    let sig = signer.sign_hash_sync(&tx.digest(domain))?;
    Ok(tx.with_signature(27 + u8::from(sig.v()), sig.r(), sig.s()))
}

/// Posts a queue-only batch carrying the overdue (and following, up to the per-batch cap) queue messages. This is
/// the censorship escape hatch: callable by anyone once a message is overdue.
///
/// # Errors
/// `NothingOverdue`/`ForcedInclusionViolated` reverts or RPC failures.
pub async fn force_batch(provider: &DynProvider, contracts: &Contracts, chain: &mut Chain, me: Address) -> Result<u64> {
    chain.sync(provider, contracts).await?;
    let cursor = usize::try_from(chain.queue_cursor()).unwrap_or(usize::MAX);
    let records: Vec<bindings::Record> =
        chain.queue().iter().skip(cursor).take(MAX_QUEUE_PER_BATCH).map(|r| (*r).into()).collect();
    send(contracts.inbox.forceBatch(records), me).await?;
    Ok(contracts.inbox.batchCount().call().await?.to::<u64>())
}

/// Pays out a withdrawal on L1 given its proof against a finalized epoch.
///
/// # Errors
/// Reverts (not finalized, bad proof, already paid) or RPC failures.
pub async fn finalize_withdrawal(contracts: &Contracts, proof: &WithdrawalProof, me: Address) -> Result<()> {
    let smt = bindings::SmtProof { bitmap: proof.bitmap, siblings: proof.siblings.clone() };
    let call =
        contracts.bridge.finalizeWithdrawal(proof.epoch, proof.withdrawal_id, proof.recipient, proof.amount, smt);
    send(call, me).await?;
    Ok(())
}

/// Checks that a proof matches the state root the oracle finalized for its epoch.
///
/// # Errors
/// RPC failure or a mismatch.
pub async fn check_against_l1(contracts: &Contracts, proof: &WithdrawalProof) -> Result<()> {
    let root = contracts.oracle.finalizedStateRoot(proof.epoch).call().await?;
    if root != proof.state_root {
        return Err(NodeError::Derivation(format!(
            "epoch {} finalized root {root} differs from the proof's {}",
            proof.epoch, proof.state_root
        )));
    }
    Ok(())
}
