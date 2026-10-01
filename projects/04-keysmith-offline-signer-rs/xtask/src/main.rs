// SPDX-License-Identifier: MIT
//! Repository automation for Keysmith (`cargo xtask <task>`).
//!
//! * `check-airgap`: the signer path (`keysmith-core`, `keysmith-cli`) must not depend on any
//!   networking crate nor reference socket APIs; `keysmith-relay` serves as a positive control.
//! * `regen-golden [--check]`: regenerate (or verify) the golden vectors with Foundry's `cast`.
//! * `coverage <lcov.info> [--fail-under PCT]`: line coverage of production code, with inline
//!   `#[cfg(test)]` modules excluded.

mod airgap;
mod coverage;
mod golden;

use std::path::PathBuf;
use std::process::ExitCode;

fn project_root() -> PathBuf {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest.parent().map(PathBuf::from).unwrap_or(manifest)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let root = project_root();
    let result = match args.first().map(String::as_str) {
        Some("check-airgap") => airgap::run(&root),
        Some("regen-golden") => golden::run(&root, args.iter().any(|a| a == "--check")),
        Some("coverage") => coverage::run(&root, &args[1..]),
        _ => Err("usage: cargo xtask <check-airgap | regen-golden [--check] | coverage <lcov.info> [--fail-under PCT]>".to_owned()),
    };
    match result {
        Ok(report) => {
            print!("{report}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("xtask failed:\n{e}");
            ExitCode::FAILURE
        }
    }
}
