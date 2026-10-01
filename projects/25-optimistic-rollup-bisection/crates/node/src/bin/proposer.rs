// SPDX-License-Identifier: MIT
//! Output proposer service.

use std::time::Duration;

use clap::Parser;
use rollup_node::{
    DeploymentFile, Proposer, ProposerConfig,
    cli::{CommonArgs, KeyArgs, ctrl_c_shutdown},
    connect, init_tracing,
};

/// Proposes bonded output roots for derived epochs and defends them in disputes.
#[derive(Debug, Parser)]
#[command(version)]
struct Args {
    #[command(flatten)]
    common: CommonArgs,
    /// Environment variable holding the proposer's raw private key (local devnets; see `--keystore`).
    #[arg(long, default_value = "PROPOSER_KEY")]
    key_env: String,
    #[command(flatten)]
    key: KeyArgs,
    /// Claim fraudulent roots (mint 1,000 ETH to self half-way through each epoch) and defend them. For demos.
    #[arg(long)]
    malicious: bool,
    /// Do not propose beyond this epoch.
    #[arg(long)]
    max_epoch: Option<u64>,
    /// Stop proposing after this many proposals (keeps defending and finalizing).
    #[arg(long)]
    max_proposals: Option<u32>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    init_tracing();
    let args = Args::parse();
    let file = DeploymentFile::load(&args.common.deployment)?;
    let signer = args.key.signer(&args.key_env)?;
    let me = signer.address();
    let (provider, contracts) = connect(&args.common.rpc_url, &file, signer)?;
    let chain = file.verified_chain(&contracts).await?;
    let cfg = ProposerConfig {
        malicious: args.malicious,
        poll: Duration::from_millis(args.common.poll_ms),
        max_epoch: args.max_epoch,
        max_proposals: args.max_proposals,
    };
    Proposer::new(provider, contracts, me, chain, cfg).run(ctrl_c_shutdown()).await?;
    Ok(())
}
