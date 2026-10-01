// SPDX-License-Identifier: MIT
//! EIP-712 typed structured data hashing from `eth_signTypedData_v4` JSON.
//!
//! ```text
//! encodeType(S) = "S(t1 n1,...)" ++ sorted(encodeType(dependencies of S))
//! hashStruct(s) = keccak256(keccak256(encodeType(S)) ‖ encodeData(s))
//! digest        = keccak256(0x19 0x01 ‖ hashStruct(domain) ‖ hashStruct(message))
//! ```
//!
//! Supported member types: `uint8..uint256`, `int8..int256`, `bool`, `address`, `bytes1..bytes32`,
//! `bytes`, `string`, struct references, and arrays `T[]` / `T[k]` nested to any depth.
//!
//! The parser is deliberately strict because a signer must hash exactly what the operator
//! reviewed: unknown types, duplicate members, missing values, **extra message fields that the
//! type does not declare** (they would be displayed but not signed), wrong `bytesN` lengths,
//! out-of-range integers and lossy JSON floats are all errors. Type names follow the Solidity
//! grammar exactly: bit widths and `bytesN` lengths are plain ASCII digits without a sign or a
//! leading zero (`uint+8` and `bytes01` are errors, not aliases), and member names must be
//! identifiers. When `primaryType` is `EIP712Domain` the digest omits the message hash
//! (MetaMask / alloy compatibility).
//!
//! Hostile inputs are bounded before any recursive work: at most [`MAX_TYPES`] declared types,
//! at most [`MAX_DEPTH`] array dimensions per member type, and at most [`MAX_DEPTH`] levels of
//! struct / array nesting while hashing. Dependency collection is iterative, so a long chain
//! of struct types cannot exhaust the stack.

use crate::address::Address;
use crate::gas::{Finding, Severity};
use crate::hash::keccak256;
use crate::hex;
use crate::u256::U256;
use alloc::collections::{BTreeMap, BTreeSet};
use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec::Vec;
use serde_json::{Map, Value};

/// Maximum struct / array nesting while hashing values, and maximum number of array
/// dimensions in one member type.
pub const MAX_DEPTH: usize = 64;

/// Maximum number of struct types a document may declare (`EIP712Domain` included).
pub const MAX_TYPES: usize = 256;

/// The implicit domain members, in canonical order, used when `types.EIP712Domain` is absent.
const CANONICAL_DOMAIN: [(&str, &str); 5] = [
    ("name", "string"),
    ("version", "string"),
    ("chainId", "uint256"),
    ("verifyingContract", "address"),
    ("salt", "bytes32"),
];

/// Errors produced while parsing or hashing typed data.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Eip712Error {
    /// The input is not valid JSON or has the wrong shape.
    #[error("invalid typed-data JSON: {0}")]
    InvalidJson(String),
    /// A member type is neither atomic, dynamic, an array nor a declared struct.
    #[error("unknown type `{0}`")]
    UnknownType(String),
    /// A struct name shadows an atomic type or is malformed.
    #[error("invalid struct name `{0}`")]
    InvalidTypeName(String),
    /// A struct declares the same member twice.
    #[error("struct `{ty}` declares member `{member}` twice")]
    DuplicateMember {
        /// Struct name.
        ty: String,
        /// Duplicated member.
        member: String,
    },
    /// The value lacks a declared member.
    #[error("value of `{ty}` is missing member `{member}`")]
    MissingValue {
        /// Struct name.
        ty: String,
        /// Missing member.
        member: String,
    },
    /// The value has a member the type does not declare.
    #[error("value of `{ty}` has undeclared member `{member}`")]
    UndeclaredMember {
        /// Struct name.
        ty: String,
        /// Extra member.
        member: String,
    },
    /// A value cannot be encoded as its declared type.
    #[error("invalid `{ty}` value: {reason}")]
    InvalidValue {
        /// Declared type.
        ty: String,
        /// Why it failed.
        reason: String,
    },
    /// Nesting exceeds [`MAX_DEPTH`].
    #[error("typed data nested deeper than {0} levels")]
    TooDeep(usize),
    /// More than [`MAX_TYPES`] struct types are declared.
    #[error("typed data declares more than {0} types")]
    TooManyTypes(usize),
    /// A struct member name is not an identifier.
    #[error("struct `{ty}` has a member named `{member}`, which is not an identifier")]
    InvalidMemberName {
        /// Struct name.
        ty: String,
        /// Offending member name.
        member: String,
    },
}

fn invalid(ty: &str, reason: impl Into<String>) -> Eip712Error {
    Eip712Error::InvalidValue {
        ty: ty.to_string(),
        reason: reason.into(),
    }
}

/// Classification of a type string.
enum Kind<'a> {
    Array { inner: &'a str, len: Option<usize> },
    Uint(u32),
    Int(u32),
    FixedBytes(usize),
    Bool,
    Address,
    Bytes,
    String,
    Struct(&'a str),
}

/// A decimal number written as Solidity does: ASCII digits only, no sign, no leading zero
/// (Rust's integer parser alone would accept `+8` and `01`).
fn plain_decimal(s: &str) -> Option<usize> {
    if s.is_empty() || s.len() > 5 || s.starts_with('0') || !s.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

fn parse_bits(s: &str) -> Option<u32> {
    if s.is_empty() {
        return Some(256);
    }
    let bits = u32::try_from(plain_decimal(s)?).ok()?;
    (bits.is_multiple_of(8) && (8..=256).contains(&bits)).then_some(bits)
}

fn classify(ty: &str) -> Option<Kind<'_>> {
    if let Some(open) = ty.strip_suffix(']').and_then(|t| t.rfind('[')) {
        let inner = &ty[..open];
        let len_str = &ty[open + 1..ty.len() - 1];
        let len = if len_str.is_empty() {
            None
        } else {
            if !len_str.bytes().all(|c| c.is_ascii_digit()) || len_str.starts_with('0') {
                return None;
            }
            Some(len_str.parse().ok()?)
        };
        if inner.is_empty() {
            return None;
        }
        return Some(Kind::Array { inner, len });
    }
    match ty {
        "bool" => return Some(Kind::Bool),
        "address" => return Some(Kind::Address),
        "bytes" => return Some(Kind::Bytes),
        "string" => return Some(Kind::String),
        _ => {}
    }
    if let Some(bits) = ty.strip_prefix("uint") {
        return parse_bits(bits).map(Kind::Uint);
    }
    if let Some(bits) = ty.strip_prefix("int") {
        return parse_bits(bits).map(Kind::Int);
    }
    if let Some(n) = ty.strip_prefix("bytes") {
        let n = plain_decimal(n)?;
        return (1..=32).contains(&n).then_some(Kind::FixedBytes(n));
    }
    Some(Kind::Struct(ty))
}

/// One hashed leaf of a typed-data value, as shown in the operator review.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Field {
    /// Path from the root object, e.g. `from.wallet` or `items[2].amount`.
    pub path: String,
    /// Declared EIP-712 type of the leaf.
    pub ty: String,
    /// The value exactly as it is hashed.
    pub value: FieldValue,
}

