// SPDX-License-Identifier: MIT
//! `keeper` CLI.
//!
//! ```text
//! keeper scan --rpc-url http://127.0.0.1:<port> --engine 0x.. --market-id 0x..
//! KEEPER_KEYSTORE_PASSWORD=... keeper run --rpc-url .. --engine .. --liquidator .. --venue .. \
//!     --market-id .. --keystore ./keeper.json --eth-price-in-loan 2000000000000000000000
//! ```
//!
//! The signer is always loaded from an encrypted keystore; the password comes from the environment, never from a
//! command-line argument.

use std::path::PathBuf;
use std::time::Duration;

use alloy::primitives::{Address, B256, U256};
use alloy::providers::ProviderBuilder;
use alloy::signers::local::PrivateKeySigner;
use anyhow::Context;
use clap::{Args, Parser, Subcommand};
use keeper::{Keeper, KeeperConfig};
use risk_math::liquidation::position_health;
use tracing::{error, info};

#[derive(Debug, Parser)]
#[command(name = "keeper", version, about = "Liquidation keeper for the isolated lending engine")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Print every borrower's health factor once and exit (read-only, no signer).
    Scan(MarketArgs),
    /// Watch the market and liquidate unhealthy positions until Ctrl-C.
    Run(RunArgs),
}

#[derive(Debug, Args)]
struct MarketArgs {
    /// JSON-RPC endpoint.
    #[arg(long, env = "KEEPER_RPC_URL")]
    rpc_url: reqwest_url::Url,
    /// Lending engine address.
    #[arg(long)]
    engine: Address,
    /// Market id (`keccak256(abi.encode(marketParams))`).
    #[arg(long)]
    market_id: B256,
    /// First block to replay events from.
    #[arg(long, default_value_t = 0)]
    from_block: u64,
    /// Block span of each `eth_getLogs` query.
    #[arg(long, default_value_t = 5_000)]
    log_chunk_size: u64,
    /// Blocks behind the head after which events are treated as final (newer ones are re-read on every sync).
    #[arg(long, default_value_t = 3)]
    confirmations: u64,
}

#[derive(Debug, Args)]
struct RunArgs {
    #[command(flatten)]
    market: MarketArgs,
    /// `FlashLiquidator` owned by the keystore's account.
    #[arg(long)]
    liquidator: Address,
    /// Swap venue used to sell seized collateral.
    #[arg(long)]
    venue: Address,
    /// Encrypted JSON keystore of the keeper account (password in `KEEPER_KEYSTORE_PASSWORD`).
    #[arg(long)]
    keystore: PathBuf,
    /// Price of 1 ETH in loan-token base units, used to convert gas into profit terms.
    #[arg(long)]
    eth_price_in_loan: U256,
    /// Minimum profit after gas, in loan-token base units.
    #[arg(long, default_value = "0")]
    min_net_profit: U256,
    /// Flash-loan headroom over the simulated repayment, in basis points.
    #[arg(long, default_value_t = 50)]
    flash_buffer_bps: u64,
    /// Polling interval.
    #[arg(long, default_value_t = 2_000)]
    poll_interval_ms: u64,
    /// Seconds to wait for a liquidation's receipt before reporting the candidate as failed and moving on.
    #[arg(long, default_value_t = 60)]
    receipt_timeout_secs: u64,
}

mod reqwest_url {
    pub use alloy::transports::http::reqwest::Url;
}

fn config(market: &MarketArgs, liquidator: Address, venue: Address) -> KeeperConfig {
    KeeperConfig {
        engine: market.engine,
        liquidator,
        venue,
        market_id: market.market_id,
        eth_price_in_loan: U256::ZERO,
        min_net_profit: U256::ZERO,
        flash_buffer_bps: 50,
        log_chunk_size: market.log_chunk_size,
        from_block: market.from_block,
        confirmations: market.confirmations,
        receipt_timeout: Duration::from_secs(60),
    }
}

async fn scan(args: MarketArgs) -> anyhow::Result<()> {
    let provider = ProviderBuilder::new().connect_http(args.rpc_url.clone());
    let mut keeper = Keeper::new(provider, config(&args, Address::ZERO, Address::ZERO)).await?;
    let events = keeper.sync().await?;
    let snapshot = keeper.snapshot().await?;
    let lltv = keeper.market_params().lltv;
    println!("{events} events replayed; price {}", snapshot.price);
    for (borrower, position) in keeper.book().borrowers() {
        let health = position_health(position, &snapshot.market, snapshot.price, lltv)?;
        println!("{borrower}  collateral {}  shares {}  health {health}", position.collateral, position.borrow_shares);
    }
    Ok(())
}

async fn run(args: RunArgs) -> anyhow::Result<()> {
    let password = std::env::var("KEEPER_KEYSTORE_PASSWORD")
        .context("KEEPER_KEYSTORE_PASSWORD must hold the keystore password")?;
    let signer = PrivateKeySigner::decrypt_keystore(&args.keystore, password)
        .with_context(|| format!("decrypting {}", args.keystore.display()))?;
    info!(keeper = %signer.address(), "loaded keystore");
    let provider = ProviderBuilder::new().wallet(signer).connect_http(args.market.rpc_url.clone());

    let mut cfg = config(&args.market, args.liquidator, args.venue);
    cfg.eth_price_in_loan = args.eth_price_in_loan;
    cfg.min_net_profit = args.min_net_profit;
    cfg.flash_buffer_bps = args.flash_buffer_bps;
    cfg.receipt_timeout = Duration::from_secs(args.receipt_timeout_secs);
    let mut keeper = Keeper::new(provider, cfg).await?;

    let mut interval = tokio::time::interval(Duration::from_millis(args.poll_interval_ms));
    let mut liquidations = 0usize;
    // One shutdown future, polled both between ticks and while a tick runs, so Ctrl-C is never stuck behind an RPC
    // call. Abandoning a tick is safe: the book commits whole log chunks together with its block cursor, and a
    // transaction already sent is picked up from its events on the next start.
    let shutdown = tokio::signal::ctrl_c();
    tokio::pin!(shutdown);
    loop {
        tokio::select! {
            _ = &mut shutdown => {
                info!(liquidations, "shutting down");
                return Ok(());
            }
            _ = interval.tick() => {
                tokio::select! {
                    _ = &mut shutdown => {
                        info!(liquidations, "shutting down during a tick");
                        return Ok(());
                    }
                    result = keeper.tick() => match result {
                        Ok(report) => liquidations += report.executed.len(),
                        Err(e) => error!(error = %e, "tick failed; retrying next interval"),
                    },
                }
            }
        }
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();
    match Cli::parse().command {
        Command::Scan(args) => scan(args).await,
        Command::Run(args) => run(args).await,
    }
}
