// SPDX-License-Identifier: MIT
//! Recursive Length Prefix (RLP) encoding, written from the Ethereum Yellow Paper (Appendix B).
//!
//! The decoder is strict: it accepts exactly one encoding per value. It rejects
//!
//! * a single byte below `0x80` wrapped in a string header (`0x81 0x05` instead of `0x05`),
//! * the long form (`0xb8..`, `0xf8..`) for payloads shorter than 56 bytes,
//! * length-of-length fields with a leading zero byte,
//! * integers with leading zero bytes (including a lone `0x00`, since zero is `0x80`),
//! * payloads that run past the end of the input,
//! * trailing bytes after the top-level item, and unconsumed bytes inside a list,
//! * nesting deeper than [`MAX_DEPTH`] (so hostile input cannot exhaust the stack).
//!
//! These are the malleability classes that make two different byte strings decode to the same
//! transaction; a signer must refuse them so that "what was reviewed" is "what gets signed".

use crate::u256::U256;
use alloc::vec::Vec;

/// Maximum list nesting accepted by [`Value::decode`].
pub const MAX_DEPTH: usize = 64;

/// Errors produced by the strict decoder.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum RlpError {
    /// The input ends before the item does.
    #[error("unexpected end of input")]
    UnexpectedEof,
    /// A byte below `0x80` was wrapped in a one-byte string header.
    #[error("non-canonical: single byte below 0x80 must encode as itself")]
    NonCanonicalSingleByte,
    /// A long-form header was used for a payload shorter than 56 bytes.
    #[error("non-canonical: long-form length for a payload shorter than 56 bytes")]
    NonCanonicalLength,
    /// The length-of-length field starts with a zero byte.
    #[error("non-canonical: length prefix has a leading zero byte")]
    LeadingZeroLength,
    /// The declared length does not fit in `usize`.
    #[error("declared length does not fit in usize")]
    LengthOverflow,
    /// An integer is encoded with a leading zero byte.
    #[error("non-canonical: integer has a leading zero byte")]
    LeadingZeroInteger,
    /// An integer is wider than its field.
    #[error("integer does not fit in {bits} bits")]
    IntegerOverflow {
        /// Width of the target field.
        bits: u32,
    },
    /// Bytes remain after the top-level item.
    #[error("{count} trailing bytes after the RLP item")]
    TrailingBytes {
        /// Number of unconsumed bytes.
        count: usize,
    },
    /// A list was required but a string was found.
    #[error("expected an RLP list, found a string")]
    ExpectedList,
    /// A string was required but a list was found.
    #[error("expected an RLP string, found a list")]
    ExpectedString,
    /// A fixed-width field has the wrong length.
    #[error("expected {expected} bytes, got {got}")]
    UnexpectedLength {
        /// Required length.
        expected: usize,
        /// Actual length.
        got: usize,
    },
    /// A list contains more items than the schema allows.
    #[error("list contains unexpected extra items")]
    ListNotConsumed,
    /// A list ended before all schema fields were read.
    #[error("list is missing a field")]
    MissingField,
    /// Nesting exceeds [`MAX_DEPTH`].
    #[error("nesting deeper than {max} levels")]
    TooDeep {
        /// The enforced limit.
        max: usize,
    },
}

/// An RLP header: string or list, and the payload length that follows it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header {
    /// `true` for a list, `false` for a byte string.
    pub list: bool,
    /// Length of the payload in bytes.
    pub payload_len: usize,
}