/// The value of a typed-data leaf.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FieldValue {
    /// `uint8` .. `uint256`.
    Uint(U256),
    /// `int8` .. `int256`, as sign and magnitude.
    Int {
        /// `true` for values below zero.
        negative: bool,
        /// Absolute value.
        magnitude: U256,
    },
    /// `bool`.
    Bool(bool),
    /// `address`.
    Address(Address),
    /// `bytes` / `bytes1` .. `bytes32`.
    Bytes(Vec<u8>),
    /// `string`: untrusted text from the document.
    Text(String),
    /// An empty array (it is hashed, but has no leaves).
    EmptyArray,
}

/// Last path segments treated as expiry timestamps (compared case-insensitively).
const DEADLINE_NAMES: [&str; 7] = [
    "deadline",
    "expiry",
    "expiration",
    "sigdeadline",
    "validuntil",
    "validbefore",
    "endtime",
];

/// A deadline further in the future than this (relative to the signer's clock) is flagged.
pub const FAR_DEADLINE_SECS: u64 = 365 * 24 * 60 * 60;

fn uint_max(bits: u32) -> U256 {
    let mut b = [0u8; 32];
    // bits is a multiple of 8 in 8..=256 (parse_bits), so this is a whole number of bytes.
    let bytes = (bits / 8) as usize;
    for byte in b.iter_mut().skip(32 - bytes) {
        *byte = 0xff;
    }
    U256::from_be_bytes(b)
}

fn last_segment(path: &str) -> &str {
    let tail = path.rsplit('.').next().unwrap_or(path);
    tail.split('[').next().unwrap_or(tail)
}

fn is_reserved(name: &str) -> bool {
    !matches!(classify(name), Some(Kind::Struct(_)))
}

fn valid_ident(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_' || c == '$')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '$')
}

/// Parsed `eth_signTypedData_v4` payload.
#[derive(Debug, Clone, PartialEq)]
pub struct TypedData {
    types: BTreeMap<String, Vec<(String, String)>>,
    primary_type: String,
    domain: Value,
    message: Value,
}

fn take_object(v: &Value, what: &str) -> Result<Map<String, Value>, Eip712Error> {
    v.as_object()
        .cloned()
        .ok_or_else(|| Eip712Error::InvalidJson(format!("`{what}` must be an object")))
}

impl TypedData {
    /// Parses a typed-data JSON document.
    pub fn from_json_str(s: &str) -> Result<Self, Eip712Error> {
        let v: Value =
            serde_json::from_str(s).map_err(|e| Eip712Error::InvalidJson(e.to_string()))?;
        Self::from_value(&v)
    }

    /// Builds typed data from an already-parsed JSON value.
    pub fn from_value(v: &Value) -> Result<Self, Eip712Error> {
        let root = take_object(v, "typed data")?;
        let raw_types = take_object(
            root.get("types")
                .ok_or_else(|| Eip712Error::InvalidJson("missing `types`".into()))?,
            "types",
        )?;
        let primary_type = root
            .get("primaryType")
            .and_then(Value::as_str)
            .ok_or_else(|| Eip712Error::InvalidJson("missing string `primaryType`".into()))?
            .to_string();
        let domain = root
            .get("domain")
            .cloned()
            .unwrap_or_else(|| Value::Object(Map::new()));
        let domain_obj = take_object(&domain, "domain")?;
        let message = root
            .get("message")
            .cloned()
            .unwrap_or_else(|| Value::Object(Map::new()));
        for key in root.keys() {
            if !matches!(key.as_str(), "types" | "primaryType" | "domain" | "message") {
                return Err(Eip712Error::InvalidJson(format!(
                    "unexpected top-level key `{key}`"
                )));
            }
        }

        if raw_types.len() > MAX_TYPES {
            return Err(Eip712Error::TooManyTypes(MAX_TYPES));
        }
        let mut types = BTreeMap::new();
        for (name, members) in &raw_types {
            if is_reserved(name) || !valid_ident(name) {
                return Err(Eip712Error::InvalidTypeName(name.clone()));
            }
            let list = members.as_array().ok_or_else(|| {
                Eip712Error::InvalidJson(format!("members of `{name}` must be an array"))
            })?;
            let mut seen = BTreeSet::new();
            let mut fields = Vec::with_capacity(list.len());
            for m in list {
                let field_name = m.get("name").and_then(Value::as_str);
                let field_type = m.get("type").and_then(Value::as_str);
                let (Some(field_name), Some(field_type)) = (field_name, field_type) else {
                    return Err(Eip712Error::InvalidJson(format!(
                        "members of `{name}` need string `name` and `type`"
                    )));
                };
                if !valid_ident(field_name) {
                    return Err(Eip712Error::InvalidMemberName {
                        ty: name.clone(),
                        member: field_name.to_string(),
                    });
                }
                if !seen.insert(field_name.to_string()) {
                    return Err(Eip712Error::DuplicateMember {
                        ty: name.clone(),
                        member: field_name.to_string(),
                    });
                }
                fields.push((field_name.to_string(), field_type.to_string()));
            }
            types.insert(name.clone(), fields);
        }
        if !types.contains_key("EIP712Domain") {
            let mut inferred = Vec::new();
            for (name, ty) in CANONICAL_DOMAIN {
                if domain_obj.contains_key(name) {
                    inferred.push((name.to_string(), ty.to_string()));
                }
            }
            types.insert("EIP712Domain".to_string(), inferred);
        }
        let td = Self {
            types,
            primary_type,
            domain,
            message,
        };
        td.validate_types()?;
        if !td.types.contains_key(&td.primary_type) {
            return Err(Eip712Error::UnknownType(td.primary_type.clone()));
        }
        Ok(td)
    }

