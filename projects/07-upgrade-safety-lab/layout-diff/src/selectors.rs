// SPDX-License-Identifier: MIT
//! Build-time selector-clash detector for diamonds.
//!
//! Input: `forge inspect <Facet> methodIdentifiers --json` entries for every facet (and for the diamond itself,
//! whose compiled functions are immutable), wrapped as `{"sources": [{"name": "...", "selectors": {...}}]}`. The
//! lab's driver keeps, for each facet, only the selectors the diamond's routing table really cuts. Every selector is
//! recomputed from its signature, then any selector served by two sources is an error.

use std::collections::BTreeMap;
use std::path::Path;

use serde::Deserialize;

use crate::erc7201::selector;
use crate::error::Error;
use crate::finding::{Finding, Kind};

/// One facet (or the diamond) and its method identifiers.
#[derive(Clone, Debug, Deserialize)]
pub struct SelectorSource {
    /// Contract name.
    pub name: String,
    /// `signature -> 8-hex-digit selector`, exactly as `forge inspect methodIdentifiers --json` prints it.
    pub selectors: BTreeMap<String, String>,
}

/// Every source that will be cut into one diamond.
#[derive(Clone, Debug, Deserialize)]
pub struct SelectorSet {
    /// Facets and the diamond itself.
    pub sources: Vec<SelectorSource>,
}

impl SelectorSet {
    /// Reads a selector set from a JSON file.
    pub fn load(path: &Path) -> Result<Self, Error> {
        let text = std::fs::read_to_string(path).map_err(|source| Error::Io {
            path: path.display().to_string(),
            source,
        })?;
        serde_json::from_str(&text).map_err(|source| Error::Json {
            path: path.display().to_string(),
            source,
        })
    }
}

fn parse_selector(signature: &str, text: &str) -> Result<[u8; 4], Error> {
    let bad = || Error::BadSelector {
        signature: signature.to_owned(),
        selector: text.to_owned(),
    };
    let hex = text.trim_start_matches("0x");
    if hex.len() != 8 {
        return Err(bad());
    }
    let mut out = [0u8; 4];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(hex.get(2 * i..2 * i + 2).ok_or_else(bad)?, 16).map_err(|_| bad())?;
    }
    Ok(out)
}

fn hex4(sel: [u8; 4]) -> String {
    format!("0x{:02x}{:02x}{:02x}{:02x}", sel[0], sel[1], sel[2], sel[3])
}

/// Reports mismatching selectors, 4-byte collisions and duplicated functions.
pub fn check_selectors(set: &SelectorSet) -> Result<Vec<Finding>, Error> {
    let mut findings = Vec::new();
    let mut by_selector: BTreeMap<[u8; 4], Vec<(&str, &str)>> = BTreeMap::new();
    for source in &set.sources {
        for (signature, text) in &source.selectors {
            let declared = parse_selector(signature, text)?;
            let computed = selector(signature);
            if declared != computed {
                findings.push(Finding::new(
                    Kind::SelectorMismatch,
                    "selectors",
                    signature.clone(),
                    format!(
                        "{}.{signature} is listed as {} but keccak256 gives {}",
                        source.name,
                        hex4(declared),
                        hex4(computed)
                    ),
                ));
            }
            by_selector
                .entry(computed)
                .or_default()
                .push((source.name.as_str(), signature.as_str()));
        }
    }
    for (sel, users) in &by_selector {
        if users.len() < 2 {
            continue;
        }
        let listing = users
            .iter()
            .map(|(n, s)| format!("{n}.{s}"))
            .collect::<Vec<_>>()
            .join(", ");
        let same_signature = users.iter().all(|(_, s)| *s == users[0].1);
        let (kind, what) = if same_signature {
            (
                Kind::DuplicateFunction,
                "the same function is served by several sources",
            )
        } else {
            (Kind::SelectorCollision, "different functions share one 4-byte selector")
        };
        findings.push(Finding::new(
            kind,
            "selectors",
            hex4(*sel),
            format!("{what}: {listing}"),
        ));
    }
    Ok(findings)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn source(name: &str, entries: &[(&str, &str)]) -> SelectorSource {
        SelectorSource {
            name: name.into(),
            selectors: entries
                .iter()
                .map(|(s, h)| ((*s).to_owned(), (*h).to_owned()))
                .collect(),
        }
    }

    #[test]
    fn clean_set_has_no_findings() {
        let set = SelectorSet {
            sources: vec![
                source("A", &[("transfer(address,uint256)", "a9059cbb")]),
                source("B", &[("burn(uint256)", "42966c68")]),
            ],
        };
        assert_eq!(check_selectors(&set).ok(), Some(vec![]));
    }

    #[test]
    fn four_byte_collision_and_duplicate() {
        let set = SelectorSet {
            sources: vec![
                source("A", &[("burn(uint256)", "42966c68"), ("owner()", "8da5cb5b")]),
                source("B", &[("collate_propagate_storage(bytes16)", "42966c68")]),
                source("C", &[("owner()", "8da5cb5b")]),
            ],
        };
        let kinds: Vec<Kind> = check_selectors(&set)
            .unwrap_or_default()
            .iter()
            .map(|f| f.kind)
            .collect();
        assert_eq!(kinds, vec![Kind::SelectorCollision, Kind::DuplicateFunction]);
    }

    #[test]
    fn forged_selector_is_caught() {
        let set = SelectorSet {
            sources: vec![source("A", &[("owner()", "deadbeef")])],
        };
        let findings = check_selectors(&set).unwrap_or_default();
        assert_eq!(findings.len(), 1);
        assert_eq!(findings[0].kind, Kind::SelectorMismatch);
    }

    #[test]
    fn malformed_selector_is_an_input_error() {
        let set = SelectorSet {
            sources: vec![source("A", &[("owner()", "8da5")])],
        };
        assert!(check_selectors(&set).is_err());
    }
}