/// A decoded item borrowing its payload from the input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Item<'a> {
    /// A byte string.
    String(&'a [u8]),
    /// A list; the slice is the concatenated encodings of its elements.
    List(&'a [u8]),
}

fn read_length(buf: &mut &[u8], len_of_len: usize) -> Result<usize, RlpError> {
    let bytes = buf.get(..len_of_len).ok_or(RlpError::UnexpectedEof)?;
    if bytes.first() == Some(&0) {
        return Err(RlpError::LeadingZeroLength);
    }
    if len_of_len > core::mem::size_of::<usize>() {
        return Err(RlpError::LengthOverflow);
    }
    let len = bytes
        .iter()
        .fold(0usize, |acc, b| (acc << 8) | usize::from(*b));
    if len < 56 {
        return Err(RlpError::NonCanonicalLength);
    }
    *buf = &buf[len_of_len..];
    Ok(len)
}

/// Decodes a header and advances `buf` past it.
///
/// For a single byte below `0x80` the byte *is* the payload, so `buf` is left untouched and a
/// one-byte string header is returned. On success the payload is guaranteed to fit in `buf`.
pub fn decode_header(buf: &mut &[u8]) -> Result<Header, RlpError> {
    let first = *buf.first().ok_or(RlpError::UnexpectedEof)?;
    let header = match first {
        0x00..=0x7f => {
            return Ok(Header {
                list: false,
                payload_len: 1,
            });
        }
        0x80..=0xb7 => {
            *buf = &buf[1..];
            let payload_len = usize::from(first - 0x80);
            if payload_len == 1 {
                let b = *buf.first().ok_or(RlpError::UnexpectedEof)?;
                if b < 0x80 {
                    return Err(RlpError::NonCanonicalSingleByte);
                }
            }
            Header {
                list: false,
                payload_len,
            }
        }
        0xb8..=0xbf => {
            *buf = &buf[1..];
            Header {
                list: false,
                payload_len: read_length(buf, usize::from(first - 0xb7))?,
            }
        }
        0xc0..=0xf7 => {
            *buf = &buf[1..];
            Header {
                list: true,
                payload_len: usize::from(first - 0xc0),
            }
        }
        0xf8..=0xff => {
            *buf = &buf[1..];
            Header {
                list: true,
                payload_len: read_length(buf, usize::from(first - 0xf7))?,
            }
        }
    };
    if header.payload_len > buf.len() {
        return Err(RlpError::UnexpectedEof);
    }
    Ok(header)
}

/// Decodes one item and advances `buf` past it.
pub fn decode_item<'a>(buf: &mut &'a [u8]) -> Result<Item<'a>, RlpError> {
    let header = decode_header(buf)?;
    // `decode_header` guarantees `payload_len <= buf.len()`.
    let (payload, rest) = buf.split_at(header.payload_len);
    *buf = rest;
    Ok(if header.list {
        Item::List(payload)
    } else {
        Item::String(payload)
    })
}

/// Decodes exactly one item spanning the whole input.
pub fn decode_exact(input: &[u8]) -> Result<Item<'_>, RlpError> {
    let mut buf = input;
    let item = decode_item(&mut buf)?;
    if !buf.is_empty() {
        return Err(RlpError::TrailingBytes { count: buf.len() });
    }
    Ok(item)
}

fn check_uint(bytes: &[u8], max_bytes: usize) -> Result<&[u8], RlpError> {
    if bytes.first() == Some(&0) {
        return Err(RlpError::LeadingZeroInteger);
    }
    if bytes.len() > max_bytes {
        // max_bytes <= 32, so the cast cannot truncate.
        return Err(RlpError::IntegerOverflow {
            bits: 8 * max_bytes as u32,
        });
    }
    Ok(bytes)
}

/// Sequential reader over the elements of a list, used to decode fixed schemas.
#[derive(Debug, Clone)]
pub struct ListDecoder<'a> {
    buf: &'a [u8],
}

impl<'a> ListDecoder<'a> {
    /// Wraps the payload of a list.
    pub fn new(payload: &'a [u8]) -> Self {
        Self { buf: payload }
    }

    /// Decodes `input` as exactly one list and returns a reader over its elements.
    pub fn from_exact(input: &'a [u8]) -> Result<Self, RlpError> {
        match decode_exact(input)? {
            Item::List(payload) => Ok(Self::new(payload)),
            Item::String(_) => Err(RlpError::ExpectedList),
        }
    }

