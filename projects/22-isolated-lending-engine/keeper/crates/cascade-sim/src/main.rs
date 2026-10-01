// SPDX-License-Identifier: MIT
//! `cascade-sim`: sweep LLTV x bonus cap and write `reports/`, or export the shared liquidation vectors.
//!
//! ```text
//! cascade-sim                    # full sweep (+ seed-stability re-runs) -> reports/risk-grid.csv + reports/RISK.md
//! cascade-sim --check            # the same, compared with the committed reports
//! cascade-sim --quick            # reduced sweep -> reports/risk-grid.quick.csv (golden file)
//! cascade-sim --quick --check    # reduced sweep on 1 and N threads, compare with the golden file
//! cascade-sim export-vectors     # -> test/vectors/liquidation-vectors.json
//! cascade-sim export-vectors --check
//! ```

use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{Context, bail};
use cascade_sim::config::SimConfig;
use cascade_sim::report::{render_csv, render_markdown};
use cascade_sim::sweep::{self, CellStats};
use cascade_sim::vectors;
use clap::{Parser, Subcommand};

const PROJECT_ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../..");

#[derive(Debug, Parser)]
#[command(name = "cascade-sim", version, about = "Liquidation-cascade risk simulator for the isolated lending engine")]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    /// Run the reduced grid whose output is the golden file `risk-grid.quick.csv`.
    #[arg(long)]
    quick: bool,

    /// Regenerate and compare with the committed files instead of writing them (exit code 1 on drift).
    #[arg(long)]
    check: bool,

    /// Directory of the reports (defaults to the project's `reports/`).
    #[arg(long)]
    out_dir: Option<PathBuf>,

    /// Worker threads.
    #[arg(long, default_value_t = 4)]
    threads: usize,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Write the 100 health/liquidation vectors replayed by `test/vectors/HealthVectors.t.sol`.
    ExportVectors {
        /// Output file (defaults to the project's `test/vectors/liquidation-vectors.json`).
        #[arg(long)]
        out: Option<PathBuf>,
        /// Compare with the existing file instead of writing it.
        #[arg(long)]
        check: bool,
        /// Generator seed.
        #[arg(long, default_value_t = vectors::DEFAULT_SEED)]
        seed: u64,
    },
}

fn run_sweep(config: &SimConfig, threads: usize) -> anyhow::Result<Vec<CellStats>> {
    let pool = rayon::ThreadPoolBuilder::new().num_threads(threads.max(1)).build()?;
    Ok(pool.install(|| sweep::run(config)))
}

fn compare(path: &Path, fresh: &str) -> anyhow::Result<()> {
    let committed = std::fs::read_to_string(path)
        .with_context(|| format!("reading {} (generate it without --check first)", path.display()))?
        .replace("\r\n", "\n");
    if committed == fresh {
        return Ok(());
    }
    let first_diff = committed
        .lines()
        .zip(fresh.lines())
        .position(|(a, b)| a != b)
        .unwrap_or_else(|| committed.lines().count().min(fresh.lines().count()));
    bail!(
        "{} is out of date (first difference at line {}):\n  committed: {}\n  generated: {}",
        path.display(),
        first_diff + 1,
        committed.lines().nth(first_diff).unwrap_or("<eof>"),
        fresh.lines().nth(first_diff).unwrap_or("<eof>")
    )
}

fn write(path: &Path, contents: &str) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, contents).with_context(|| format!("writing {}", path.display()))?;
    println!("wrote {}", path.display());
    Ok(())
}

fn sweep_command(cli: &Cli) -> anyhow::Result<()> {
    let out_dir = cli.out_dir.clone().unwrap_or_else(|| Path::new(PROJECT_ROOT).join("reports"));
    let config = if cli.quick { SimConfig::quick() } else { SimConfig::full() };
    let started = Instant::now();
    let stats = run_sweep(&config, cli.threads)?;
    let csv = render_csv(&stats)?;
    let valid = stats.iter().filter(|s| s.valid).count();
    println!(
        "{} sweep: {} cells ({} valid) x {} paths x {} blocks in {:.1}s on {} threads",
        if cli.quick { "quick" } else { "full" },
        stats.len(),
        valid,
        config.paths,
        config.steps,
        started.elapsed().as_secs_f64(),
        cli.threads
    );

    if cli.quick {
        let golden = out_dir.join("risk-grid.quick.csv");
        if cli.check {
            let single = render_csv(&run_sweep(&config, 1)?)?;
            if single != csv {
                bail!("the sweep is not deterministic: 1 thread and {} threads disagree", cli.threads);
            }
            compare(&golden, &csv)?;
            println!("deterministic across 1 and {} threads; matches {}", cli.threads, golden.display());
        } else {
            write(&golden, &csv)?;
        }
    } else {
        let (recommended, _) = sweep::recommend(&config, &stats);
        let reseeded = Instant::now();
        let pool = rayon::ThreadPoolBuilder::new().num_threads(cli.threads.max(1)).build()?;
        let stability = pool.install(|| sweep::stability(&config, recommended));
        println!(
            "stability: {} more seeds in {:.1}s; same recommendation on {} of {}",
            stability.len(),
            reseeded.elapsed().as_secs_f64(),
            stability.iter().filter(|c| c.recommended == recommended).count() + 1,
            stability.len() + 1
        );
        let markdown = render_markdown(&config, &stats, &stability);
        let csv_path = out_dir.join("risk-grid.csv");
        let md_path = out_dir.join("RISK.md");
        if cli.check {
            compare(&csv_path, &csv)?;
            compare(&md_path, &markdown)?;
            println!("matches {} and {}", csv_path.display(), md_path.display());
        } else {
            write(&csv_path, &csv)?;
            write(&md_path, &markdown)?;
        }
    }
    Ok(())
}

fn export_vectors(out: Option<PathBuf>, check: bool, seed: u64) -> anyhow::Result<()> {
    let path = out.unwrap_or_else(|| Path::new(PROJECT_ROOT).join("test/vectors/liquidation-vectors.json"));
    let file = vectors::generate(seed)?;
    let json = vectors::render(&file)?;
    if check {
        compare(&path, &json)?;
        println!("{} vectors match {}", file.count, path.display());
    } else {
        write(&path, &json)?;
    }
    Ok(())
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Some(Command::ExportVectors { out, check, seed }) => export_vectors(out, check, seed),
        None => sweep_command(&cli),
    }
}
