// SPDX-License-Identifier: MIT
//! EVM representation of FROST keys and signatures, and a bit-exact Rust model
//! of `SchnorrSecp256k1.verify` (contracts/src/SchnorrSecp256k1.sol).
//!
//! ## The ecrecover trick
//!
//! The `ecrecover(h, v, r, s)` precompile returns the address of
//! `Q = r⁻¹·(s·R' − h·G)`, where `R'` is the curve point with `x = r` and
//! `y`-parity `v − 27`. The verifier chooses
//!
//! ```text
//! R' = P                (r = P.x, v = 27 + parity(P))
//! s  = −e·P.x  mod n
//! h  = −z·P.x  mod n
//! ```
//!
//! so that `Q = P.x⁻¹·(−e·P.x·P + z·P.x·G) = z·G − e·P`, which equals the
//! nonce commitment `R` exactly when the Schnorr equation `z·G = R + e·P`
//! holds. Comparing `address(Q)` with the signature's `address(R)` therefore
//! verifies the signature with one precompile call (3 000 gas) plus a few
//! `mulmod`s, instead of two elliptic-curve multiplications in Solidity.
//!
//! The trick needs `0 < P.x < n` because `r` must be a valid ECDSA scalar.
//! Keys outside that range are rejected at key generation
//! ([`crate::Secp256K1Keccak256`]'s `post_dkg` hook) and by the contract.

use frost_core::Group;
use k256::{
    AffinePoint, ProjectivePoint, Scalar,
    elliptic_curve::{
        PrimeField,
        point::{AffineCoordinates, DecompressPoint},
        sec1::ToEncodedPoint,
        subtle::Choice,
    },
};

use crate::{Error, Secp256K1Keccak256, Signature, VerifyingKey, keccak256, reduce_mod_n};

/// Order `n` of the secp256k1 group, big-endian.
pub const SECP256K1_ORDER: [u8; 32] = [
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
    0xba, 0xae, 0xdc, 0xe6, 0xaf, 0x48, 0xa0, 0x3b, 0xbf, 0xd2, 0x5e, 0x8c, 0xd0, 0x36, 0x41, 0x41,
];

/// Errors raised when converting FROST objects to their EVM representation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum EvmError {
    /// The identity point has no affine coordinates and therefore no address.
    #[error("the identity point has no Ethereum address")]
    IdentityPoint,
    /// `P.x` is zero or `>= n`, so it cannot be passed to `ecrecover` as `r`.
    #[error("group key x-coordinate 0x{0} is not in [1, n-1]; ecrecover cannot verify it")]
    KeyNotEcrecoverCompatible(HexWord),
    /// The y-parity byte is neither 0 nor 1.
    #[error("y-parity must be 0 or 1, got {0}")]
    InvalidParity(u8),
    /// No curve point has the given x-coordinate.
    #[error("x-coordinate is not on secp256k1")]
    NotOnCurve,
    /// The FROST object could not be serialised.
    #[error("malformed FROST encoding")]
    Malformed,
}

/// A 32-byte word, displayed as lower-case hex (used in error messages).
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct HexWord(pub [u8; 32]);

impl core::fmt::Display for HexWord {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(&hex::encode(self.0))
    }
}

impl core::fmt::Debug for HexWord {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "0x{self}")
    }
}

/// Returns `true` iff `0 < x < n` (big-endian comparison).
#[must_use]
pub fn is_valid_scalar_word(x: &[u8; 32]) -> bool {
    x.iter().any(|b| *b != 0) && x.as_slice() < SECP256K1_ORDER.as_slice()
}

/// Ethereum address of a curve point: `keccak256(x || y)[12..]`.
pub fn eth_address(point: &ProjectivePoint) -> Result<[u8; 20], EvmError> {
    if *point == <Secp256K1Keccak256 as frost_core::Ciphersuite>::Group::identity() {
        return Err(EvmError::IdentityPoint);
    }
    let encoded = point.to_affine().to_encoded_point(false);
    // Uncompressed SEC1 encoding is 0x04 || x || y (65 bytes) for non-identity points.
    let xy = encoded.as_bytes().get(1..).ok_or(EvmError::IdentityPoint)?;
    let hash = keccak256(&[xy]);
    let mut address = [0u8; 20];
    address.copy_from_slice(&hash[12..]);
    Ok(address)
}

/// The group key as the vault stores it: `x` coordinate and `y` parity.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct EvmGroupKey {
    /// Big-endian `x` coordinate of the group key.
    pub x: [u8; 32],
    /// `0` if `y` is even, `1` if odd.
    pub y_parity: u8,
}

impl EvmGroupKey {
    /// Converts a FROST verifying key, rejecting keys the contract cannot verify.
    pub fn from_verifying_key(verifying_key: &VerifyingKey) -> Result<Self, EvmError> {
        let key =
            Self::from_verifying_key_unchecked(verifying_key).map_err(|_| EvmError::Malformed)?;
        if !is_valid_scalar_word(&key.x) {
            return Err(EvmError::KeyNotEcrecoverCompatible(HexWord(key.x)));
        }
        Ok(key)
    }

    /// Splits the compressed SEC1 encoding into `(x, parity)` without the
    /// `x < n` check. Used by the challenge, which is defined for every key.
    pub(crate) fn from_verifying_key_unchecked(
        verifying_key: &VerifyingKey,
    ) -> Result<Self, Error> {
        let compressed = verifying_key.serialize()?;
        Self::from_compressed(&compressed).map_err(|_| Error::MalformedVerifyingKey)
    }

