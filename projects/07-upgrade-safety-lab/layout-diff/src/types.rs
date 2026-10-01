// SPDX-License-Identifier: MIT
//! Structural description of solc storage types and the upgrade-compatibility relation between them.
//!
//! Type keys (`t_struct(Plan)1234_storage`) embed AST ids that change between compilations, so two layouts are
//! never compared by key: every type is expanded into a [`Ty`] tree and the trees are compared.

use ruint::aliases::U256;

use crate::error::Error;
use crate::layout::{TypeTable, parse_u256};

/// A storage type, expanded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ty {
    /// Value type stored in place (integers, `address`, `bool`, contracts, enums, fixed bytes, UDVTs).
    Value {
        /// solc label, e.g. `uint64`, `contract IERC20`.
        label: String,
        /// Size in bytes.
        bytes: u64,
    },
    /// `bytes` or `string` (length slot plus hashed data).
    Bytes {
        /// solc label.
        label: String,
    },
    /// `mapping(K => V)`.
    Mapping {
        /// Key type.
        key: Box<Ty>,
        /// Value type.
        value: Box<Ty>,
    },
    /// `T[]` (length slot plus contiguous hashed data).
    DynArray {
        /// Element type.
        base: Box<Ty>,
    },
    /// `T[N]` stored in place.
    StaticArray {
        /// Element type.
        base: Box<Ty>,
        /// Total size in bytes.
        bytes: u64,
    },
    /// A struct stored in place.
    Struct {
        /// solc label, e.g. `struct RegistryStorageV1.Plan`.
        label: String,
        /// Total size in bytes.
        bytes: u64,
        /// Members in declaration order.
        members: Vec<Member>,
    },
    /// A struct that refers to itself through a mapping or a dynamic array (compared by label).
    Recursive {
        /// solc label.
        label: String,
    },
}

/// A struct member.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Member {
    /// Name.
    pub label: String,
    /// Slot relative to the struct.
    pub slot: U256,
    /// Byte offset inside the slot.
    pub offset: u32,
    /// Type.
    pub ty: Ty,
}

impl Ty {
    /// Short human-readable name used in findings.
    pub fn label(&self) -> String {
        match self {
            Ty::Value { label, .. } | Ty::Bytes { label } | Ty::Struct { label, .. } | Ty::Recursive { label } => {
                label.clone()
            }
            Ty::Mapping { key, value } => format!("mapping({} => {})", key.label(), value.label()),
            Ty::DynArray { base } => format!("{}[]", base.label()),
            Ty::StaticArray { base, bytes } => format!("{}[{} bytes]", base.label(), bytes),
        }
    }

    fn kind(&self) -> &'static str {
        match self {
            Ty::Value { .. } => "value type",
            Ty::Bytes { .. } => "bytes/string",
            Ty::Mapping { .. } => "mapping",
            Ty::DynArray { .. } => "dynamic array",
            Ty::StaticArray { .. } => "static array",
            Ty::Struct { .. } | Ty::Recursive { .. } => "struct",
        }
    }
}

/// Expands `key` from `types`. `owner` names the variable that references it (for error messages).
pub fn describe(types: &TypeTable, key: &str, owner: &str) -> Result<Ty, Error> {
    let mut stack = Vec::new();
    describe_inner(types, key, owner, &mut stack)
}

