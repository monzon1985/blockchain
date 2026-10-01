// SPDX-License-Identifier: MIT
//! Input formats and the resolved storage model.
//!
//! Two JSON shapes are accepted:
//! - the raw output of `forge inspect <Contract> storageLayout --json` (`storage` + `types`). It carries no
//!   ERC-7201 information at all, so the CLI only accepts it with `--sequential-only`;
//! - a lab snapshot: the same two fields plus `namespaces`, one entry per ERC-7201 namespace. Each entry holds the
//!   `forge inspect` output of a *probe* contract (`contract P layout at <base> { S internal $; }`), which makes solc
//!   report the namespace struct at its absolute base slot, and the `accessors`: every function of the contract's
//!   code that points a storage pointer of that struct somewhere (`$.slot := ...`), with the location the driver
//!   resolved from the AST.

use std::collections::BTreeMap;
use std::path::Path;

use ruint::aliases::U256;
use serde::{Deserialize, Serialize};

use crate::erc7201::erc7201_slot;
use crate::error::Error;

/// One entry of a solc storage layout (`storage[]` or a struct's `members[]`).
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct StorageEntry {
    /// AST id of the declaration (dropped by the lab's normalizer; unused by the analysis).
    #[serde(rename = "astId", default, skip_serializing_if = "Option::is_none")]
    pub ast_id: Option<u64>,
    /// Contract the layout was computed for, as `path:Name`.
    #[serde(default)]
    pub contract: String,
    /// Variable or member name.
    pub label: String,
    /// Byte offset inside the slot.
    pub offset: u32,
    /// Slot as a decimal string (solc) or 0x-hex.
    pub slot: String,
    /// Key into the `types` table.
    #[serde(rename = "type")]
    pub ty: String,
}

/// One entry of the solc `types` table.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct TypeInfo {
    /// `inplace`, `mapping`, `dynamic_array` or `bytes`.
    pub encoding: String,
    /// Human-readable type, e.g. `mapping(address => uint256)`.
    pub label: String,
    /// Size in storage, as a decimal string.
    #[serde(rename = "numberOfBytes")]
    pub number_of_bytes: String,
    /// Mapping key type.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    /// Mapping value type.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    /// Array element type.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
    /// Struct members.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub members: Option<Vec<StorageEntry>>,
}

/// The solc `types` table.
pub type TypeTable = BTreeMap<String, TypeInfo>;

/// Exactly what `forge inspect <C> storageLayout --json` prints.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct RawLayout {
    /// State variables in declaration order.
    #[serde(default)]
    pub storage: Vec<StorageEntry>,
    /// Type table (`null` when the contract has no state variables).
    #[serde(default)]
    pub types: Option<TypeTable>,
}

/// The location an accessor assigns to a namespace struct's storage pointer, as the driver resolved it from the
/// compiled AST (constants, the `erc7201` builtin and pure getters are followed; anything else stays unresolved).
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum AccessorLocation {
    /// `erc7201("<id>")`: the tool computes the slot.
    Erc7201(String),
    /// A literal slot, decimal or `0x`-hex.
    Slot(String),
    /// An expression the driver could not evaluate statically (its source text).
    Unresolved(String),
}

/// One accessor of a namespace in a snapshot.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct AccessorSnapshot {
    /// `Contract.function` (or `Library.function`) that assigns the pointer's `.slot`.
    pub function: String,
    /// What it assigns.
    pub location: AccessorLocation,
}

/// An ERC-7201 namespace in a snapshot.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct NamespaceSnapshot {
    /// Namespace id, as in `@custom:storage-location erc7201:<id>`.
    pub id: String,
    /// Canonical name of the namespace struct (informational).
    #[serde(rename = "struct", default, skip_serializing_if = "Option::is_none")]
    pub struct_name: Option<String>,
    /// Every function of the analysed code that places a pointer to this struct (`$.slot := ...`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub accessors: Vec<AccessorSnapshot>,
    /// `forge inspect` output of the probe contract.
    pub layout: RawLayout,
}

/// A lab snapshot (a superset of [`RawLayout`]).
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Snapshot {
    /// Contract name (informational).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contract: Option<String>,
    /// Sequential state variables.
    #[serde(default)]
    pub storage: Vec<StorageEntry>,
    /// Type table of the sequential variables.
    #[serde(default)]
    pub types: Option<TypeTable>,
    /// ERC-7201 namespaces, each described by a probe layout. Absent (not merely empty) in raw `forge inspect`
    /// output, which cannot see namespaces at all.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub namespaces: Option<Vec<NamespaceSnapshot>>,
}

