// SPDX-License-Identifier: MIT
//! `frost-custody`: run the threshold custody stack on one machine.
//!
//! * `demo`: coordinator and `n` participants in one process (loopback TCP,
//!   OS-assigned port): DKG, then threshold-sign one withdrawal; prints JSON.
//! * `roster`: generate a static roster file and one key file per party.
//! * `coordinator` / `participant`: the same flow with one OS process per
//!   party, configured from the roster and key files. The coordinator binds
//!   port 0 and publishes its address in `--addr-file` (deleting any stale
//!   file first and the file itself on exit); participants poll the file and
//!   re-read it whenever a connection attempt fails.
//!
//! Key shares live only in process memory: every command exits after one
//! signature and the group's shares are gone with it. The printed signature
//! is bound to the `--vault`/`--chain-id` domain given on the command line.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use alloy_primitives::{Address, U256};
use clap::{Args, Parser, Subcommand};
use custody_net::{
    cluster::LocalCluster,
    coordinator::{Coordinator, CoordinatorConfig},
    participant::{ParticipantConfig, SharedNode, spawn_shared},
};
use custody_protocol::{
    ParticipantId, Party,
    identity::{GeneratedRoster, KeyFile, Roster},
    intent::{CustodyAction, SignerPolicy, VaultDomain, WithdrawalIntent},
    keygen::{KeygenOutcome, group_key_bytes},
    node::ParticipantNode,
    signing::{SessionJournal, SignerState, SigningOutcome},
};
use frost_keccak::evm::EvmGroupKey;
use rand_core::OsRng;
use serde_json::json;
use tracing_subscriber::EnvFilter;

type Error = Box<dyn std::error::Error>;

#[derive(Parser)]
#[command(
    name = "frost-custody",
    version,
    about = "FROST threshold custody over authenticated local TCP"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

/// The vault domain the signers are pinned to.
#[derive(Args, Clone, Copy)]
struct DomainArgs {
    /// EIP-155 chain id of the vault.
    #[arg(long, default_value_t = 31_337)]
    chain_id: u64,
    /// Vault address.
    #[arg(long, default_value = "0x00000000000000000000000000000000F2057001")]
    vault: Address,
}

impl DomainArgs {
    fn domain(self) -> VaultDomain {
        VaultDomain {
            chain_id: self.chain_id,
            vault: self.vault,
        }
    }
}

/// The withdrawal to sign.
#[derive(Args, Clone)]
struct IntentArgs {
    /// Withdrawal recipient.
    #[arg(long, default_value = "0x000000000000000000000000000000000000bEEF")]
    to: Address,
    /// Amount in wei.
    #[arg(long, default_value = "1000000000000000000")]
    amount: U256,
    /// Vault nonce.
    #[arg(long, default_value_t = 1)]
    nonce: u64,
    /// Deadline (unix seconds).
    #[arg(long, default_value_t = 4_102_444_800)]
    deadline: u64,
}

impl IntentArgs {
    fn intent(&self) -> WithdrawalIntent {
        WithdrawalIntent {
            to: self.to,
            token: Address::ZERO,
            amount: self.amount,
            nonce: U256::from(self.nonce),
            deadline: U256::from(self.deadline),
        }
    }
}

#[derive(Subcommand)]
enum Command {
    /// Coordinator and participants in one process: DKG + threshold-sign one withdrawal.
    Demo {
        /// Number of participants.
        #[arg(long, default_value_t = 5)]
        participants: u16,
        /// Signing threshold.
        #[arg(long, default_value_t = 3)]
        threshold: u16,
        #[command(flatten)]
        domain: DomainArgs,
        #[command(flatten)]
        intent: IntentArgs,
    },
    /// Generate `roster.json` plus one key file per party (demo secrets: keep them out of git).
    Roster {
        /// Number of participants.
        #[arg(long, default_value_t = 5)]
        participants: u16,
        /// Output directory.
        #[arg(long)]
        out: PathBuf,
    },
    /// Run the coordinator: wait for every roster participant, run the DKG, sign one withdrawal.
    Coordinator {
        /// Roster file.
        #[arg(long)]
        roster: PathBuf,
        /// The coordinator's key file.
        #[arg(long)]
        key: PathBuf,
        /// Signing threshold.
        #[arg(long, default_value_t = 2)]
        threshold: u16,
        /// File the listening address (OS-assigned port) is written to.
        #[arg(long)]
        addr_file: PathBuf,
        /// Per-phase deadline in milliseconds.
        #[arg(long, default_value_t = 5_000)]
        phase_timeout_ms: u64,
        /// How long to wait for all participants to connect, in seconds.
        #[arg(long, default_value_t = 60)]
        connect_timeout_secs: u64,
        #[command(flatten)]
        domain: DomainArgs,
        #[command(flatten)]
        intent: IntentArgs,
    },
    /// Run one participant until the coordinator closes the connection.
    Participant {
        /// Roster file.
        #[arg(long)]
        roster: PathBuf,
        /// This participant's key file.
        #[arg(long)]
        key: PathBuf,
        /// File holding the coordinator's address (polled until it exists).
        #[arg(long)]
        addr_file: PathBuf,
        /// Optional durable session journal (nonce-reuse protection across restarts).
        #[arg(long)]
        journal: Option<PathBuf>,
        /// How long to keep waiting for a reachable coordinator, in seconds.
        #[arg(long, default_value_t = 60)]
        wait_secs: u64,
        #[command(flatten)]
        domain: DomainArgs,
    },
}

