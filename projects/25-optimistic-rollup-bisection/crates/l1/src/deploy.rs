// SPDX-License-Identifier: MIT
//! Deploying the whole system with precomputed CREATE addresses (the contracts reference each other immutably).

use alloy::{
    network::TransactionBuilder,
    primitives::{Address, B256, Bytes, U256},
    providers::{DynProvider, Provider},
    rpc::types::TransactionRequest,
    sol_types::SolCall,
};
use serde::{Deserialize, Serialize};

use crate::{
    L1Error,
    artifacts::{Artifact, Artifacts},
    bindings::Constructors,
};

/// Protocol parameters fixed at deployment.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeployConfig {
    /// Owner of the inbox (can rotate the sequencer).
    pub owner: Address,
    /// Initial sequencer.
    pub sequencer: Address,
    /// L1 blocks a queue message may wait before it must be included.
    pub inclusion_window: u64,
    /// Bond per output proposal, wei.
    pub proposer_bond: U256,
    /// Bond per challenge, wei.
    pub challenger_bond: U256,
    /// Challenge window, seconds.
    pub challenge_window: u64,
    /// Chess-clock budget per party, seconds.
    pub clock: u64,
    /// Bisection depth.
    pub max_depth: u8,
    /// L2 state root before epoch 1.
    pub genesis_state_root: B256,
    /// Merkle root of the STF program.
    pub code_root: B256,
    /// Length of the STF program.
    pub code_size: u32,
}

/// Addresses of a deployed system.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Deployment {
    /// `OneStepVM`.
    pub one_step_vm: Address,
    /// `ForcedInclusionQueue`.
    pub queue: Address,
    /// `BatchInbox`.
    pub inbox: Address,
    /// `OutputOracle`.
    pub oracle: Address,
    /// `DisputeGame`.
    pub game: Address,
    /// `Bridge`.
    pub bridge: Address,
    /// L1 block of the first deployment transaction (log scans start here).
    pub start_block: u64,
}

fn creation_code(artifact: &Artifact, constructor_call: &impl SolCall) -> Bytes {
    // A constructor's arguments are ABI-encoded exactly like a call's, minus the 4-byte selector.
    let encoded = constructor_call.abi_encode();
    [artifact.bytecode.as_ref(), &encoded[4..]].concat().into()
}

async fn deploy_one(
    provider: &DynProvider,
    from: Address,
    nonce: u64,
    code: Bytes,
    expected: Address,
    name: &str,
) -> Result<(), L1Error> {
    let tx = TransactionRequest::default().with_from(from).with_nonce(nonce).with_deploy_code(code);
    let receipt = provider.send_transaction(tx).await?.get_receipt().await?;
    let deployed = receipt.contract_address.filter(|_| receipt.status());
    if deployed != Some(expected) {
        return Err(L1Error::Deployment(format!("{name}: expected {expected}, got {deployed:?}")));
    }
    Ok(())
}

/// Deploys the six contracts from `deployer` in one run of consecutive nonces.
///
/// # Errors
/// Transport failures, reverted deployments, or an address that differs from the precomputed one (which would mean
/// another transaction from `deployer` interleaved).
pub async fn deploy(
    provider: &DynProvider,
    deployer: Address,
    artifacts: &Artifacts,
    cfg: &DeployConfig,
) -> Result<Deployment, L1Error> {
    let nonce = provider.get_transaction_count(deployer).await?;
    let start_block = provider.get_block_number().await?;
    let at = |i: u64| deployer.create(nonce + i);
    let d = Deployment {
        one_step_vm: at(0),
        queue: at(1),
        inbox: at(2),
        oracle: at(3),
        game: at(4),
        bridge: at(5),
        start_block,
    };

    deploy_one(provider, deployer, nonce, artifacts.one_step_vm.bytecode.clone(), d.one_step_vm, "OneStepVM").await?;
    let queue = creation_code(
        &artifacts.queue,
        &Constructors::forcedInclusionQueueCall { bridge: d.bridge, inclusionWindow: cfg.inclusion_window },
    );
    deploy_one(provider, deployer, nonce + 1, queue, d.queue, "ForcedInclusionQueue").await?;
    let inbox = creation_code(
        &artifacts.inbox,
        &Constructors::batchInboxCall { queue: d.queue, initialOwner: cfg.owner, initialSequencer: cfg.sequencer },
    );
    deploy_one(provider, deployer, nonce + 2, inbox, d.inbox, "BatchInbox").await?;
    let oracle = creation_code(
        &artifacts.oracle,
        &Constructors::outputOracleCall {
            inbox: d.inbox,
            disputeGame: d.game,
            genesisStateRoot: cfg.genesis_state_root,
            proposerBond: cfg.proposer_bond,
            challengeWindow: cfg.challenge_window,
        },
    );
    deploy_one(provider, deployer, nonce + 3, oracle, d.oracle, "OutputOracle").await?;
    let game = creation_code(
        &artifacts.game,
        &Constructors::disputeGameCall {
            oracle: d.oracle,
            inbox: d.inbox,
            vm: d.one_step_vm,
            codeRoot: cfg.code_root,
            codeSize: cfg.code_size,
            maxDepth: cfg.max_depth,
            clock: cfg.clock,
            challengerBond: cfg.challenger_bond,
        },
    );
    deploy_one(provider, deployer, nonce + 4, game, d.game, "DisputeGame").await?;
    let bridge = creation_code(&artifacts.bridge, &Constructors::bridgeCall { queue: d.queue, oracle: d.oracle });
    deploy_one(provider, deployer, nonce + 5, bridge, d.bridge, "Bridge").await?;
    Ok(d)
}
