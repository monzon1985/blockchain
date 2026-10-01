// SPDX-License-Identifier: MIT
//! # rollup-l1
//!
//! Everything the Rust services need to talk to the L1 contracts: `sol!` bindings, artifact loading from
//! `contracts/out`, a provider builder, and a deployer for the whole system.

pub mod artifacts;
pub mod bindings;
pub mod deploy;

use alloy::{
    network::EthereumWallet,
    providers::{DynProvider, Provider, ProviderBuilder},
    signers::local::PrivateKeySigner,
    transports::http::reqwest::Url,
};
use thiserror::Error;

pub use artifacts::{Artifact, Artifacts};
pub use bindings::{
    IBatchInbox, IBridge, IDisputeGame, IForcedInclusionQueue, IOneStepVM, IOutputOracle, Outcome, Phase,
    ProposalStatus,
};
pub use deploy::{DeployConfig, Deployment, deploy};

/// Errors of the L1 layer.
#[derive(Debug, Error)]
pub enum L1Error {
    /// Missing or malformed compiled artifact.
    #[error("artifact: {0}")]
    Artifact(String),
    /// Deployment did not produce the expected addresses.
    #[error("deployment: {0}")]
    Deployment(String),
    /// RPC failure.
    #[error(transparent)]
    Transport(#[from] alloy::transports::TransportError),
    /// Transaction was not confirmed.
    #[error(transparent)]
    Pending(#[from] alloy::providers::PendingTransactionError),
    /// Contract call failure (including decoded reverts).
    #[error(transparent)]
    Contract(#[from] alloy::contract::Error),
    /// Bad endpoint URL.
    #[error("invalid RPC URL: {0}")]
    Url(String),
}

/// Handles to every contract of a deployment.
#[derive(Debug, Clone)]
pub struct Contracts {
    /// Addresses.
    pub deployment: Deployment,
    /// Forced-inclusion queue.
    pub queue: IForcedInclusionQueue::IForcedInclusionQueueInstance<DynProvider>,
    /// Batch inbox.
    pub inbox: IBatchInbox::IBatchInboxInstance<DynProvider>,
    /// Output oracle.
    pub oracle: IOutputOracle::IOutputOracleInstance<DynProvider>,
    /// Dispute game.
    pub game: IDisputeGame::IDisputeGameInstance<DynProvider>,
    /// Bridge.
    pub bridge: IBridge::IBridgeInstance<DynProvider>,
}

impl Contracts {
    /// Binds every contract of `deployment` to `provider`.
    pub fn new(deployment: Deployment, provider: DynProvider) -> Self {
        Self {
            deployment,
            queue: IForcedInclusionQueue::new(deployment.queue, provider.clone()),
            inbox: IBatchInbox::new(deployment.inbox, provider.clone()),
            oracle: IOutputOracle::new(deployment.oracle, provider.clone()),
            game: IDisputeGame::new(deployment.game, provider.clone()),
            bridge: IBridge::new(deployment.bridge, provider),
        }
    }
}

/// HTTP provider that signs with `signer`. Nonces are read from the node for every transaction (no local cache), so a
/// transaction that fails gas estimation never leaves a nonce gap behind.
///
/// # Errors
/// [`L1Error::Url`] for a malformed endpoint.
pub fn provider(rpc_url: &str, signer: PrivateKeySigner) -> Result<DynProvider, L1Error> {
    let url: Url = rpc_url.parse().map_err(|e| L1Error::Url(format!("{rpc_url}: {e}")))?;
    Ok(ProviderBuilder::new()
        .disable_recommended_fillers()
        .with_simple_nonce_management()
        .with_gas_estimation()
        .fetch_chain_id()
        .wallet(EthereumWallet::from(signer))
        .connect_http(url)
        .erased())
}

/// Read-only HTTP provider.
///
/// # Errors
/// [`L1Error::Url`] for a malformed endpoint.
pub fn read_provider(rpc_url: &str) -> Result<DynProvider, L1Error> {
    let url: Url = rpc_url.parse().map_err(|e| L1Error::Url(format!("{rpc_url}: {e}")))?;
    Ok(ProviderBuilder::new().connect_http(url).erased())
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use alloy::{primitives::hex, sol_types::SolCall};

    use super::*;

    /// Checks one interface: every function and error selector and every event topic declared in `bindings.rs` must
    /// be in the compiled contract's ABI. Returns how many declarations were checked.
    fn declared_in_abi(artifact: &Artifact, calls: &[[u8; 4]], events: &[[u8; 32]], errors: &[[u8; 4]]) -> usize {
        let functions: BTreeSet<[u8; 4]> = artifact.abi.functions().map(|f| f.selector().0).collect();
        let topics: BTreeSet<[u8; 32]> = artifact.abi.events().map(|e| e.selector().0).collect();
        let custom_errors: BTreeSet<[u8; 4]> = artifact.abi.errors().map(|e| e.selector().0).collect();
        for s in calls {
            assert!(
                functions.contains(s),
                "{}: function selector 0x{} is not in the ABI",
                artifact.name,
                hex::encode(s)
            );
        }
        for t in events {
            assert!(topics.contains(t), "{}: event topic 0x{} is not in the ABI", artifact.name, hex::encode(t));
        }
        for s in errors {
            assert!(
                custom_errors.contains(s),
                "{}: error selector 0x{} is not in the ABI",
                artifact.name,
                hex::encode(s)
            );
        }
        calls.len() + events.len() + errors.len()
    }

    /// Every declaration in `bindings.rs` exists, with the same signature, in the compiled ABI (requires `forge build`
    /// first, as in the documented gate order): the six interfaces' 62 functions, 20 events and 43 errors, plus the
    /// five constructor signatures `Constructors` encodes deployment arguments with.
    #[test]
    fn bindings_match_artifacts() {
        let a = Artifacts::load_default().expect("contracts/out missing: run `forge build` in contracts/ first");
        let checked = declared_in_abi(
            &a.queue,
            IForcedInclusionQueue::IForcedInclusionQueueCalls::SELECTORS,
            IForcedInclusionQueue::IForcedInclusionQueueEvents::SELECTORS,
            IForcedInclusionQueue::IForcedInclusionQueueErrors::SELECTORS,
        ) + declared_in_abi(
            &a.inbox,
            IBatchInbox::IBatchInboxCalls::SELECTORS,
            IBatchInbox::IBatchInboxEvents::SELECTORS,
            IBatchInbox::IBatchInboxErrors::SELECTORS,
        ) + declared_in_abi(
            &a.oracle,
            IOutputOracle::IOutputOracleCalls::SELECTORS,
            IOutputOracle::IOutputOracleEvents::SELECTORS,
            IOutputOracle::IOutputOracleErrors::SELECTORS,
        ) + declared_in_abi(
            &a.game,
            IDisputeGame::IDisputeGameCalls::SELECTORS,
            IDisputeGame::IDisputeGameEvents::SELECTORS,
            IDisputeGame::IDisputeGameErrors::SELECTORS,
        ) + declared_in_abi(
            &a.bridge,
            IBridge::IBridgeCalls::SELECTORS,
            IBridge::IBridgeEvents::SELECTORS,
            IBridge::IBridgeErrors::SELECTORS,
        ) + declared_in_abi(
            &a.one_step_vm,
            IOneStepVM::IOneStepVMCalls::SELECTORS,
            &[],
            IOneStepVM::IOneStepVMErrors::SELECTORS,
        );

        fn constructor_args(artifact: &Artifact) -> String {
            let inputs = artifact.abi.constructor().map(|c| c.inputs.as_slice()).unwrap_or_default();
            inputs.iter().map(|p| p.selector_type().into_owned()).collect::<Vec<_>>().join(",")
        }
        fn declared_args(signature: &str) -> &str {
            signature.split_once('(').and_then(|(_, rest)| rest.strip_suffix(')')).unwrap_or_default()
        }
        let constructors = [
            (&a.queue, bindings::Constructors::forcedInclusionQueueCall::SIGNATURE),
            (&a.inbox, bindings::Constructors::batchInboxCall::SIGNATURE),
            (&a.oracle, bindings::Constructors::outputOracleCall::SIGNATURE),
            (&a.game, bindings::Constructors::disputeGameCall::SIGNATURE),
            (&a.bridge, bindings::Constructors::bridgeCall::SIGNATURE),
        ];
        for (artifact, signature) in constructors {
            assert_eq!(declared_args(signature), constructor_args(artifact), "{} constructor", artifact.name);
        }
        assert_eq!(
            checked + constructors.len(),
            67 + 20 + 43,
            "a declaration was added to bindings.rs; update the count"
        );
    }

    /// The drift check is not vacuous: a signature that differs from the contract's (here a wrong parameter type) is
    /// caught.
    #[test]
    #[should_panic(expected = "is not in the ABI")]
    fn a_drifted_signature_is_caught() {
        let a = Artifacts::load_default().expect("contracts/out missing: run `forge build` in contracts/ first");
        let drifted = alloy::primitives::keccak256("BatchAppended(uint256,bytes32,uint64,uint64,uint64,bool,bytes)");
        declared_in_abi(&a.inbox, &[], &[drifted.0], &[]);
    }

    /// solc's `methodIdentifiers` agree with the ABI for the calls the services send.
    #[test]
    fn selectors_match_artifacts() {
        let a = Artifacts::load_default().expect("contracts/out missing: run `forge build` in contracts/ first");
        fn has(artifact: &Artifact, sig: &str, selector: [u8; 4]) {
            let hex: String = selector.iter().map(|b| format!("{b:02x}")).collect();
            assert_eq!(artifact.method_identifiers.get(sig), Some(&hex), "{}: {sig}", artifact.name);
        }
        has(&a.inbox, IBatchInbox::submitBatchCall::SIGNATURE, IBatchInbox::submitBatchCall::SELECTOR);
        has(&a.inbox, IBatchInbox::forceBatchCall::SIGNATURE, IBatchInbox::forceBatchCall::SELECTOR);
        has(&a.inbox, IBatchInbox::batchCall::SIGNATURE, IBatchInbox::batchCall::SELECTOR);
        has(&a.oracle, IOutputOracle::proposeCall::SIGNATURE, IOutputOracle::proposeCall::SELECTOR);
        has(&a.oracle, IOutputOracle::finalizeCall::SIGNATURE, IOutputOracle::finalizeCall::SELECTOR);
        has(&a.oracle, IOutputOracle::getProposalCall::SIGNATURE, IOutputOracle::getProposalCall::SELECTOR);
        has(&a.game, IDisputeGame::challengeCall::SIGNATURE, IDisputeGame::challengeCall::SELECTOR);
        has(&a.game, IDisputeGame::commitEndCall::SIGNATURE, IDisputeGame::commitEndCall::SELECTOR);
        has(&a.game, IDisputeGame::bisectCall::SIGNATURE, IDisputeGame::bisectCall::SELECTOR);
        has(&a.game, IDisputeGame::chooseCall::SIGNATURE, IDisputeGame::chooseCall::SELECTOR);
        has(&a.game, IDisputeGame::stepCall::SIGNATURE, IDisputeGame::stepCall::SELECTOR);
        has(&a.game, IDisputeGame::getGameCall::SIGNATURE, IDisputeGame::getGameCall::SELECTOR);
        has(&a.game, IDisputeGame::claimTimeoutCall::SIGNATURE, IDisputeGame::claimTimeoutCall::SELECTOR);
        has(&a.bridge, IBridge::finalizeWithdrawalCall::SIGNATURE, IBridge::finalizeWithdrawalCall::SELECTOR);
        has(&a.bridge, IBridge::depositCall::SIGNATURE, IBridge::depositCall::SELECTOR);
        has(
            &a.queue,
            IForcedInclusionQueue::forceTransferCall::SIGNATURE,
            IForcedInclusionQueue::forceTransferCall::SELECTOR,
        );
        has(&a.one_step_vm, IOneStepVM::stepCall::SIGNATURE, IOneStepVM::stepCall::SELECTOR);
        has(&a.one_step_vm, IOneStepVM::stepHashCall::SIGNATURE, IOneStepVM::stepHashCall::SELECTOR);
    }
}
