// SPDX-License-Identifier: MIT
//! `cargo xtask check-airgap`: proves the signer path has no networking code.
//!
//! Three checks, all of which must pass:
//!
//! 1. **Dependency graph.** `cargo tree -e normal,build --target all --all-features` for
//!    `keysmith-core` and `keysmith-cli` must contain no crate from [`NETWORK_CRATES`] and no
//!    `tokio` with its `net` feature. Build dependencies are included because build scripts run
//!    on the signing machine, and every feature is enabled so that a networking dependency
//!    hidden behind an optional feature is still seen.
//! 2. **Source scan.** No file under the signer crates' `src/` may reference `std::net`, socket
//!    types, Unix sockets, FFI, or any `std::process` item other than [`ALLOWED_PROCESS_ITEMS`].
//!    A hand-rolled HTTP client would not show up in the dependency graph, and spawning `curl`
//!    or `ssh` would exfiltrate data without any networking crate.
//! 3. **Positive control.** The same graph check run on `keysmith-relay` (the online half, which
//!    really does use HTTP) must flag at least one **transitive** networking crate. The root
//!    package's own name does not count: `cargo tree -p` always lists it, so it would satisfy a
//!    weaker control even if the graph walk stopped reporting dependencies.

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

/// Source patterns that indicate socket use, process spawning or FFI.
pub const FORBIDDEN_SOURCE_PATTERNS: &[&str] = &[
    // Sockets.
    "std::net",
    "core::net",
    "TcpStream",
    "TcpListener",
    "UdpSocket",
    "UnixStream",
    "UnixListener",
    "UnixDatagram",
    "ToSocketAddrs",
    "os::unix::net",
    // Spawning another program (`curl`, `ssh`, `nc`, `powershell`) needs no networking crate.
    "Command::new",
    "os::unix::process",
    "os::windows::process",
    // FFI, e.g. a raw `socket(2)` call. Calling it would also need `unsafe`, which the
    // workspace lints forbid; these catch the declaration itself.
    "libc::",
    "extern \"",
    "#[link",
    "windows_sys",
    "winapi",
];

/// The only `std::process` items the signer may name. Any other `process::` path, including a
/// grouped import (`process::{...}`) or an alias, is reported, so `Command` cannot be smuggled
/// in as `use std::process::Command as Run`.
pub const ALLOWED_PROCESS_ITEMS: &[&str] = &["ExitCode", "exit"];

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

/// Returns `(file, pattern)` for every forbidden pattern in `source`, plus
/// `(file, "process::<item>")` for every `std::process` path naming anything other than
/// [`ALLOWED_PROCESS_ITEMS`].
pub fn scan_source(file: &str, source: &str) -> Vec<(String, String)> {
    let mut hits: Vec<(String, String)> = FORBIDDEN_SOURCE_PATTERNS
        .iter()
        .filter(|p| source.contains(*p))
        .map(|p| (file.to_owned(), (*p).to_owned()))
        .collect();
    for (at, matched) in source.match_indices("process::") {
        let rest = &source[at + matched.len()..];
        let item: String = rest
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
            .collect();
        if !ALLOWED_PROCESS_ITEMS.contains(&item.as_str()) {
            let shown = if item.is_empty() {
                rest.chars().take(1).collect::<String>()
            } else {
                item
            };
            hits.push((file.to_owned(), format!("process::{shown}")));
        }
    }
    hits.sort();
    hits.dedup();
    hits
}

/// Networking crates reported for the positive control, excluding the control package itself:
/// only crates the graph walk found **below** the root prove that it reports transitive
/// dependencies.
pub fn transitive_violations(entries: &[TreeEntry], root: &str) -> Vec<String> {
    let below_root: Vec<TreeEntry> = entries.iter().filter(|e| e.name != root).cloned().collect();
    violations(&below_root)
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
            "--all-features",
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
                "ok   {package}: {} crates in the normal+build graph (all targets, all features), no networking crate\n",
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
            "ok   source scan: {} files in the signer crates, no socket, process-spawning or FFI APIs\n",
            files.len()
        ));
    } else {
        for (file, pattern) in hits {
            failures.push(format!("{file} references `{pattern}`"));
        }
    }
    let control = transitive_violations(&cargo_tree(root, CONTROL)?, CONTROL);
    if control.is_empty() {
        failures.push(format!(
            "positive control failed: no networking crate was found below {CONTROL}, so the \
             graph walk cannot detect a transitive one"
        ));
    } else {
        report.push_str(&format!(
            "ok   positive control: {CONTROL} is flagged through its dependencies ({})\n",
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

    fn patterns(source: &str) -> Vec<String> {
        scan_source("x.rs", source)
            .into_iter()
            .map(|(_, p)| p)
            .collect()
    }

    #[test]
    fn source_scan_catches_raw_sockets() {
        assert!(scan_source("a.rs", "fn main() {}").is_empty());
        let hits = scan_source("b.rs", "use std::net::TcpStream;");
        assert_eq!(hits.len(), 2);
        assert_eq!(
            patterns("use std::os::unix::net::UnixDatagram;"),
            ["UnixDatagram", "os::unix::net"]
        );
    }

    /// Regression: the scan covered sockets only, so a signer that ran `curl` through
    /// `std::process::Command` passed both the graph check and the scan.
    #[test]
    fn source_scan_catches_process_spawning_and_ffi() {
        // Every spelling of "run another program" is caught, including aliases and groups.
        for src in [
            r#"std::process::Command::new("curl").arg(url).status();"#,
            "use std::process::Command;",
            "use std::process::{Command, ExitCode};",
            "use std::process::Command as Run;",
            "use std::process::Stdio;",
            "use std::os::unix::process::CommandExt;",
            "use std::os::windows::process::CommandExt;",
        ] {
            assert!(!scan_source("x.rs", src).is_empty(), "{src}");
        }
        assert_eq!(
            patterns(r#"std::process::Command::new("ssh")"#),
            ["Command::new", "process::Command"]
        );
        assert_eq!(patterns("use std::process::{ExitCode};"), ["process::{"]);
        // FFI declarations.
        assert_eq!(
            patterns(r#"extern "C" { fn socket(d: i32, t: i32, p: i32) -> i32; }"#),
            ["extern \""]
        );
        assert_eq!(patterns("let fd = libc::socket(2, 1, 0);"), ["libc::"]);
        assert_eq!(patterns("#[link(name = \"ws2_32\")]"), ["#[link"]);
        // What the signer legitimately uses stays allowed.
        for ok in [
            "use std::process::ExitCode;",
            "fn main() -> std::process::ExitCode { std::process::exit(3) }",
            "extern crate alloc;",
            "pub enum Command { Sign }",
            "Command::Sign(args) => run(args),",
        ] {
            assert!(scan_source("x.rs", ok).is_empty(), "{ok}");
        }
    }

    /// Regression: `keysmith-relay` is itself in [`NETWORK_CRATES`] and `cargo tree -p` always
    /// lists the root package, so the old control passed even if the graph walk had reported
    /// no dependency at all.
    #[test]
    fn positive_control_needs_a_transitive_crate() {
        let root_only = parse_tree("keysmith-relay v0.1.0 (C:\\x)|\n");
        assert_eq!(violations(&root_only), ["keysmith-relay"]);
        assert!(transitive_violations(&root_only, CONTROL).is_empty());
        let full = parse_tree(
            "keysmith-relay v0.1.0 (C:\\x)|\nureq v3.4.2|json,rustls\nrustls v0.23.45|ring\n",
        );
        assert_eq!(transitive_violations(&full, CONTROL), ["rustls", "ureq"]);
    }
}
