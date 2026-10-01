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
//! out-of-range integers and lossy JSON floats are all errors. When `primaryType` is
//! `EIP712Domain` the digest omits the message hash (MetaMask / alloy compatibility).

use crate::address::Address;
use crate::hash::keccak256;
use crate::hex;
use crate::u256::U256;
use alloc::collections::{BTreeMap, BTreeSet};
use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec::Vec;
use serde_json::{Map, Value};

/// Maximum struct / array nesting while hashing values.
pub const MAX_DEPTH: usize = 64;

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

fn parse_bits(s: &str) -> Option<u32> {
    if s.is_empty() {
        return Some(256);
    }
    if s.starts_with('0') {
        return None;
    }
    let bits: u32 = s.parse().ok()?;
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
        let n: usize = n.parse().ok()?;
        return (1..=32).contains(&n).then_some(Kind::FixedBytes(n));
    }
    Some(Kind::Struct(ty))
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

    fn check_type(&self, ty: &str) -> Result<(), Eip712Error> {
        match classify(ty) {
            None => Err(Eip712Error::UnknownType(ty.to_string())),
            Some(Kind::Array { inner, .. }) => self.check_type(inner),
            Some(Kind::Struct(name)) if !self.types.contains_key(name) => {
                Err(Eip712Error::UnknownType(ty.to_string()))
            }
            Some(_) => Ok(()),
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

    fn collect_deps(&self, name: &str, deps: &mut BTreeSet<String>) -> Result<(), Eip712Error> {
        for (_, ty) in self.members(name)? {
            if let Some(dep) = Self::base_struct(ty)
                && deps.insert(dep.to_string())
            {
                self.collect_deps(dep, deps)?;
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
            Kind::Bool => {
                let b = match v {
                    Value::Bool(b) => *b,
                    Value::String(s) if s == "true" => true,
                    Value::String(s) if s == "false" => false,
                    _ => return Err(invalid(ty, "expected a boolean")),
                };
                Ok(U256::from_u64(u64::from(b)).to_be_bytes())
            }
            Kind::Address => {
                let s = v
                    .as_str()
                    .ok_or_else(|| invalid(ty, "expected a hex string"))?;
                let a = Address::parse(s).map_err(|e| invalid(ty, e.to_string()))?;
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

fn signed_value(ty: &str, v: &Value, bits: u32) -> Result<[u8; 32], Eip712Error> {
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
}