    fn validate_types(&self) -> Result<(), Eip712Error> {
        for fields in self.types.values() {
            for (_, ty) in fields {
                self.check_type(ty)?;
            }
        }
        Ok(())
    }

    /// Validates a member type iteratively: one loop step per array dimension, bounded by
    /// [`MAX_DEPTH`] (a type with 20,000 `[]` suffixes used to recurse once per suffix).
    fn check_type(&self, ty: &str) -> Result<(), Eip712Error> {
        let mut t = ty;
        let mut dims = 0usize;
        loop {
            match classify(t) {
                None => return Err(Eip712Error::UnknownType(ty.to_string())),
                Some(Kind::Array { inner, .. }) => {
                    dims += 1;
                    if dims > MAX_DEPTH {
                        return Err(Eip712Error::TooDeep(MAX_DEPTH));
                    }
                    t = inner;
                }
                Some(Kind::Struct(name)) if !self.types.contains_key(name) => {
                    return Err(Eip712Error::UnknownType(ty.to_string()));
                }
                Some(_) => return Ok(()),
            }
        }
    }

    /// The primary type name.
    pub fn primary_type(&self) -> &str {
        &self.primary_type
    }

    /// The domain object.
    pub fn domain(&self) -> &Value {
        &self.domain
    }

    /// The message object.
    pub fn message(&self) -> &Value {
        &self.message
    }

    fn members(&self, name: &str) -> Result<&[(String, String)], Eip712Error> {
        self.types
            .get(name)
            .map(Vec::as_slice)
            .ok_or_else(|| Eip712Error::UnknownType(name.to_string()))
    }

    fn base_struct(ty: &str) -> Option<&str> {
        let mut t = ty;
        while let Some(Kind::Array { inner, .. }) = classify(t) {
            t = inner;
        }
        match classify(t) {
            Some(Kind::Struct(name)) => Some(name),
            _ => None,
        }
    }

    /// Transitive struct dependencies of `name`, collected with an explicit work list (a
    /// chain of thousands of struct types used to recurse once per link).
    fn collect_deps(&self, name: &str, deps: &mut BTreeSet<String>) -> Result<(), Eip712Error> {
        let mut pending: Vec<&str> = alloc::vec![name];
        while let Some(current) = pending.pop() {
            for (_, ty) in self.members(current)? {
                if let Some(dep) = Self::base_struct(ty)
                    && deps.insert(dep.to_string())
                {
                    pending.push(dep);
                }
            }
        }
        Ok(())
    }

    fn encode_single(&self, name: &str) -> Result<String, Eip712Error> {
        let members = self.members(name)?;
        let body: Vec<String> = members.iter().map(|(n, t)| format!("{t} {n}")).collect();
        Ok(format!("{name}({})", body.join(",")))
    }

    /// `encodeType(name)`: the struct followed by its sorted transitive dependencies.
    pub fn encode_type(&self, name: &str) -> Result<String, Eip712Error> {
        let mut deps = BTreeSet::new();
        self.collect_deps(name, &mut deps)?;
        deps.remove(name);
        let mut out = self.encode_single(name)?;
        for dep in &deps {
            out.push_str(&self.encode_single(dep)?);
        }
        Ok(out)
    }

    /// `typeHash = keccak256(encodeType(name))`.
    pub fn type_hash(&self, name: &str) -> Result<[u8; 32], Eip712Error> {
        Ok(keccak256(self.encode_type(name)?.as_bytes()))
    }

    /// `hashStruct(name, value)`.
    pub fn hash_struct(&self, name: &str, value: &Value) -> Result<[u8; 32], Eip712Error> {
        self.hash_struct_at(name, value, 0)
    }

    fn hash_struct_at(
        &self,
        name: &str,
        value: &Value,
        depth: usize,
    ) -> Result<[u8; 32], Eip712Error> {
        if depth > MAX_DEPTH {
            return Err(Eip712Error::TooDeep(MAX_DEPTH));
        }
        let obj = value
            .as_object()
            .ok_or_else(|| invalid(name, "expected a JSON object"))?;
        let members = self.members(name)?;
        for key in obj.keys() {
            if !members.iter().any(|(n, _)| n == key) {
                return Err(Eip712Error::UndeclaredMember {
                    ty: name.to_string(),
                    member: key.clone(),
                });
            }
        }
        let mut buf = Vec::with_capacity(32 * (members.len() + 1));
        buf.extend_from_slice(&self.type_hash(name)?);
        for (member, ty) in members {
            let v = obj.get(member).ok_or_else(|| Eip712Error::MissingValue {
                ty: name.to_string(),
                member: member.clone(),
            })?;
            buf.extend_from_slice(&self.encode_value(ty, v, depth + 1)?);
        }
        Ok(keccak256(&buf))
    }

