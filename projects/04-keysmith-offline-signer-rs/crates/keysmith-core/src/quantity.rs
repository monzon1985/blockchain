// SPDX-License-Identifier: MIT
//! Serde helpers for numeric and byte fields in Keysmith's JSON formats.
//!
//! Integers are accepted as JSON numbers (up to `u64`) or as strings holding decimal or
//! `0x`-prefixed hex, and are always written back as decimal strings. JSON numbers above
//! `u64::MAX` would be parsed as lossy floats by `serde_json`, so they are rejected with a
//! hint to quote them instead of being silently rounded.

use crate::u256::U256;
use alloc::string::String;
use alloc::vec::Vec;
use core::fmt;
use serde::de::{self, Visitor};
use serde::{Deserializer, Serializer};

struct U256Visitor;

impl Visitor<'_> for U256Visitor {
    type Value = U256;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a non-negative integer, or a decimal / 0x-hex string")
    }

    fn visit_u64<E: de::Error>(self, v: u64) -> Result<U256, E> {
        Ok(U256::from_u64(v))
    }

    fn visit_i64<E: de::Error>(self, v: i64) -> Result<U256, E> {
        u64::try_from(v)
            .map(U256::from_u64)
            .map_err(|_| E::custom("negative value where an unsigned integer is required"))
    }

    fn visit_f64<E: de::Error>(self, _v: f64) -> Result<U256, E> {
        Err(E::custom(
            "non-integer or too-large JSON number; pass large integers as quoted strings",
        ))
    }

    fn visit_str<E: de::Error>(self, v: &str) -> Result<U256, E> {
        U256::parse(v).map_err(E::custom)
    }
}

/// Deserializes a [`U256`] from a JSON number or a decimal / hex string.
pub fn deserialize_u256<'de, D: Deserializer<'de>>(deserializer: D) -> Result<U256, D::Error> {
    deserializer.deserialize_any(U256Visitor)
}

fn narrow<E: de::Error, T: TryFrom<u128>>(v: U256, what: &str) -> Result<T, E> {
    v.to_u128()
        .and_then(|x| T::try_from(x).ok())
        .ok_or_else(|| E::custom(alloc::format!("{what} out of range")))
}

/// `u64` fields: accept number / decimal / hex, write decimal strings.
pub mod u64_str {
    use super::*;

    /// Serializes as a decimal string.
    pub fn serialize<S: Serializer>(v: &u64, s: S) -> Result<S::Ok, S::Error> {
        s.collect_str(v)
    }

    /// Deserializes from a number or string.
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<u64, D::Error> {
        narrow(deserialize_u256(d)?, "u64 value")
    }
}

/// `u128` fields: accept number / decimal / hex, write decimal strings.
pub mod u128_str {
    use super::*;

    /// Serializes as a decimal string.
    pub fn serialize<S: Serializer>(v: &u128, s: S) -> Result<S::Ok, S::Error> {
        s.collect_str(v)
    }

    /// Deserializes from a number or string.
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<u128, D::Error> {
        narrow(deserialize_u256(d)?, "u128 value")
    }
}

/// `u8` fields: accept number / decimal / hex, write decimal strings.
pub mod u8_str {
    use super::*;

    /// Serializes as a decimal string.
    pub fn serialize<S: Serializer>(v: &u8, s: S) -> Result<S::Ok, S::Error> {
        s.collect_str(v)
    }

    /// Deserializes from a number or string.
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<u8, D::Error> {
        narrow(deserialize_u256(d)?, "u8 value")
    }
}

/// `Option<u128>` fields (`null` or absent means `None`).
pub mod opt_u128_str {
    use super::*;
    use serde::Deserialize;

    /// Serializes `Some` as a decimal string and `None` as `null`.
    pub fn serialize<S: Serializer>(v: &Option<u128>, s: S) -> Result<S::Ok, S::Error> {
        match v {
            Some(x) => s.collect_str(x),
            None => s.serialize_none(),
        }
    }

    /// Deserializes from `null`, a number or a string.
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<u128>, D::Error> {
        let raw: Option<U256> = Option::deserialize(d)?;
        raw.map(|v| narrow(v, "u128 value")).transpose()
    }
}

/// `Option<u64>` fields (`null` or absent means `None`).
pub mod opt_u64_str {
    use super::*;
    use serde::Deserialize;

    /// Serializes `Some` as a decimal string and `None` as `null`.
    pub fn serialize<S: Serializer>(v: &Option<u64>, s: S) -> Result<S::Ok, S::Error> {
        match v {
            Some(x) => s.collect_str(x),
            None => s.serialize_none(),
        }
    }

    /// Deserializes from `null`, a number or a string.
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<u64>, D::Error> {
        let raw: Option<U256> = Option::deserialize(d)?;
        raw.map(|v| narrow(v, "u64 value")).transpose()
    }
}

/// Byte-string fields as `0x`-prefixed hex.
pub mod hex_bytes {
    use super::*;
    use serde::Deserialize;

    /// Serializes as `0x`-prefixed lowercase hex.
    pub fn serialize<S: Serializer>(v: &[u8], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&crate::hex::encode_prefixed(v))
    }

    /// Deserializes from hex text (prefix optional).
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let s = String::deserialize(d)?;
        crate::hex::decode(&s).map_err(de::Error::custom)
    }
}

