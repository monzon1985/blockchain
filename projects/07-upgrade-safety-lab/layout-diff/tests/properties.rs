// SPDX-License-Identifier: MIT
//! Property tests (proptest) over randomly generated sequential layouts, packed exactly like solc packs value
//! types: a variable starts a new slot when it does not fit in the rest of the current one.

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use layout_diff::erc7201::erc7201_slot;
use layout_diff::layout::{StorageEntry, TypeInfo, TypeTable};
use layout_diff::{Layout, Severity, Snapshot, diff_layouts};
use proptest::prelude::*;
use ruint::aliases::U256;

/// (label, solc type key, size in bytes)
const VALUE_TYPES: [(&str, &str, u64); 7] = [
    ("uint8", "t_uint8", 1),
    ("bool", "t_bool", 1),
    ("uint64", "t_uint64", 8),
    ("uint128", "t_uint128", 16),
    ("address", "t_address", 20),
    ("uint256", "t_uint256", 32),
    ("bytes32", "t_bytes32", 32),
];

/// A variable: its name index and its type index into VALUE_TYPES.
type Decl = (u32, usize);

fn build(decls: &[Decl]) -> Layout {
    let mut types = TypeTable::new();
    let mut storage = Vec::new();
    let (mut slot, mut offset) = (0u64, 0u64);
    for (name, t) in decls {
        let (label, key, size) = VALUE_TYPES[*t];
        if offset + size > 32 {
            slot += 1;
            offset = 0;
        }
        storage.push(StorageEntry {
            ast_id: None,
            contract: "Generated".into(),
            label: format!("v{name}"),
            offset: u32::try_from(offset).unwrap(),
            slot: slot.to_string(),
            ty: key.into(),
        });
        types.insert(
            key.into(),
            TypeInfo {
                encoding: "inplace".into(),
                label: label.into(),
                number_of_bytes: size.to_string(),
                key: None,
                value: None,
                base: None,
                members: None,
            },
        );
        offset += size;
    }
    let snapshot = Snapshot {
        contract: None,
        storage,
        types: Some(types),
        namespaces: Some(vec![]),
    };
    Layout::from_snapshot("generated", &snapshot).unwrap()
}

fn errors(old: &[Decl], new: &[Decl]) -> usize {
    diff_layouts(&build(old), &build(new))
        .unwrap()
        .iter()
        .filter(|f| f.severity == Severity::Error)
        .count()
}

/// Layouts with unique variable names.
fn layouts() -> impl Strategy<Value = Vec<Decl>> {
    prop::collection::vec(0..VALUE_TYPES.len(), 1..24).prop_map(|types| {
        types
            .into_iter()
            .enumerate()
            .map(|(i, t)| (u32::try_from(i).unwrap(), t))
            .collect()
    })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    #[test]
    fn identical_layouts_are_always_safe(decls in layouts()) {
        prop_assert_eq!(errors(&decls, &decls), 0);
    }

    #[test]
    fn appending_variables_is_always_safe(decls in layouts(), extra in prop::collection::vec(0..VALUE_TYPES.len(), 1..6)) {
        let mut grown = decls.clone();
        for (i, t) in extra.into_iter().enumerate() {
            grown.push((1000 + u32::try_from(i).unwrap(), t));
        }
        prop_assert_eq!(errors(&decls, &grown), 0);
    }

    #[test]
    fn removing_any_variable_is_always_unsafe(decls in layouts(), pick in any::<prop::sample::Index>()) {
        let i = pick.index(decls.len());
        let mut shrunk = decls.clone();
        shrunk.remove(i);
        prop_assert!(errors(&decls, &shrunk) > 0);
    }

    #[test]
    fn inserting_before_the_end_is_always_unsafe(
        decls in layouts(),
        pick in any::<prop::sample::Index>(),
        t in 0..VALUE_TYPES.len(),
    ) {
        let i = pick.index(decls.len());
        let mut shifted = decls.clone();
        shifted.insert(i, (5000, t));
        // Inserting a variable before the last one either moves a later variable or, when it slips into padding,
        // leaves positions intact; the latter is safe, so only count shifts.
        let old = build(&decls);
        let new = build(&shifted);
        let moved = old.sequential.vars.iter().any(|o| {
            new.sequential.vars.iter().any(|n| n.label == o.label && (n.slot, n.offset) != (o.slot, o.offset))
        });
        prop_assert_eq!(errors(&decls, &shifted) > 0, moved);
    }

    #[test]
    fn swapping_two_neighbours_is_always_unsafe(decls in layouts(), pick in any::<prop::sample::Index>()) {
        prop_assume!(decls.len() >= 2);
        let i = pick.index(decls.len() - 1);
        let mut swapped = decls.clone();
        swapped.swap(i, i + 1);
        prop_assert!(errors(&decls, &swapped) > 0);
    }

    #[test]
    fn erc7201_slots_are_256_slot_aligned(id in ".{0,64}") {
        prop_assert_eq!(erc7201_slot(&id) & U256::from(0xffu8), U256::ZERO);
    }
}
