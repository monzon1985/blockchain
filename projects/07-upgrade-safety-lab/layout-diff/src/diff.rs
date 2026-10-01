// SPDX-License-Identifier: MIT
//! The upgrade-safety rules.
//!
//! [`diff_layouts`] compares an old and a new layout region by region (sequential storage, then every
//! ERC-7201 namespace) and finishes with [`lint_layout`] on the new layout. Rules, all errors unless noted:
//!
//! | kind | trigger |
//! |---|---|
//! | `moved` | a live variable of the old layout now sits at another slot/offset |
//! | `removed` | a live variable is gone (its value is orphaned; its bytes may be reused) |
//! | `retired` | a live variable is now covered by reserved space (`__` + `uint256[N]`) |
//! | `type-changed` | same position, incompatible type (width, kind, struct shape, array length) |
//! | `gap-resized` | a `__gap` no longer ends at the same slot |
//! | `moved-to-namespace` | a sequential variable reappears in a namespace that the old layout did not have |
//! | `namespace-removed` | an old namespace id is missing |
//! | `erc7201-slot-mismatch` | a probe or an accessor places a namespace away from its ERC-7201 slot (lint) |
//! | `accessor-unresolved` | an accessor's slot is not a compile-time constant the driver can evaluate (lint) |
//! | `storage-collision` | two static footprints overlap, accessor placements included (lint) |
//! | `renamed`, `type-relabeled`, `namespaces-unchecked` | warnings |
//! | `added`, `gap-consumed`, `namespace-added` | infos: expected evolution |

use std::collections::{BTreeMap, BTreeSet};

use ruint::aliases::U256;

use crate::erc7201::{erc7201_slot, hex_slot};
use crate::error::Error;
use crate::finding::{Finding, Kind};
use crate::layout::{AccessorSlot, Layout, Namespace, Region, Var};
use crate::types::{Compat, Context, compat, describe};

const SEQUENTIAL: &str = "sequential";

/// Compares two layouts; the result includes the single-layout checks of the new layout.
pub fn diff_layouts(old: &Layout, new: &Layout) -> Result<Vec<Finding>, Error> {
    let mut findings = diff_region(&old.sequential, &new.sequential, SEQUENTIAL)?;

    let old_ns: BTreeMap<&str, &Namespace> = old.namespaces.iter().map(|n| (n.id.as_str(), n)).collect();
    let new_ns: BTreeMap<&str, &Namespace> = new.namespaces.iter().map(|n| (n.id.as_str(), n)).collect();

    for (id, o) in &old_ns {
        match new_ns.get(id) {
            None => findings.push(Finding::new(
                Kind::NamespaceRemoved,
                o.region_name(),
                *id,
                format!(
                    "namespace `{id}` ({}) is no longer declared: all of its state is orphaned",
                    o.root_label
                ),
            )),
            Some(n) => findings.extend(diff_region(&o.members, &n.members, &n.region_name())?),
        }
    }

    for (id, n) in &new_ns {
        if old_ns.contains_key(id) {
            continue;
        }
        findings.push(Finding::new(
            Kind::NamespaceAdded,
            n.region_name(),
            *id,
            format!("new namespace `{id}` ({}) at {}", n.root_label, hex_slot(n.base)),
        ));
        flag_moves_into_namespace(&old.sequential, n, &mut findings);
    }

    findings.extend(lint_layout(new));
    Ok(findings)
}

/// The OpenZeppelin issue #6362 detector: a variable that lived in sequential storage and now appears as a
/// member of a namespace the old layout did not have. The new code reads the (empty) namespace, never the old
/// slot, unless a migration step copies the value first.
fn flag_moves_into_namespace(old_seq: &Region, ns: &Namespace, findings: &mut Vec<Finding>) {
    let members: BTreeSet<&str> = ns.members.vars.iter().map(|m| m.label.as_str()).collect();
    for o in old_seq
        .vars
        .iter()
        .filter(|v| !v.is_reserved() && members.contains(v.label.as_str()))
    {
        let message = format!(
            "`{}` lives at {} in the old layout and in namespace `{}` in the new one; the new code reads the \
             namespace, which starts empty, so the old value is stranded (OpenZeppelin issue #6362). Copy it in a \
             migration step (reinitializer) before switching implementations",
            o.label,
            o.position(),
            ns.id
        );
        // A plain `removed`/`retired` finding for the same variable is superseded by this more precise one.
        if let Some(existing) = findings
            .iter_mut()
            .find(|f| f.region == SEQUENTIAL && f.label == o.label && matches!(f.kind, Kind::Removed | Kind::Retired))
        {
            *existing = Finding::new(Kind::MovedToNamespace, SEQUENTIAL, o.label.clone(), message);
        } else {
            findings.push(Finding::new(
                Kind::MovedToNamespace,
                SEQUENTIAL,
                o.label.clone(),
                message,
            ));
        }
    }
}