fn hex0x(bytes: &[u8]) -> String {
    format!("0x{}", hex::encode(bytes))
}

async fn dkg_and_sign(
    coordinator: &mut Coordinator,
    ids: &[ParticipantId],
    threshold: u16,
    domain: VaultDomain,
    intent: WithdrawalIntent,
) -> Result<serde_json::Value, Error> {
    let public = match coordinator.dkg(threshold, ids).await? {
        KeygenOutcome::Committed { public_key_package } => public_key_package,
        KeygenOutcome::Aborted(report) => return Err(format!("DKG aborted: {report:?}").into()),
    };
    let group_key = group_key_bytes(&public)?;
    let evm_key = EvmGroupKey::from_verifying_key(public.verifying_key())?;
    let action = CustodyAction::Withdrawal(intent.clone());
    let report = coordinator
        .sign_with_retry(group_key, action.clone(), domain)
        .await?;
    let SigningOutcome::Signed { evm, signers, .. } = report.outcome else {
        return Err(format!("signing failed: {:?}", report.outcome).into());
    };
    Ok(json!({
        "domain": domain,
        "groupKey": {
            "x": hex0x(&evm_key.x),
            "yParity": evm_key.y_parity,
            "compressed": hex0x(&group_key),
        },
        "threshold": threshold,
        "participants": ids.len(),
        "signers": signers,
        "failedAttempts": report.failed_attempts.len(),
        "intent": intent,
        "digest": hex0x(&action.signing_hash(&domain)),
        "signature": {
            "rAddr": hex0x(&evm.r_address),
            "z": hex0x(&evm.z),
        },
    }))
}

/// Deletes the published address file when the coordinator exits.
struct RemoveOnDrop(PathBuf);

impl Drop for RemoveOnDrop {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn remove_if_exists(path: &Path) -> Result<(), Error> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.into()),
    }
}

fn read_key_file(path: &Path) -> Result<KeyFile, Error> {
    Ok(serde_json::from_str(&std::fs::read_to_string(path)?)?)
}

fn write_roster(participants: u16, out: &Path) -> Result<(), Error> {
    let generated = GeneratedRoster::generate(participants, &mut OsRng)?;
    std::fs::create_dir_all(out)?;
    std::fs::write(out.join("roster.json"), generated.roster.to_json()? + "\n")?;
    let coordinator = generated.coordinator.to_key_file(Party::Coordinator);
    std::fs::write(
        out.join("coordinator.key.json"),
        serde_json::to_string_pretty(&coordinator)?,
    )?;
    for (id, keys) in &generated.participants {
        let file = keys.to_key_file(Party::Participant(*id));
        std::fs::write(
            out.join(format!("participant-{}.key.json", id.get())),
            serde_json::to_string_pretty(&file)?,
        )?;
    }
    eprintln!(
        "wrote roster and {} key files to {} (demo secrets: keep them out of version control)",
        participants + 1,
        out.display()
    );
    Ok(())
}

struct CoordinatorRun {
    roster: PathBuf,
    key: PathBuf,
    threshold: u16,
    addr_file: PathBuf,
    phase_timeout: Duration,
    connect_timeout: Duration,
    domain: VaultDomain,
    intent: WithdrawalIntent,
}