/// A byte position in storage: `slot * 32 + byte`, kept as a pair so that slots near 2^256 never overflow.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Pos {
    /// Slot.
    pub slot: U256,
    /// Byte inside the slot, 0..32.
    pub byte: u64,
}

/// A variable (or a namespace member) placed in storage.
#[derive(Clone, Debug)]
pub struct Var {
    /// Name.
    pub label: String,
    /// Slot (absolute for sequential storage, relative to the base for namespace members).
    pub slot: U256,
    /// Byte offset inside the slot.
    pub offset: u32,
    /// Size in bytes.
    pub bytes: u64,
    /// Key into the region's type table.
    pub ty: String,
    /// Reserved storage (see [`is_reserved_declaration`]).
    pub reserved: bool,
}

/// Reserved storage follows the OpenZeppelin `__gap` convention, and only that convention: a name starting with
/// `__` **and** a fixed-size array of `uint256` (`uint256[47] __gap`, `uint256[1] __retiredOwnerSlot`). Its slots may
/// be handed to new variables. Any other variable is live, whatever its name, so a real `uint256 __counter` that
/// is removed, moved or retyped is reported like any other variable.
pub fn is_reserved_declaration(label: &str, ty: Option<&TypeInfo>) -> bool {
    label.starts_with("__")
        && ty.is_some_and(|t| t.encoding == "inplace" && t.members.is_none() && t.base.as_deref() == Some("t_uint256"))
}

impl Var {
    /// Whether the variable is reserved space rather than live state.
    pub fn is_reserved(&self) -> bool {
        self.reserved
    }

    /// First byte occupied.
    pub fn start(&self) -> Pos {
        Pos {
            slot: self.slot,
            byte: u64::from(self.offset),
        }
    }

    /// One past the last byte occupied.
    pub fn end(&self) -> Pos {
        let total = u64::from(self.offset) + self.bytes;
        Pos {
            slot: self.slot.saturating_add(U256::from(total / 32)),
            byte: total % 32,
        }
    }

    /// First slot after the variable.
    pub fn end_slot(&self) -> U256 {
        let end = self.end();
        if end.byte == 0 {
            end.slot
        } else {
            end.slot.saturating_add(U256::from(1u8))
        }
    }

    /// Whether two variables share at least one byte.
    pub fn overlaps(&self, other: &Var) -> bool {
        self.start() < other.end() && other.start() < self.end()
    }

    /// `slot 3` or `slot 3 offset 8`.
    pub fn position(&self) -> String {
        if self.offset == 0 {
            format!("slot {}", self.slot)
        } else {
            format!("slot {} offset {}", self.slot, self.offset)
        }
    }
}

/// Variables that share one type table: the sequential storage of a contract, or the members of one namespace.
#[derive(Clone, Debug, Default)]
pub struct Region {
    /// Variables in declaration order.
    pub vars: Vec<Var>,
    /// Type table the variables refer to.
    pub types: TypeTable,
}

impl Region {
    /// First slot after the last variable (0 for an empty region).
    pub fn end_slot(&self) -> U256 {
        self.vars.iter().map(Var::end_slot).max().unwrap_or(U256::ZERO)
    }
}

/// Where an accessor points a namespace struct.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AccessorSlot {
    /// A statically known slot.
    Resolved(U256),
    /// An expression the driver could not evaluate (source text).
    Unresolved(String),
}

/// A function that places a pointer to a namespace struct.
#[derive(Clone, Debug)]
pub struct Accessor {
    /// `Contract.function`.
    pub function: String,
    /// The slot it assigns.
    pub slot: AccessorSlot,
}

/// A resolved ERC-7201 namespace.
#[derive(Clone, Debug)]
pub struct Namespace {
    /// Namespace id.
    pub id: String,
    /// Canonical struct name, when provided.
    pub struct_name: Option<String>,
    /// Declared base slot (where the probe placed the struct).
    pub base: U256,
    /// Type label of the namespace struct, e.g. `struct OwnableUpgradeable.OwnableStorage`.
    pub root_label: String,
    /// Size of the struct in bytes.
    pub bytes: u64,
    /// Struct members, slots relative to `base`.
    pub members: Region,
    /// Where the production code actually points the struct.
    pub accessors: Vec<Accessor>,
}

impl Namespace {
    /// Number of consecutive slots the struct occupies from `base` (static part only; mappings and dynamic
    /// arrays store their data at hashed locations).
    pub fn slot_count(&self) -> U256 {
        U256::from(self.bytes.div_ceil(32).max(1))
    }

