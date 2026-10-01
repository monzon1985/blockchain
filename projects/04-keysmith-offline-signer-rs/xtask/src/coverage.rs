// SPDX-License-Identifier: MIT
//! `cargo xtask coverage <lcov.info> [--fail-under PCT]`: line coverage of **production** code.
//!
//! `cargo llvm-cov` on stable instruments inline `#[cfg(test)] mod tests { ... }` modules like
//! any other code, and the unit tests execute almost all of their own lines, so the summary it
//! prints overstates how much production code is covered. This task reads the lcov export and
//! drops every line record that falls inside such a module before computing the percentage.
//!
//! A test module starts at a `#[cfg(test)]` line directly followed by `mod <name> {` and ends at
//! the next line that is exactly `}` at column 0 (the layout `cargo fmt --check`, which CI
//! enforces, guarantees). Files under a `tests/` directory and the xtask crate itself are
//! excluded entirely, as in the llvm-cov `--ignore-filename-regex`.

use std::path::Path;

/// One lcov line record: `DA:<line>,<hits>`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LineRecord {
    /// 1-based line number.
    pub line: usize,
    /// Execution count.
    pub hits: u64,
}

/// Line records of one source file (`SF:` ... `end_of_record`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileRecord {
    /// Source path as llvm-cov wrote it.
    pub path: String,
    /// Its `DA` records.
    pub lines: Vec<LineRecord>,
}

/// Parses the `SF` and `DA` records of an lcov file (everything else is ignored).
pub fn parse_lcov(text: &str) -> Result<Vec<FileRecord>, String> {
    let mut files = Vec::new();
    let mut current: Option<FileRecord> = None;
    for (n, raw) in text.lines().enumerate() {
        let line = raw.trim();
        if let Some(path) = line.strip_prefix("SF:") {
            current = Some(FileRecord {
                path: path.to_owned(),
                lines: Vec::new(),
            });
        } else if let Some(da) = line.strip_prefix("DA:") {
            let file = current
                .as_mut()
                .ok_or_else(|| format!("lcov line {}: DA outside a file record", n + 1))?;
            let mut parts = da.split(',');
            let parse = |p: Option<&str>| p.and_then(|s| s.trim().parse::<u64>().ok());
            let (Some(l), Some(hits)) = (parse(parts.next()), parse(parts.next())) else {
                return Err(format!("lcov line {}: malformed `{line}`", n + 1));
            };
            let line_no = usize::try_from(l).map_err(|e| e.to_string())?;
            file.lines.push(LineRecord {
                line: line_no,
                hits,
            });
        } else if line == "end_of_record"
            && let Some(file) = current.take()
        {
            files.push(file);
        }
    }
    Ok(files)
}

/// 1-based inclusive line ranges of the inline test modules in `source`.
pub fn test_module_ranges(source: &str) -> Vec<(usize, usize)> {
    let lines: Vec<&str> = source.lines().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let is_mod = lines
            .get(i + 1)
            .map(|l| l.trim_start())
            .is_some_and(|l| l.starts_with("mod ") && l.ends_with('{'));
        if lines[i].trim() == "#[cfg(test)]" && is_mod {
            let end = (i + 2..lines.len())
                .find(|&j| lines[j] == "}")
                .unwrap_or(lines.len() - 1);
            out.push((i + 1, end + 1));
            i = end + 1;
        } else {
            i += 1;
        }
    }
    out
}

fn excluded_file(path: &str) -> bool {
    let normalized = path.replace('\\', "/");
    normalized.contains("/tests/") || normalized.contains("/xtask/")
}

/// Totals for one lcov report.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Totals {
    /// Production lines with at least one hit.
    pub covered: usize,
    /// Production lines instrumented.
    pub total: usize,
    /// Instrumented lines dropped because they belong to inline test modules.
    pub test_lines: usize,
    /// Of those, the lines with at least one hit.
    pub test_covered: usize,
    /// Source files counted.
    pub files: usize,
}

impl Totals {
    /// Covered fraction in percent.
    pub fn percent(&self) -> f64 {
        pct(self.covered, self.total)
    }

    /// Covered fraction in percent counting the inline test modules too (what the llvm-cov
    /// summary measures), for comparison.
    pub fn percent_with_tests(&self) -> f64 {
        pct(
            self.covered + self.test_covered,
            self.total + self.test_lines,
        )
    }
}

