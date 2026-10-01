// SPDX-License-Identifier: MIT
//! # rollup-node
//!
//! The off-chain half of the rollup:
//!
//! - [`chain::Chain`] derives every epoch from L1 logs and executes it with the VM program;
//! - [`sequencer::Sequencer`] (+ [`api`]) orders signed transactions and posts batches;
//! - [`proposer::Proposer`] posts bonded output roots and defends them (or, with `malicious`, lies);
//! - [`challenger::Challenger`] disputes wrong outputs and plays the bisection down to one instruction.
//!
//! Each service is a plain async task driven by a `watch` shutdown signal, so the binaries in `src/bin` and the
//! end-to-end tests run exactly the same code.

pub mod api;
pub mod chain;
pub mod challenger;
pub mod cli;
pub mod client;
pub mod config;
pub mod error;
pub mod games;
pub mod proposer;
pub mod sequencer;
pub mod util;
pub mod wallet;

pub use chain::{Chain, WithdrawalProof};
pub use challenger::{Challenger, ChallengerConfig};
pub use client::SequencerClient;
pub use config::{DeploymentFile, connect, devnet_config};
pub use error::{NodeError, Result};
pub use proposer::{Proposer, ProposerConfig};
pub use sequencer::{Sequencer, SequencerConfig};

/// Installs a `tracing` subscriber honouring `RUST_LOG` (default `info`). Safe to call more than once.
pub fn init_tracing() {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
    let _ = tracing_subscriber::fmt().with_env_filter(filter).with_target(false).try_init();
}
