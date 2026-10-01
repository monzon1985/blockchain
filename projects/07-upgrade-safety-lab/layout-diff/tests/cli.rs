// SPDX-License-Identifier: MIT
//! End-to-end tests of the binary: exit codes, output formats and the handling of raw `forge inspect` input.

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_layout-diff"))
}

fn fixture(rel: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(rel)
}

fn snapshot(contract: &str) -> PathBuf {
    fixture(&format!("snapshots/{contract}.json"))
}

fn run(args: &[&std::ffi::OsStr]) -> Output {
    bin().args(args).output().unwrap()
}

#[test]
fn exit_zero_for_a_safe_upgrade() {
    let out = run(&[
        "diff".as_ref(),
        snapshot("SubscriptionRegistryV2").as_os_str(),
        snapshot("SubscriptionRegistryV3").as_os_str(),
    ]);
    assert_eq!(out.status.code(), Some(0), "{}", String::from_utf8_lossy(&out.stdout));
    assert!(String::from_utf8_lossy(&out.stdout).contains("result: SAFE"));
}

#[test]
fn exit_one_for_an_unsafe_upgrade_with_json_output() {
    let out = run(&[
        "diff".as_ref(),
        snapshot("ReorderOld").as_os_str(),
        snapshot("ReorderNew").as_os_str(),
        "--format".as_ref(),
        "json".as_ref(),
    ]);
    assert_eq!(out.status.code(), Some(1));
    let report: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(report["safe"], false);
    assert_eq!(report["errors"], 2);
    assert_eq!(report["findings"][0]["kind"], "moved");
}

#[test]
fn allowances_accept_reviewed_errors_and_stale_ones_fail() {
    let v1 = snapshot("SubscriptionRegistryV1");
    let bridge = snapshot("SubscriptionRegistryBridge");
    let allowed = run(&[
        "diff".as_ref(),
        v1.as_os_str(),
        bridge.as_os_str(),
        "--allow".as_ref(),
        "moved-to-namespace:_initialized".as_ref(),
        "--allow".as_ref(),
        "moved-to-namespace:_initializing".as_ref(),
        "--allow".as_ref(),
        "moved-to-namespace:_owner".as_ref(),
    ]);
    assert_eq!(
        allowed.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&allowed.stdout)
    );

    let stale = run(&[
        "diff".as_ref(),
        snapshot("SubscriptionRegistryV2").as_os_str(),
        snapshot("SubscriptionRegistryV3").as_os_str(),
        "--allow".as_ref(),
        "removed:_owner".as_ref(),
    ]);
    assert_eq!(stale.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&stale.stdout).contains("unused allowance `removed:_owner`"));
}

#[test]
fn exit_two_for_bad_input() {
    let missing = run(&[
        "diff".as_ref(),
        fixture("nope.json").as_os_str(),
        fixture("nope.json").as_os_str(),
    ]);
    assert_eq!(missing.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&missing.stderr).contains("cannot read"));

    let bad_allow = run(&[
        "diff".as_ref(),
        snapshot("ReorderOld").as_os_str(),
        snapshot("ReorderOld").as_os_str(),
        "--allow".as_ref(),
        "whatever".as_ref(),
    ]);
    assert_eq!(bad_allow.status.code(), Some(2));

    let usage = run(&["frobnicate".as_ref()]);
    assert_eq!(usage.status.code(), Some(2));
}

#[test]
fn raw_forge_inspect_output_is_accepted_with_sequential_only_and_ast_ids_do_not_matter() {
    // A verbatim `forge inspect SubscriptionRegistryV1 storageLayout --json` (astIds and AST-id type keys)
    // against the normalized snapshot of the same contract: structurally identical, so no error and no change,
    // only the warning that raw input cannot show namespaces.
    let raw = fixture("raw/SubscriptionRegistryV1.forge-inspect.json");
    let out = run(&[
        "diff".as_ref(),
        raw.as_os_str(),
        snapshot("SubscriptionRegistryV1").as_os_str(),
        "--sequential-only".as_ref(),
        "--format".as_ref(),
        "json".as_ref(),
    ]);
    assert_eq!(out.status.code(), Some(0));
    let report: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    let findings = report["findings"].as_array().unwrap();
    assert_eq!(findings.len(), 1);
    assert_eq!(findings[0]["kind"], "namespaces-unchecked");
    assert_eq!(report["errors"], 0);
}

/// Regression test for the review finding: the README's single-pair example ran `diff` on raw `forge inspect`
/// output of V1 and V2, which cannot show namespaces, and reported the OZ #6362 pair as SAFE with exit code 0.
#[test]
fn raw_input_is_refused_without_an_explicit_flag() {
    let v1 = fixture("raw/SubscriptionRegistryV1.forge-inspect.json");
    let v2 = fixture("raw/SubscriptionRegistryV2.forge-inspect.json");
    let refused = run(&["diff".as_ref(), v1.as_os_str(), v2.as_os_str()]);
    assert_eq!(refused.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&refused.stderr);
    assert!(stderr.contains("raw `forge inspect storageLayout` output"), "{stderr}");
    assert!(stderr.contains("--sequential-only"), "{stderr}");

    let lint = run(&["lint".as_ref(), v2.as_os_str()]);
    assert_eq!(lint.status.code(), Some(2));

    // Opting in still never prints a plain SAFE: the verdict says what was not checked.
    let partial = run(&[
        "diff".as_ref(),
        v1.as_os_str(),
        v2.as_os_str(),
        "--sequential-only".as_ref(),
    ]);
    let stdout = String::from_utf8_lossy(&partial.stdout);
    assert!(stdout.contains("namespaces-unchecked"), "{stdout}");
    assert!(stdout.contains("ERC-7201 namespaces NOT checked"), "{stdout}");
}

/// The README's single-pair example as it now stands: the snapshots the gate builds expose the #6362 move.
#[test]
fn snapshots_expose_the_naive_migration() {
    let out = run(&[
        "diff".as_ref(),
        snapshot("SubscriptionRegistryV1").as_os_str(),
        snapshot("SubscriptionRegistryV2").as_os_str(),
    ]);
    assert_eq!(out.status.code(), Some(1));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("moved-to-namespace"), "{stdout}");
    assert!(stdout.contains("result: UNSAFE (3 errors"), "{stdout}");
}

#[test]
fn lint_and_selectors_subcommands() {
    let lint_bad = run(&["lint".as_ref(), snapshot("VaultMiscomputed").as_os_str()]);
    assert_eq!(lint_bad.status.code(), Some(1));
    let lint_ok = run(&["lint".as_ref(), snapshot("RegistryDiamond").as_os_str()]);
    assert_eq!(lint_ok.status.code(), Some(0));

    let clash = run(&["selectors".as_ref(), fixture("selectors/clash-4byte.json").as_os_str()]);
    assert_eq!(clash.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&clash.stdout).contains("0x42966c68"));
    let ok = run(&[
        "selectors".as_ref(),
        fixture("selectors/registry-diamond.json").as_os_str(),
    ]);
    assert_eq!(ok.status.code(), Some(0));
}

#[test]
fn erc7201_subcommand_prints_the_eip_example() {
    let out = run(&["erc7201".as_ref(), "example.main".as_ref()]);
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(
        String::from_utf8_lossy(&out.stdout).trim(),
        "0x183a6125c38840424c4a85fa12bab2ab606c4b6d0e7cc73c0c06ba5300eab500  example.main"
    );
}
