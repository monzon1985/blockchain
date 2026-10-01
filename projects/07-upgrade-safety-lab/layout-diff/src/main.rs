// SPDX-License-Identifier: MIT
//! Command-line entry point. Exit codes: 0 safe, 1 unsafe, 2 invalid input or usage.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand, ValueEnum};
use layout_diff::diff::namespaces_unchecked;
use layout_diff::erc7201::{erc7201_slot, hex_slot};
use layout_diff::{Allowance, Error, Layout, Report, SelectorSet, check_selectors, diff_layouts, lint_layout};

/// Storage-layout gate for upgradeable Solidity contracts.
#[derive(Parser)]
#[command(name = "layout-diff", version, about)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Clone, Copy, ValueEnum)]
enum Format {
    Text,
    Json,
}

#[derive(Subcommand)]
enum Command {
    /// Checks that NEW can replace OLD behind the same proxy (and lints NEW).
    Diff {
        /// Layout of the deployed implementation (forge storageLayout JSON or lab snapshot).
        old: PathBuf,
        /// Layout of the candidate implementation.
        new: PathBuf,
        /// Accept one reviewed error, as KIND:LABEL (repeatable). Unused allowances fail the check.
        #[arg(long = "allow", value_name = "KIND:LABEL")]
        allow: Vec<String>,
        /// Accept raw `forge inspect` input, which cannot show ERC-7201 namespaces (the report says so).
        #[arg(long)]
        sequential_only: bool,
        /// Output format.
        #[arg(long, value_enum, default_value = "text")]
        format: Format,
    },
    /// Checks ERC-7201 base slots, accessor placements and region overlaps of one layout.
    Lint {
        /// Layout to check.
        layout: PathBuf,
        /// Accept raw `forge inspect` input, which cannot show ERC-7201 namespaces (the report says so).
        #[arg(long)]
        sequential_only: bool,
        /// Output format.
        #[arg(long, value_enum, default_value = "text")]
        format: Format,
    },
    /// Detects selector collisions and duplicates across the facets of a diamond.
    Selectors {
        /// JSON file: {"sources": [{"name": ..., "selectors": {signature: selector}}]}.
        set: PathBuf,
        /// Output format.
        #[arg(long, value_enum, default_value = "text")]
        format: Format,
    },
    /// Prints the ERC-7201 base slot of each namespace id.
    Erc7201 {
        /// Namespace ids, e.g. openzeppelin.storage.Ownable.
        #[arg(required = true)]
        ids: Vec<String>,
    },
}

fn emit(report: &Report, format: Format) -> ExitCode {
    match format {
        Format::Text => print!("{}", report.render_text()),
        Format::Json => match serde_json::to_string_pretty(report) {
            Ok(json) => println!("{json}"),
            Err(e) => {
                eprintln!("error: cannot serialize the report: {e}");
                return ExitCode::from(2);
            }
        },
    }
    if report.safe {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}

/// Loads a layout; raw `forge inspect` input (no namespace information) needs `--sequential-only`, and then
/// carries a `namespaces-unchecked` warning into the report.
fn load(
    path: &std::path::Path,
    sequential_only: bool,
    warnings: &mut Vec<layout_diff::Finding>,
) -> Result<Layout, Error> {
    let layout = Layout::load(path)?;
    if !layout.namespaces_known {
        if !sequential_only {
            return Err(Error::NamespacesUnknown {
                path: path.display().to_string(),
            });
        }
        warnings.push(namespaces_unchecked(&layout));
    }
    Ok(layout)
}

fn run(cli: Cli) -> Result<ExitCode, Error> {
    match cli.command {
        Command::Diff {
            old,
            new,
            allow,
            sequential_only,
            format,
        } => {
            let allowances = allow
                .iter()
                .map(|a| Allowance::parse(a))
                .collect::<Result<Vec<_>, _>>()?;
            let mut findings = Vec::new();
            let old = load(&old, sequential_only, &mut findings)?;
            let new = load(&new, sequential_only, &mut findings)?;
            findings.extend(diff_layouts(&old, &new)?);
            let subject = format!("{} -> {}", old.name, new.name);
            Ok(emit(&Report::new("diff", &subject, findings, &allowances), format))
        }
        Command::Lint {
            layout,
            sequential_only,
            format,
        } => {
            let mut findings = Vec::new();
            let layout = load(&layout, sequential_only, &mut findings)?;
            findings.extend(lint_layout(&layout));
            Ok(emit(&Report::new("lint", &layout.name, findings, &[]), format))
        }
        Command::Selectors { set, format } => {
            let subject = set
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default();
            let findings = check_selectors(&SelectorSet::load(&set)?)?;
            Ok(emit(&Report::new("selectors", &subject, findings, &[]), format))
        }
        Command::Erc7201 { ids } => {
            for id in ids {
                println!("{}  {id}", hex_slot(erc7201_slot(&id)));
            }
            Ok(ExitCode::SUCCESS)
        }
    }
}

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::from(2)
        }
    }
}
