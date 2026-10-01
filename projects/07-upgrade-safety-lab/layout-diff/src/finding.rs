// SPDX-License-Identifier: MIT
//! Findings, allowances and the report every subcommand prints.

use serde::Serialize;

use crate::error::Error;

/// How bad a finding is. Only errors make the gate fail.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    /// The upgrade corrupts or orphans state.
    Error,
    /// Probably intended, but worth a human look.
    Warning,
    /// Expected evolution (appended variables, consumed gaps, new namespaces).
    Info,
}

impl Severity {
    fn as_str(self) -> &'static str {
        match self {
            Severity::Error => "error",
            Severity::Warning => "warning",
            Severity::Info => "info",
        }
    }
}

/// What a finding is about.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Kind {
    /// A variable now sits at a different slot or offset (reordering, insertion before it).
    Moved,
    /// A variable disappeared: its value is orphaned, and its bytes may be reused by another variable.
    Removed,
    /// A variable was turned into reserved space (`__*`): the value is still there but nothing reads it.
    Retired,
    /// The type at an unchanged position changed incompatibly.
    TypeChanged,
    /// A reserved `__gap` array no longer ends where it used to, so everything after it shifts.
    GapResized,
    /// A variable moved from sequential storage into a new ERC-7201 namespace without a migration
    /// (the OpenZeppelin issue #6362 failure class).
    MovedToNamespace,
    /// A namespace of the old layout is gone: all of its state is orphaned.
    NamespaceRemoved,
    /// A namespace is not stored at the slot the ERC-7201 formula gives for its id (by its probe, or by an accessor
    /// of the production code).
    Erc7201SlotMismatch,
    /// An accessor places a namespace at a location that is not a statically evaluable constant.
    AccessorUnresolved,
    /// Two storage regions overlap (two namespaces, or a namespace and sequential storage).
    StorageCollision,
    /// The same namespace id is declared twice.
    DuplicateNamespace,
    /// Raw `forge inspect` input: ERC-7201 namespaces were not checked (`--sequential-only`).
    NamespacesUnchecked,
    /// Same position and type, different name.
    Renamed,
    /// Same bytes, different type name (e.g. `address` to `contract IERC20`).
    TypeRelabeled,
    /// A new variable in previously unused or reserved space.
    Added,
    /// New variables were carved out of a `__gap` whose end did not move.
    GapConsumed,
    /// A namespace that did not exist before.
    NamespaceAdded,
    /// Two different functions share a 4-byte selector.
    SelectorCollision,
    /// The same function is served by two facets.
    DuplicateFunction,
    /// A selector does not match keccak256 of its signature.
    SelectorMismatch,
}

impl Kind {
    /// Every kind, in documentation order.
    pub const ALL: [Kind; 20] = [
        Kind::Moved,
        Kind::Removed,
        Kind::Retired,
        Kind::TypeChanged,
        Kind::GapResized,
        Kind::MovedToNamespace,
        Kind::NamespaceRemoved,
        Kind::Erc7201SlotMismatch,
        Kind::AccessorUnresolved,
        Kind::StorageCollision,
        Kind::DuplicateNamespace,
        Kind::NamespacesUnchecked,
        Kind::Renamed,
        Kind::TypeRelabeled,
        Kind::Added,
        Kind::GapConsumed,
        Kind::NamespaceAdded,
        Kind::SelectorCollision,
        Kind::DuplicateFunction,
        Kind::SelectorMismatch,
    ];

    /// Kebab-case name used on the command line and in reports.
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Moved => "moved",
            Kind::Removed => "removed",
            Kind::Retired => "retired",
            Kind::TypeChanged => "type-changed",
            Kind::GapResized => "gap-resized",
            Kind::MovedToNamespace => "moved-to-namespace",
            Kind::NamespaceRemoved => "namespace-removed",
            Kind::Erc7201SlotMismatch => "erc7201-slot-mismatch",
            Kind::AccessorUnresolved => "accessor-unresolved",
            Kind::StorageCollision => "storage-collision",
            Kind::DuplicateNamespace => "duplicate-namespace",
            Kind::NamespacesUnchecked => "namespaces-unchecked",
            Kind::Renamed => "renamed",
            Kind::TypeRelabeled => "type-relabeled",
            Kind::Added => "added",
            Kind::GapConsumed => "gap-consumed",
            Kind::NamespaceAdded => "namespace-added",
            Kind::SelectorCollision => "selector-collision",
            Kind::DuplicateFunction => "duplicate-function",
            Kind::SelectorMismatch => "selector-mismatch",
        }
    }

    /// Parses a kebab-case kind name.
    pub fn parse(name: &str) -> Option<Kind> {
        Kind::ALL.into_iter().find(|k| k.as_str() == name)
    }

    /// Default severity of the kind.
    pub fn severity(self) -> Severity {
        match self {
            Kind::Renamed | Kind::TypeRelabeled | Kind::NamespacesUnchecked => Severity::Warning,
            Kind::Added | Kind::GapConsumed | Kind::NamespaceAdded => Severity::Info,
            _ => Severity::Error,
        }
    }
}

/// One observation about a layout pair, a single layout, or a selector set.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Finding {
    /// Severity (derived from the kind).
    pub severity: Severity,
    /// Kind.
    pub kind: Kind,
    /// `sequential`, `erc7201:<id>` or `selectors`.
    pub region: String,
    /// Variable, member, namespace or selector concerned.
    pub label: String,
    /// Explanation with the offending values.
    pub message: String,
    /// True when an `--allow KIND:LABEL` entry accepted this error.
    pub allowed: bool,
}

