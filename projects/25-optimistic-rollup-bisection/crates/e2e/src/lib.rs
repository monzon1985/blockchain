// SPDX-License-Identifier: MIT
//! # e2e
//!
//! Harness for the end-to-end scenarios in `tests/`: spawns `anvil` on an OS-assigned port, deploys the six
//! contracts from `contracts/out`, checks the deployment descriptor against L1, and runs the sequencer, proposer and
//! challenger services (the same library code the binaries run) as tasks against it. The binaries themselves are
//! driven end to end by `crates/node/tests/binaries_e2e.rs`. Every process and task is stopped when its handle is
//! dropped (anvil is killed through its own child handle, never by image name).

use std::{future::Future, sync::Arc, time::Duration};

use alloy::{
    node_bindings::{Anvil, AnvilInstance},
    primitives::{Address, B256, U256},
    providers::{DynProvider, Provider, ext::AnvilApi},
    signers::local::PrivateKeySigner,
};
use rollup_l1::{Artifacts, Contracts};
use rollup_node::{
    Challenger, ChallengerConfig, DeploymentFile, Proposer, ProposerConfig, Sequencer, SequencerClient,
    SequencerConfig, api, devnet_config,
};
use tokio::{net::TcpListener, sync::watch, task::JoinHandle};

/// L2 chain id used by the scenarios.
pub const L2_CHAIN_ID: u64 = 901;
/// Challenge window used by the scenarios (seconds).
pub const CHALLENGE_WINDOW: u64 = 600;
/// Chess-clock budget used by the scenarios (seconds).
pub const CLOCK: u64 = 300;
/// Poll interval of the services.
pub const POLL: Duration = Duration::from_millis(100);

/// Anvil account indices.
pub mod accounts {
    /// Deployer and inbox owner.
    pub const DEPLOYER: usize = 0;
    /// Sequencer.
    pub const SEQUENCER: usize = 1;
    /// Honest proposer.
    pub const PROPOSER: usize = 2;
    /// Challenger.
    pub const CHALLENGER: usize = 3;
    /// Malicious proposer.
    pub const MALLORY: usize = 4;
    /// First user account (5..=9 are users).
    pub const ALICE: usize = 5;
    /// Second user.
    pub const BOB: usize = 6;
    /// Third user.
    pub const CAROL: usize = 7;
}

/// A running background service; stopped (and awaited) on [`ServiceHandle::stop`] or aborted on drop.
#[derive(Debug)]
pub struct ServiceHandle {
    stop: watch::Sender<bool>,
    tasks: Vec<JoinHandle<()>>,
}

impl ServiceHandle {
    /// Signals shutdown and waits for the tasks to exit.
    pub async fn stop(mut self) {
        let _ = self.stop.send(true);
        for t in self.tasks.drain(..) {
            let _ = t.await;
        }
    }
}

impl Drop for ServiceHandle {
    fn drop(&mut self) {
        let _ = self.stop.send(true);
        for t in &self.tasks {
            t.abort();
        }
    }
}

/// Sequencer handle with its API client.
#[derive(Debug)]
pub struct SequencerHandle {
    /// Client bound to the sequencer's OS-assigned port.
    pub client: SequencerClient,
    /// Service handle.
    pub service: ServiceHandle,
}

/// A local devnet.
#[derive(Debug)]
pub struct Devnet {
    /// The anvil process (killed on drop).
    pub anvil: AnvilInstance,
    /// Deployment descriptor.
    pub file: DeploymentFile,
    signers: Vec<PrivateKeySigner>,
}

