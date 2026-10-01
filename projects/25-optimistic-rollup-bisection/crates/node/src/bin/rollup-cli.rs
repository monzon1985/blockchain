// SPDX-License-Identifier: MIT
//! Operator and user CLI: deploy the contracts, inspect the STF program, and act as a user (deposit, transfer,
//! force a transaction through L1, post a forced batch, finalize a withdrawal).

use std::path::PathBuf;

use alloy::{
    primitives::{Address, U256},
    providers::Provider,
};
use clap::{Parser, Subcommand};
use rollup_l1::Artifacts;
use rollup_node::{
    DeploymentFile, SequencerClient, cli::KeyArgs, config::DEFAULT_L2_CHAIN_ID, connect, devnet_config, init_tracing,
    util::send, wallet,
};
use rollup_stf::{Kind, Stf};

#[derive(Debug, Parser)]
#[command(version, about = "Minimal optimistic rollup: operator and user CLI")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Debug, clap::Args)]
struct L1Args {
    /// L1 JSON-RPC endpoint.
    #[arg(long, env = "ROLLUP_RPC_URL")]
    rpc_url: String,
    /// Deployment descriptor.
    #[arg(long, env = "ROLLUP_DEPLOYMENT", default_value = "deployment.json")]
    deployment: PathBuf,
    /// Environment variable holding the raw signing key (local devnets; see `--keystore`).
    #[arg(long, default_value = "USER_KEY")]
    key_env: String,
    #[command(flatten)]
    key: KeyArgs,
}

impl L1Args {
    fn signer(&self) -> anyhow::Result<alloy::signers::local::PrivateKeySigner> {
        self.key.signer(&self.key_env)
    }
}

