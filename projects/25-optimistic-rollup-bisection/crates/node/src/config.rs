// SPDX-License-Identifier: MIT
//! Deployment descriptor shared by every service and the CLI.

use std::path::Path;

use alloy::{
    primitives::{Address, B256, U256},
    providers::DynProvider,
    signers::local::PrivateKeySigner,
};
use rollup_l1::{Contracts, DeployConfig, Deployment};
use rollup_stf::Stf;
use rollup_vm::SparseMerkleTree;
use serde::{Deserialize, Serialize};

use crate::chain::Chain;

/// Default L2 chain id (part of the signing domain, hence of the program's code root).
pub const DEFAULT_L2_CHAIN_ID: u64 = 901;

/// What a deployment writes to disk and what services read at start-up.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeploymentFile {
    /// L2 chain id the STF program was built for.
    pub l2_chain_id: u64,
    /// Contract addresses.
    pub deployment: Deployment,
    /// Parameters the contracts were deployed with.
    pub config: DeployConfig,
}

impl DeploymentFile {
    /// Reads a descriptor.
    ///
    /// # Errors
    /// I/O or JSON errors.
    pub fn load(path: &Path) -> anyhow::Result<Self> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| anyhow::anyhow!("cannot read deployment descriptor {}: {e}", path.display()))?;
        serde_json::from_str(&text)
            .map_err(|e| anyhow::anyhow!("malformed deployment descriptor {}: {e}", path.display()))
    }

    /// Writes a descriptor.
    ///
    /// # Errors
    /// I/O or JSON errors.
    pub fn save(&self, path: &Path) -> anyhow::Result<()> {
        std::fs::write(path, serde_json::to_string_pretty(self)?)?;
        Ok(())
    }

    /// The STF this descriptor describes: the locally built program for `l2_chain_id`, at `max_depth`, checked against
    /// the code root and size *recorded in the descriptor*. This is an offline consistency check only; services
    /// also call [`DeploymentFile::verify_on_l1`], which checks the descriptor against the deployed contracts.
    ///
    /// # Errors
    /// When the locally built program does not match the descriptor.
    pub fn stf(&self) -> anyhow::Result<Stf> {
        let stf = Stf::with_depth(self.l2_chain_id, self.config.max_depth);
        anyhow::ensure!(
            stf.program().code_root() == self.config.code_root && stf.program().code_size() == self.config.code_size,
            "the local STF program does not match the descriptor's code root; wrong l2ChainId or binary version"
        );
        Ok(stf)
    }

    /// Checks the descriptor and the local STF program against what the deployed contracts enforce:
    /// `DisputeGame.CODE_ROOT`, `CODE_SIZE` and `MAX_DEPTH`, and `OutputOracle.GENESIS_STATE_ROOT`, which must be the
    /// empty tree's root because derivation starts from an empty state. With a stale or edited descriptor every
    /// honest party would bisect a different program (or depth) than the game and lose on time, so services refuse to
    /// start instead.
    ///
    /// # Errors
    /// RPC failures (including addresses without the expected contracts) or any mismatch.
    pub async fn verify_on_l1(&self, contracts: &Contracts) -> anyhow::Result<Stf> {
        let stf = self.stf()?;
        let code_root = contracts.game.CODE_ROOT().call().await?;
        let code_size = contracts.game.CODE_SIZE().call().await?;
        let max_depth = contracts.game.MAX_DEPTH().call().await?;
        let genesis = contracts.oracle.GENESIS_STATE_ROOT().call().await?;
        anyhow::ensure!(
            code_root == stf.program().code_root() && code_size == stf.program().code_size(),
            "DisputeGame at {} runs program {code_root} ({code_size} instructions) but this binary builds {} ({}) for L2 chain {}; wrong deployment descriptor, l2ChainId or binary version",
            contracts.deployment.game,
            stf.program().code_root(),
            stf.program().code_size(),
            self.l2_chain_id
        );
        anyhow::ensure!(
            max_depth == stf.max_depth(),
            "DisputeGame MAX_DEPTH is {max_depth} but the descriptor says {}",
            stf.max_depth()
        );
        anyhow::ensure!(
            genesis == SparseMerkleTree::new().root(),
            "OutputOracle GENESIS_STATE_ROOT is {genesis}; derivation only supports the empty genesis state"
        );
        Ok(stf)
    }

    /// A fresh chain view scanning from the deployment block (descriptor checked offline only; see
    /// [`DeploymentFile::verified_chain`]).
    ///
    /// # Errors
    /// See [`DeploymentFile::stf`].
    pub fn chain(&self) -> anyhow::Result<Chain> {
        Ok(Chain::new(self.stf()?, self.deployment.start_block))
    }

    /// A fresh chain view after [`DeploymentFile::verify_on_l1`]: what every service starts from.
    ///
    /// # Errors
    /// See [`DeploymentFile::verify_on_l1`].
    pub async fn verified_chain(&self, contracts: &Contracts) -> anyhow::Result<Chain> {
        Ok(Chain::new(self.verify_on_l1(contracts).await?, self.deployment.start_block))
    }

    /// Contract handles bound to `provider`.
    pub fn contracts(&self, provider: DynProvider) -> Contracts {
        Contracts::new(self.deployment, provider)
    }
}

/// Default parameters for a local devnet: 1 ETH proposer bond, 0.5 ETH challenger bond, one-hour challenge window,
/// 30-minute chess clocks, 10-block inclusion window, 2^16-step traces.
pub fn devnet_config(owner: Address, sequencer: Address, l2_chain_id: u64) -> DeployConfig {
    let stf = Stf::new(l2_chain_id);
    DeployConfig {
        owner,
        sequencer,
        inclusion_window: 10,
        proposer_bond: U256::from(10u64).pow(U256::from(18u64)),
        challenger_bond: U256::from(5u64) * U256::from(10u64).pow(U256::from(17u64)),
        challenge_window: 3_600,
        clock: 1_800,
        max_depth: stf.max_depth(),
        genesis_state_root: B256::ZERO,
        code_root: stf.program().code_root(),
        code_size: stf.program().code_size(),
    }
}

/// Signing provider + contracts for a service.
///
/// # Errors
/// Malformed RPC URL.
pub fn connect(
    rpc_url: &str,
    file: &DeploymentFile,
    signer: PrivateKeySigner,
) -> anyhow::Result<(DynProvider, Contracts)> {
    let provider = rollup_l1::provider(rpc_url, signer)?;
    let contracts = file.contracts(provider.clone());
    Ok((provider, contracts))
}