fn spawn_logged<F>(name: &'static str, fut: F) -> JoinHandle<()>
where
    F: Future<Output = rollup_node::Result<()>> + Send + 'static,
{
    tokio::spawn(async move {
        if let Err(e) = fut.await {
            tracing::error!(service = name, error = %e, "service exited with an error");
        }
    })
}

impl Devnet {
    /// Spawns anvil and deploys the system with scenario parameters.
    ///
    /// # Errors
    /// Missing `anvil` binary, missing artifacts, or deployment failure.
    pub async fn start() -> anyhow::Result<Self> {
        rollup_node::init_tracing();
        let anvil = Anvil::new().try_spawn()?;
        let signers = anvil
            .keys()
            .iter()
            .map(|k| PrivateKeySigner::from_bytes(&B256::from_slice(&k.to_bytes())))
            .collect::<Result<Vec<_>, _>>()?;
        let deployer = signers[accounts::DEPLOYER].clone();
        let provider = rollup_l1::provider(&anvil.endpoint(), deployer.clone())?;
        let mut config = devnet_config(deployer.address(), signers[accounts::SEQUENCER].address(), L2_CHAIN_ID);
        config.challenge_window = CHALLENGE_WINDOW;
        config.clock = CLOCK;
        let deployment = rollup_l1::deploy(&provider, deployer.address(), &Artifacts::load_default()?, &config).await?;
        let file = DeploymentFile { l2_chain_id: L2_CHAIN_ID, deployment, config };
        // What every service binary does at start-up.
        file.verify_on_l1(&file.contracts(provider)).await?;
        Ok(Self { anvil, file, signers })
    }

    /// Signer of anvil account `i`.
    pub fn signer(&self, i: usize) -> PrivateKeySigner {
        self.signers[i].clone()
    }

    /// Address of anvil account `i`.
    pub fn address(&self, i: usize) -> Address {
        self.signers[i].address()
    }

    /// Provider and contracts signing as account `i`.
    ///
    /// # Errors
    /// Malformed endpoint (never for anvil).
    pub fn as_account(&self, i: usize) -> anyhow::Result<(DynProvider, Contracts)> {
        let provider = rollup_l1::provider(&self.anvil.endpoint(), self.signer(i))?;
        Ok((provider.clone(), self.file.contracts(provider)))
    }

    /// Starts the sequencer (optionally censoring some addresses) with its API on a free port.
    ///
    /// # Errors
    /// Bind or setup failure.
    pub async fn spawn_sequencer(&self, censor: Vec<Address>) -> anyhow::Result<SequencerHandle> {
        let (provider, contracts) = self.as_account(accounts::SEQUENCER)?;
        let me = self.address(accounts::SEQUENCER);
        let sequencer = Sequencer::new(self.file.chain()?, SequencerConfig { batch_interval: POLL * 3, censor });
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let url = format!("http://{}", listener.local_addr()?);
        let (stop, rx) = watch::channel(false);
        let api_task = {
            let (s, rx) = (Arc::clone(&sequencer), rx.clone());
            tokio::spawn(async move {
                let _ = api::serve(listener, s, rx).await;
            })
        };
        let loop_task = spawn_logged("sequencer", sequencer.run(provider, contracts, me, rx));
        Ok(SequencerHandle {
            client: SequencerClient::new(url),
            service: ServiceHandle { stop, tasks: vec![api_task, loop_task] },
        })
    }

    /// Starts a proposer as account `i`.
    ///
    /// # Errors
    /// Setup failure.
    pub fn spawn_proposer(&self, i: usize, malicious: bool, poll: Duration) -> anyhow::Result<ServiceHandle> {
        self.spawn_proposer_with(i, ProposerConfig { malicious, poll, max_epoch: None, max_proposals: None })
    }

    /// Starts a proposer as account `i` with a custom configuration.
    ///
    /// # Errors
    /// Setup failure.
    pub fn spawn_proposer_with(&self, i: usize, cfg: ProposerConfig) -> anyhow::Result<ServiceHandle> {
        let (provider, contracts) = self.as_account(i)?;
        let proposer = Proposer::new(provider, contracts, self.address(i), self.file.chain()?, cfg);
        let (stop, rx) = watch::channel(false);
        Ok(ServiceHandle { stop, tasks: vec![spawn_logged("proposer", proposer.run(rx))] })
    }

    /// Starts the challenger as account `i`.
    ///
    /// # Errors
    /// Setup failure.
    pub fn spawn_challenger(&self, i: usize) -> anyhow::Result<ServiceHandle> {
        let (provider, contracts) = self.as_account(i)?;
        let challenger =
            Challenger::new(provider, contracts, self.address(i), self.file.chain()?, ChallengerConfig { poll: POLL });
        let (stop, rx) = watch::channel(false);
        Ok(ServiceHandle { stop, tasks: vec![spawn_logged("challenger", challenger.run(rx))] })
    }

    /// Read-only contracts.
    ///
    /// # Errors
    /// Malformed endpoint (never for anvil).
    pub fn contracts(&self) -> anyhow::Result<Contracts> {
        Ok(self.as_account(accounts::DEPLOYER)?.1)
    }

    /// Moves L1 time forward by `secs` and mines a block.
    ///
    /// # Errors
    /// RPC failure.
    pub async fn warp(&self, secs: u64) -> anyhow::Result<()> {
        let (provider, _) = self.as_account(accounts::DEPLOYER)?;
        provider.anvil_increase_time(secs).await?;
        provider.anvil_mine(Some(1), None).await?;
        Ok(())
    }

    /// Sets the L1 balance of `who` (anvil cheat code).
    ///
    /// # Errors
    /// RPC failure.
    pub async fn set_balance(&self, who: Address, amount: U256) -> anyhow::Result<()> {
        let (provider, _) = self.as_account(accounts::DEPLOYER)?;
        provider.anvil_set_balance(who, amount).await?;
        Ok(())
    }

    /// Mines `n` empty blocks.
    ///
    /// # Errors
    /// RPC failure.
    pub async fn mine(&self, n: u64) -> anyhow::Result<()> {
        let (provider, _) = self.as_account(accounts::DEPLOYER)?;
        provider.anvil_mine(Some(n), None).await?;
        Ok(())
    }

    /// L1 balance of an address.
    ///
    /// # Errors
    /// RPC failure.
    pub async fn balance(&self, a: Address) -> anyhow::Result<U256> {
        let (provider, _) = self.as_account(accounts::DEPLOYER)?;
        Ok(provider.get_balance(a).await?)
    }
}

/// Polls `check` every 100 ms until it returns `Some`, failing after `timeout`.
///
/// # Errors
/// Timeout (the message names the condition) or an error from `check`.
pub async fn wait_for<T, F, Fut>(what: &str, timeout: Duration, mut check: F) -> anyhow::Result<T>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = anyhow::Result<Option<T>>>,
{
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if let Some(v) = check().await? {
            return Ok(v);
        }
        if tokio::time::Instant::now() >= deadline {
            anyhow::bail!("timed out after {timeout:?} waiting for: {what}");
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// One ether.
pub fn eth(n: u64) -> U256 {
    U256::from(n) * U256::from(10u64).pow(U256::from(18u64))
}
