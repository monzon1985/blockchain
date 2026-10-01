// SPDX-License-Identifier: MIT
//! Ed25519 precompile instruction layout: building and *strict* verification.
//!
//! Solana programs cannot verify ed25519 signatures cheaply themselves; instead
//! the transaction carries an instruction for the `Ed25519SigVerify111…`
//! precompile, which aborts the whole transaction if a signature is invalid.
//! The program then *introspects* that instruction through the instructions
//! sysvar. The precompile only proves "some key signed some bytes", so the
//! program must prove the key and the bytes are the ones it expects:
//!
//! 1. the instruction really targets the ed25519 program,
//! 2. it carries exactly one signature,
//! 3. `signature_instruction_index`, `public_key_instruction_index` and
//!    `message_instruction_index` are all `u16::MAX` ("this instruction"), so
//!    the precompile verified exactly the bytes this program reads,
//! 4. the public key equals the maker's registered quote signer and the message
//!    equals the domain-separated quote encoding, byte for byte.
//!
//! Skipping any of these checks is exploitable; `naive_v1` skips all of them.
//!
//! ```text
//! [0]      num_signatures (u8)          [1]      padding
//! [2..16]  Ed25519SignatureOffsets: 7 × u16 LE
//!          signature_offset, signature_instruction_index,
//!          public_key_offset, public_key_instruction_index,
//!          message_data_offset, message_data_size, message_instruction_index
//! [16..48] public key   [48..112] signature   [112..] message   (canonical layout)
//! ```

use crate::{Pubkey, RfqError, read_u16};

/// Start of the offsets table.
pub const SIGNATURE_OFFSETS_START: usize = 2;
/// Size of one offsets entry.
pub const SIGNATURE_OFFSETS_SERIALIZED_SIZE: usize = 14;
/// First byte after the header of a single-signature instruction.
pub const DATA_START: usize = SIGNATURE_OFFSETS_START + SIGNATURE_OFFSETS_SERIALIZED_SIZE;
/// Public key length.
pub const PUBKEY_LEN: usize = 32;
/// Signature length.
pub const SIGNATURE_LEN: usize = 64;
/// Sentinel meaning "the data lives in the ed25519 instruction itself".
pub const INLINE: u16 = u16::MAX;

/// The offsets entry of a single-signature ed25519 instruction.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SignatureOffsets {
    /// Byte offset of the 64-byte signature.
    pub signature_offset: u16,
    /// Instruction holding the signature (`u16::MAX` = this one).
    pub signature_instruction_index: u16,
    /// Byte offset of the 32-byte public key.
    pub public_key_offset: u16,
    /// Instruction holding the public key (`u16::MAX` = this one).
    pub public_key_instruction_index: u16,
    /// Byte offset of the message.
    pub message_data_offset: u16,
    /// Message length.
    pub message_data_size: u16,
    /// Instruction holding the message (`u16::MAX` = this one).
    pub message_instruction_index: u16,
}

/// Total length of a canonical single-signature instruction for `msg_len`.
pub const fn encoded_len(msg_len: usize) -> usize {
    DATA_START + PUBKEY_LEN + SIGNATURE_LEN + msg_len
}

/// Writes the canonical single-signature layout (identical to
/// `solana_ed25519_program::new_ed25519_instruction_with_signature`) into
/// `out`, returning the number of bytes written.
pub fn encode_single(
    pubkey: &Pubkey,
    signature: &[u8; SIGNATURE_LEN],
    message: &[u8],
    out: &mut [u8],
) -> Result<usize, RfqError> {
    let len = encoded_len(message.len());
    let msg_size =
        u16::try_from(message.len()).map_err(|_| RfqError::MalformedEd25519Instruction)?;
    if out.len() < len || u16::try_from(len).is_err() {
        return Err(RfqError::MalformedEd25519Instruction);
    }
    let pk_off = DATA_START as u16;
    let sig_off = pk_off + PUBKEY_LEN as u16;
    let msg_off = sig_off + SIGNATURE_LEN as u16;
    out[0] = 1;
    out[1] = 0;
    let fields = [sig_off, INLINE, pk_off, INLINE, msg_off, msg_size, INLINE];
    for (i, f) in fields.iter().enumerate() {
        let o = SIGNATURE_OFFSETS_START + i * 2;
        out[o..o + 2].copy_from_slice(&f.to_le_bytes());
    }
    out[DATA_START..DATA_START + PUBKEY_LEN].copy_from_slice(pubkey);
    let s = usize::from(sig_off);
    out[s..s + SIGNATURE_LEN].copy_from_slice(signature);
    let m = usize::from(msg_off);
    out[m..m + message.len()].copy_from_slice(message);
    Ok(len)
}

