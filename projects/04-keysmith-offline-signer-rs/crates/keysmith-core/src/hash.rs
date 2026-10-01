// SPDX-License-Identifier: MIT
//! Hash functions used across Keysmith.

use sha2::Digest as _;

/// Keccak-256 (the pre-standard SHA-3 variant Ethereum uses).
pub fn keccak256(data: &[u8]) -> [u8; 32] {
    sha3::Keccak256::digest(data).into()
}

/// Keccak-256 over the concatenation of several slices, without allocating.
pub fn keccak256_concat(parts: &[&[u8]]) -> [u8; 32] {
    let mut hasher = sha3::Keccak256::new();
    for part in parts {
        hasher.update(part);
    }
    hasher.finalize().into()
}

/// SHA-256.
pub fn sha256(data: &[u8]) -> [u8; 32] {
    sha2::Sha256::digest(data).into()
}

/// Bitcoin's HASH160, `RIPEMD-160(SHA-256(data))`, used for BIP-32 fingerprints.
pub fn hash160(data: &[u8]) -> [u8; 20] {
    ripemd::Ripemd160::digest(sha256(data)).into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hex;

    #[test]
    fn known_digests() {
        assert_eq!(
            hex::encode(&keccak256(b"")),
            "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
        );
        assert_eq!(keccak256_concat(&[b"ab", b"c"]), keccak256(b"abc"));
        assert_eq!(
            hex::encode(&sha256(b"abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        // HASH160 of the empty string.
        assert_eq!(
            hex::encode(&hash160(b"")),
            "b472a266d0bd89c13706a4132ccfb16f7c3b9fcb"
        );
    }
}
