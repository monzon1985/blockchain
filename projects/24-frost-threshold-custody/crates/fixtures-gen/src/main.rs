// SPDX-License-Identifier: MIT
//! `fixtures-gen [--check] [--out PATH]`
//!
//! Writes `contracts/test/fixtures/sigs.json` (or `PATH`). With `--check`, it
//! regenerates the fixtures in memory and exits non-zero if the file on disk
//! differs, so CI catches fixtures that drift from the Rust implementation.

use std::path::PathBuf;
use std::process::ExitCode;

fn default_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("contracts")
        .join("test")
        .join("fixtures")
        .join("sigs.json")
}

fn main() -> ExitCode {
    let mut check = false;
    let mut out = default_path();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--check" => check = true,
            "--out" => match args.next() {
                Some(path) => out = PathBuf::from(path),
                None => {
                    eprintln!("--out needs a path");
                    return ExitCode::from(2);
                }
            },
            other => {
                eprintln!("unknown argument {other}; usage: fixtures-gen [--check] [--out PATH]");
                return ExitCode::from(2);
            }
        }
    }
    let rendered = match fixtures_gen::render() {
        Ok(text) => text,
        Err(e) => {
            eprintln!("fixture generation failed: {e}");
            return ExitCode::FAILURE;
        }
    };
    if check {
        let on_disk = std::fs::read_to_string(&out)
            .unwrap_or_default()
            .replace("\r\n", "\n");
        if on_disk == rendered {
            eprintln!("fixtures up to date: {}", out.display());
            return ExitCode::SUCCESS;
        }
        let line = on_disk
            .lines()
            .zip(rendered.lines())
            .position(|(a, b)| a != b)
            .map_or_else(
                || on_disk.lines().count().min(rendered.lines().count()) + 1,
                |i| i + 1,
            );
        eprintln!(
            "fixtures drifted: {} differs from the generator output (first difference at line {line}); run `cargo run -p fixtures-gen`",
            out.display()
        );
        return ExitCode::FAILURE;
    }
    if let Some(parent) = out.parent()
        && let Err(e) = std::fs::create_dir_all(parent)
    {
        eprintln!("cannot create {}: {e}", parent.display());
        return ExitCode::FAILURE;
    }
    if let Err(e) = std::fs::write(&out, rendered) {
        eprintln!("cannot write {}: {e}", out.display());
        return ExitCode::FAILURE;
    }
    eprintln!("wrote {}", out.display());
    ExitCode::SUCCESS
}
