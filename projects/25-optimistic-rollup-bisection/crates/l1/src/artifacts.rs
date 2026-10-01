// SPDX-License-Identifier: MIT
//! Loading compiled contracts from Foundry's `contracts/out` directory.

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

use alloy::{json_abi::JsonAbi, primitives::Bytes};
use serde::Deserialize;

use crate::L1Error;

/// Environment variable overriding the artifacts directory.
pub const ARTIFACTS_ENV: &str = "ROLLUP_CONTRACTS_OUT";

/// Default `contracts/out`, resolved relative to this crate so tests work from any working directory.
pub fn default_out_dir() -> PathBuf {
    std::env::var_os(ARTIFACTS_ENV)
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("../../contracts/out"))
}

#[derive(Deserialize)]
struct RawBytecode {
    object: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawArtifact {
    bytecode: RawBytecode,
    deployed_bytecode: RawBytecode,
    #[serde(default)]
    method_identifiers: BTreeMap<String, String>,
    #[serde(default)]
    abi: JsonAbi,
}

/// A compiled contract.
#[derive(Debug, Clone)]
pub struct Artifact {
    /// Contract name.
    pub name: String,
    /// Creation bytecode (constructor arguments are appended at deployment).
    pub bytecode: Bytes,
    /// Runtime bytecode.
    pub deployed_bytecode: Bytes,
    /// `signature -> selector (hex, no 0x)`, as emitted by solc.
    pub method_identifiers: BTreeMap<String, String>,
    /// The compiled ABI (functions, events and errors, including inherited ones).
    pub abi: JsonAbi,
}

fn decode_hex(name: &str, s: &str) -> Result<Bytes, L1Error> {
    s.parse::<Bytes>().map_err(|e| L1Error::Artifact(format!("{name}: invalid bytecode hex: {e}")))
}

impl Artifact {
    /// Loads `<out>/<name>.sol/<name>.json`.
    ///
    /// # Errors
    /// [`L1Error::Artifact`] when the file is missing (run `forge build` in `contracts/`) or malformed.
    pub fn load(out_dir: &Path, name: &str) -> Result<Self, L1Error> {
        let path = out_dir.join(format!("{name}.sol")).join(format!("{name}.json"));
        let text = std::fs::read_to_string(&path).map_err(|e| {
            L1Error::Artifact(format!("{}: {e} (run `forge build` in contracts/ first)", path.display()))
        })?;
        let raw: RawArtifact =
            serde_json::from_str(&text).map_err(|e| L1Error::Artifact(format!("{}: {e}", path.display())))?;
        Ok(Self {
            name: name.to_owned(),
            bytecode: decode_hex(name, &raw.bytecode.object)?,
            deployed_bytecode: decode_hex(name, &raw.deployed_bytecode.object)?,
            method_identifiers: raw.method_identifiers,
            abi: raw.abi,
        })
    }
}

/// All contracts of the system.
#[derive(Debug, Clone)]
pub struct Artifacts {
    /// `OneStepVM`.
    pub one_step_vm: Artifact,
    /// `ForcedInclusionQueue`.
    pub queue: Artifact,
    /// `BatchInbox`.
    pub inbox: Artifact,
    /// `OutputOracle`.
    pub oracle: Artifact,
    /// `DisputeGame`.
    pub game: Artifact,
    /// `Bridge`.
    pub bridge: Artifact,
}

impl Artifacts {
    /// Loads every contract from `out_dir`.
    ///
    /// # Errors
    /// See [`Artifact::load`].
    pub fn load(out_dir: &Path) -> Result<Self, L1Error> {
        Ok(Self {
            one_step_vm: Artifact::load(out_dir, "OneStepVM")?,
            queue: Artifact::load(out_dir, "ForcedInclusionQueue")?,
            inbox: Artifact::load(out_dir, "BatchInbox")?,
            oracle: Artifact::load(out_dir, "OutputOracle")?,
            game: Artifact::load(out_dir, "DisputeGame")?,
            bridge: Artifact::load(out_dir, "Bridge")?,
        })
    }

    /// Loads from [`default_out_dir`].
    ///
    /// # Errors
    /// See [`Artifact::load`].
    pub fn load_default() -> Result<Self, L1Error> {
        Self::load(&default_out_dir())
    }
}
