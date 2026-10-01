// SPDX-License-Identifier: MIT
//! `cargo xtask check-airgap`: proves the signer path has no networking code.
//!
//! Three checks, all of which must pass:
//!
//! 1. **Dependency graph.** `cargo tree -e normal,build --target all` for `keysmith-core` and
//!    `keysmith-cli` must contain no crate from [`NETWORK_CRATES`] and no `tokio` with its `net`
//!    feature. Build dependencies are included because build scripts run on the signing machine.
//! 2. **Source scan.** No file under the signer crates' `src/` may reference `std::net` or socket
//!    types (a hand-rolled HTTP client would not show up in the dependency graph).
//! 3. **Positive control.** The same graph check run on `keysmith-relay` (the online half, which
//!    really does use HTTP) must report violations; otherwise the check itself is broken.

use std::path::Path;
use std::process::Command;

/// Crates that open sockets, speak network protocols or bundle a TLS stack.
pub const NETWORK_CRATES: &[&str] = &[
    "alloy-provider",
    "alloy-pubsub",
    "alloy-rpc-client",
    "alloy-transport",
    "alloy-transport-http",
    "alloy-transport-ipc",
    "alloy-transport-ws",
    "async-tungstenite",
    "attohttpc",
    "curl",
    "curl-sys",
    "ethers-providers",
    "h2",
    "h3",
    "hickory-resolver",
    "hyper",
    "hyper-rustls",
    "hyper-tls",
    "hyper-util",
    "isahc",
    "jsonrpsee",
    "keysmith-relay",
    "libp2p",
    "minreq",
    "mio",
    "native-tls",
    "openssl",
    "openssl-sys",
    "quinn",
    "reqwest",
    "rustls",
    "socket2",
    "surf",
    "tokio-native-tls",
    "tokio-rustls",
    "tokio-tungstenite",
    "trust-dns-resolver",
    "tungstenite",
    "ureq",
    "web3",
    "websocket",
];

/// Source patterns that indicate direct socket use.
pub const FORBIDDEN_SOURCE_PATTERNS: &[&str] = &[
    "std::net",
    "core::net",
    "TcpStream",
    "TcpListener",
    "UdpSocket",
    "UnixStream",
    "UnixListener",
    "ToSocketAddrs",
];

/// Crates whose code runs on the air-gapped machine.
pub const SIGNER_PATH: &[&str] = &["keysmith-core", "keysmith-cli"];

/// The online crate used as a positive control.
pub const CONTROL: &str = "keysmith-relay";

/// One package in a `cargo tree` listing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TreeEntry {
    /// Crate name.
    pub name: String,
    /// Enabled features.
    pub features: Vec<String>,
}

/// Parses `cargo tree --prefix none --format "{p}|{f}"` output.
pub fn parse_tree(output: &str) -> Vec<TreeEntry> {
    let mut out: Vec<TreeEntry> = Vec::new();
    for line in output.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let (pkg, features) = line.split_once('|').unwrap_or((line, ""));
        let Some(name) = pkg.split_whitespace().next() else {
            continue;
        };
        let features: Vec<String> = features
            .trim_end_matches("(*)")
            .split(',')
            .map(|f| f.trim().to_owned())
            .filter(|f| !f.is_empty())
            .collect();
        if !out.iter().any(|e| e.name == name && e.features == features) {
            out.push(TreeEntry {
                name: name.to_owned(),
                features,
            });
        }
    }
    out
}

/// Returns a description of every networking crate in `entries`.
pub fn violations(entries: &[TreeEntry]) -> Vec<String> {
    let mut found = Vec::new();
    for e in entries {
        if NETWORK_CRATES.contains(&e.name.as_str()) {
            found.push(e.name.clone());
        }
        if e.name == "tokio" && e.features.iter().any(|f| f == "net") {
            found.push("tokio[net]".to_owned());
        }
    }
    found.sort();
    found.dedup();
    found
}