fn describe_inner(types: &TypeTable, key: &str, owner: &str, stack: &mut Vec<String>) -> Result<Ty, Error> {
    let info = types.get(key).ok_or_else(|| Error::UnknownType {
        ty: key.to_owned(),
        label: owner.to_owned(),
    })?;
    if stack.iter().any(|k| k == key) {
        return Ok(Ty::Recursive {
            label: info.label.clone(),
        });
    }
    stack.push(key.to_owned());
    let bytes = u64::try_from(parse_u256(&info.number_of_bytes)?).map_err(|_| Error::TooLarge {
        label: owner.to_owned(),
        bytes: info.number_of_bytes.clone(),
    })?;
    let child = |k: &Option<String>, stack: &mut Vec<String>| -> Result<Box<Ty>, Error> {
        let k = k.as_deref().ok_or_else(|| Error::UnknownType {
            ty: format!("{key} (child)"),
            label: owner.to_owned(),
        })?;
        Ok(Box::new(describe_inner(types, k, owner, stack)?))
    };
    let ty = match info.encoding.as_str() {
        "mapping" => Ty::Mapping {
            key: child(&info.key, stack)?,
            value: child(&info.value, stack)?,
        },
        "dynamic_array" => Ty::DynArray {
            base: child(&info.base, stack)?,
        },
        "bytes" => Ty::Bytes {
            label: info.label.clone(),
        },
        _ => {
            if let Some(members) = &info.members {
                let mut out = Vec::with_capacity(members.len());
                for m in members {
                    out.push(Member {
                        label: m.label.clone(),
                        slot: parse_u256(&m.slot)?,
                        offset: m.offset,
                        ty: describe_inner(types, &m.ty, &m.label, stack)?,
                    });
                }
                Ty::Struct {
                    label: info.label.clone(),
                    bytes,
                    members: out,
                }
            } else if info.base.is_some() {
                Ty::StaticArray {
                    base: child(&info.base, stack)?,
                    bytes,
                }
            } else {
                Ty::Value {
                    label: info.label.clone(),
                    bytes,
                }
            }
        }
    };
    stack.pop();
    Ok(ty)
}

/// How a new type relates to the old type stored at the same position.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Compat {
    /// Identical.
    Same,
    /// Different name, same bytes and same meaning of the stored bits (e.g. `address` to `contract IERC20`).
    Relabeled(String),
    /// Reading the old bytes with the new type is wrong.
    Incompatible(String),
}

impl Compat {
    fn join(self, other: Compat) -> Compat {
        match (self, other) {
            (Compat::Incompatible(a), _) | (_, Compat::Incompatible(a)) => Compat::Incompatible(a),
            (Compat::Relabeled(a), Compat::Relabeled(b)) => Compat::Relabeled(format!("{a}; {b}")),
            (Compat::Relabeled(a), Compat::Same) | (Compat::Same, Compat::Relabeled(a)) => Compat::Relabeled(a),
            (Compat::Same, Compat::Same) => Compat::Same,
        }
    }
}

/// Where a type lives; it decides whether a struct may grow.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Context {
    /// Stored in place among other variables: its size must not change.
    Inline,
    /// Value of a mapping: every value has its own hashed location, so members may be appended.
    MappingValue,
}

fn is_address_like(label: &str) -> bool {
    label == "address" || label == "address payable" || label.starts_with("contract ")
}