    fn encode_value(&self, ty: &str, v: &Value, depth: usize) -> Result<[u8; 32], Eip712Error> {
        if depth > MAX_DEPTH {
            return Err(Eip712Error::TooDeep(MAX_DEPTH));
        }
        let kind = classify(ty).ok_or_else(|| Eip712Error::UnknownType(ty.to_string()))?;
        match kind {
            Kind::Array { inner, len } => {
                let items = v
                    .as_array()
                    .ok_or_else(|| invalid(ty, "expected a JSON array"))?;
                if let Some(expected) = len
                    && items.len() != expected
                {
                    return Err(invalid(
                        ty,
                        format!("expected {expected} elements, got {}", items.len()),
                    ));
                }
                let mut buf = Vec::with_capacity(32 * items.len());
                for item in items {
                    buf.extend_from_slice(&self.encode_value(inner, item, depth + 1)?);
                }
                Ok(keccak256(&buf))
            }
            Kind::Struct(name) => self.hash_struct_at(name, v, depth),
            Kind::String => {
                let s = v.as_str().ok_or_else(|| invalid(ty, "expected a string"))?;
                Ok(keccak256(s.as_bytes()))
            }
            Kind::Bytes => Ok(keccak256(&hex_value(ty, v)?)),
            Kind::FixedBytes(n) => {
                let bytes = hex_value(ty, v)?;
                if bytes.len() != n {
                    return Err(invalid(
                        ty,
                        format!("expected {n} bytes, got {}", bytes.len()),
                    ));
                }
                let mut out = [0u8; 32];
                out[..n].copy_from_slice(&bytes);
                Ok(out)
            }
            Kind::Bool => Ok(U256::from_u64(u64::from(bool_value(ty, v)?)).to_be_bytes()),
            Kind::Address => {
                let a = address_value(ty, v)?;
                let mut out = [0u8; 32];
                out[12..].copy_from_slice(&a.0);
                Ok(out)
            }
            Kind::Uint(bits) => {
                let n = unsigned_value(ty, v)?;
                if n.bits() > bits {
                    return Err(invalid(ty, format!("value does not fit in {bits} bits")));
                }
                Ok(n.to_be_bytes())
            }
            Kind::Int(bits) => signed_value(ty, v, bits),
        }
    }

    /// `hashStruct(EIP712Domain, domain)`.
    pub fn domain_separator(&self) -> Result<[u8; 32], Eip712Error> {
        self.hash_struct("EIP712Domain", &self.domain)
    }

    /// `hashStruct(primaryType, message)`, or `None` when the primary type is the domain.
    pub fn message_hash(&self) -> Result<Option<[u8; 32]>, Eip712Error> {
        if self.primary_type == "EIP712Domain" {
            return Ok(None);
        }
        self.hash_struct(&self.primary_type, &self.message)
            .map(Some)
    }

    /// The digest to sign: `keccak256(0x1901 ‖ domainSeparator ‖ hashStruct(message))`.
    pub fn signing_hash(&self) -> Result<[u8; 32], Eip712Error> {
        let mut buf = Vec::with_capacity(66);
        buf.extend_from_slice(&[0x19, 0x01]);
        buf.extend_from_slice(&self.domain_separator()?);
        if let Some(h) = self.message_hash()? {
            buf.extend_from_slice(&h);
        }
        Ok(keccak256(&buf))
    }

    /// The domain's `chainId`, if present and numeric.
    pub fn domain_chain_id(&self) -> Option<U256> {
        self.domain
            .get("chainId")
            .and_then(|v| unsigned_value("uint256", v).ok())
    }

    /// The domain's `verifyingContract`, if present and well-formed.
    pub fn domain_verifying_contract(&self) -> Option<Address> {
        self.domain
            .get("verifyingContract")
            .and_then(Value::as_str)
            .and_then(|s| Address::parse(s).ok())
    }

    /// The hashed leaves of the domain, in declared member order.
    pub fn domain_fields(&self) -> Result<Vec<Field>, Eip712Error> {
        let mut out = Vec::new();
        self.flatten_struct("EIP712Domain", &self.domain, "", 0, &mut out)?;
        Ok(out)
    }

    /// The hashed leaves of the message, in declared member order (none when `primaryType`
    /// is `EIP712Domain`, whose digest omits the message).
    pub fn message_fields(&self) -> Result<Vec<Field>, Eip712Error> {
        let mut out = Vec::new();
        if self.primary_type != "EIP712Domain" {
            self.flatten_struct(&self.primary_type, &self.message, "", 0, &mut out)?;
        }
        Ok(out)
    }

    /// Operator warnings that do not make the document invalid:
    ///
    /// * `typed-data-no-chain-id`: the domain has no `chainId`, so the signature is valid on
    ///   every chain where the verifying contract accepts it;
    /// * `typed-data-max-uint`: a `uint32`..`uint256` leaf holds its type's maximum, the usual
    ///   encoding of an UNLIMITED allowance or of a permit that never expires;
    /// * `typed-data-far-deadline`: with `now` (Unix seconds from the signer's clock), a
    ///   deadline-like member more than [`FAR_DEADLINE_SECS`] away.
    pub fn review_findings(&self, now: Option<u64>) -> Result<Vec<Finding>, Eip712Error> {
        let mut out = Vec::new();
        if self.domain.get("chainId").is_none() {
            out.push(Finding {
                severity: Severity::Warning,
                code: "typed-data-no-chain-id",
                message: "the domain has no chainId: the signature is valid on every chain where \
                          the verifying contract accepts it"
                    .into(),
            });
        }
        let mut leaves = self.domain_fields()?;
        leaves.extend(self.message_fields()?);
        for f in &leaves {
            let (FieldValue::Uint(v), Some(Kind::Uint(bits))) = (&f.value, classify(&f.ty)) else {
                continue;
            };
            if bits >= 32 && *v == uint_max(bits) {
                out.push(Finding {
                    severity: Severity::Warning,
                    code: "typed-data-max-uint",
                    message: format!(
                        "`{}` is the maximum {} (2^{bits}-1): typically an UNLIMITED allowance or \
                         a signature that never expires",
                        f.path, f.ty
                    ),
                });
                continue;
            }
            let name = last_segment(&f.path).to_ascii_lowercase();
            if let Some(now) = now
                && DEADLINE_NAMES.contains(&name.as_str())
                && *v > U256::from_u64(now.saturating_add(FAR_DEADLINE_SECS))
            {
                out.push(Finding {
                    severity: Severity::Warning,
                    code: "typed-data-far-deadline",
                    message: format!(
                        "`{}` = {v} is more than a year after this machine's clock ({now}): the \
                         signature stays usable until then",
                        f.path
                    ),
                });
            }
        }
        Ok(out)
    }

