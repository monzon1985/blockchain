// SPDX-License-Identifier: MIT
//! `keysmith-relay`: the online half of Keysmith (prepare, broadcast, receipt).
//!
//! It never handles key material. Exit codes: 0 success, 1 error, 3 refused (the envelope
//! failed verification or targets another chain; nothing was sent), 4 mined but reverted.

use clap::{Args, Parser, Subcommand, ValueEnum};
use keysmith_core::authorization::SignedAuthorization;
use keysmith_core::envelope::{SelfAuthorization, SignedEnvelope};
use keysmith_core::tx::{AccessListItem, TxType};
use keysmith_core::units::parse_units;
use keysmith_core::{Address, U256, hex};
use keysmith_relay::{
    HttpTransport, PrepareRequest, RelayError, RpcClient, broadcast, prepare, wait_for_receipt,
};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

/// keysmith-relay: prepares unsigned envelopes from an RPC node and broadcasts signed ones.
///
/// This binary is the ONLINE half and never touches keys. Sign on the air-gapped machine
/// with `keysmith sign`.
#[derive(Debug, Parser)]
#[command(name = "keysmith-relay", bin_name = "keysmith-relay", version, about, long_about = None, max_term_width = 100)]
struct Cli {
    /// JSON-RPC endpoint (http:// or https://).
    #[arg(long, value_name = "URL", global = true)]
    rpc_url: Option<String>,
    /// Per-request timeout in seconds.
    #[arg(long, default_value_t = 30, global = true)]
    timeout_secs: u64,
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Build a keysmith/unsigned-tx@1 envelope from live chain state.
    Prepare(Box<PrepareArgs>),
    /// Verify a keysmith/signed-tx@1 envelope and submit it.
    Broadcast(BroadcastArgs),
    /// Print a transaction receipt.
    Receipt {
        /// Transaction hash.
        hash: String,
    },
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum TypeArg {
    Legacy,
    Eip2930,
    Eip1559,
    Eip7702,
}

impl From<TypeArg> for TxType {
    fn from(t: TypeArg) -> Self {
        match t {
            TypeArg::Legacy => TxType::Legacy,
            TypeArg::Eip2930 => TxType::Eip2930,
            TypeArg::Eip1559 => TxType::Eip1559,
            TypeArg::Eip7702 => TxType::Eip7702,
        }
    }
}

#[derive(Debug, Args)]
struct PrepareArgs {
    /// Transaction type.
    #[arg(long = "type", value_enum)]
    tx_type: TypeArg,
    /// Sender (the offline key's address).
    #[arg(long)]
    from: String,
    /// Recipient.
    #[arg(long, required_unless_present = "create", conflicts_with = "create")]
    to: Option<String>,
    /// Deploy a contract (`--data` is the initcode).
    #[arg(long)]
    create: bool,
    /// Value (wei, or with a unit: 1.5ether, 20gwei).
    #[arg(long, default_value = "0")]
    value: String,
    /// Calldata / initcode as 0x-hex.
    #[arg(long, default_value = "0x")]
    data: String,
    /// Nonce (default: pending nonce from the node).
    #[arg(long)]
    nonce: Option<u64>,
    /// Gas limit (default: eth_estimateGas; required for eip7702).
    #[arg(long)]
    gas_limit: Option<u64>,
    /// Legacy / EIP-2930 gas price (default: eth_gasPrice).
    #[arg(long)]
    gas_price: Option<String>,
    /// EIP-1559 / 7702 fee cap (default: 2 * baseFee + tip).
    #[arg(long)]
    max_fee: Option<String>,
    /// EIP-1559 / 7702 tip (default: eth_maxPriorityFeePerGas).
    #[arg(long)]
    priority_fee: Option<String>,
    /// JSON file with an EIP-2930 access list ([{"address": ..., "storageKeys": [...]}]).
    #[arg(long, value_name = "FILE")]
    access_list: Option<PathBuf>,
    /// An already-signed authorization (RLP hex from `keysmith sign-auth`); repeatable.
    #[arg(long = "auth", value_name = "RLP")]
    auths: Vec<String>,
    /// A delegation the sender signs offline for itself, as CHAIN_ID:ADDRESS; repeatable. The
    /// signer assigns nonces tx nonce + 1, + 2, ... in order, so only the last one stays in force.
    #[arg(long = "self-auth", value_name = "CHAIN_ID:ADDRESS")]
    self_auths: Vec<String>,
    /// Abort unless the node serves this chain id.
    #[arg(long)]
    chain_id: Option<u64>,
    /// Legacy only: omit the EIP-155 chain id (the result is replayable on every chain).
    #[arg(long)]
    no_replay_protection: bool,
    /// Free-form note for the offline operator. `keysmith sign` shows it escaped and labelled
    /// as untrusted text, never as a description of what is signed.
    #[arg(long)]
    note: Option<String>,
    /// Write the envelope here instead of stdout (refuses to overwrite).
    #[arg(long, value_name = "FILE")]
    out: Option<PathBuf>,
}

#[derive(Debug, Args)]
struct BroadcastArgs {
    /// Signed envelope (`-` for stdin).
    #[arg(long, value_name = "FILE")]
    envelope: PathBuf,
    /// Wait for the receipt and print it.
    #[arg(long)]
    wait: bool,
    /// How long --wait waits, in seconds.
    #[arg(long, default_value_t = 120)]
    wait_secs: u64,
}

enum Failure {
    Error(String),
    Refused(String),
    Reverted(String),
}

impl From<RelayError> for Failure {
    fn from(e: RelayError) -> Self {
        match e {
            RelayError::ChainMismatch { .. } | RelayError::Envelope(_) => {
                Failure::Refused(e.to_string())
            }
            other => Failure::Error(other.to_string()),
        }
    }
}

fn input_err(e: impl std::fmt::Display) -> Failure {
    Failure::Error(e.to_string())
}

fn read_input(path: &Path) -> Result<String, Failure> {
    if path.as_os_str() == "-" {
        let mut s = String::new();
        std::io::stdin()
            .read_to_string(&mut s)
            .map_err(|e| Failure::Error(format!("cannot read stdin: {e}")))?;
        return Ok(s);
    }
    std::fs::read_to_string(path)
        .map_err(|e| Failure::Error(format!("cannot read {}: {e}", path.display())))
}

fn wei_u128(s: &str, what: &str) -> Result<u128, Failure> {
    parse_units(s)
        .map_err(input_err)?
        .to_u128()
        .ok_or_else(|| Failure::Error(format!("{what} does not fit in 128 bits")))
}

fn parse_self_auth(s: &str) -> Result<SelfAuthorization, Failure> {
    let (chain, address) = s.split_once(':').ok_or_else(|| {
        Failure::Error(format!("--self-auth expects CHAIN_ID:ADDRESS, got `{s}`"))
    })?;
    Ok(SelfAuthorization {
        chain_id: U256::parse(chain).map_err(input_err)?,
        address: Address::parse(address).map_err(input_err)?,
    })
}

fn rpc(cli: &Cli) -> Result<RpcClient<HttpTransport>, Failure> {
    let url = cli
        .rpc_url
        .as_deref()
        .ok_or_else(|| Failure::Error("--rpc-url is required".into()))?;
    let transport = HttpTransport::new(url, Duration::from_secs(cli.timeout_secs))?;
    Ok(RpcClient::new(transport))
}

fn run_prepare(cli: &Cli, args: &PrepareArgs) -> Result<String, Failure> {
    let from = Address::parse(&args.from).map_err(input_err)?;
    let to = match &args.to {
        Some(t) => Some(Address::parse(t).map_err(input_err)?),
        None => None,
    };
    let mut req = PrepareRequest::new(args.tx_type.into(), from, to);
    req.value = parse_units(&args.value).map_err(input_err)?;
    req.input = hex::decode(&args.data).map_err(input_err)?;
    req.nonce = args.nonce;
    req.gas_limit = args.gas_limit;
    req.gas_price = args
        .gas_price
        .as_deref()
        .map(|v| wei_u128(v, "--gas-price"))
        .transpose()?;
    req.max_fee_per_gas = args
        .max_fee
        .as_deref()
        .map(|v| wei_u128(v, "--max-fee"))
        .transpose()?;
    req.max_priority_fee_per_gas = args
        .priority_fee
        .as_deref()
        .map(|v| wei_u128(v, "--priority-fee"))
        .transpose()?;
    if let Some(path) = &args.access_list {
        req.access_list = serde_json::from_str::<Vec<AccessListItem>>(&read_input(path)?)
            .map_err(|e| Failure::Error(format!("invalid access list: {e}")))?;
    }
    for rlp in &args.auths {
        let bytes = hex::decode(rlp).map_err(input_err)?;
        req.authorizations.push(
            SignedAuthorization::decode(&bytes)
                .map_err(|e| Failure::Error(format!("--auth: {e}")))?,
        );
    }
    req.self_authorizations = args
        .self_auths
        .iter()
        .map(|s| parse_self_auth(s))
        .collect::<Result<_, _>>()?;
    req.expected_chain_id = args.chain_id;
    req.replay_protected = !args.no_replay_protection;
    req.note = args.note.clone();
    let env = prepare(&rpc(cli)?, &req)?;
    let mut json = serde_json::to_string_pretty(&env).map_err(input_err)?;
    json.push('\n');
    match &args.out {
        Some(path) => {
            let mut f = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(path)
                .map_err(|e| Failure::Error(format!("cannot create {}: {e}", path.display())))?;
            f.write_all(json.as_bytes())
                .map_err(|e| Failure::Error(format!("cannot write {}: {e}", path.display())))?;
            Ok(format!("wrote {}\n", path.display()))
        }
        None => Ok(json),
    }
}

fn run_broadcast(cli: &Cli, args: &BroadcastArgs) -> Result<String, Failure> {
    let env =
        SignedEnvelope::from_json_str(&read_input(&args.envelope)?).map_err(RelayError::from)?;
    let rpc = rpc(cli)?;
    let out = broadcast(&rpc, &env)?;
    if out.chain_id.is_none() {
        eprintln!(
            "WARNING: pre-EIP-155 transaction: it is valid on every chain where the nonce matches."
        );
    }
    eprintln!(
        "sent {} transaction {} from {}",
        out.tx_type, out.hash, out.signer
    );
    if !args.wait {
        return Ok(format!("{}\n", out.hash));
    }
    let receipt = wait_for_receipt(
        &rpc,
        &out.hash,
        Duration::from_secs(args.wait_secs),
        Duration::from_millis(250),
    )?;
    let json = serde_json::to_string_pretty(&receipt).map_err(input_err)?;
    if receipt.status {
        Ok(format!("{json}\n"))
    } else {
        Err(Failure::Reverted(format!("transaction reverted:\n{json}")))
    }
}

fn run(cli: &Cli) -> Result<String, Failure> {
    match &cli.command {
        Command::Prepare(args) => run_prepare(cli, args),
        Command::Broadcast(args) => run_broadcast(cli, args),
        Command::Receipt { hash } => match rpc(cli)?.receipt(hash)? {
            Some(r) => Ok(format!(
                "{}\n",
                serde_json::to_string_pretty(&r).map_err(input_err)?
            )),
            None => Err(Failure::Error(format!(
                "no receipt for {hash} (pending or unknown)"
            ))),
        },
    }
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(&cli) {
        Ok(out) => {
            if std::io::stdout().lock().write_all(out.as_bytes()).is_err() {
                return ExitCode::from(1);
            }
            ExitCode::SUCCESS
        }
        Err(Failure::Error(e)) => {
            eprintln!("error: {e}");
            ExitCode::from(1)
        }
        Err(Failure::Refused(e)) => {
            eprintln!("REFUSED: {e}");
            ExitCode::from(3)
        }
        Err(Failure::Reverted(e)) => {
            eprintln!("error: {e}");
            ExitCode::from(4)
        }
    }
}