/// Upgrade compatibility of `new` stored where `old` was.
pub fn compat(old: &Ty, new: &Ty, ctx: Context) -> Compat {
    match (old, new) {
        (Ty::Value { label: a, bytes: x }, Ty::Value { label: b, bytes: y }) => {
            if x != y {
                Compat::Incompatible(format!("{a} ({x} bytes) became {b} ({y} bytes)"))
            } else if a == b {
                Compat::Same
            } else if is_address_like(a) && is_address_like(b) {
                Compat::Relabeled(format!("{a} became {b} (same 20-byte address encoding)"))
            } else if a.starts_with("enum ") && b.starts_with("enum ") {
                Compat::Relabeled(format!("{a} became {b} (same size; check the member order)"))
            } else {
                Compat::Incompatible(format!("{a} became {b}"))
            }
        }
        (Ty::Bytes { label: a }, Ty::Bytes { label: b }) => {
            if a == b {
                Compat::Same
            } else {
                Compat::Relabeled(format!("{a} became {b} (same encoding)"))
            }
        }
        (Ty::Mapping { key: k1, value: v1 }, Ty::Mapping { key: k2, value: v2 }) => {
            let keys = match compat(k1, k2, Context::Inline) {
                Compat::Same => Compat::Same,
                Compat::Relabeled(r) => Compat::Relabeled(format!("mapping key: {r}")),
                Compat::Incompatible(r) => Compat::Incompatible(format!("mapping key: {r}")),
            };
            keys.join(compat(v1, v2, Context::MappingValue))
        }
        (Ty::DynArray { base: a }, Ty::DynArray { base: b }) => match compat(a, b, Context::Inline) {
            Compat::Incompatible(r) => Compat::Incompatible(format!("array element: {r}")),
            other => other,
        },
        (Ty::StaticArray { base: a, bytes: x }, Ty::StaticArray { base: b, bytes: y }) => {
            if x != y {
                Compat::Incompatible(format!("{} became {} (array length changed)", old.label(), new.label()))
            } else {
                compat(a, b, Context::Inline)
            }
        }
        (
            Ty::Struct {
                label: la,
                bytes: x,
                members: ma,
            },
            Ty::Struct {
                label: lb,
                bytes: y,
                members: mb,
            },
        ) => struct_compat(la, *x, ma, lb, *y, mb, ctx),
        (Ty::Recursive { label: a }, Ty::Recursive { label: b }) => {
            if a == b {
                Compat::Same
            } else {
                Compat::Relabeled(format!("{a} became {b}"))
            }
        }
        _ => Compat::Incompatible(format!(
            "{} ({}) became {} ({})",
            old.label(),
            old.kind(),
            new.label(),
            new.kind()
        )),
    }
}

