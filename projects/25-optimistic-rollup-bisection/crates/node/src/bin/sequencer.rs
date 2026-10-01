// SPDX-License-Identifier: MIT
//! Sequencer / batcher service.

use std::{net::SocketAddr, time::Duration};

use alloy::primitives::Address;
use clap::Parser;
use rollup_node::{
    DeploymentFile, Sequencer, SequencerConfig, api,
    cli::{CommonArgs, KeyArgs, ctrl_c_shutdown},
    connect, init_tracing,
};
use tokio::net::TcpListener;
use tracing::info;

/// Orders signed L2 transactions and posts batches to the L1 inbox.
#[derive(Debug, Parser)]
#[command(version)]
struct Args {
    #[command(flatten)]
    common: CommonArgs,
    /// Environment variable holding the sequencer's raw private key (local devnets; see `--keystore`).
    #[arg(long, default_value = "SEQUENCER_KEY")]
    key_env: String,
    #[command(flatten)]
    key: KeyArgs,
    /// HTTP API address; port 0 lets the OS pick a free port (printed at start-up).
    #[arg(long, default_value = "127.0.0.1:0")]
    http_addr: SocketAddr,
    /// Milliseconds between batch attempts.
    #[arg(long, default_value_t = 1_000)]
    batch_interval_ms: u64,
    /// Censor this address (repeatable): drop its transactions and stall its queue messages.
    #[arg(long)]
    censor: Vec<Address>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    init_tracing();
    let args = Args::parse();
    let file = DeploymentFile::load(&args.common.deployment)?;
    let signer = args.key.signer(&args.key_env)?;
    let me = signer.address();
    let (provider, contracts) = connect(&args.common.rpc_url, &file, signer)?;
    let sequencer = Sequencer::new(
        file.verified_chain(&contracts).await?,
        SequencerConfig { batch_interval: Duration::from_millis(args.batch_interval_ms), censor: args.censor },
    );
    let listener = TcpListener::bind(args.http_addr).await?;
    info!(addr = %listener.local_addr()?, "sequencer API listening");
    let shutdown = ctrl_c_shutdown();
    let server = tokio::spawn(api::serve(listener, sequencer.clone(), shutdown.clone()));
    sequencer.run(provider, contracts, me, shutdown).await?;
    server.await??;
    Ok(())
}