/// 32-byte words (storage keys, hashes) as `0x`-prefixed hex.
pub mod hex_b256 {
    use super::*;
    use serde::Deserialize;

    /// Serializes as `0x`-prefixed lowercase hex.
    pub fn serialize<S: Serializer>(v: &[u8; 32], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&crate::hex::encode_prefixed(v))
    }

    /// Deserializes exactly 32 bytes of hex.
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<[u8; 32], D::Error> {
        let s = String::deserialize(d)?;
        crate::hex::decode_array::<32>(&s).map_err(de::Error::custom)
    }
}

/// Lists of 32-byte words.
pub mod hex_b256_vec {
    use super::*;
    use serde::Deserialize;
    use serde::ser::SerializeSeq;

    /// Serializes each word as `0x`-prefixed hex.
    pub fn serialize<S: Serializer>(v: &[[u8; 32]], s: S) -> Result<S::Ok, S::Error> {
        let mut seq = s.serialize_seq(Some(v.len()))?;
        for word in v {
            seq.serialize_element(&crate::hex::encode_prefixed(word))?;
        }
        seq.end()
    }

    /// Deserializes a list of 32-byte hex words.
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<[u8; 32]>, D::Error> {
        let raw: Vec<String> = Vec::deserialize(d)?;
        raw.iter()
            .map(|s| crate::hex::decode_array::<32>(s).map_err(de::Error::custom))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::string::ToString;
    use serde::{Deserialize, Serialize};

    #[derive(Debug, PartialEq, Serialize, Deserialize)]
    struct Fields {
        #[serde(with = "u8_str")]
        small: u8,
        #[serde(with = "u64_str")]
        nonce: u64,
        #[serde(with = "u128_str")]
        fee: u128,
        #[serde(default, with = "opt_u64_str")]
        chain: Option<u64>,
        #[serde(default, with = "opt_u128_str")]
        tip: Option<u128>,
        #[serde(with = "hex_bytes")]
        data: Vec<u8>,
        #[serde(with = "hex_b256")]
        word: [u8; 32],
        #[serde(with = "hex_b256_vec")]
        words: Vec<[u8; 32]>,
        value: U256,
    }

    fn parse(json: &str) -> Result<Fields, serde_json::Error> {
        serde_json::from_str(json)
    }

    const WORD: &str = "0x0000000000000000000000000000000000000000000000000000000000000001";

    fn doc(overrides: &str) -> alloc::string::String {
        let base = alloc::format!(
            r#""small":"0xff","nonce":7,"fee":"1000","chain":null,"data":"0xabcd","word":"{WORD}","words":["{WORD}"],"value":"0x10""#
        );
        alloc::format!("{{{base}{overrides}}}")
    }

    #[test]
    fn accepts_numbers_decimal_and_hex_and_writes_decimal_strings() {
        let f = parse(&doc(r#","tip":"0x3b9aca00""#)).unwrap();
        assert_eq!(
            (f.small, f.nonce, f.fee, f.chain, f.tip),
            (255, 7, 1000, None, Some(1_000_000_000))
        );
        assert_eq!(f.data, [0xab, 0xcd]);
        assert_eq!(f.word[31], 1);
        assert_eq!(f.value, U256::from_u64(16));
        let out = serde_json::to_value(&f).unwrap();
        assert_eq!(out["small"], "255");
        assert_eq!(out["nonce"], "7");
        assert_eq!(out["tip"], "1000000000");
        assert_eq!(out["chain"], serde_json::Value::Null);
        assert_eq!(out["data"], "0xabcd");
        assert_eq!(out["words"][0], WORD);
        assert_eq!(out["value"], "16");
        assert_eq!(parse(&out.to_string()).unwrap(), f, "round trip");
    }

    #[test]
    fn rejects_lossy_negative_and_out_of_range_values() {
        // Above u64::MAX as a bare JSON number would be a lossy float.
        let err = parse(&doc(r#","tip":18446744073709551616"#))
            .unwrap_err()
            .to_string();
        assert!(err.contains("quoted strings"), "{err}");
        assert!(
            parse(&doc(r#","tip":-1"#))
                .unwrap_err()
                .to_string()
                .contains("negative")
        );
        assert!(parse(&doc(r#","tip":1.5"#)).is_err());
        assert!(
            parse(&doc(r#","tip":true"#))
                .unwrap_err()
                .to_string()
                .contains("non-negative integer")
        );
        assert!(
            parse(r#"{"small":"256"}"#)
                .unwrap_err()
                .to_string()
                .contains("u8 value out of range")
        );
        assert!(
            parse(&doc("").replace("\"chain\":null", "\"chain\":\"0x10000000000000000\""))
                .unwrap_err()
                .to_string()
                .contains("u64 value out of range")
        );
        assert!(parse(&doc("").replace("\"0xabcd\"", "\"0xabc\"")).is_err());
        assert!(
            parse(&doc("").replace(&alloc::format!("\"word\":\"{WORD}\""), "\"word\":\"0x01\""))
                .is_err()
        );
        assert!(parse(&doc("").replace(&alloc::format!("[\"{WORD}\"]"), "[\"0x01\"]")).is_err());
    }
}
