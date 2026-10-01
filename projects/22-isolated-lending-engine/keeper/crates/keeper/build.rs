// SPDX-License-Identifier: MIT
//! With the `anvil-e2e` feature, the end-to-end test embeds contract artifacts from Foundry's `out/` at compile
//! time. This script runs `forge build` in the project root first, so the test never compiles against missing or
//! stale artifacts (for example after `slither`, which rebuilds `out/` without the test mocks). Without the feature
//! it does nothing.

use std::error::Error;
use std::path::PathBuf;
use std::process::Command;

fn main() -> Result<(), Box<dyn Error>> {
    println!("cargo:rerun-if-env-changed=CARGO_FEATURE_ANVIL_E2E");
    if std::env::var_os("CARGO_FEATURE_ANVIL_E2E").is_none() {
        return Ok(());
    }

    let root = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR")?).join("../../..");
    for watched in ["src", "test/mocks", "foundry.toml"] {
        println!("cargo:rerun-if-changed={}", root.join(watched).display());
    }
    for artifact in [
        "out/LendingEngine.sol/LendingEngine.json",
        "out/AdaptiveCurveIrm.sol/AdaptiveCurveIrm.json",
        "out/FlashLiquidator.sol/FlashLiquidator.json",
        "out/MockERC20.sol/MockERC20.json",
        "out/MockOracle.sol/MockOracle.json",
        "out/MockSwapVenue.sol/MockSwapVenue.json",
    ] {
        println!("cargo:rerun-if-changed={}", root.join(artifact).display());
    }

    let status = Command::new("forge")
        .arg("build")
        .current_dir(&root)
        .status()
        .map_err(|e| format!("the anvil-e2e feature needs `forge` on PATH: {e}"))?;
    if !status.success() {
        return Err(format!("`forge build` failed with {status}").into());
    }
    Ok(())
}