/// Returns `(file, pattern)` for every forbidden pattern in `source`.
pub fn scan_source(file: &str, source: &str) -> Vec<(String, &'static str)> {
    FORBIDDEN_SOURCE_PATTERNS
        .iter()
        .filter(|p| source.contains(*p))
        .map(|p| (file.to_owned(), *p))
        .collect()
}

fn cargo_tree(root: &Path, package: &str) -> Result<Vec<TreeEntry>, String> {
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".to_owned());
    let output = Command::new(cargo)
        .current_dir(root)
        .args([
            "tree",
            "--locked",
            "-p",
            package,
            "-e",
            "normal,build",
            "--target",
            "all",
            "--prefix",
            "none",
            "--format",
            "{p}|{f}",
        ])
        .output()
        .map_err(|e| format!("cannot run cargo tree: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "cargo tree -p {package} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(parse_tree(&String::from_utf8_lossy(&output.stdout)))
}

fn rust_files(dir: &Path, out: &mut Vec<std::path::PathBuf>) -> Result<(), String> {
    let entries = std::fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    for entry in entries {
        let path = entry.map_err(|e| e.to_string())?.path();
        if path.is_dir() {
            rust_files(&path, out)?;
        } else if path.extension().is_some_and(|x| x == "rs") {
            out.push(path);
        }
    }
    Ok(())
}

/// Runs all three checks. Returns a human-readable report or the list of failures.
pub fn run(root: &Path) -> Result<String, String> {
    let mut report = String::new();
    let mut failures = Vec::new();
    for package in SIGNER_PATH {
        let entries = cargo_tree(root, package)?;
        let bad = violations(&entries);
        if bad.is_empty() {
            report.push_str(&format!(
                "ok   {package}: {} crates in the normal+build graph (all targets), no networking crate\n",
                entries.len()
            ));
        } else {
            failures.push(format!(
                "{package} depends on networking crates: {}",
                bad.join(", ")
            ));
        }
    }
    let mut files = Vec::new();
    for package in SIGNER_PATH {
        rust_files(&root.join("crates").join(package).join("src"), &mut files)?;
    }
    let mut hits = Vec::new();
    for file in &files {
        let source =
            std::fs::read_to_string(file).map_err(|e| format!("{}: {e}", file.display()))?;
        hits.extend(scan_source(&file.display().to_string(), &source));
    }
    if hits.is_empty() {
        report.push_str(&format!(
            "ok   source scan: {} files in the signer crates, no socket APIs\n",
            files.len()
        ));
    } else {
        for (file, pattern) in hits {
            failures.push(format!("{file} references `{pattern}`"));
        }
    }
    let control = violations(&cargo_tree(root, CONTROL)?);
    if control.is_empty() {
        failures.push(format!(
            "positive control failed: {CONTROL} shows no networking crate, so the check cannot detect one"
        ));
    } else {
        report.push_str(&format!(
            "ok   positive control: {CONTROL} is flagged ({})\n",
            control.join(", ")
        ));
    }
    if failures.is_empty() {
        Ok(report)
    } else {
        Err(failures.join("\n"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_cargo_tree_lines() {
        let out = "keysmith-cli v0.1.0 (C:\\x)|anvil-e2e\nclap v4.6.7|color,derive\ntokio v1.4.0|net,rt (*)\nclap v4.6.7|color,derive (*)\n";
        let entries = parse_tree(out);
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[2].name, "tokio");
        assert_eq!(entries[2].features, ["net", "rt"]);
    }

    #[test]
    fn flags_network_crates_and_tokio_net_only() {
        let clean = parse_tree("tokio v1|rt,macros\nk256 v0.13|ecdsa\n");
        assert!(violations(&clean).is_empty());
        let dirty = parse_tree("tokio v1|net\nureq v3|json\nrustls v0.23|ring\n");
        assert_eq!(violations(&dirty), ["rustls", "tokio[net]", "ureq"]);
    }

    #[test]
    fn source_scan_catches_raw_sockets() {
        assert!(scan_source("a.rs", "fn main() {}").is_empty());
        let hits = scan_source("b.rs", "use std::net::TcpStream;");
        assert_eq!(hits.len(), 2);
    }
}