    fn flatten_struct(
        &self,
        name: &str,
        value: &Value,
        prefix: &str,
        depth: usize,
        out: &mut Vec<Field>,
    ) -> Result<(), Eip712Error> {
        if depth > MAX_DEPTH {
            return Err(Eip712Error::TooDeep(MAX_DEPTH));
        }
        let obj = value
            .as_object()
            .ok_or_else(|| invalid(name, "expected a JSON object"))?;
        let members = self.members(name)?;
        for key in obj.keys() {
            if !members.iter().any(|(n, _)| n == key) {
                return Err(Eip712Error::UndeclaredMember {
                    ty: name.to_string(),
                    member: key.clone(),
                });
            }
        }
        for (member, ty) in members {
            let v = obj.get(member).ok_or_else(|| Eip712Error::MissingValue {
                ty: name.to_string(),
                member: member.clone(),
            })?;
            let path = if prefix.is_empty() {
                member.clone()
            } else {
                format!("{prefix}.{member}")
            };
            self.flatten_value(ty, v, path, depth + 1, out)?;
        }
        Ok(())
    }

    fn flatten_value(
        &self,
        ty: &str,
        v: &Value,
        path: String,
        depth: usize,
        out: &mut Vec<Field>,
    ) -> Result<(), Eip712Error> {
        if depth > MAX_DEPTH {
            return Err(Eip712Error::TooDeep(MAX_DEPTH));
        }
        let kind = classify(ty).ok_or_else(|| Eip712Error::UnknownType(ty.to_string()))?;
        let value = match kind {
            Kind::Array { inner, len } => {
                let items = v
                    .as_array()
                    .ok_or_else(|| invalid(ty, "expected a JSON array"))?;
                if let Some(expected) = len
                    && items.len() != expected
                {
                    return Err(invalid(
                        ty,
                        format!("expected {expected} elements, got {}", items.len()),
                    ));
                }
                if items.is_empty() {
                    out.push(Field {
                        path,
                        ty: ty.to_string(),
                        value: FieldValue::EmptyArray,
                    });
                    return Ok(());
                }
                for (i, item) in items.iter().enumerate() {
                    self.flatten_value(inner, item, format!("{path}[{i}]"), depth + 1, out)?;
                }
                return Ok(());
            }
            Kind::Struct(name) => return self.flatten_struct(name, v, &path, depth, out),
            Kind::String => FieldValue::Text(
                v.as_str()
                    .ok_or_else(|| invalid(ty, "expected a string"))?
                    .to_string(),
            ),
            Kind::Bytes => FieldValue::Bytes(hex_value(ty, v)?),
            Kind::FixedBytes(n) => {
                let bytes = hex_value(ty, v)?;
                if bytes.len() != n {
                    return Err(invalid(
                        ty,
                        format!("expected {n} bytes, got {}", bytes.len()),
                    ));
                }
                FieldValue::Bytes(bytes)
            }
            Kind::Bool => FieldValue::Bool(bool_value(ty, v)?),
            Kind::Address => FieldValue::Address(address_value(ty, v)?),
            Kind::Uint(bits) => {
                let n = unsigned_value(ty, v)?;
                if n.bits() > bits {
                    return Err(invalid(ty, format!("value does not fit in {bits} bits")));
                }
                FieldValue::Uint(n)
            }
            Kind::Int(bits) => {
                let (negative, magnitude) = signed_parts(ty, v, bits)?;
                FieldValue::Int {
                    negative: negative && !magnitude.is_zero(),
                    magnitude,
                }
            }
        };
        out.push(Field {
            path,
            ty: ty.to_string(),
            value,
        });
        Ok(())
    }
}

fn bool_value(ty: &str, v: &Value) -> Result<bool, Eip712Error> {
    match v {
        Value::Bool(b) => Ok(*b),
        Value::String(s) if s == "true" => Ok(true),
        Value::String(s) if s == "false" => Ok(false),
        _ => Err(invalid(ty, "expected a boolean")),
    }
}

fn address_value(ty: &str, v: &Value) -> Result<Address, Eip712Error> {
    let s = v
        .as_str()
        .ok_or_else(|| invalid(ty, "expected a hex string"))?;
    Address::parse(s).map_err(|e| invalid(ty, e.to_string()))
}

fn hex_value(ty: &str, v: &Value) -> Result<Vec<u8>, Eip712Error> {
    let s = v
        .as_str()
        .ok_or_else(|| invalid(ty, "expected a 0x-hex string"))?;
    if !s.starts_with("0x") && !s.starts_with("0X") {
        return Err(invalid(ty, "expected a 0x-hex string"));
    }
    hex::decode(s).map_err(|e| invalid(ty, e.to_string()))
}

fn unsigned_value(ty: &str, v: &Value) -> Result<U256, Eip712Error> {
    match v {
        Value::Number(n) => n.as_u64().map(U256::from_u64).ok_or_else(|| {
            invalid(
                ty,
                "negative, fractional or too-large JSON number (quote big integers)",
            )
        }),
        Value::String(s) => U256::parse(s).map_err(|e| invalid(ty, e.to_string())),
        _ => Err(invalid(ty, "expected a number or numeric string")),
    }
}