/// Parses the offsets of an instruction that must carry exactly one signature.
pub fn parse_single_offsets(data: &[u8]) -> Result<SignatureOffsets, RfqError> {
    if data.len() < DATA_START || data[0] != 1 {
        return Err(RfqError::MalformedEd25519Instruction);
    }
    let f = |i: usize| read_u16(data, SIGNATURE_OFFSETS_START + i * 2);
    let (Some(a), Some(b), Some(c), Some(d), Some(e), Some(g), Some(h)) =
        (f(0), f(1), f(2), f(3), f(4), f(5), f(6))
    else {
        return Err(RfqError::MalformedEd25519Instruction);
    };
    Ok(SignatureOffsets {
        signature_offset: a,
        signature_instruction_index: b,
        public_key_offset: c,
        public_key_instruction_index: d,
        message_data_offset: e,
        message_data_size: g,
        message_instruction_index: h,
    })
}

fn slice(data: &[u8], offset: u16, len: usize) -> Result<&[u8], RfqError> {
    let start = usize::from(offset);
    let end = start
        .checked_add(len)
        .ok_or(RfqError::MalformedEd25519Instruction)?;
    data.get(start..end)
        .ok_or(RfqError::MalformedEd25519Instruction)
}

/// Strict (v2) verification of the ed25519 instruction data preceding
/// `settle`: exactly one signature, every offset inline, and the verified
/// public key and message equal to `expected_signer` / `message_ok`.
///
/// `message_ok` receives the verified message bytes; callers pass either a
/// full comparison against a pre-built message or the zero-copy
/// [`crate::quote::message_matches`].
pub fn verify_inline_single<F>(
    data: &[u8],
    expected_signer: &Pubkey,
    message_ok: F,
) -> Result<(), RfqError>
where
    F: FnOnce(&[u8]) -> bool,
{
    let o = parse_single_offsets(data)?;
    if o.signature_instruction_index != INLINE
        || o.public_key_instruction_index != INLINE
        || o.message_instruction_index != INLINE
    {
        return Err(RfqError::Ed25519OffsetsNotInline);
    }
    // The precompile already checked these ranges; re-checking keeps the
    // function total for arbitrary input.
    slice(data, o.signature_offset, SIGNATURE_LEN)?;
    let pk = slice(data, o.public_key_offset, PUBKEY_LEN)?;
    if pk != expected_signer {
        return Err(RfqError::SignerMismatch);
    }
    let msg = slice(
        data,
        o.message_data_offset,
        usize::from(o.message_data_size),
    )?;
    if !message_ok(msg) {
        return Err(RfqError::MessageMismatch);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use {
        super::*,
        ed25519_dalek::{Signer as _, SigningKey},
        proptest::prelude::*,
        std::vec,
    };

    fn build(msg: &[u8], seed: [u8; 32]) -> (Pubkey, std::vec::Vec<u8>) {
        let sk = SigningKey::from_bytes(&seed);
        let pk = sk.verifying_key().to_bytes();
        let sig = sk.sign(msg).to_bytes();
        let mut out = vec![0u8; encoded_len(msg.len())];
        let n = encode_single(&pk, &sig, msg, &mut out).expect("fits");
        assert_eq!(n, out.len());
        (pk, out)
    }

    proptest! {
        /// Differential: byte-identical to the SDK's canonical builder.
        #[test]
        fn encoding_matches_sdk(msg in proptest::collection::vec(any::<u8>(), 0..600), seed in any::<[u8; 32]>()) {
            let sk = SigningKey::from_bytes(&seed);
            let pk = sk.verifying_key().to_bytes();
            let sig = sk.sign(&msg).to_bytes();
            let mut ours = vec![0u8; encoded_len(msg.len())];
            encode_single(&pk, &sig, &msg, &mut ours).expect("fits");
            let canonical = solana_ed25519_program::new_ed25519_instruction_with_signature(&msg, &sig, &pk);
            prop_assert_eq!(ours, canonical.data);
        }

        /// Accepts exactly the expected signer and message.
        #[test]
        fn strict_verification(msg in proptest::collection::vec(any::<u8>(), 1..300), seed in any::<[u8; 32]>(), other in any::<[u8; 32]>()) {
            let (pk, data) = build(&msg, seed);
            prop_assert_eq!(verify_inline_single(&data, &pk, |m| m == msg.as_slice()), Ok(()));
            prop_assume!(other != pk);
            prop_assert_eq!(verify_inline_single(&data, &other, |m| m == msg.as_slice()), Err(RfqError::SignerMismatch));
            prop_assert_eq!(verify_inline_single(&data, &pk, |_| false), Err(RfqError::MessageMismatch));
        }

        /// Arbitrary bytes never panic, and are accepted for a fixed key
        /// exactly when an independent oracle says so: one signature, all
        /// three offsets inline, every range in bounds and the public-key
        /// range holding that key. Half of the inputs get a forced valid
        /// header and the key planted at the declared offset, so the
        /// accepting branch is actually exercised.
        #[test]
        fn total_on_garbage(
            mut data in proptest::collection::vec(any::<u8>(), 0..200),
            force_header in any::<bool>(),
            picks in any::<[u16; 4]>(),
        ) {
            const KEY: Pubkey = [9u8; 32];
            if force_header && data.len() >= DATA_START {
                data[0] = 1;
                for field in [1usize, 3, 6] {
                    let o = SIGNATURE_OFFSETS_START + field * 2;
                    data[o..o + 2].copy_from_slice(&INLINE.to_le_bytes());
                }
                // Mostly in-bounds offsets (the modulus reaches one past the
                // last valid start, so out-of-bounds cases still occur).
                let pick = |v: u16, len: usize| {
                    (usize::from(v) % (data.len().saturating_sub(len) + 2)) as u16
                };
                let sig_off = pick(picks[0], SIGNATURE_LEN);
                let pk_off = pick(picks[1], PUBKEY_LEN);
                let msg_size = picks[3] % 40;
                let msg_off = pick(picks[2], usize::from(msg_size));
                for (field, v) in [(0usize, sig_off), (2, pk_off), (4, msg_off), (5, msg_size)] {
                    let o = SIGNATURE_OFFSETS_START + field * 2;
                    data[o..o + 2].copy_from_slice(&v.to_le_bytes());
                }
                let at = usize::from(pk_off);
                if at + PUBKEY_LEN <= data.len() {
                    data[at..at + PUBKEY_LEN].copy_from_slice(&KEY);
                }
            }
            let accepted = verify_inline_single(&data, &KEY, |_| true).is_ok();
            prop_assert_eq!(accepted, oracle_accepts(&data, &KEY));
        }
    }

    /// Independent restatement of the acceptance rule, for `total_on_garbage`.
    fn oracle_accepts(data: &[u8], key: &Pubkey) -> bool {
        if data.len() < DATA_START || data[0] != 1 {
            return false;
        }
        let f = |i: usize| {
            let o = SIGNATURE_OFFSETS_START + i * 2;
            usize::from(u16::from_le_bytes([data[o], data[o + 1]]))
        };
        let inline = usize::from(INLINE);
        if f(1) != inline || f(3) != inline || f(6) != inline {
            return false;
        }
        let in_bounds = |start: usize, len: usize| start + len <= data.len();
        in_bounds(f(0), SIGNATURE_LEN)
            && in_bounds(f(2), PUBKEY_LEN)
            && data[f(2)..f(2) + PUBKEY_LEN] == key[..]
            && in_bounds(f(4), f(5))
    }

    #[test]
    fn rejects_non_inline_offsets_for_each_index() {
        let (pk, data) = build(b"quote", [1; 32]);
        for field in [1usize, 3, 6] {
            let mut d = data.clone();
            let o = SIGNATURE_OFFSETS_START + field * 2;
            d[o..o + 2].copy_from_slice(&0u16.to_le_bytes());
            assert_eq!(
                verify_inline_single(&d, &pk, |m| m == b"quote"),
                Err(RfqError::Ed25519OffsetsNotInline),
                "field {field}"
            );
        }
    }

    #[test]
    fn rejects_signature_counts_other_than_one() {
        let (pk, mut data) = build(b"quote", [2; 32]);
        for n in [0u8, 2, 255] {
            data[0] = n;
            assert_eq!(
                verify_inline_single(&data, &pk, |_| true),
                Err(RfqError::MalformedEd25519Instruction)
            );
        }
    }

    #[test]
    fn rejects_truncated_and_out_of_range() {
        let (pk, data) = build(b"quote", [3; 32]);
        assert_eq!(
            verify_inline_single(&data[..DATA_START - 1], &pk, |_| true),
            Err(RfqError::MalformedEd25519Instruction)
        );
        let mut d = data.clone();
        // message size pointing past the end
        let o = SIGNATURE_OFFSETS_START + 5 * 2;
        d[o..o + 2].copy_from_slice(&u16::MAX.to_le_bytes());
        assert_eq!(
            verify_inline_single(&d, &pk, |_| true),
            Err(RfqError::MalformedEd25519Instruction)
        );
        let mut d = data;
        // public key offset pointing past the end
        let o = SIGNATURE_OFFSETS_START + 2 * 2;
        d[o..o + 2].copy_from_slice(&60_000u16.to_le_bytes());
        assert_eq!(
            verify_inline_single(&d, &pk, |_| true),
            Err(RfqError::MalformedEd25519Instruction)
        );
    }

    #[test]
    fn encode_rejects_small_buffer() {
        let mut out = [0u8; 10];
        assert_eq!(
            encode_single(&[0; 32], &[0; 64], b"m", &mut out),
            Err(RfqError::MalformedEd25519Instruction)
        );
    }
}
