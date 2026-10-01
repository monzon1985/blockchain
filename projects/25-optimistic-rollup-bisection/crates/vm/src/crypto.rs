// SPDX-License-Identifier: MIT
//! `ECRECOVER` semantics, identical to the Ethereum `ecrecover` precompile (address `0x01`).

use alloy_primitives::{B256, U256, keccak256};
use k256::ecdsa::{RecoveryId, Signature, VerifyingKey};

/// Recovers the signer of `digest` as a word (address right-aligned), or zero on any failure.
///
/// Mirrors the precompile exactly: `v` must be the full word 27 or 28; `r` and `s` must be valid non-zero scalars;
/// high-`s` signatures are accepted (normalised with a flipped recovery id, as revm does).
pub fn ecrecover(digest: B256, v: U256, r: B256, s: B256) -> B256 {
    let recid = if v == U256::from(27u8) {
        0u8
    } else if v == U256::from(28u8) {
        1u8
    } else {
        return B256::ZERO;
    };
    let mut rs = [0u8; 64];
    rs[..32].copy_from_slice(r.as_slice());
    rs[32..].copy_from_slice(s.as_slice());
    let Ok(mut sig) = Signature::from_slice(&rs) else {
        return B256::ZERO;
    };
    let mut recid = recid;
    if let Some(normalized) = sig.normalize_s() {
        sig = normalized;
        recid ^= 1;
    }
    let Some(recovery_id) = RecoveryId::from_byte(recid) else {
        return B256::ZERO;
    };
    let Ok(key) = VerifyingKey::recover_from_prehash(digest.as_slice(), &sig, recovery_id) else {
        return B256::ZERO;
    };
    let point = key.to_encoded_point(false);
    let mut hash = keccak256(&point.as_bytes()[1..]);
    hash[..12].fill(0);
    hash
}

#[cfg(test)]
mod tests {
    use super::*;
    use k256::ecdsa::SigningKey;

    fn sign(key: &SigningKey, digest: B256) -> (U256, B256, B256) {
        let (sig, recid) = key.sign_prehash_recoverable(digest.as_slice()).unwrap();
        let bytes = sig.to_bytes();
        (U256::from(27u8 + recid.to_byte()), B256::from_slice(&bytes[..32]), B256::from_slice(&bytes[32..]))
    }

    fn address_word(key: &SigningKey) -> B256 {
        let point = key.verifying_key().to_encoded_point(false);
        let mut h = keccak256(&point.as_bytes()[1..]);
        h[..12].fill(0);
        h
    }

    #[test]
    fn recovers_the_signer() {
        let key = SigningKey::from_slice(&[7u8; 32]).unwrap();
        let digest = keccak256(b"rollup");
        let (v, r, s) = sign(&key, digest);
        assert_eq!(ecrecover(digest, v, r, s), address_word(&key));
    }

    #[test]
    fn high_s_twin_recovers_the_same_signer() {
        // n - s with the other recovery id is the malleable twin; the precompile accepts it.
        let key = SigningKey::from_slice(&[9u8; 32]).unwrap();
        let digest = keccak256(b"malleable");
        let (v, r, s) = sign(&key, digest);
        let n = U256::from_be_slice(&hex_n());
        let s_twin = B256::from(n - U256::from_be_bytes(s.0));
        let v_twin = if v == U256::from(27u8) { U256::from(28u8) } else { U256::from(27u8) };
        assert_eq!(ecrecover(digest, v_twin, r, s_twin), address_word(&key));
    }

    #[test]
    fn invalid_inputs_recover_zero() {
        let key = SigningKey::from_slice(&[3u8; 32]).unwrap();
        let digest = keccak256(b"x");
        let (v, r, s) = sign(&key, digest);
        assert_eq!(ecrecover(digest, U256::from(29u8), r, s), B256::ZERO);
        assert_eq!(ecrecover(digest, v + (U256::from(1u8) << 8), r, s), B256::ZERO);
        assert_eq!(ecrecover(digest, v, B256::ZERO, s), B256::ZERO);
        assert_eq!(ecrecover(digest, v, r, B256::ZERO), B256::ZERO);
        assert_eq!(ecrecover(digest, v, B256::from_slice(&hex_n()), s), B256::ZERO);
    }

    fn hex_n() -> [u8; 32] {
        // secp256k1 group order.
        let mut n = [0u8; 32];
        let hex = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141";
        for (i, byte) in n.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).unwrap();
        }
        n
    }
}