/// Parses an `intN` value into sign and magnitude, enforcing its range.
fn signed_parts(ty: &str, v: &Value, bits: u32) -> Result<(bool, U256), Eip712Error> {
    let (negative, magnitude) = match v {
        Value::Number(n) => match (n.as_u64(), n.as_i64()) {
            (Some(u), _) => (false, U256::from_u64(u)),
            (None, Some(i)) => (true, U256::from_u64(i.unsigned_abs())),
            _ => {
                return Err(invalid(
                    ty,
                    "fractional or too-large JSON number (quote big integers)",
                ));
            }
        },
        Value::String(s) => match s.strip_prefix('-') {
            Some(rest) => (
                true,
                U256::parse(rest).map_err(|e| invalid(ty, e.to_string()))?,
            ),
            None => (
                false,
                U256::parse(s).map_err(|e| invalid(ty, e.to_string()))?,
            ),
        },
        _ => return Err(invalid(ty, "expected a number or numeric string")),
    };
    // Range: [-2^(bits-1), 2^(bits-1) - 1].
    let limit_bits = bits - 1;
    let fits = if negative {
        // magnitude <= 2^(bits-1)  <=>  magnitude - 1 < 2^(bits-1)
        magnitude.is_zero()
            || magnitude
                .checked_sub(&U256::ONE)
                .is_some_and(|m| m.bits() <= limit_bits)
    } else {
        magnitude.bits() <= limit_bits
    };
    if !fits {
        return Err(invalid(
            ty,
            format!("value does not fit in {bits} signed bits"),
        ));
    }
    Ok((negative, magnitude))
}