fn struct_compat(la: &str, x: u64, ma: &[Member], lb: &str, y: u64, mb: &[Member], ctx: Context) -> Compat {
    let mut result = if la == lb {
        Compat::Same
    } else {
        Compat::Relabeled(format!("{la} became {lb}"))
    };
    for (i, old_m) in ma.iter().enumerate() {
        let Some(new_m) = mb.get(i) else {
            return Compat::Incompatible(format!("{la}: member `{}` was removed", old_m.label));
        };
        if new_m.slot != old_m.slot || new_m.offset != old_m.offset {
            return Compat::Incompatible(format!(
                "{la}: member `{}` moved from slot +{} offset {} to slot +{} offset {}",
                old_m.label, old_m.slot, old_m.offset, new_m.slot, new_m.offset
            ));
        }
        match compat(&old_m.ty, &new_m.ty, Context::Inline) {
            Compat::Incompatible(r) => return Compat::Incompatible(format!("{la}.{}: {r}", old_m.label)),
            Compat::Relabeled(r) => result = result.join(Compat::Relabeled(format!("{la}.{}: {r}", old_m.label))),
            Compat::Same => {}
        }
        if new_m.label != old_m.label {
            result = result.join(Compat::Relabeled(format!(
                "{la}: member `{}` renamed to `{}`",
                old_m.label, new_m.label
            )));
        }
    }
    if x != y && ctx == Context::Inline {
        return Compat::Incompatible(format!(
            "{la} grew from {x} to {y} bytes in place: every variable declared after it shifts"
        ));
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(label: &str, bytes: u64) -> Ty {
        Ty::Value {
            label: label.into(),
            bytes,
        }
    }

    fn member(label: &str, slot: u8, offset: u32, ty: Ty) -> Member {
        Member {
            label: label.into(),
            slot: U256::from(slot),
            offset,
            ty,
        }
    }

    #[test]
    fn value_types() {
        assert_eq!(
            compat(&v("uint256", 32), &v("uint256", 32), Context::Inline),
            Compat::Same
        );
        assert!(matches!(
            compat(&v("uint64", 8), &v("uint128", 16), Context::Inline),
            Compat::Incompatible(_)
        ));
        assert!(matches!(
            compat(&v("uint256", 32), &v("int256", 32), Context::Inline),
            Compat::Incompatible(_)
        ));
        assert!(matches!(
            compat(&v("address", 20), &v("contract IERC20", 20), Context::Inline),
            Compat::Relabeled(_)
        ));
        assert!(matches!(
            compat(&v("enum A.E", 1), &v("enum B.E", 1), Context::Inline),
            Compat::Relabeled(_)
        ));
    }

    #[test]
    fn structs_may_grow_only_behind_a_mapping() {
        let old = Ty::Struct {
            label: "struct S".into(),
            bytes: 32,
            members: vec![member("a", 0, 0, v("uint256", 32))],
        };
        let grown = Ty::Struct {
            label: "struct S".into(),
            bytes: 64,
            members: vec![member("a", 0, 0, v("uint256", 32)), member("b", 1, 0, v("uint256", 32))],
        };
        assert_eq!(compat(&old, &grown, Context::MappingValue), Compat::Same);
        assert!(matches!(compat(&old, &grown, Context::Inline), Compat::Incompatible(_)));
        let mapping = |t: Ty| Ty::Mapping {
            key: Box::new(v("address", 20)),
            value: Box::new(t),
        };
        assert_eq!(
            compat(&mapping(old.clone()), &mapping(grown), Context::Inline),
            Compat::Same
        );
        let dyn_old = Ty::DynArray {
            base: Box::new(old.clone()),
        };
        let dyn_new = Ty::DynArray {
            base: Box::new(Ty::Struct {
                label: "struct S".into(),
                bytes: 64,
                members: vec![member("a", 0, 0, v("uint256", 32)), member("b", 1, 0, v("uint256", 32))],
            }),
        };
        assert!(
            matches!(compat(&dyn_old, &dyn_new, Context::Inline), Compat::Incompatible(_)),
            "array stride changes"
        );
    }

    #[test]
    fn struct_member_reorder_and_rename() {
        let a = Ty::Struct {
            label: "struct S".into(),
            bytes: 64,
            members: vec![member("x", 0, 0, v("uint256", 32)), member("y", 1, 0, v("address", 20))],
        };
        let swapped = Ty::Struct {
            label: "struct S".into(),
            bytes: 64,
            members: vec![member("y", 0, 0, v("address", 20)), member("x", 1, 0, v("uint256", 32))],
        };
        assert!(matches!(
            compat(&a, &swapped, Context::MappingValue),
            Compat::Incompatible(_)
        ));
        let renamed = Ty::Struct {
            label: "struct S".into(),
            bytes: 64,
            members: vec![
                member("x", 0, 0, v("uint256", 32)),
                member("owner", 1, 0, v("address", 20)),
            ],
        };
        assert!(matches!(compat(&a, &renamed, Context::Inline), Compat::Relabeled(_)));
    }

    #[test]
    fn kind_changes_and_mapping_keys() {
        let map = |k: &str, kb: u64| Ty::Mapping {
            key: Box::new(v(k, kb)),
            value: Box::new(v("uint256", 32)),
        };
        assert!(matches!(
            compat(&map("address", 20), &map("uint256", 32), Context::Inline),
            Compat::Incompatible(_)
        ));
        assert!(matches!(
            compat(&map("address", 20), &map("contract IERC20", 20), Context::Inline),
            Compat::Relabeled(_)
        ));
        assert!(matches!(
            compat(
                &v("uint256", 32),
                &Ty::Bytes { label: "string".into() },
                Context::Inline
            ),
            Compat::Incompatible(_)
        ));
        let arr = |n: u64| Ty::StaticArray {
            base: Box::new(v("uint256", 32)),
            bytes: 32 * n,
        };
        assert!(matches!(
            compat(&arr(3), &arr(4), Context::Inline),
            Compat::Incompatible(_)
        ));
        assert_eq!(compat(&arr(3), &arr(3), Context::Inline), Compat::Same);
    }
}