/// Rules for one region (sequential storage or one namespace's members).
pub fn diff_region(old: &Region, new: &Region, region: &str) -> Result<Vec<Finding>, Error> {
    let mut findings = Vec::new();
    let new_at: BTreeMap<(U256, u32), &Var> = new.vars.iter().map(|v| ((v.slot, v.offset), v)).collect();
    let new_live_by_label: BTreeMap<&str, &Var> = new
        .vars
        .iter()
        .filter(|v| !v.is_reserved())
        .map(|v| (v.label.as_str(), v))
        .collect();
    let old_live_labels: BTreeSet<&str> = old
        .vars
        .iter()
        .filter(|v| !v.is_reserved())
        .map(|v| v.label.as_str())
        .collect();

    for o in old.vars.iter().filter(|v| !v.is_reserved()) {
        let old_ty = describe(&old.types, &o.ty, &o.label)?;
        let same_label_elsewhere = new_live_by_label
            .get(o.label.as_str())
            .filter(|n| (n.slot, n.offset) != (o.slot, o.offset));

        if let Some(n) = same_label_elsewhere {
            findings.push(Finding::new(
                Kind::Moved,
                region,
                o.label.clone(),
                format!(
                    "`{}` ({}) moved from {} to {}: it now reads whatever the old layout stored there",
                    o.label,
                    old_ty.label(),
                    o.position(),
                    n.position()
                ),
            ));
            continue;
        }

        match new_at.get(&(o.slot, o.offset)) {
            Some(n) if n.is_reserved() => findings.push(Finding::new(
                Kind::Retired,
                region,
                o.label.clone(),
                format!(
                    "`{}` ({}) at {} is now covered by reserved `{}`: the value stays in storage but nothing reads it",
                    o.label,
                    old_ty.label(),
                    o.position(),
                    n.label
                ),
            )),
            // Another old variable moved onto this position: `o` itself is gone, not renamed.
            Some(n) if n.label != o.label && old_live_labels.contains(n.label.as_str()) => findings.push(Finding::new(
                Kind::Removed,
                region,
                o.label.clone(),
                format!(
                    "`{}` ({}) at {} is no longer declared; its bytes are reused by `{}`, which moved there",
                    o.label,
                    old_ty.label(),
                    o.position(),
                    n.label
                ),
            )),
            Some(n) => {
                let new_ty = describe(&new.types, &n.ty, &n.label)?;
                match compat(&old_ty, &new_ty, Context::Inline) {
                    Compat::Incompatible(reason) => findings.push(Finding::new(
                        Kind::TypeChanged,
                        region,
                        o.label.clone(),
                        format!("`{}` at {}: {reason}", o.label, o.position()),
                    )),
                    Compat::Relabeled(reason) => findings.push(Finding::new(
                        Kind::TypeRelabeled,
                        region,
                        o.label.clone(),
                        format!("`{}` at {}: {reason}", o.label, o.position()),
                    )),
                    Compat::Same => {}
                }
                if n.label != o.label {
                    findings.push(Finding::new(
                        Kind::Renamed,
                        region,
                        o.label.clone(),
                        format!("`{}` at {} is now called `{}`", o.label, o.position(), n.label),
                    ));
                }
            }
            None => {
                let reused_by = new.vars.iter().find(|n| n.overlaps(o));
                let (kind, detail) = match reused_by {
                    Some(n) if n.is_reserved() => (
                        Kind::Retired,
                        format!("its bytes are now inside reserved `{}`", n.label),
                    ),
                    Some(n) => (
                        Kind::Removed,
                        format!("its bytes are reused by `{}` at {}", n.label, n.position()),
                    ),
                    None => (Kind::Removed, "the old value stays orphaned in storage".to_owned()),
                };
                findings.push(Finding::new(
                    kind,
                    region,
                    o.label.clone(),
                    format!(
                        "`{}` ({}) at {} is no longer declared; {detail}",
                        o.label,
                        old_ty.label(),
                        o.position()
                    ),
                ));
            }
        }
    }

    check_gaps(old, new, region, &mut findings);

    for n in new.vars.iter().filter(|v| !v.is_reserved()) {
        let known = old
            .vars
            .iter()
            .any(|o| !o.is_reserved() && (o.label == n.label || (o.slot, o.offset) == (n.slot, n.offset)));
        if known || old.vars.iter().any(|o| !o.is_reserved() && o.overlaps(n)) {
            continue;
        }
        let place = if old.vars.iter().any(|o| o.is_reserved() && o.overlaps(n)) {
            "in space the old layout reserved"
        } else {
            "after every old variable"
        };
        let new_ty = describe(&new.types, &n.ty, &n.label)?;
        findings.push(Finding::new(
            Kind::Added,
            region,
            n.label.clone(),
            format!("new `{}` ({}) at {}, {place}", n.label, new_ty.label(), n.position()),
        ));
    }
    Ok(findings)
}

