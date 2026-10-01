// SPDX-License-Identifier: MIT
//! Challenger service.

use std::time::Duration;

use clap::Parser;
use rollup_node::{
    Challenger, ChallengerConfig, DeploymentFile,
    cli::{CommonArgs, KeyArgs, ctrl_c_shutdown},
    connect, init_tracing,
};

/// Re-derives every epoch from L1, disputes wrong outputs and plays the bisection to the one-step proof.
#[derive(Debug, Parser)]
#[command(version)]
struct Args {
    #[command(flatten)]
    common: CommonArgs,
    /// Environment variable holding the challenger's raw private key (local devnets; see `--keystore`).
    #[arg(long, default_value = "CHALLENGER_KEY")]
    key_env: String,
    #[command(flatten)]
    key: KeyArgs,
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
    let cfg = ChallengerConfig { poll: Duration::from_millis(args.common.poll_ms) };
    Challenger::new(provider, contracts, me, chain, cfg).run(ctrl_c_shutdown()).await?;
    Ok(())
}
