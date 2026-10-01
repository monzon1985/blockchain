// SPDX-License-Identifier: MIT

// Package rlp implements Recursive Length Prefix serialization (Ethereum Yellow Paper,
// Appendix B) with a strictly canonical decoder.
//
// An RLP item is either a string (a byte array) or a list of items. The encoding of an item
// is unique, and the decoder in this package enforces that uniqueness: it rejects every input
// that a canonical encoder could not have produced. Concretely, Split and Decode reject
//
//   - a single byte below 0x80 wrapped in a string header (0x81 0x05 instead of 0x05),
//   - a long-form length prefix for a payload shorter than 56 bytes (0xb8 0x05 ...),
//   - a long-form length with leading zero bytes (0xb9 0x00 0x40 ...),
//   - a declared length that runs past the end of the input,
//   - bytes left over after the top-level item,
//
// and the integer accessors additionally reject leading zero bytes (0x82 0x00 0x01) and values
// wider than the target type. Canonicality matters because Ethereum commits to hashes of
// encodings: if two byte strings decoded to the same value, a decoder that accepted both
// would let an attacker vary a hash without varying the data.
//
// The package has two layers. Split, SplitString, SplitList and SplitUint64 are zero-copy
// primitives that validate one item header at a time. Decode builds a fully validated Value
// tree (rejecting nesting deeper than MaxDepth) and is what the higher-level packages of this
// module use. Encoding is append-style (AppendString, AppendUint64, AppendBig, AppendList,
// AppendListPayload) plus the convenience wrappers EncodeString, EncodeUint64, EncodeBig and
// EncodeList.
package rlp