/// A `__gap` must keep ending at the same slot: inserting k variables before it requires shrinking it by k.
/// Each old gap is matched with the lowest-placed reserved variable of the new layout that overlaps it: a gap that
/// gave slots away starts later but still overlaps its old span, and solc lays out parents in linearization order,
/// so the overlap identifies the same gap without any declaration metadata.
fn check_gaps(old: &Region, new: &Region, region: &str, findings: &mut Vec<Finding>) {
    for og in old.vars.iter().filter(|v| v.is_reserved()) {
        let matched = new
            .vars
            .iter()
            .filter(|n| n.is_reserved() && n.overlaps(og))
            .min_by_key(|n| n.slot);
        let Some(ng) = matched else { continue };
        let (old_end, new_end) = (og.end_slot(), ng.end_slot());
        if old_end != new_end {
            let old_len = og.end_slot() - og.slot;
            let new_len = ng.end_slot() - ng.slot;
            findings.push(Finding::new(
                Kind::GapResized,
                region,
                og.label.clone(),
                format!(
                    "`{}` spanned slots {}..{} ({} slots) and now spans {}..{} ({} slots): it must keep ending at slot \
                     {}, otherwise every variable declared after it shifts",
                    og.label, og.slot, old_end, old_len, ng.slot, new_end, new_len, old_end
                ),
            ));
        } else if ng.slot > og.slot {
            findings.push(Finding::new(
                Kind::GapConsumed,
                region,
                og.label.clone(),
                format!(
                    "`{}` gave {} slot(s) to new variables and still ends at slot {}",
                    og.label,
                    ng.slot - og.slot,
                    old_end
                ),
            ));
        }
    }
}

/// The warning attached to a diff or lint of raw `forge inspect` input (accepted only with `--sequential-only`).
pub fn namespaces_unchecked(layout: &Layout) -> Finding {
    Finding::new(
        Kind::NamespacesUnchecked,
        "layout",
        layout.name.clone(),
        format!(
            "`{}` is raw `forge inspect storageLayout` output, which lists sequential variables only: ERC-7201 \
             namespaces were not checked, so a move of state into a namespace (OpenZeppelin issue #6362) would go \
             unnoticed. Use a snapshot built by scripts/check-layouts.mjs for a full check",
            layout.name
        ),
    )
}

