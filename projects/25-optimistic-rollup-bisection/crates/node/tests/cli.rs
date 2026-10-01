// SPDX-License-Identifier: MIT
//! Smoke tests of the four binaries (argument parsing, the offline `program` command, and start-up checks that fail
//! before any L1 access). `binaries_e2e.rs` runs them against anvil.
#![allow(clippy::unwrap_used, clippy::expect_used, missing_docs)]

use std::{path::PathBuf, process::Command};

use alloy::primitives::Address;
use rollup_l1::Deployment;
use rollup_node::{DeploymentFile, devnet_config};
use rollup_stf::Stf;

/// Runs a binary with a clean key environment; returns (success, stdout, stderr).
fn run(bin: &str, args: &[&str]) -> (bool, String, String) {
    let out = Command::new(bin)
        .args(args)
        .env_remove("ROLLUP_TEST_MISSING_KEY")
        .env_remove("ROLLUP_TEST_MISSING_PASSWORD")
        .env_remove("ROLLUP_DEPLOYMENT")
        .env_remove("ROLLUP_RPC_URL")
        .output()
        .expect("binary runs");
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

/// A well-formed descriptor (the services parse it before they read their key).
fn descriptor(name: &str) -> PathBuf {
    let path = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!("{name}-{}.json", std::process::id()));
    let deployment = Deployment {
        one_step_vm: Address::repeat_byte(1),
        queue: Address::repeat_byte(2),
        inbox: Address::repeat_byte(3),
        oracle: Address::repeat_byte(4),
        game: Address::repeat_byte(5),
        bridge: Address::repeat_byte(6),
        start_block: 0,
    };
    let config = devnet_config(Address::repeat_byte(7), Address::repeat_byte(8), 901);
    DeploymentFile { l2_chain_id: 901, deployment, config }.save(&path).unwrap();
    path
}

#[test]
fn program_command_prints_the_deployed_code_root() {
    let (ok, stdout, _) = run(env!("CARGO_BIN_EXE_rollup-cli"), &["program", "--disassemble"]);
    assert!(ok);
    let stf = Stf::new(901);
    assert!(stdout.contains(&stf.program().code_root().to_string()));
    assert!(stdout.contains(&format!("{} instructions", stf.program().code_size())));
    assert!(stdout.contains("ECRECOVER") && stdout.contains("SSTORE") && stdout.contains("HALT"));
}

#[test]
fn services_document_their_flags() {
    let (ok, help, _) = run(env!("CARGO_BIN_EXE_proposer"), &["--help"]);
    assert!(ok && help.contains("--malicious") && help.contains("--rpc-url") && help.contains("--keystore"));
    let (ok, help, _) = run(env!("CARGO_BIN_EXE_sequencer"), &["--help"]);
    assert!(ok && help.contains("--censor") && help.contains("--http-addr"));
    let (ok, help, _) = run(env!("CARGO_BIN_EXE_challenger"), &["--help"]);
    assert!(ok && help.contains("--key-env") && help.contains("--password-env"));
    let (ok, help, _) = run(env!("CARGO_BIN_EXE_rollup-cli"), &["deploy", "--help"]);
    assert!(ok && help.contains("ROLLUP_DEPLOYMENT"), "deploy --out follows ROLLUP_DEPLOYMENT: {help}");
}

#[test]
fn services_refuse_to_start_without_a_key() {
    // The descriptor is valid, so the only thing missing is the key; nothing reaches the (unreachable) RPC URL.
    let path = descriptor("missing-key");
    for bin in [env!("CARGO_BIN_EXE_challenger"), env!("CARGO_BIN_EXE_proposer"), env!("CARGO_BIN_EXE_sequencer")] {
        let (ok, _, stderr) = run(
            bin,
            &[
                "--rpc-url",
                "http://127.0.0.1:1",
                "--deployment",
                path.to_str().unwrap(),
                "--key-env",
                "ROLLUP_TEST_MISSING_KEY",
            ],
        );
        assert!(!ok);
        assert!(stderr.contains("environment variable ROLLUP_TEST_MISSING_KEY is not set"), "{bin}: {stderr}");
    }
}

#[test]
fn keystore_needs_its_password_variable() {
    let path = descriptor("missing-password");
    let (ok, _, stderr) = run(
        env!("CARGO_BIN_EXE_challenger"),
        &[
            "--rpc-url",
            "http://127.0.0.1:1",
            "--deployment",
            path.to_str().unwrap(),
            "--keystore",
            "does-not-matter.json",
            "--password-env",
            "ROLLUP_TEST_MISSING_PASSWORD",
        ],
    );
    assert!(!ok);
    assert!(
        stderr.contains("environment variable ROLLUP_TEST_MISSING_PASSWORD (keystore password) is not set"),
        "{stderr}"
    );
}

#[test]
fn a_missing_descriptor_is_named() {
    let (ok, _, stderr) = run(
        env!("CARGO_BIN_EXE_challenger"),
        &["--rpc-url", "http://127.0.0.1:1", "--deployment", "does-not-exist.json"],
    );
    assert!(!ok);
    assert!(stderr.contains("cannot read deployment descriptor does-not-exist.json"), "{stderr}");
}