fn pct(covered: usize, total: usize) -> f64 {
    if total == 0 {
        return 0.0;
    }
    // Line counts are far below 2^52, so the conversions are exact.
    100.0 * covered as f64 / total as f64
}

/// Sums the production lines of `files`, reading each source through `read`.
pub fn totals(
    files: &[FileRecord],
    read: &dyn Fn(&str) -> Result<String, String>,
) -> Result<Totals, String> {
    let mut t = Totals::default();
    for file in files {
        if excluded_file(&file.path) {
            continue;
        }
        let ranges = test_module_ranges(&read(&file.path)?);
        t.files += 1;
        for rec in &file.lines {
            if ranges.iter().any(|(a, b)| (*a..=*b).contains(&rec.line)) {
                t.test_lines += 1;
                if rec.hits > 0 {
                    t.test_covered += 1;
                }
                continue;
            }
            t.total += 1;
            if rec.hits > 0 {
                t.covered += 1;
            }
        }
    }
    Ok(t)
}

/// Entry point: `args` are the arguments after `coverage`.
pub fn run(root: &Path, args: &[String]) -> Result<String, String> {
    let mut lcov = None;
    let mut fail_under = None;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if a == "--fail-under" {
            let v = it
                .next()
                .and_then(|v| v.parse::<f64>().ok())
                .ok_or("--fail-under needs a percentage")?;
            fail_under = Some(v);
        } else {
            lcov = Some(a.clone());
        }
    }
    let lcov = lcov.ok_or("usage: cargo xtask coverage <lcov.info> [--fail-under PCT]")?;
    let lcov_path = root.join(&lcov);
    let text =
        std::fs::read_to_string(&lcov_path).map_err(|e| format!("{}: {e}", lcov_path.display()))?;
    let files = parse_lcov(&text)?;
    let read = |p: &str| {
        let path = Path::new(p);
        let path = if path.is_absolute() {
            path.to_path_buf()
        } else {
            root.join(path)
        };
        std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))
    };
    let t = totals(&files, &read)?;
    let report = format!(
        "production line coverage: {:.1} % ({} / {} lines in {} files), inline #[cfg(test)] \
         modules excluded\nfor comparison, counting those {} test-module lines too: {:.1} % \
         ({} / {})\n",
        t.percent(),
        t.covered,
        t.total,
        t.files,
        t.test_lines,
        t.percent_with_tests(),
        t.covered + t.test_covered,
        t.total + t.test_lines
    );
    if let Some(min) = fail_under
        && t.percent() < min
    {
        return Err(format!("{report}below the {min} % gate"));
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SOURCE: &str = "\
pub fn a() -> u8 {
    1
}

#[cfg(test)]
mod tests {
    #[test]
    fn t() {
        let s = \"}\";
        assert_eq!(super::a(), 1);
    }
}
";

    #[test]
    fn finds_the_inline_test_module() {
        assert_eq!(test_module_ranges(SOURCE), [(5, 12)]);
        assert!(test_module_ranges("fn main() {}\n").is_empty());
        // `#[cfg(test)]` on an item that is not a module is production code.
        assert!(test_module_ranges("#[cfg(test)]\nfn helper() {}\n").is_empty());
    }

    /// Regression: the README's coverage figure counted inline unit-test modules as covered
    /// production lines.
    #[test]
    fn test_module_lines_are_not_production_lines() {
        let lcov = "SF:/p/crates/x/src/lib.rs\nDA:1,3\nDA:2,3\nDA:3,0\nDA:8,1\nDA:9,1\nDA:10,1\n\
                    end_of_record\nSF:/p/crates/x/tests/it.rs\nDA:1,0\nend_of_record\n\
                    SF:/p/xtask/src/main.rs\nDA:1,0\nend_of_record\n";
        let files = parse_lcov(lcov).unwrap();
        assert_eq!(files.len(), 3);
        let t = totals(&files, &|_| Ok(SOURCE.to_owned())).unwrap();
        assert_eq!(
            t,
            Totals {
                covered: 2,
                total: 3,
                test_lines: 3,
                test_covered: 3,
                files: 1
            }
        );
        assert!((t.percent() - 66.666).abs() < 0.01);
        assert!((t.percent_with_tests() - 83.333).abs() < 0.01);
        assert!(parse_lcov("DA:1,1\n").is_err());
        assert!(parse_lcov("SF:a\nDA:x,1\n").is_err());
    }
}