/// Checks that need only one layout: ERC-7201 base slots (as placed by the probe and by every accessor of the
/// production code), statically evaluable accessors, and overlaps between storage regions.
pub fn lint_layout(layout: &Layout) -> Vec<Finding> {
    let mut findings = Vec::new();
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    for ns in &layout.namespaces {
        if !seen.insert(ns.id.as_str()) {
            findings.push(Finding::new(
                Kind::DuplicateNamespace,
                ns.region_name(),
                ns.id.clone(),
                format!("namespace `{}` is declared more than once", ns.id),
            ));
        }
        let expected = erc7201_slot(&ns.id);
        let formula = format!(
            "keccak256(abi.encode(uint256(keccak256(\"{}\")) - 1)) & ~0xff = {}",
            ns.id,
            hex_slot(expected)
        );
        if ns.base != expected {
            findings.push(Finding::new(
                Kind::Erc7201SlotMismatch,
                ns.region_name(),
                ns.id.clone(),
                format!(
                    "the probe places `{}` at {} but {formula}",
                    ns.root_label,
                    hex_slot(ns.base)
                ),
            ));
        }
        for accessor in &ns.accessors {
            match &accessor.slot {
                AccessorSlot::Resolved(slot) if *slot != expected => findings.push(Finding::new(
                    Kind::Erc7201SlotMismatch,
                    ns.region_name(),
                    ns.id.clone(),
                    format!(
                        "accessor `{}` points `{}` at {} but {formula}",
                        accessor.function,
                        ns.root_label,
                        hex_slot(*slot)
                    ),
                )),
                AccessorSlot::Resolved(_) => {}
                AccessorSlot::Unresolved(expr) => findings.push(Finding::new(
                    Kind::AccessorUnresolved,
                    ns.region_name(),
                    ns.id.clone(),
                    format!(
                        "accessor `{}` points `{}` at `{expr}`, which is not a compile-time constant the gate can \
                         evaluate; use the `erc7201` builtin or a literal constant so the slot can be checked",
                        accessor.function, ns.root_label
                    ),
                )),
            }
        }
    }

    // Static footprints: [start, end) in slots. Hashed data (mappings, dynamic arrays) is not a footprint. A
    // namespace has one footprint at its probe base and one more at every distinct slot an accessor really uses.
    struct Footprint {
        owner: usize,
        id: String,
        display: String,
        start: U256,
        end: U256,
    }
    let mut regions: Vec<Footprint> = Vec::new();
    let seq_end = layout.sequential.end_slot();
    if seq_end > U256::ZERO {
        regions.push(Footprint {
            owner: usize::MAX,
            id: SEQUENTIAL.to_owned(),
            display: "sequential storage".to_owned(),
            start: U256::ZERO,
            end: seq_end,
        });
    }
    for (index, ns) in layout.namespaces.iter().enumerate() {
        regions.push(Footprint {
            owner: index,
            id: ns.id.clone(),
            display: format!("namespace `{}`", ns.id),
            start: ns.base,
            end: ns.base.saturating_add(ns.slot_count()),
        });
        let mut placed: BTreeSet<U256> = BTreeSet::from([ns.base]);
        for accessor in &ns.accessors {
            if let AccessorSlot::Resolved(slot) = accessor.slot
                && placed.insert(slot)
            {
                regions.push(Footprint {
                    owner: index,
                    id: ns.id.clone(),
                    display: format!("namespace `{}` as placed by `{}`", ns.id, accessor.function),
                    start: slot,
                    end: slot.saturating_add(ns.slot_count()),
                });
            }
        }
    }
    for (i, a) in regions.iter().enumerate() {
        for b in &regions[i + 1..] {
            if a.owner == b.owner {
                continue; // two placements of one namespace: already an erc7201-slot-mismatch
            }
            if a.start < b.end && b.start < a.end {
                findings.push(Finding::new(
                    Kind::StorageCollision,
                    "layout",
                    b.id.clone(),
                    format!(
                        "{} [{}, {}) overlaps {} [{}, {}): both write the same slots",
                        a.display,
                        hex_slot(a.start),
                        hex_slot(a.end),
                        b.display,
                        hex_slot(b.start),
                        hex_slot(b.end)
                    ),
                ));
            }
        }
    }
    findings
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::Accessor;

    fn uint256_types() -> crate::layout::TypeTable {
        let json = r#"{
            "t_uint256": {"encoding": "inplace", "label": "uint256", "numberOfBytes": "32"},
            "t_array(t_uint256)3_storage": {"encoding": "inplace", "label": "uint256[3]", "numberOfBytes": "96",
                                            "base": "t_uint256"}
        }"#;
        serde_json::from_str(json).unwrap()
    }

    fn var(label: &str, slot: u64, ty: &str, bytes: u64, reserved: bool) -> Var {
        Var {
            label: label.into(),
            slot: U256::from(slot),
            offset: 0,
            bytes,
            ty: ty.into(),
            reserved,
        }
    }

    fn namespace(id: &str, base: U256, accessors: Vec<Accessor>) -> Namespace {
        Namespace {
            id: id.into(),
            struct_name: None,
            base,
            root_label: format!("struct {id}"),
            bytes: 64,
            members: Region {
                vars: vec![var("a", 0, "t_uint256", 32, false), var("b", 1, "t_uint256", 32, false)],
                types: uint256_types(),
            },
            accessors,
        }
    }

    fn layout(namespaces: Vec<Namespace>) -> Layout {
        Layout {
            name: "L".into(),
            sequential: Region::default(),
            namespaces,
            namespaces_known: true,
        }
    }

    fn kinds(findings: &[Finding]) -> Vec<&'static str> {
        findings.iter().map(|f| f.kind.as_str()).collect()
    }

    #[test]
    fn an_accessor_pointing_at_the_right_slot_is_clean() {
        let base = erc7201_slot("lab.a");
        let ok = Accessor {
            function: "A._a".into(),
            slot: AccessorSlot::Resolved(base),
        };
        assert!(lint_layout(&layout(vec![namespace("lab.a", base, vec![ok])])).is_empty());
    }

    #[test]
    fn a_wrong_accessor_is_caught_even_when_the_probe_is_right() {
        // The review's proof of concept: the accessor of one namespace reuses another namespace's location.
        let (a, b) = (erc7201_slot("lab.a"), erc7201_slot("lab.b"));
        let wrong = Accessor {
            function: "B._b".into(),
            slot: AccessorSlot::Resolved(a),
        };
        let findings = lint_layout(&layout(vec![
            namespace("lab.a", a, vec![]),
            namespace("lab.b", b, vec![wrong]),
        ]));
        assert_eq!(kinds(&findings), vec!["erc7201-slot-mismatch", "storage-collision"]);
        assert!(findings[0].message.contains("accessor `B._b`"));
        assert!(findings[1].message.contains("as placed by `B._b`"));
    }

    #[test]
    fn an_unresolved_accessor_fails_closed() {
        let base = erc7201_slot("lab.a");
        let opaque = Accessor {
            function: "A._a".into(),
            slot: AccessorSlot::Unresolved("keccak256(abi.encode(x))".into()),
        };
        let findings = lint_layout(&layout(vec![namespace("lab.a", base, vec![opaque])]));
        assert_eq!(kinds(&findings), vec!["accessor-unresolved"]);
        assert_eq!(findings[0].severity, crate::finding::Severity::Error);
    }

    #[test]
    fn a_live_variable_with_a_double_underscore_name_is_not_reserved() {
        let types = uint256_types();
        let old = Region {
            vars: vec![
                var("a", 0, "t_uint256", 32, false),
                var("__counter", 1, "t_uint256", 32, false),
            ],
            types: types.clone(),
        };
        let new = Region {
            vars: vec![var("a", 0, "t_uint256", 32, false)],
            types,
        };
        let findings = diff_region(&old, &new, SEQUENTIAL).unwrap();
        assert_eq!(kinds(&findings), vec!["removed"]);
        assert_eq!(findings[0].label, "__counter");
    }

    #[test]
    fn gaps_are_matched_by_overlap() {
        let types = uint256_types();
        let old = Region {
            vars: vec![
                var("x", 0, "t_uint256", 32, false),
                var("__gap", 1, "t_array(t_uint256)3_storage", 96, true),
            ],
            types: types.clone(),
        };
        let consumed = Region {
            vars: vec![
                var("x", 0, "t_uint256", 32, false),
                var("y", 1, "t_uint256", 32, false),
                var("__gap", 2, "t_array(t_uint256)3_storage", 64, true),
            ],
            types: types.clone(),
        };
        assert_eq!(
            kinds(&diff_region(&old, &consumed, SEQUENTIAL).unwrap()),
            vec!["gap-consumed", "added"]
        );
        let unchanged_size = Region {
            vars: vec![
                var("x", 0, "t_uint256", 32, false),
                var("y", 1, "t_uint256", 32, false),
                var("__gap", 2, "t_array(t_uint256)3_storage", 96, true),
            ],
            types,
        };
        assert_eq!(
            kinds(&diff_region(&old, &unchanged_size, SEQUENTIAL).unwrap()),
            vec!["gap-resized", "added"]
        );
    }
}