async fn run_coordinator(run: CoordinatorRun) -> Result<serde_json::Value, Error> {
    let CoordinatorRun {
        roster,
        key,
        threshold,
        addr_file,
        phase_timeout,
        connect_timeout,
        domain,
        intent,
    } = run;
    let roster = Roster::load(&roster)?;
    let key_file = read_key_file(&key)?;
    if key_file.party != Party::Coordinator {
        return Err("key file does not belong to the coordinator".into());
    }
    // A file left by an earlier run would point waiting participants at a
    // dead port; remove it before anyone can read it.
    remove_if_exists(&addr_file)?;
    let mut coordinator = Coordinator::bind(
        key_file.keys(),
        roster.clone(),
        CoordinatorConfig {
            phase_timeout,
            ..CoordinatorConfig::default()
        },
    )
    .await?;
    // Publish the OS-assigned address atomically (write, then rename), and
    // withdraw it on exit.
    let tmp = addr_file.with_extension("tmp");
    std::fs::write(&tmp, coordinator.local_addr().to_string())?;
    std::fs::rename(&tmp, &addr_file)?;
    let _published = RemoveOnDrop(addr_file.clone());
    let ids: Vec<ParticipantId> = roster.participant_ids().collect();
    coordinator.wait_for(&ids, connect_timeout).await?;
    let output = dkg_and_sign(&mut coordinator, &ids, threshold, domain, intent).await;
    coordinator.shutdown().await;
    output
}

async fn wait_for_addr(path: &Path, limit: Duration) -> Result<SocketAddr, Error> {
    let deadline = tokio::time::Instant::now() + limit;
    loop {
        if let Ok(text) = std::fs::read_to_string(path)
            && let Ok(addr) = text.trim().parse()
        {
            return Ok(addr);
        }
        if tokio::time::Instant::now() >= deadline {
            return Err(format!("{} did not appear", path.display()).into());
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

async fn run_participant(
    roster: &Path,
    key: &Path,
    addr_file: &Path,
    journal: Option<PathBuf>,
    wait: Duration,
    domain: VaultDomain,
) -> Result<(), Error> {
    let roster = Roster::load(roster)?;
    let key_file = read_key_file(key)?;
    let Party::Participant(id) = key_file.party else {
        return Err("key file does not belong to a participant".into());
    };
    let journal = match journal {
        Some(path) => SessionJournal::open(path)?,
        None => SessionJournal::in_memory(),
    };
    let node = ParticipantNode::new(
        id,
        key_file.keys(),
        roster,
        SignerState::new(SignerPolicy::permissive(domain), journal),
    )?;
    let node: SharedNode = Arc::new(Mutex::new(node));
    // The file may still name a previous coordinator's port: on any failure,
    // re-read it and try again until `wait` has elapsed.
    let deadline = tokio::time::Instant::now() + wait;
    let handle = loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let addr = wait_for_addr(addr_file, remaining).await?;
        let config = ParticipantConfig {
            connect_timeout: Duration::from_secs(1),
            ..ParticipantConfig::new(addr)
        };
        match spawn_shared(node.clone(), config).await {
            Ok(handle) => break handle,
            Err(e) if tokio::time::Instant::now() < deadline => {
                tracing::warn!(%addr, error = %e, "coordinator not reachable; re-reading the address file");
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
            Err(e) => return Err(e.into()),
        }
    };
    handle.join().await?;
    Ok(())
}

fn print_json(value: &serde_json::Value) -> Result<(), Error> {
    use std::io::Write;
    let text = serde_json::to_string_pretty(value)?;
    writeln!(std::io::stdout(), "{text}")?;
    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), Error> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("warn")),
        )
        .with_writer(std::io::stderr)
        .init();
    match Cli::parse().command {
        Command::Demo {
            participants,
            threshold,
            domain,
            intent,
        } => {
            let domain = domain.domain();
            let mut cluster =
                LocalCluster::start(participants, domain, Duration::from_secs(5)).await?;
            let ids = cluster.ids();
            let output = dkg_and_sign(
                &mut cluster.coordinator,
                &ids,
                threshold,
                domain,
                intent.intent(),
            )
            .await;
            cluster.shutdown().await?;
            print_json(&output?)
        }
        Command::Roster { participants, out } => write_roster(participants, &out),
        Command::Coordinator {
            roster,
            key,
            threshold,
            addr_file,
            phase_timeout_ms,
            connect_timeout_secs,
            domain,
            intent,
        } => {
            let output = run_coordinator(CoordinatorRun {
                roster,
                key,
                threshold,
                addr_file,
                phase_timeout: Duration::from_millis(phase_timeout_ms),
                connect_timeout: Duration::from_secs(connect_timeout_secs),
                domain: domain.domain(),
                intent: intent.intent(),
            })
            .await?;
            print_json(&output)
        }
        Command::Participant {
            roster,
            key,
            addr_file,
            journal,
            wait_secs,
            domain,
        } => {
            run_participant(
                &roster,
                &key,
                &addr_file,
                journal,
                Duration::from_secs(wait_secs),
                domain.domain(),
            )
            .await
        }
    }
}