    /// `erc7201:<id>`, the region name used in findings.
    pub fn region_name(&self) -> String {
        format!("erc7201:{}", self.id)
    }
}

/// A fully resolved layout.
#[derive(Clone, Debug)]
pub struct Layout {
    /// Display name (contract name or file stem).
    pub name: String,
    /// Sequential storage.
    pub sequential: Region,
    /// ERC-7201 namespaces.
    pub namespaces: Vec<Namespace>,
    /// False for raw `forge inspect` input: the namespaces (if any) are unknown, not absent.
    pub namespaces_known: bool,
}

/// Parses a decimal or `0x`-prefixed hexadecimal integer of at most 256 bits.
pub fn parse_u256(text: &str) -> Result<U256, Error> {
    let trimmed = text.trim();
    let parsed = match trimmed.strip_prefix("0x").or_else(|| trimmed.strip_prefix("0X")) {
        Some(hex) => U256::from_str_radix(hex, 16),
        None => U256::from_str_radix(trimmed, 10),
    };
    parsed.map_err(|_| Error::Integer(text.to_owned()))
}

fn parse_bytes(label: &str, text: &str) -> Result<u64, Error> {
    let value = parse_u256(text)?;
    u64::try_from(value).map_err(|_| Error::TooLarge {
        label: label.to_owned(),
        bytes: text.to_owned(),
    })
}

fn resolve_vars(entries: &[StorageEntry], types: &TypeTable) -> Result<Vec<Var>, Error> {
    entries
        .iter()
        .map(|e| {
            let info = types.get(&e.ty).ok_or_else(|| Error::UnknownType {
                ty: e.ty.clone(),
                label: e.label.clone(),
            })?;
            Ok(Var {
                label: e.label.clone(),
                slot: parse_u256(&e.slot)?,
                offset: e.offset,
                bytes: parse_bytes(&e.label, &info.number_of_bytes)?,
                ty: e.ty.clone(),
                reserved: is_reserved_declaration(&e.label, Some(info)),
            })
        })
        .collect()
}

fn resolve_accessor(a: &AccessorSnapshot) -> Result<Accessor, Error> {
    let slot = match &a.location {
        AccessorLocation::Erc7201(id) => AccessorSlot::Resolved(erc7201_slot(id)),
        AccessorLocation::Slot(text) => AccessorSlot::Resolved(parse_u256(text)?),
        AccessorLocation::Unresolved(expr) => AccessorSlot::Unresolved(expr.clone()),
    };
    Ok(Accessor {
        function: a.function.clone(),
        slot,
    })
}

fn resolve_namespace(ns: &NamespaceSnapshot) -> Result<Namespace, Error> {
    let types = ns.layout.types.clone().unwrap_or_default();
    let [root] = ns.layout.storage.as_slice() else {
        return Err(Error::BadProbe {
            id: ns.id.clone(),
            found: ns.layout.storage.len(),
        });
    };
    let info = types.get(&root.ty).ok_or_else(|| Error::UnknownType {
        ty: root.ty.clone(),
        label: root.label.clone(),
    })?;
    let Some(members) = &info.members else {
        return Err(Error::BadProbe {
            id: ns.id.clone(),
            found: 0,
        });
    };
    Ok(Namespace {
        id: ns.id.clone(),
        struct_name: ns.struct_name.clone(),
        base: parse_u256(&root.slot)?,
        root_label: info.label.clone(),
        bytes: parse_bytes(&root.label, &info.number_of_bytes)?,
        members: Region {
            vars: resolve_vars(members, &types)?,
            types: types.clone(),
        },
        accessors: ns
            .accessors
            .iter()
            .map(resolve_accessor)
            .collect::<Result<Vec<_>, _>>()?,
    })
}