    /// Parses a 33-byte compressed SEC1 point (`0x02`/`0x03` prefix).
    pub fn from_compressed(compressed: &[u8]) -> Result<Self, EvmError> {
        let (prefix, x) = compressed.split_first().ok_or(EvmError::Malformed)?;
        let y_parity = match prefix {
            0x02 => 0,
            0x03 => 1,
            _ => return Err(EvmError::Malformed),
        };
        let x: [u8; 32] = x.try_into().map_err(|_| EvmError::Malformed)?;
        Ok(Self { x, y_parity })
    }

    /// Recovers the curve point `P`.
    pub fn to_point(&self) -> Result<ProjectivePoint, EvmError> {
        decompress(&self.x, self.y_parity)
    }

    /// The `v` value handed to `ecrecover` (`27 + parity`).
    #[must_use]
    pub fn ecrecover_v(&self) -> u8 {
        27 + self.y_parity
    }
}

/// A Schnorr signature in the form the vault accepts: `(address(R), z)`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct EvmSignature {
    /// Ethereum address of the nonce commitment `R`.
    pub r_address: [u8; 20],
    /// Response scalar `z`, big-endian, `0 < z < n`.
    pub z: [u8; 32],
}

impl EvmSignature {
    /// Converts an aggregate FROST signature.
    pub fn from_signature(signature: &Signature) -> Result<Self, EvmError> {
        let r_address = eth_address(signature.R())?;
        let z: [u8; 32] = signature.z().to_bytes().into();
        Ok(Self { r_address, z })
    }

    /// 52-byte packed encoding `address(R) || z`.
    #[must_use]
    pub fn to_packed(&self) -> [u8; 52] {
        let mut out = [0u8; 52];
        out[..20].copy_from_slice(&self.r_address);
        out[20..].copy_from_slice(&self.z);
        out
    }
}

/// `keccak256(address(R) || parity || x || message) mod n`, identical to
/// `SchnorrSecp256k1.challenge` for 32-byte messages.
#[must_use]
pub fn challenge_scalar(r_address: &[u8; 20], key: &EvmGroupKey, message: &[u8]) -> Scalar {
    reduce_mod_n(&keccak256(&[r_address, &[key.y_parity], &key.x, message]))
}

/// The four words the Solidity verifier passes to `ecrecover`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EcrecoverCall {
    /// `h = −z·P.x mod n`.
    pub hash: [u8; 32],
    /// `27 + parity(P)`.
    pub v: u8,
    /// `P.x`.
    pub r: [u8; 32],
    /// `s = −e·P.x mod n`.
    pub s: [u8; 32],
}

/// Computes the `ecrecover` arguments exactly as the Solidity verifier does.
/// Returns `None` whenever the Solidity code returns `false` before calling
/// the precompile.
#[must_use]
pub fn ecrecover_inputs(
    key: &EvmGroupKey,
    message_hash: &[u8; 32],
    signature: &EvmSignature,
) -> Option<EcrecoverCall> {
    if signature.r_address == [0u8; 20]
        || !is_valid_scalar_word(&signature.z)
        || !is_valid_scalar_word(&key.x)
        || key.y_parity > 1
    {
        return None;
    }
    let e = challenge_scalar(&signature.r_address, key, message_hash);
    let px = scalar_from_word(&key.x)?;
    let z = scalar_from_word(&signature.z)?;
    let e_px = e * px;
    if e_px == Scalar::ZERO {
        return None;
    }
    let s = -e_px;
    let h = -(z * px);
    Some(EcrecoverCall {
        hash: h.to_bytes().into(),
        v: key.ecrecover_v(),
        r: key.x,
        s: s.to_bytes().into(),
    })
}

/// Emulation of the `ecrecover` precompile (address `0x01`).
///
/// Mirrors go-ethereum: `v ∈ {27, 28}`, `r, s ∈ [1, n−1]` (no low-`s` rule for
/// the precompile), the hash is reduced modulo `n`, and a failed recovery or a
/// point at infinity yields `None` (Solidity observes `address(0)`).
#[must_use]
pub fn ecrecover(hash: &[u8; 32], v: u8, r: &[u8; 32], s: &[u8; 32]) -> Option<[u8; 20]> {
    if v != 27 && v != 28 {
        return None;
    }
    let r_scalar = scalar_from_word(r)?;
    let s_scalar = scalar_from_word(s)?;
    if r_scalar == Scalar::ZERO || s_scalar == Scalar::ZERO {
        return None;
    }
    let r_point = decompress(r, v - 27).ok()?;
    let h = reduce_mod_n(hash);
    let r_inv = Option::<Scalar>::from(r_scalar.invert())?;
    let q = (r_point * s_scalar - ProjectivePoint::GENERATOR * h) * r_inv;
    eth_address(&q).ok()
}

/// Bit-exact model of `SchnorrSecp256k1.verify`.
#[must_use]
pub fn verify(key: &EvmGroupKey, message_hash: &[u8; 32], signature: &EvmSignature) -> bool {
    match ecrecover_inputs(key, message_hash, signature) {
        Some(call) => ecrecover(&call.hash, call.v, &call.r, &call.s) == Some(signature.r_address),
        None => false,
    }
}

fn scalar_from_word(word: &[u8; 32]) -> Option<Scalar> {
    Option::<Scalar>::from(Scalar::from_repr((*word).into()))
}

fn decompress(x: &[u8; 32], y_parity: u8) -> Result<ProjectivePoint, EvmError> {
    if y_parity > 1 {
        return Err(EvmError::InvalidParity(y_parity));
    }
    let point = Option::<AffinePoint>::from(AffinePoint::decompress(
        &(*x).into(),
        Choice::from(y_parity),
    ))
    .ok_or(EvmError::NotOnCurve)?;
    debug_assert_eq!(u8::from(bool::from(point.y_is_odd())), y_parity);
    Ok(ProjectivePoint::from(point))
}
