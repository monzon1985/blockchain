// SPDX-License-Identifier: MIT
//! The README's fraud-proof demo, run with the real binaries against `anvil`: `rollup-cli deploy` (from an encrypted
//! keystore) writes the descriptor, the `sequencer`, `challenger` and a `--malicious` `proposer` run as child
//! processes configured only through environment variables and flags, and a user deposits and transfers through
//! `rollup-cli`. This covers what the in-process scenarios in `crates/e2e` cannot: key loading, descriptor loading
//! and its check against L1, the API bind, and argument wiring. Run with:
//!
//! ```text
//! (cd contracts && forge build) && cargo test -p rollup-node --features anvil --test binaries_e2e
//! ```
//!
//! Every child is killed through its own process handle (by PID) when the test ends, pass or fail.
#![cfg(feature = "anvil")]
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, missing_docs)]

use std::{
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    process::{Child, Command, Output, Stdio},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use alloy::{
    node_bindings::Anvil,
    primitives::{Address, B256, U256},
    signers::local::PrivateKeySigner,
};
use rollup_l1::{Outcome, Phase, ProposalStatus};
use rollup_node::{DeploymentFile, SequencerClient};

const TIMEOUT: Duration = Duration::from_secs(180);
const PASSWORD: &str = "correct horse battery staple";

/// A running binary; killed (by its process handle) and reaped on drop.
struct Proc {
    name: &'static str,
    child: Child,
    log: Arc<Mutex<Vec<String>>>,
}

impl Proc {
    fn log(&self) -> String {
        self.log.lock().unwrap().join("\n")
    }

    fn logged(&self, needle: &str) -> bool {
        self.log.lock().unwrap().iter().any(|l| l.contains(needle))
    }
}

impl Drop for Proc {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        if std::thread::panicking() {
            eprintln!("---- {} output ----\n{}", self.name, self.log());
        }
    }
}