fn signed_value(ty: &str, v: &Value, bits: u32) -> Result<[u8; 32], Eip712Error> {
    let (negative, magnitude) = signed_parts(ty, v, bits)?;
    if !negative || magnitude.is_zero() {
        return Ok(magnitude.to_be_bytes());
    }
    // Two's complement: 2^256 - magnitude = MAX - (magnitude - 1).
    let twos = magnitude
        .checked_sub(&U256::ONE)
        .and_then(|m| U256::MAX.checked_sub(&m))
        .ok_or_else(|| invalid(ty, "two's complement overflow"))?;
    Ok(twos.to_be_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The `Mail` example from the EIP-712 specification.
    pub(crate) const MAIL: &str = r#"{
      "types": {
        "EIP712Domain": [
          {"name": "name", "type": "string"},
          {"name": "version", "type": "string"},
          {"name": "chainId", "type": "uint256"},
          {"name": "verifyingContract", "type": "address"}
        ],
        "Person": [{"name": "name", "type": "string"}, {"name": "wallet", "type": "address"}],
        "Mail": [
          {"name": "from", "type": "Person"},
          {"name": "to", "type": "Person"},
          {"name": "contents", "type": "string"}
        ]
      },
      "primaryType": "Mail",
      "domain": {
        "name": "Ether Mail",
        "version": "1",
        "chainId": 1,
        "verifyingContract": "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"
      },
      "message": {
        "from": {"name": "Cow", "wallet": "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"},
        "to": {"name": "Bob", "wallet": "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"},
        "contents": "Hello, Bob!"
      }
    }"#;

    #[test]
    fn eip712_specification_example() {
        let td = TypedData::from_json_str(MAIL).unwrap();
        assert_eq!(
            td.encode_type("Mail").unwrap(),
            "Mail(Person from,Person to,string contents)Person(string name,address wallet)"
        );
        assert_eq!(
            hex::encode(&td.type_hash("Mail").unwrap()),
            "a0cedeb2dc280ba39b857546d74f5549c3a1d7bdc2dd96bf881f76108e23dac2"
        );
        assert_eq!(
            hex::encode(&td.domain_separator().unwrap()),
            "f2cee375fa42b42143804025fc449deafd50cc031ca257e0b194a650a912090f"
        );
        assert_eq!(
            hex::encode(&td.message_hash().unwrap().unwrap()),
            "c52c0ee5d84264471806290a3f2c4cecfc5490626bf912d01f240d7a274b371e"
        );
        assert_eq!(
            hex::encode(&td.signing_hash().unwrap()),
            "be609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2"
        );
        // The spec signs with keccak256("cow").
        let key = crate::keys::PrivateKey::from_bytes(&keccak256(b"cow")).unwrap();
        let sig = key.sign_hash(&td.signing_hash().unwrap()).unwrap();
        assert!(sig.y_parity, "the specification reports v = 28");
        assert_eq!(
            hex::encode(&sig.r.to_be_bytes()),
            "4355c47d63924e8a72e509b65029052eb6c299d53a04e167c5775fd466751c9d"
        );
        assert_eq!(
            hex::encode(&sig.s.to_be_bytes()),
            "07299936d304c153f6443dfa05f40ff007d72911b6f72307f996231605b91562"
        );
        assert_eq!(td.domain_chain_id(), Some(U256::ONE));
        assert!(td.domain_verifying_contract().is_some());
    }

    fn with(types: &str, primary: &str, message: &str) -> Result<[u8; 32], Eip712Error> {
        let json = format!(
            r#"{{"types":{types},"primaryType":"{primary}","domain":{{"name":"T","chainId":"0x1"}},"message":{message}}}"#
        );
        TypedData::from_json_str(&json)?.signing_hash()
    }

    #[test]
    fn value_encoding_rules() {
        let t = r#"{"S":[{"name":"a","type":"int8"},{"name":"b","type":"bytes2"},{"name":"c","type":"uint8[2]"},{"name":"d","type":"bool"}]}"#;
        assert!(
            with(
                t,
                "S",
                r#"{"a":-128,"b":"0x0102","c":[1,"0xff"],"d":"true"}"#
            )
            .is_ok()
        );
        assert!(with(t, "S", r#"{"a":"-128","b":"0x0102","c":[1,2],"d":false}"#).is_ok());
        assert!(matches!(
            with(t, "S", r#"{"a":-129,"b":"0x0102","c":[1,2],"d":true}"#),
            Err(Eip712Error::InvalidValue { .. })
        ));
        assert!(matches!(
            with(t, "S", r#"{"a":128,"b":"0x0102","c":[1,2],"d":true}"#),
            Err(Eip712Error::InvalidValue { .. })
        ));
        assert!(matches!(
            with(t, "S", r#"{"a":1,"b":"0x01","c":[1,2],"d":true}"#),
            Err(Eip712Error::InvalidValue { .. })
        ));
        assert!(matches!(
            with(t, "S", r#"{"a":1,"b":"0102","c":[1,2],"d":true}"#),
            Err(Eip712Error::InvalidValue { .. })
        ));
        assert!(matches!(
            with(t, "S", r#"{"a":1,"b":"0x0102","c":[1],"d":true}"#),
            Err(Eip712Error::InvalidValue { .. })
        ));
        assert!(matches!(
            with(t, "S", r#"{"a":1,"b":"0x0102","c":[1,256],"d":true}"#),
            Err(Eip712Error::InvalidValue { .. })
        ));
        assert!(matches!(
            with(t, "S", r#"{"a":1,"b":"0x0102","c":[1,2],"d":1}"#),
            Err(Eip712Error::InvalidValue { .. })
        ));
        assert!(matches!(
            with(t, "S", r#"{"a":1.5,"b":"0x0102","c":[1,2],"d":true}"#),
            Err(Eip712Error::InvalidValue { .. })
        ));
        assert_eq!(
            with(
                t,
                "S",
                r#"{"a":1,"b":"0x0102","c":[1,2],"d":true,"extra":1}"#
            ),
            Err(Eip712Error::UndeclaredMember {
                ty: "S".into(),
                member: "extra".into()
            })
        );
        assert_eq!(
            with(t, "S", r#"{"a":1,"b":"0x0102","c":[1,2]}"#),
            Err(Eip712Error::MissingValue {
                ty: "S".into(),
                member: "d".into()
            })
        );
        // -1 as int256 is all ones; "-0" is zero.
        let t2 = r#"{"S":[{"name":"a","type":"int256"}]}"#;
        assert_eq!(with(t2, "S", r#"{"a":"-0"}"#), with(t2, "S", r#"{"a":0}"#));
    }

    #[test]
    fn type_system_rules() {
        assert_eq!(
            with(r#"{"S":[{"name":"a","type":"Missing"}]}"#, "S", "{}"),
            Err(Eip712Error::UnknownType("Missing".into()))
        );
        assert_eq!(
            with(r#"{"S":[{"name":"a","type":"uint7"}]}"#, "S", "{}"),
            Err(Eip712Error::UnknownType("uint7".into()))
        );
        assert_eq!(
            with(r#"{"uint256":[]}"#, "uint256", "{}"),
            Err(Eip712Error::InvalidTypeName("uint256".into()))
        );
        assert_eq!(
            with(
                r#"{"S":[{"name":"a","type":"bool"},{"name":"a","type":"bool"}]}"#,
                "S",
                "{}"
            ),
            Err(Eip712Error::DuplicateMember {
                ty: "S".into(),
                member: "a".into()
            })
        );
        assert_eq!(
            with(r#"{"S":[]}"#, "Nope", "{}"),
            Err(Eip712Error::UnknownType("Nope".into()))
        );
        // Self-referential types terminate in encodeType and hash finite values.
        let tree = r#"{"Node":[{"name":"v","type":"uint256"},{"name":"kids","type":"Node[]"}]}"#;
        assert!(with(tree, "Node", r#"{"v":1,"kids":[{"v":2,"kids":[]}]}"#).is_ok());
        // Nested arrays.
        let nested = r#"{"S":[{"name":"m","type":"uint8[2][]"}]}"#;
        assert!(with(nested, "S", r#"{"m":[[1,2],[3,4]]}"#).is_ok());
        assert!(TypedData::from_json_str("[]").is_err());
        assert!(
            TypedData::from_json_str(r#"{"types":{},"primaryType":"EIP712Domain","junk":1}"#)
                .is_err()
        );
    }

    #[test]
    fn domain_only_digest_and_depth_limit() {
        let td = TypedData::from_json_str(
            r#"{"types":{"EIP712Domain":[]},"primaryType":"EIP712Domain","domain":{}}"#,
        )
        .unwrap();
        assert_eq!(td.message_hash().unwrap(), None);
        let sep = td.domain_separator().unwrap();
        assert_eq!(
            td.signing_hash().unwrap(),
            keccak256_concat2(&[0x19, 0x01], &sep)
        );
        let mut deep = String::from("{\"v\":1,\"kids\":[]}");
        for _ in 0..40 {
            deep = format!("{{\"v\":1,\"kids\":[{deep}]}}");
        }
        let tree = r#"{"Node":[{"name":"v","type":"uint256"},{"name":"kids","type":"Node[]"}]}"#;
        assert_eq!(
            with(tree, "Node", &deep),
            Err(Eip712Error::TooDeep(MAX_DEPTH))
        );
    }

    fn keccak256_concat2(a: &[u8], b: &[u8]) -> [u8; 32] {
        crate::hash::keccak256_concat(&[a, b])
    }

    /// Regression: type validation recursed once per array dimension and dependency
    /// collection once per struct link, so a ~40 KB document overflowed the stack and
    /// aborted the process. Both are now iterative and bounded.
    #[test]
    fn hostile_type_shapes_are_errors_not_stack_overflows() {
        let deep_array = format!("uint256{}", "[]".repeat(20_000));
        assert_eq!(
            with(
                &format!(r#"{{"S":[{{"name":"a","type":"{deep_array}"}}]}}"#),
                "S",
                "{}"
            ),
            Err(Eip712Error::TooDeep(MAX_DEPTH))
        );
        // MAX_DEPTH dimensions are still a valid type; one more is not.
        let ok = format!("uint8{}", "[]".repeat(MAX_DEPTH));
        let t = format!(r#"{{"S":[{{"name":"a","type":"{ok}"}}]}}"#);
        assert!(
            TypedData::from_json_str(&format!(
                r#"{{"types":{t},"primaryType":"S","domain":{{}}}}"#
            ))
            .is_ok()
        );
        let one_more = format!("uint8{}", "[]".repeat(MAX_DEPTH + 1));
        assert_eq!(
            with(
                &format!(r#"{{"S":[{{"name":"a","type":"{one_more}"}}]}}"#),
                "S",
                "{}"
            ),
            Err(Eip712Error::TooDeep(MAX_DEPTH))
        );

        // A chain T0 -> T1 -> ... of struct types.
        let chain = |n: usize| {
            let mut types = Vec::new();
            for i in 0..n {
                let member = if i + 1 < n {
                    format!(r#"{{"name":"next","type":"T{}"}}"#, i + 1)
                } else {
                    String::from(r#"{"name":"v","type":"uint256"}"#)
                };
                types.push(format!(r#""T{i}":[{member}]"#));
            }
            format!(
                r#"{{"types":{{{}}},"primaryType":"T0","domain":{{}}}}"#,
                types.join(",")
            )
        };
        assert_eq!(
            TypedData::from_json_str(&chain(5_000)),
            Err(Eip712Error::TooManyTypes(MAX_TYPES))
        );
        // Within the cap, a long chain resolves without recursion.
        let td = TypedData::from_json_str(&chain(MAX_TYPES - 1)).unwrap();
        let encoded = td.encode_type("T0").unwrap();
        assert!(encoded.starts_with("T0(T1 next)"));
        assert_eq!(encoded.matches('(').count(), MAX_TYPES - 1);
    }

    /// Regression: `uint+8`, `int+256` and `bytes01` were accepted as aliases of `uint8`,
    /// `int256` and `bytes1` (Rust's integer parser accepts a sign and leading zeros) and the
    /// malformed string was hashed into encodeType. Member names were never validated.
    #[test]
    fn type_names_follow_the_solidity_grammar_exactly() {
        for bad in [
            "uint+8", "int+256", "bytes01", "bytes+1", "uint08", "int008", "bytes 1", "uint-8",
            "bytes٣",
        ] {
            assert_eq!(
                with(
                    &format!(r#"{{"S":[{{"name":"a","type":"{bad}"}}]}}"#),
                    "S",
                    "{}"
                ),
                Err(Eip712Error::UnknownType(bad.into())),
                "{bad}"
            );
        }
        for good in ["uint8", "int256", "bytes1", "bytes32", "uint", "int"] {
            let t = format!(r#"{{"S":[{{"name":"a","type":"{good}"}}]}}"#);
            assert!(
                TypedData::from_json_str(&format!(
                    r#"{{"types":{t},"primaryType":"S","domain":{{}}}}"#
                ))
                .is_ok(),
                "{good}"
            );
        }
        for bad_member in ["", "a b", "1x", "x-y", "from.wallet", "é"] {
            assert_eq!(
                with(
                    &format!(r#"{{"S":[{{"name":"{bad_member}","type":"uint8"}}]}}"#),
                    "S",
                    "{}"
                ),
                Err(Eip712Error::InvalidMemberName {
                    ty: "S".into(),
                    member: bad_member.into()
                }),
                "{bad_member:?}"
            );
        }
    }

    #[test]
    fn review_fields_and_warnings() {
        let td = TypedData::from_json_str(MAIL).unwrap();
        let paths: Vec<_> = td
            .message_fields()
            .unwrap()
            .into_iter()
            .map(|f| f.path)
            .collect();
        assert_eq!(
            paths,
            [
                "from.name",
                "from.wallet",
                "to.name",
                "to.wallet",
                "contents"
            ]
        );
        let domain = td.domain_fields().unwrap();
        assert_eq!(domain[2].path, "chainId");
        assert_eq!(domain[2].value, FieldValue::Uint(U256::ONE));
        assert!(td.review_findings(Some(0)).unwrap().is_empty());

        let permit = r#"{"types":{"Permit":[{"name":"spender","type":"address"},
              {"name":"value","type":"uint256"},{"name":"deadline","type":"uint256"},
              {"name":"delta","type":"int8"},{"name":"tags","type":"bytes2[]"},{"name":"on","type":"bool"}]},
            "primaryType":"Permit","domain":{"name":"T"},
            "message":{"spender":"0x0000000000000000000000000000000000000001",
              "value":"115792089237316195423570985008687907853269984665640564039457584007913129639935",
              "deadline":"4102444800","delta":-5,"tags":[],"on":true}}"#;
        let td = TypedData::from_json_str(permit).unwrap();
        let fields = td.message_fields().unwrap();
        assert_eq!(fields[1].value, FieldValue::Uint(U256::MAX));
        assert_eq!(
            fields[3].value,
            FieldValue::Int {
                negative: true,
                magnitude: U256::from_u64(5)
            }
        );
        assert_eq!(fields[4].value, FieldValue::EmptyArray);
        assert_eq!(fields[5].value, FieldValue::Bool(true));
        let codes = |now| -> Vec<&'static str> {
            td.review_findings(now)
                .unwrap()
                .iter()
                .map(|f| f.code)
                .collect()
        };
        // 2100-01-01 is more than a year after 2026-10-01, but not after 2099-06-01.
        assert_eq!(
            codes(Some(1_790_812_800)),
            [
                "typed-data-no-chain-id",
                "typed-data-max-uint",
                "typed-data-far-deadline"
            ]
        );
        assert_eq!(
            codes(Some(4_084_000_000)),
            ["typed-data-no-chain-id", "typed-data-max-uint"]
        );
        assert_eq!(
            codes(None),
            ["typed-data-no-chain-id", "typed-data-max-uint"]
        );
    }
}
