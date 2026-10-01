// SPDX-License-Identifier: MIT
//! Golden (insta) tests over layouts generated from real Solidity sources.
//!
//! The snapshots in `tests/fixtures/snapshots` are produced by `node scripts/check-layouts.mjs --write` from
//! `test/layout/fixtures/LayoutFixtures.sol` (deliberately broken upgrades) and from the lab's production contracts.
//! The gate re-generates them on every run and fails on drift, so these goldens always describe the current code.

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::path::{Path, PathBuf};

use layout_diff::{Allowance, Layout, Report, SelectorSet, check_selectors, diff_layouts, lint_layout};

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests").join("fixtures")
}

fn layout(contract: &str) -> Layout {
    Layout::load(&fixtures().join("snapshots").join(format!("{contract}.json"))).unwrap()
}

fn config() -> serde_json::Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("layouts.config.json");
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

fn diff(old: &str, new: &str, allow: &[String]) -> Report {
    let (o, n) = (layout(old), layout(new));
    let allowances: Vec<Allowance> = allow.iter().map(|a| Allowance::parse(a).unwrap()).collect();
    Report::new(
        "diff",
        &format!("{old} -> {new}"),
        diff_layouts(&o, &n).unwrap(),
        &allowances,
    )
}

fn kinds(report: &Report) -> Vec<&'static str> {
    let mut k: Vec<&'static str> = report
        .findings
        .iter()
        .filter(|f| f.severity == layout_diff::Severity::Error && !f.allowed)
        .map(|f| f.kind.as_str())
        .collect();
    k.dedup();
    k
}

/// The deliberately broken layouts: every one must be rejected, with a stable, reviewed explanation.
const BROKEN: [(&str, &str, &str); 11] = [
    ("reorder", "ReorderOld", "ReorderNew"),
    ("removed", "RemovedOld", "RemovedNew"),
    ("type-changed", "RetypedOld", "RetypedNew"),
    ("inserted-before", "InsertedOld", "InsertedNew"),
    ("gap-shrunk", "GapChildOld", "GapChildNew"),
    ("namespace-reordered", "VaultOld", "VaultReordered"),
    ("erc7201-miscomputed", "VaultOld", "VaultMiscomputed"),
    ("erc7201-collision", "VaultOld", "VaultWithRewards"),
    ("sequential-to-namespace", "OwnedSequentialOld", "OwnedNamespacedNew"),
    ("library-namespace", "VaultOld", "VaultWithFeeLibrary"),
    ("accessor-unresolved", "VaultOld", "VaultComputed"),
];

fn check_broken(name: &str) {
    let (_, old, new) = BROKEN.iter().find(|(n, _, _)| *n == name).copied().unwrap();
    let report = diff(old, new, &[]);
    assert!(!report.safe, "{name} must be unsafe");
    insta::assert_snapshot!(format!("broken__{name}"), report.render_text());
}

macro_rules! broken {
    ($($test:ident => $name:literal),* $(,)?) => {
        $(
            #[test]
            fn $test() {
                check_broken($name);
            }
        )*
    };
}

broken! {
    broken_01_reorder => "reorder",
    broken_02_removed => "removed",
    broken_03_type_changed => "type-changed",
    broken_04_inserted_before => "inserted-before",
    broken_05_gap_shrunk => "gap-shrunk",
    broken_06_namespace_reordered => "namespace-reordered",
    broken_07_erc7201_miscomputed => "erc7201-miscomputed",
    broken_08_erc7201_collision => "erc7201-collision",
    broken_09_sequential_to_namespace => "sequential-to-namespace",
    broken_10_library_namespace => "library-namespace",
    broken_11_accessor_unresolved => "accessor-unresolved",
}

#[test]
fn naive_v4_to_v5_upgrade_is_rejected() {
    // The lab's own V1 (OZ 4.9.6) straight to V2 (OZ 5.7.0): the OpenZeppelin issue #6362 failure class.
    let report = diff("SubscriptionRegistryV1", "SubscriptionRegistryV2", &[]);
    assert!(!report.safe);
    assert_eq!(kinds(&report), vec!["moved-to-namespace"]);
    let labels: Vec<&str> = report
        .findings
        .iter()
        .filter(|f| f.kind.as_str() == "moved-to-namespace")
        .map(|f| f.label.as_str())
        .collect();
    assert_eq!(labels, vec!["_initialized", "_initializing", "_owner"]);
    insta::assert_snapshot!("real__naive_v1_to_v2", report.render_text());
}