#[derive(Debug, Subcommand)]
enum Cmd {
    /// Print the STF program's code root, size and (optionally) its disassembly.
    Program {
        /// L2 chain id (part of the signing domain).
        #[arg(long, default_value_t = DEFAULT_L2_CHAIN_ID)]
        l2_chain_id: u64,
        /// Print every instruction.
        #[arg(long)]
        disassemble: bool,
    },
    /// Deploy the six contracts with devnet parameters and write the deployment descriptor.
    Deploy {
        /// L1 JSON-RPC endpoint.
        #[arg(long, env = "ROLLUP_RPC_URL")]
        rpc_url: String,
        /// Output descriptor (the same variable the services read it from).
        #[arg(long, env = "ROLLUP_DEPLOYMENT", default_value = "deployment.json")]
        out: PathBuf,
        /// Environment variable holding the deployer's raw key, also the inbox owner (local devnets; see `--keystore`).
        #[arg(long, default_value = "DEPLOYER_KEY")]
        key_env: String,
        #[command(flatten)]
        key: KeyArgs,
        /// Sequencer address.
        #[arg(long)]
        sequencer: Address,
        /// L2 chain id.
        #[arg(long, default_value_t = DEFAULT_L2_CHAIN_ID)]
        l2_chain_id: u64,
        /// Foundry artifacts directory (default: contracts/out).
        #[arg(long)]
        artifacts: Option<PathBuf>,
        /// Challenge window in seconds.
        #[arg(long, default_value_t = 3_600)]
        challenge_window: u64,
        /// Chess-clock budget per party in seconds.
        #[arg(long, default_value_t = 1_800)]
        clock: u64,
    },
    /// Deposit ETH to an L2 account (through the bridge and the forced-inclusion queue).
    Deposit {
        #[command(flatten)]
        l1: L1Args,
        /// L2 recipient.
        #[arg(long)]
        to: Address,
        /// Amount in wei.
        #[arg(long)]
        amount: U256,
    },
    /// Sign an L2 transfer or withdrawal and send it to the sequencer.
    Send {
        /// Sequencer API base URL.
        #[arg(long)]
        sequencer_url: String,
        /// Deployment descriptor (for the chain id).
        #[arg(long, env = "ROLLUP_DEPLOYMENT", default_value = "deployment.json")]
        deployment: PathBuf,
        /// Environment variable holding the raw signing key (local devnets; see `--keystore`).
        #[arg(long, default_value = "USER_KEY")]
        key_env: String,
        #[command(flatten)]
        key: KeyArgs,
        /// `transfer` or `withdrawal`.
        #[arg(long, value_parser = ["transfer", "withdrawal"])]
        kind: String,
        /// Recipient (L2 account for transfers, L1 address for withdrawals).
        #[arg(long)]
        to: Address,
        /// Amount in wei.
        #[arg(long)]
        amount: U256,
        /// Sender nonce (default: fetched from the sequencer).
        #[arg(long)]
        nonce: Option<U256>,
    },
    /// Force an L2 transfer through the L1 queue (bypasses the sequencer).
    ForceTransfer {
        #[command(flatten)]
        l1: L1Args,
        /// L2 recipient.
        #[arg(long)]
        to: Address,
        /// Amount in wei.
        #[arg(long)]
        amount: U256,
    },
    /// Post a queue-only batch once a queue message is overdue (censorship escape hatch).
    ForceBatch {
        #[command(flatten)]
        l1: L1Args,
    },
    /// Pay out a withdrawal on L1 using a proof served by the sequencer.
    FinalizeWithdrawal {
        #[command(flatten)]
        l1: L1Args,
        /// Sequencer API base URL.
        #[arg(long)]
        sequencer_url: String,
        /// Finalized epoch to prove against.
        #[arg(long)]
        epoch: u64,
        /// Withdrawal id.
        #[arg(long)]
        id: u64,
    },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    init_tracing();
    match Cli::parse().cmd {
        Cmd::Program { l2_chain_id, disassemble } => {
            let stf = Stf::new(l2_chain_id);
            println!("code root:   {}", stf.program().code_root());
            println!("code size:   {} instructions", stf.program().code_size());
            println!("trace depth: {} (2^{} steps)", stf.max_depth(), stf.max_depth());
            if disassemble {
                print!("{}", stf.program().disassemble());
            }
        }
        Cmd::Deploy { rpc_url, out, key_env, key, sequencer, l2_chain_id, artifacts, challenge_window, clock } => {
            let signer = key.signer(&key_env)?;
            let deployer = signer.address();
            let provider = rollup_l1::provider(&rpc_url, signer)?;
            let artifacts = match artifacts {
                Some(dir) => Artifacts::load(&dir)?,
                None => Artifacts::load_default()?,
            };
            let mut config = devnet_config(deployer, sequencer, l2_chain_id);
            config.challenge_window = challenge_window;
            config.clock = clock;
            let deployment = rollup_l1::deploy(&provider, deployer, &artifacts, &config).await?;
            DeploymentFile { l2_chain_id, deployment, config }.save(&out)?;
            println!("{}", serde_json::to_string_pretty(&deployment)?);
            println!("deployment descriptor written to {}", out.display());
        }
        Cmd::Deposit { l1, to, amount } => {
            let file = DeploymentFile::load(&l1.deployment)?;
            let signer = l1.signer()?;
            let me = signer.address();
            let (_, contracts) = connect(&l1.rpc_url, &file, signer)?;
            let receipt = send(contracts.bridge.deposit(to).value(amount), me).await?;
            println!("deposit included in L1 tx {}", receipt.transaction_hash);
        }
        Cmd::Send { sequencer_url, deployment, key_env, key, kind, to, amount, nonce } => {
            let file = DeploymentFile::load(&deployment)?;
            let signer = key.signer(&key_env)?;
            let client = SequencerClient::new(sequencer_url);
            let nonce = match nonce {
                Some(n) => n,
                None => client.account(signer.address()).await?.nonce,
            };
            let kind = if kind == "transfer" { Kind::Transfer } else { Kind::Withdrawal };
            let record = wallet::sign_tx(&signer, kind, to, amount, nonce, file.stf()?.domain())?;
            println!("accepted, digest {}", client.submit(&record).await?);
        }
        Cmd::ForceTransfer { l1, to, amount } => {
            let file = DeploymentFile::load(&l1.deployment)?;
            let signer = l1.signer()?;
            let me = signer.address();
            let (_, contracts) = connect(&l1.rpc_url, &file, signer)?;
            let receipt = send(contracts.queue.forceTransfer(to, amount), me).await?;
            println!("forced transfer queued in L1 tx {}", receipt.transaction_hash);
        }
        Cmd::ForceBatch { l1 } => {
            let file = DeploymentFile::load(&l1.deployment)?;
            let signer = l1.signer()?;
            let me = signer.address();
            let (provider, contracts) = connect(&l1.rpc_url, &file, signer)?;
            let mut chain = file.verified_chain(&contracts).await?;
            let epoch = wallet::force_batch(&provider, &contracts, &mut chain, me).await?;
            println!("forced batch posted as epoch {epoch} (L1 block {})", provider.get_block_number().await?);
        }
        Cmd::FinalizeWithdrawal { l1, sequencer_url, epoch, id } => {
            let file = DeploymentFile::load(&l1.deployment)?;
            let signer = l1.signer()?;
            let me = signer.address();
            let (_, contracts) = connect(&l1.rpc_url, &file, signer)?;
            let proof = SequencerClient::new(sequencer_url).withdrawal_proof(epoch, id).await?;
            wallet::check_against_l1(&contracts, &proof).await?;
            wallet::finalize_withdrawal(&contracts, &proof, me).await?;
            println!(
                "withdrawal {id} paid: {} wei to {} (proved against epoch {})",
                proof.amount, proof.recipient, proof.epoch
            );
        }
    }
    Ok(())
}