impl Finding {
    /// Builds a finding with the kind's default severity.
    pub fn new(kind: Kind, region: impl Into<String>, label: impl Into<String>, message: impl Into<String>) -> Self {
        Finding {
            severity: kind.severity(),
            kind,
            region: region.into(),
            label: label.into(),
            message: message.into(),
            allowed: false,
        }
    }
}

/// An explicit, reviewed exception: `KIND:LABEL`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Allowance {
    /// Kind to accept.
    pub kind: Kind,
    /// Label to accept it for.
    pub label: String,
}

impl Allowance {
    /// Parses `KIND:LABEL`.
    pub fn parse(text: &str) -> Result<Self, Error> {
        let (kind, label) = text
            .split_once(':')
            .ok_or_else(|| Error::BadAllowance(text.to_owned()))?;
        let kind = Kind::parse(kind).ok_or_else(|| Error::BadAllowance(text.to_owned()))?;
        if label.is_empty() {
            return Err(Error::BadAllowance(text.to_owned()));
        }
        Ok(Allowance {
            kind,
            label: label.to_owned(),
        })
    }

    fn matches(&self, finding: &Finding) -> bool {
        finding.kind == self.kind && finding.label == self.label
    }
}

impl std::fmt::Display for Allowance {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}:{}", self.kind.as_str(), self.label)
    }
}

/// Result of one command.
#[derive(Clone, Debug, Serialize)]
pub struct Report {
    /// `diff`, `lint` or `selectors`.
    pub command: String,
    /// What was checked, e.g. `V1 -> V2`.
    pub subject: String,
    /// True when no unallowed error remains and every allowance was used.
    pub safe: bool,
    /// Number of unallowed errors.
    pub errors: usize,
    /// Number of warnings.
    pub warnings: usize,
    /// Number of infos.
    pub infos: usize,
    /// Number of errors accepted by an allowance.
    pub allowed: usize,
    /// All findings in analysis order.
    pub findings: Vec<Finding>,
    /// Allowances that matched nothing (stale exceptions fail the gate).
    pub unused_allowances: Vec<String>,
}

impl Report {
    /// Applies the allowances and computes the verdict.
    pub fn new(command: &str, subject: &str, mut findings: Vec<Finding>, allowances: &[Allowance]) -> Self {
        let mut unused = Vec::new();
        for allowance in allowances {
            let mut used = false;
            for f in findings
                .iter_mut()
                .filter(|f| f.severity == Severity::Error && allowance.matches(f))
            {
                f.allowed = true;
                used = true;
            }
            if !used {
                unused.push(allowance.to_string());
            }
        }
        let count = |sev: Severity| findings.iter().filter(|f| f.severity == sev && !f.allowed).count();
        let errors = count(Severity::Error);
        Report {
            command: command.to_owned(),
            subject: subject.to_owned(),
            safe: errors == 0 && unused.is_empty(),
            errors,
            warnings: count(Severity::Warning),
            infos: count(Severity::Info),
            allowed: findings.iter().filter(|f| f.allowed).count(),
            findings,
            unused_allowances: unused,
        }
    }

    /// Human-readable rendering (stable: used by the golden tests).
    pub fn render_text(&self) -> String {
        let mut out = format!("layout-diff {}: {}\n", self.command, self.subject);
        for f in &self.findings {
            let sev = if f.allowed {
                "allowed".to_owned()
            } else {
                f.severity.as_str().to_owned()
            };
            out.push_str(&format!(
                "  {sev:<8} {:<22} {} `{}`\n",
                f.kind.as_str(),
                f.region,
                f.label
            ));
            out.push_str(&format!("           {}\n", f.message));
        }
        for a in &self.unused_allowances {
            out.push_str(&format!("  error    unused allowance `{a}` matched no error\n"));
        }
        let partial = self.findings.iter().any(|f| f.kind == Kind::NamespacesUnchecked);
        let verdict = match (self.safe, partial) {
            (true, false) => "SAFE",
            (true, true) => "SAFE for sequential storage only, ERC-7201 namespaces NOT checked",
            (false, _) => "UNSAFE",
        };
        out.push_str(&format!(
            "result: {verdict} ({} errors, {} allowed, {} warnings, {} infos)\n",
            self.errors, self.allowed, self.warnings, self.infos
        ));
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allowance_parsing() {
        let a = Allowance::parse("moved-to-namespace:_owner").ok();
        assert_eq!(
            a,
            Some(Allowance {
                kind: Kind::MovedToNamespace,
                label: "_owner".into()
            })
        );
        assert!(Allowance::parse("moved-to-namespace").is_err());
        assert!(Allowance::parse("nonsense:_owner").is_err());
        assert!(Allowance::parse("removed:").is_err());
    }

    #[test]
    fn every_kind_round_trips() {
        for k in Kind::ALL {
            assert_eq!(Kind::parse(k.as_str()), Some(k));
        }
    }

    #[test]
    fn allowances_accept_errors_and_stale_ones_fail() {
        let findings = vec![
            Finding::new(Kind::MovedToNamespace, "sequential", "_owner", "m"),
            Finding::new(Kind::Renamed, "sequential", "_owner", "r"),
        ];
        let used = [Allowance {
            kind: Kind::MovedToNamespace,
            label: "_owner".into(),
        }];
        let r = Report::new("diff", "a -> b", findings.clone(), &used);
        assert!(r.safe);
        assert_eq!((r.errors, r.allowed, r.warnings), (0, 1, 1));

        let stale = [Allowance {
            kind: Kind::Removed,
            label: "_owner".into(),
        }];
        let r = Report::new("diff", "a -> b", findings, &stale);
        assert!(!r.safe);
        assert_eq!(r.unused_allowances, vec!["removed:_owner".to_owned()]);
    }
}