#[test]
fn the_supported_lineage_is_safe_with_its_reviewed_allowances() {
    let cfg = config();
    let chain = &cfg["chains"][0];
    let versions: Vec<&str> = chain["versions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    for pair in versions.windows(2) {
        let allow: Vec<String> = chain["allow"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|a| a["old"] == pair[0] && a["new"] == pair[1])
            .map(|a| a["finding"].as_str().unwrap().to_owned())
            .collect();
        let report = diff(pair[0], pair[1], &allow);
        assert!(report.safe, "{} -> {}:\n{}", pair[0], pair[1], report.render_text());
        insta::assert_snapshot!(format!("real__{}_to_{}", pair[0], pair[1]), report.render_text());
    }
}

#[test]
fn the_bridge_step_is_unsafe_without_its_allowances() {
    let report = diff("SubscriptionRegistryV1", "SubscriptionRegistryBridge", &[]);
    assert!(!report.safe);
    assert_eq!(kinds(&report), vec!["moved-to-namespace"]);
}

#[test]
fn safe_controls_pass() {
    for (name, old, new) in [
        ("gap-consumed", "GapChildOld", "GapChildSafe"),
        ("namespace-appended", "VaultOld", "VaultAppended"),
    ] {
        let report = diff(old, new, &[]);
        assert!(report.safe, "{name}:\n{}", report.render_text());
        insta::assert_snapshot!(format!("safe__{name}"), report.render_text());
    }
}

#[test]
fn every_lab_accessor_is_resolved_and_at_its_erc7201_slot() {
    // The production accessors (OpenZeppelin's private constants included) read from the AST by the driver: none
    // may be unresolved, and lint (above and in the gate) checks each one against the formula.
    for contract in [
        "SubscriptionRegistryBridge",
        "SubscriptionRegistryV2",
        "SubscriptionRegistryV3",
        "RegistryDiamond",
    ] {
        let layout = layout(contract);
        for ns in &layout.namespaces {
            assert!(!ns.accessors.is_empty(), "{contract}: {} has no accessor", ns.id);
            for accessor in &ns.accessors {
                assert_eq!(
                    accessor.slot,
                    layout_diff::layout::AccessorSlot::Resolved(layout_diff::erc7201::erc7201_slot(&ns.id)),
                    "{contract}: {}",
                    accessor.function
                );
            }
        }
    }
}

#[test]
fn diamond_namespaces_are_well_placed() {
    let diamond = layout("RegistryDiamond");
    assert_eq!(diamond.namespaces.len(), 3);
    let report = Report::new("lint", "RegistryDiamond", lint_layout(&diamond), &[]);
    assert!(report.safe);
    insta::assert_snapshot!("lint__diamond", report.render_text());
}

#[test]
fn every_lab_layout_lints_clean() {
    for contract in [
        "SubscriptionRegistryV1",
        "SubscriptionRegistryBridge",
        "SubscriptionRegistryV2",
        "SubscriptionRegistryV3",
    ] {
        let report = Report::new("lint", contract, lint_layout(&layout(contract)), &[]);
        assert!(report.safe, "{contract}:\n{}", report.render_text());
    }
}

#[test]
fn selector_sets() {
    for (name, expect_safe) in [
        ("registry-diamond", true),
        ("clash-4byte", false),
        ("clash-duplicate", false),
    ] {
        let set = SelectorSet::load(&fixtures().join("selectors").join(format!("{name}.json"))).unwrap();
        let report = Report::new("selectors", name, check_selectors(&set).unwrap(), &[]);
        assert_eq!(report.safe, expect_safe, "{name}:\n{}", report.render_text());
        insta::assert_snapshot!(format!("selectors__{name}"), report.render_text());
    }
}

#[test]
fn golden_cases_match_the_gate_configuration() {
    // The Node gate and these goldens must cover the same pairs.
    let cfg = config();
    let mut from_config: Vec<(String, String, String)> = cfg["mustFail"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|p| p["name"] != "naive-v4-to-v5")
        .map(|p| {
            (
                p["name"].as_str().unwrap().to_owned(),
                p["old"].as_str().unwrap().to_owned(),
                p["new"].as_str().unwrap().to_owned(),
            )
        })
        .collect();
    let mut here: Vec<(String, String, String)> = BROKEN
        .iter()
        .map(|(n, o, w)| ((*n).to_owned(), (*o).to_owned(), (*w).to_owned()))
        .collect();
    from_config.sort();
    here.sort();
    assert_eq!(from_config, here);
}