impl Layout {
    /// Resolves a snapshot (or a raw `forge inspect` layout) into the storage model.
    pub fn from_snapshot(name: &str, snapshot: &Snapshot) -> Result<Self, Error> {
        let types = snapshot.types.clone().unwrap_or_default();
        let sequential = Region {
            vars: resolve_vars(&snapshot.storage, &types)?,
            types,
        };
        let namespaces = snapshot
            .namespaces
            .iter()
            .flatten()
            .map(resolve_namespace)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Layout {
            name: snapshot.contract.clone().unwrap_or_else(|| name.to_owned()),
            sequential,
            namespaces,
            namespaces_known: snapshot.namespaces.is_some(),
        })
    }

    /// Reads and resolves a JSON file.
    pub fn load(path: &Path) -> Result<Self, Error> {
        let text = std::fs::read_to_string(path).map_err(|source| Error::Io {
            path: path.display().to_string(),
            source,
        })?;
        let snapshot: Snapshot = serde_json::from_str(&text).map_err(|source| Error::Json {
            path: path.display().to_string(),
            source,
        })?;
        let stem = path
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        Self::from_snapshot(&stem, &snapshot)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn var(label: &str, slot: u64, offset: u32, bytes: u64) -> Var {
        Var {
            label: label.into(),
            slot: U256::from(slot),
            offset,
            bytes,
            ty: "t".into(),
            reserved: false,
        }
    }

    fn type_info(label: &str, base: Option<&str>) -> TypeInfo {
        TypeInfo {
            encoding: "inplace".into(),
            label: label.into(),
            number_of_bytes: "32".into(),
            key: None,
            value: None,
            base: base.map(Into::into),
            members: None,
        }
    }

    #[test]
    fn parses_decimal_and_hex_slots() {
        assert_eq!(parse_u256("201").ok(), Some(U256::from(201u16)));
        assert_eq!(parse_u256("0xff").ok(), Some(U256::from(255u16)));
        assert!(parse_u256("-1").is_err());
        assert!(parse_u256("0x1_0000000000000000000000000000000000000000000000000000000000000000").is_err());
    }

    #[test]
    fn positions_of_packed_variables() {
        let a = var("a", 1, 0, 8);
        let b = var("b", 1, 8, 8);
        let wide = var("w", 1, 0, 16);
        assert!(!a.overlaps(&b));
        assert!(wide.overlaps(&b));
        assert_eq!(a.end_slot(), U256::from(2u8));
        let gap = var("__gap", 2, 0, 32 * 49);
        assert_eq!(gap.end_slot(), U256::from(51u8));
    }

    #[test]
    fn only_uint256_arrays_named_with_two_underscores_are_reserved() {
        let gap = type_info("uint256[49]", Some("t_uint256"));
        assert!(is_reserved_declaration("__gap", Some(&gap)));
        assert!(is_reserved_declaration("__legacyOwnableGap", Some(&gap)));
        assert!(is_reserved_declaration(
            "__retiredOwnerSlot",
            Some(&type_info("uint256[1]", Some("t_uint256")))
        ));
        // A real variable that happens to start with `__` is live.
        assert!(!is_reserved_declaration("__counter", Some(&type_info("uint256", None))));
        assert!(!is_reserved_declaration(
            "__owners",
            Some(&type_info("address[3]", Some("t_address")))
        ));
        // A gap-shaped array without the prefix is live too.
        assert!(!is_reserved_declaration("gap", Some(&gap)));
        assert!(!is_reserved_declaration("__gap", None));
    }

    #[test]
    fn slots_near_the_top_do_not_overflow() {
        let top = Var {
            slot: U256::MAX,
            ..var("x", 0, 0, 64)
        };
        assert_eq!(top.end_slot(), U256::MAX);
    }

    #[test]
    fn raw_input_has_unknown_namespaces_while_an_empty_list_is_known() {
        let raw: Snapshot = serde_json::from_str(r#"{"storage": [], "types": null}"#).unwrap();
        assert!(!Layout::from_snapshot("raw", &raw).unwrap().namespaces_known);
        let snap: Snapshot = serde_json::from_str(r#"{"storage": [], "types": null, "namespaces": []}"#).unwrap();
        assert!(Layout::from_snapshot("snap", &snap).unwrap().namespaces_known);
    }

    #[test]
    fn accessor_locations_resolve() {
        let erc = resolve_accessor(&AccessorSnapshot {
            function: "L.f".into(),
            location: AccessorLocation::Erc7201("example.main".into()),
        })
        .unwrap();
        assert_eq!(erc.slot, AccessorSlot::Resolved(erc7201_slot("example.main")));
        let lit = resolve_accessor(&AccessorSnapshot {
            function: "L.g".into(),
            location: AccessorLocation::Slot("0x10".into()),
        })
        .unwrap();
        assert_eq!(lit.slot, AccessorSlot::Resolved(U256::from(16u8)));
        let json = r#"{"function": "L.h", "location": {"unresolved": "keccak256(x)"}}"#;
        let parsed: AccessorSnapshot = serde_json::from_str(json).unwrap();
        assert_eq!(
            resolve_accessor(&parsed).unwrap().slot,
            AccessorSlot::Unresolved("keccak256(x)".into())
        );
    }
}