    /// `true` when every element has been consumed.
    pub fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }

    /// Reads the next element of any kind.
    pub fn item(&mut self) -> Result<Item<'a>, RlpError> {
        if self.buf.is_empty() {
            return Err(RlpError::MissingField);
        }
        decode_item(&mut self.buf)
    }

    /// Reads the next element as a byte string.
    pub fn bytes(&mut self) -> Result<&'a [u8], RlpError> {
        match self.item()? {
            Item::String(s) => Ok(s),
            Item::List(_) => Err(RlpError::ExpectedString),
        }
    }

    /// Reads the next element as a nested list.
    pub fn list(&mut self) -> Result<ListDecoder<'a>, RlpError> {
        match self.item()? {
            Item::List(payload) => Ok(ListDecoder::new(payload)),
            Item::String(_) => Err(RlpError::ExpectedList),
        }
    }

    /// Reads a fixed-width byte string (addresses, storage keys).
    pub fn fixed<const N: usize>(&mut self) -> Result<[u8; N], RlpError> {
        let bytes = self.bytes()?;
        <[u8; N]>::try_from(bytes).map_err(|_| RlpError::UnexpectedLength {
            expected: N,
            got: bytes.len(),
        })
    }

    /// Reads a canonical unsigned integer of at most 8 bits.
    pub fn u8(&mut self) -> Result<u8, RlpError> {
        let bytes = check_uint(self.bytes()?, 1)?;
        Ok(bytes.first().copied().unwrap_or(0))
    }

    /// Reads a canonical unsigned integer of at most 64 bits.
    pub fn u64(&mut self) -> Result<u64, RlpError> {
        let bytes = check_uint(self.bytes()?, 8)?;
        Ok(bytes.iter().fold(0u64, |acc, b| (acc << 8) | u64::from(*b)))
    }

    /// Reads a canonical unsigned integer of at most 128 bits.
    pub fn u128(&mut self) -> Result<u128, RlpError> {
        let bytes = check_uint(self.bytes()?, 16)?;
        Ok(bytes
            .iter()
            .fold(0u128, |acc, b| (acc << 8) | u128::from(*b)))
    }

    /// Reads a canonical unsigned integer of at most 256 bits.
    pub fn u256(&mut self) -> Result<U256, RlpError> {
        let bytes = check_uint(self.bytes()?, 32)?;
        U256::from_be_slice(bytes).ok_or(RlpError::IntegerOverflow { bits: 256 })
    }

    /// Asserts that every element was consumed.
    pub fn finish(self) -> Result<(), RlpError> {
        if self.buf.is_empty() {
            Ok(())
        } else {
            Err(RlpError::ListNotConsumed)
        }
    }
}

/// Appends a string or list header for a payload of `payload_len` bytes.
pub fn encode_header(out: &mut Vec<u8>, list: bool, payload_len: usize) {
    let (short, long) = if list {
        (0xc0u8, 0xf7u8)
    } else {
        (0x80u8, 0xb7u8)
    };
    if payload_len < 56 {
        // payload_len < 56, so the cast is exact and the sum stays below 0xf8.
        out.push(short + payload_len as u8);
    } else {
        let be = payload_len.to_be_bytes();
        let first = be.iter().position(|b| *b != 0).unwrap_or(be.len() - 1);
        let len_of_len = be.len() - first;
        // len_of_len <= 8, so the cast is exact and the sum stays within 0xb8..=0xbf / 0xf8..=0xff.
        out.push(long + len_of_len as u8);
        out.extend_from_slice(&be[first..]);
    }
}

/// Appends a byte string.
pub fn encode_bytes(out: &mut Vec<u8>, bytes: &[u8]) {
    match bytes {
        [b] if *b < 0x80 => out.push(*b),
        _ => {
            encode_header(out, false, bytes.len());
            out.extend_from_slice(bytes);
        }
    }
}

fn trimmed(bytes: &[u8]) -> &[u8] {
    let first = bytes.iter().position(|b| *b != 0).unwrap_or(bytes.len());
    &bytes[first..]
}

/// Appends an unsigned integer in minimal big-endian form (zero is the empty string `0x80`).
pub fn encode_u64(out: &mut Vec<u8>, v: u64) {
    encode_bytes(out, trimmed(&v.to_be_bytes()));
}