/// Removes ANSI colour sequences (in case the subscriber colours its output).
fn plain(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            for d in chars.by_ref() {
                if d.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn command(bin: &str, args: &[&str], env: &[(&str, String)]) -> Command {
    let mut cmd = Command::new(bin);
    cmd.args(args).env("NO_COLOR", "1").env("RUST_LOG", "info");
    for (k, v) in env {
        cmd.env(k, v);
    }
    cmd
}

fn spawn(name: &'static str, bin: &str, args: &[&str], env: &[(&str, String)]) -> Proc {
    let mut child = command(bin, args, env).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().expect(name);
    let log = Arc::new(Mutex::new(Vec::new()));
    for stream in [
        Box::new(child.stdout.take().unwrap()) as Box<dyn std::io::Read + Send>,
        Box::new(child.stderr.take().unwrap()),
    ] {
        let log = Arc::clone(&log);
        std::thread::spawn(move || {
            for line in BufReader::new(stream).lines().map_while(Result::ok) {
                log.lock().unwrap().push(plain(&line));
            }
        });
    }
    Proc { name, child, log }
}

fn run(bin: &str, args: &[&str], env: &[(&str, String)]) -> Output {
    command(bin, args, env).output().expect("binary runs")
}

fn run_ok(bin: &str, args: &[&str], env: &[(&str, String)]) -> String {
    let out = run(bin, args, env);
    let (stdout, stderr) = (String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    assert!(out.status.success(), "{bin} {args:?} failed\nstdout: {stdout}\nstderr: {stderr}");
    stdout.into_owned()
}

async fn wait_until<F, Fut>(what: &str, mut check: F, procs: &[&Proc])
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let start = Instant::now();
    while !check().await {
        if start.elapsed() > TIMEOUT {
            for p in procs {
                eprintln!("---- {} ----\n{}", p.name, p.log());
            }
            panic!("timed out waiting for {what}");
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

fn eth(n: u64) -> U256 {
    U256::from(n) * U256::from(10u64).pow(U256::from(18u64))
}

#[tokio::test(flavor = "multi_thread")]
async fn readme_fraud_demo_with_the_real_binaries() {
    let anvil = Anvil::new().try_spawn().expect("anvil on PATH");
    let keys: Vec<B256> = anvil.keys().iter().map(|k| B256::from_slice(&k.to_bytes())).collect();
    let addr: Vec<Address> = anvil.addresses().to_vec();
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!("binaries-e2e-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let deployment = dir.join("deployment.json");

    // The deployer signs from an encrypted keystore; the services use anvil's raw dev keys from the environment.
    PrivateKeySigner::encrypt_keystore(&dir, &mut rand::thread_rng(), keys[0], PASSWORD, Some("deployer.json"))
        .unwrap();
    let keystore = dir.join("deployer.json");
    let hex = |k: B256| format!("{k:#x}");
    let env: Vec<(&str, String)> = vec![
        ("ROLLUP_RPC_URL", anvil.endpoint()),
        ("ROLLUP_DEPLOYMENT", deployment.display().to_string()),
        ("ROLLUP_KEYSTORE_PASSWORD", PASSWORD.to_owned()),
        ("SEQUENCER_KEY", hex(keys[1])),
        ("CHALLENGER_KEY", hex(keys[3])),
        ("PROPOSER_KEY", hex(keys[4])),
        ("USER_KEY", hex(keys[5])),
    ];
    let (cli, seq_bin) = (env!("CARGO_BIN_EXE_rollup-cli"), env!("CARGO_BIN_EXE_sequencer"));
    let (challenger_bin, proposer_bin) = (env!("CARGO_BIN_EXE_challenger"), env!("CARGO_BIN_EXE_proposer"));

    // Deploy: the descriptor lands where ROLLUP_DEPLOYMENT points, and the owner is the keystore's account.
    let out =
        run_ok(cli, &["deploy", "--keystore", keystore.to_str().unwrap(), "--sequencer", &addr[1].to_string()], &env);
    assert!(out.contains("deployment descriptor written to"), "{out}");
    let file = DeploymentFile::load(&deployment).unwrap();
    assert_eq!(file.config.owner, addr[0]);

    // A wrong keystore password is refused before anything touches L1.
    let bad = [("ROLLUP_KEYSTORE_PASSWORD", "wrong".to_owned())];
    let out = run(challenger_bin, &["--keystore", keystore.to_str().unwrap()], &[&env[..], &bad[..]].concat());
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("cannot decrypt keystore"));

    // Services.
    let sequencer = spawn("sequencer", seq_bin, &["--poll-ms", "100", "--batch-interval-ms", "300"], &env);
    let challenger = spawn("challenger", challenger_bin, &["--poll-ms", "100"], &env);
    let mut url = String::new();
    wait_until(
        "the sequencer API to bind",
        || {
            let found = sequencer.log.lock().unwrap().iter().find_map(|l| {
                l.split("addr=").nth(1).map(|rest| rest.split_whitespace().next().unwrap_or_default().to_owned())
            });
            if let Some(a) = found {
                url = format!("http://{a}");
            }
            std::future::ready(!url.is_empty())
        },
        &[&sequencer],
    )
    .await;
    let client = SequencerClient::new(url.clone());

    // A user deposits, then transfers through the API.
    let (alice, bob) = (addr[5], addr[6]);
    run_ok(cli, &["deposit", "--to", &alice.to_string(), "--amount", &eth(3).to_string()], &env);
    wait_until(
        "the deposit to reach L2",
        || async { client.account(alice).await.is_ok_and(|a| a.balance == eth(3)) },
        &[&sequencer],
    )
    .await;
    let out = run_ok(
        cli,
        &[
            "send",
            "--sequencer-url",
            &url,
            "--kind",
            "transfer",
            "--to",
            &bob.to_string(),
            "--amount",
            &eth(1).to_string(),
        ],
        &env,
    );
    assert!(out.contains("accepted"), "{out}");
    wait_until(
        "the transfer to execute",
        || async { client.account(bob).await.is_ok_and(|a| a.balance == eth(1)) },
        &[&sequencer],
    )
    .await;

    // The malicious proposer claims one fraudulent root; the challenger bisects it down to the forged step.
    let mallory = spawn("proposer", proposer_bin, &["--malicious", "--max-proposals", "1", "--poll-ms", "100"], &env);
    let provider = rollup_l1::read_provider(&anvil.endpoint()).unwrap();
    let contracts = file.contracts(provider);
    let procs = [&sequencer, &challenger, &mallory];
    wait_until(
        "the fraud to be proven on L1",
        || async {
            match contracts.game.getGame(U256::from(1)).call().await {
                Ok(g) => Phase::from_u8(g.phase) == Phase::Resolved,
                Err(_) => false,
            }
        },
        &procs,
    )
    .await;
    let g = contracts.game.getGame(U256::from(1)).call().await.unwrap();
    assert_eq!(Outcome::from_u8(g.outcome), Outcome::ChallengerWins);
    assert_eq!(g.moves, 2 * u16::from(file.config.max_depth) + 2, "full-depth bisection");
    let p = contracts.oracle.getProposal(g.proposalId).call().await.unwrap();
    assert_eq!((ProposalStatus::from_u8(p.status), p.proposer), (ProposalStatus::Invalidated, addr[4]));
    assert!(challenger.logged("invalid output detected; challenging"), "{}", challenger.log());
    // The challenger logs the step after its receipt arrives, which can be just after the game shows as resolved.
    wait_until(
        "the challenger to report its one-step proof",
        || std::future::ready(challenger.logged("executed one-step proof on L1")),
        &procs,
    )
    .await;

    // A service pointed at a descriptor that no longer matches L1 refuses to start.
    let mut stale = file.clone();
    stale.config.max_depth = 15;
    let stale_path = dir.join("stale.json");
    stale.save(&stale_path).unwrap();
    let stale_env = [("ROLLUP_DEPLOYMENT", stale_path.display().to_string())];
    let out = run(challenger_bin, &[], &[&env[..], &stale_env[..]].concat());
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("MAX_DEPTH"), "{}", String::from_utf8_lossy(&out.stderr));

    drop((mallory, challenger, sequencer));
    let _ = std::fs::remove_dir_all(Path::new(&dir));
}