/// Appends a `u128` in minimal big-endian form.
pub fn encode_u128(out: &mut Vec<u8>, v: u128) {
    encode_bytes(out, trimmed(&v.to_be_bytes()));
}

/// Appends a [`U256`] in minimal big-endian form.
pub fn encode_u256(out: &mut Vec<u8>, v: &U256) {
    encode_bytes(out, trimmed(&v.to_be_bytes()));
}

/// Appends a list whose already-encoded elements are `payload`.
pub fn encode_list(out: &mut Vec<u8>, payload: &[u8]) {
    encode_header(out, true, payload.len());
    out.extend_from_slice(payload);
}

/// Encodes a list whose elements are produced by `f` into a fresh buffer.
pub fn list_with(f: impl FnOnce(&mut Vec<u8>)) -> Vec<u8> {
    let mut payload = Vec::new();
    f(&mut payload);
    let mut out = Vec::with_capacity(payload.len() + 9);
    encode_list(&mut out, &payload);
    out
}

/// A dynamically-typed RLP value, for tooling and property tests.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    /// A byte string.
    Bytes(Vec<u8>),
    /// A list of values.
    List(Vec<Value>),
}

impl Value {
    /// Canonical encoding.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        self.encode_into(&mut out);
        out
    }

    fn encode_into(&self, out: &mut Vec<u8>) {
        match self {
            Value::Bytes(b) => encode_bytes(out, b),
            Value::List(items) => {
                let mut payload = Vec::new();
                for item in items {
                    item.encode_into(&mut payload);
                }
                encode_list(out, &payload);
            }
        }
    }

    /// Strictly decodes exactly one value spanning the whole input.
    pub fn decode(input: &[u8]) -> Result<Self, RlpError> {
        let mut buf = input;
        let value = Self::decode_inner(&mut buf, 0)?;
        if !buf.is_empty() {
            return Err(RlpError::TrailingBytes { count: buf.len() });
        }
        Ok(value)
    }

    fn decode_inner(buf: &mut &[u8], depth: usize) -> Result<Self, RlpError> {
        match decode_item(buf)? {
            Item::String(s) => Ok(Value::Bytes(s.to_vec())),
            Item::List(mut payload) => {
                if depth >= MAX_DEPTH {
                    return Err(RlpError::TooDeep { max: MAX_DEPTH });
                }
                let mut items = Vec::new();
                while !payload.is_empty() {
                    items.push(Self::decode_inner(&mut payload, depth + 1)?);
                }
                Ok(Value::List(items))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hex;
    use alloc::vec;

    fn b(s: &str) -> Value {
        Value::Bytes(s.as_bytes().to_vec())
    }

    #[test]
    fn yellow_paper_examples() {
        // Examples from the Ethereum wiki / Yellow Paper appendix B.
        assert_eq!(hex::encode(&b("dog").encode()), "83646f67");
        assert_eq!(
            hex::encode(&Value::List(vec![b("cat"), b("dog")]).encode()),
            "c88363617483646f67"
        );
        assert_eq!(hex::encode(&b("").encode()), "80");
        assert_eq!(hex::encode(&Value::List(vec![]).encode()), "c0");
        let mut out = Vec::new();
        encode_u64(&mut out, 0);
        encode_u64(&mut out, 15);
        encode_u64(&mut out, 1024);
        assert_eq!(hex::encode(&out), "800f820400");
        // The set-theoretical representation of three.
        let e = Value::List(vec![]);
        let one = Value::List(vec![e.clone()]);
        let three = Value::List(vec![e.clone(), one.clone(), Value::List(vec![e, one])]);
        assert_eq!(hex::encode(&three.encode()), "c7c0c1c0c3c0c1c0");
        let lorem = b("Lorem ipsum dolor sit amet, consectetur adipisicing elit");
        let enc = lorem.encode();
        assert_eq!(&enc[..2], &[0xb8, 0x38]);
        assert_eq!(Value::decode(&enc).unwrap(), lorem);
    }

    #[test]
    fn rejects_non_canonical_forms() {
        assert_eq!(
            Value::decode(&[0x81, 0x05]),
            Err(RlpError::NonCanonicalSingleByte)
        );
        assert_eq!(
            Value::decode(&[0xb8, 0x02, 0x01, 0x02]),
            Err(RlpError::NonCanonicalLength)
        );
        assert_eq!(
            Value::decode(&[0xf8, 0x01, 0x80]),
            Err(RlpError::NonCanonicalLength)
        );
        let mut long = vec![0xb9, 0x00, 0x38];
        long.extend_from_slice(&[0xaa; 56]);
        assert_eq!(Value::decode(&long), Err(RlpError::LeadingZeroLength));
        assert_eq!(Value::decode(&[0x83, 0x01]), Err(RlpError::UnexpectedEof));
        assert_eq!(
            Value::decode(&[0x80, 0x80]),
            Err(RlpError::TrailingBytes { count: 1 })
        );
        assert_eq!(Value::decode(&[]), Err(RlpError::UnexpectedEof));
        assert_eq!(Value::decode(&[0x81]), Err(RlpError::UnexpectedEof));
        let mut overflow = vec![0xbf];
        overflow.extend_from_slice(&[0xff; 8]);
        assert_eq!(Value::decode(&overflow), Err(RlpError::UnexpectedEof));
        let mut too_wide = vec![0xbf, 0x01];
        too_wide.extend_from_slice(&[0x00; 8]);
        assert!(matches!(
            Value::decode(&too_wide),
            Err(RlpError::LengthOverflow | RlpError::UnexpectedEof)
        ));
    }

    #[test]
    fn integer_rules() {
        let mut d = ListDecoder::from_exact(&[0xc3, 0x80, 0x0f, 0x00]).unwrap();
        assert_eq!(d.u64(), Ok(0));
        assert_eq!(d.u64(), Ok(15));
        assert_eq!(d.u64(), Err(RlpError::LeadingZeroInteger));
        let mut d = ListDecoder::from_exact(&[0xc3, 0x82, 0x00, 0x01]).unwrap();
        assert_eq!(d.u64(), Err(RlpError::LeadingZeroInteger));
        let mut nine = vec![0xca, 0x89];
        nine.extend_from_slice(&[0x01; 9]);
        let mut d = ListDecoder::from_exact(&nine).unwrap();
        assert_eq!(d.u64(), Err(RlpError::IntegerOverflow { bits: 64 }));
        let mut d = ListDecoder::from_exact(&[0xc2, 0x81, 0xff]).unwrap();
        assert_eq!(d.u8(), Ok(0xff));
        assert_eq!(d.u8(), Err(RlpError::MissingField));
    }

    #[test]
    fn list_decoder_schema_errors() {
        let mut d = ListDecoder::from_exact(&[0xc2, 0xc0, 0x80]).unwrap();
        assert_eq!(d.bytes(), Err(RlpError::ExpectedString));
        assert_eq!(d.list().map(|l| l.is_empty()), Err(RlpError::ExpectedList));
        assert_eq!(
            ListDecoder::from_exact(&[0x80]).map(|_| ()),
            Err(RlpError::ExpectedList)
        );
        let mut d = ListDecoder::from_exact(&[0xc2, 0x81, 0x80]).unwrap();
        assert_eq!(
            d.fixed::<20>(),
            Err(RlpError::UnexpectedLength {
                expected: 20,
                got: 1
            })
        );
        let d = ListDecoder::from_exact(&[0xc1, 0x80]).unwrap();
        assert_eq!(d.finish(), Err(RlpError::ListNotConsumed));
    }

    #[test]
    fn depth_limit() {
        // Build [[[...]]] from the inside out: `levels` nested lists.
        let nested = |levels: usize| {
            let mut enc = vec![0xc0];
            for _ in 1..levels {
                let mut out = Vec::new();
                encode_list(&mut out, &enc);
                enc = out;
            }
            enc
        };
        assert!(Value::decode(&nested(MAX_DEPTH)).is_ok());
        assert_eq!(
            Value::decode(&nested(MAX_DEPTH + 1)),
            Err(RlpError::TooDeep { max: MAX_DEPTH })
        );
    }
}
