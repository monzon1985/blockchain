// SPDX-License-Identifier: MIT
//! secp256k1 private keys, recoverable ECDSA signatures and signer recovery.
//!
//! Signing is RFC 6979 deterministic (via `k256`) and every signature leaving this module is
//! low-s normalised, as EIP-2 requires for transactions and EIP-7702 for authorizations.
//! Recovery rejects high-s signatures instead of silently accepting a malleated twin.

use crate::address::Address;
use crate::hex;
use crate::u256::U256;
use core::fmt;
use k256::ecdsa::{RecoveryId, Signature as KSignature, SigningKey, VerifyingKey};
use zeroize::{Zeroize, Zeroizing};

/// The secp256k1 group order `n`.
pub const CURVE_ORDER: U256 = U256::from_limbs([
    0xBFD2_5E8C_D036_4141,
    0xBAAE_DCE6_AF48_A03B,
    0xFFFF_FFFF_FFFF_FFFE,
    0xFFFF_FFFF_FFFF_FFFF,
]);

/// `floor(n / 2)`: the largest `s` a canonical (low-s) signature may carry.
pub const HALF_CURVE_ORDER: U256 = U256::from_limbs([
    0xDFE9_2F46_681B_20A0,
    0x5D57_6E73_57A4_501D,
    0xFFFF_FFFF_FFFF_FFFF,
    0x7FFF_FFFF_FFFF_FFFF,
]);

/// Errors about private key material. They never contain the key itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum KeyError {
    /// The 32 bytes are zero or not below the curve order.
    #[error("private key is not a valid secp256k1 scalar (must be in [1, n-1])")]
    InvalidScalar,
    /// The text is not 32 bytes of hex.
    #[error("private key must be exactly 32 bytes of hex")]
    InvalidEncoding,
}

/// Errors about signatures.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum SignatureError {
    /// `r` or `s` is zero or not below the curve order.
    #[error("signature r/s is zero or not below the curve order")]
    OutOfRange,
    /// `s` is in the upper half of the order (malleable twin; EIP-2 forbids it).
    #[error("signature s is in the upper half of the curve order (EIP-2)")]
    HighS,
    /// The recovery value is not a valid y-parity.
    #[error("invalid y-parity / v value {0}")]
    InvalidParity(u64),
    /// No public key matches the signature.
    #[error("public key recovery failed")]
    RecoveryFailed,
    /// The signing primitive failed (or produced an unrepresentable recovery id).
    #[error("signing failed")]
    SigningFailed,
    /// A packed signature does not have 65 bytes.
    #[error("signature must be 65 bytes, got {0}")]
    WrongLength(usize),
}

/// A recoverable ECDSA signature in Ethereum form: `(r, s, y_parity)`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Signature {
    /// The `r` scalar.
    pub r: U256,
    /// The `s` scalar.
    pub s: U256,
    /// Parity of the `y` coordinate of the ephemeral point `R`.
    pub y_parity: bool,
}

impl Signature {
    /// `true` if `s <= n/2`.
    pub fn is_low_s(&self) -> bool {
        self.s <= HALF_CURVE_ORDER
    }

    /// Returns the low-s twin: `(r, n - s, !parity)` when `s > n/2`, otherwise `self`.
    pub fn normalize_s(self) -> Self {
        if self.is_low_s() {
            return self;
        }
        match CURVE_ORDER.checked_sub(&self.s) {
            Some(s) => Self {
                r: self.r,
                s,
                y_parity: !self.y_parity,
            },
            // s > n cannot be normalised; leave it for `validate` to reject.
            None => self,
        }
    }

    /// Checks `1 <= r, s < n` and `s <= n/2`.
    pub fn validate(&self) -> Result<(), SignatureError> {
        if self.r.is_zero() || self.s.is_zero() || self.r >= CURVE_ORDER || self.s >= CURVE_ORDER {
            return Err(SignatureError::OutOfRange);
        }
        if !self.is_low_s() {
            return Err(SignatureError::HighS);
        }
        Ok(())
    }

    /// Recovers the signer's public key from a 32-byte prehash.
    pub fn recover_public_key(&self, hash: &[u8; 32]) -> Result<k256::PublicKey, SignatureError> {
        self.validate()?;
        let sig = KSignature::from_scalars(self.r.to_be_bytes(), self.s.to_be_bytes())
            .map_err(|_| SignatureError::OutOfRange)?;
        let recid = RecoveryId::new(self.y_parity, false);
        let key = VerifyingKey::recover_from_prehash(hash, &sig, recid)
            .map_err(|_| SignatureError::RecoveryFailed)?;
        Ok(key.into())
    }

    /// Recovers the signer's address from a 32-byte prehash.
    pub fn recover_address(&self, hash: &[u8; 32]) -> Result<Address, SignatureError> {
        Ok(Address::from_public_key(&self.recover_public_key(hash)?))
    }

    /// Packs as `r || s || v` with `v = 27 + y_parity` (the `personal_sign` / EIP-712 format).
    pub fn to_rsv_bytes(&self) -> [u8; 65] {
        let mut out = [0u8; 65];
        out[..32].copy_from_slice(&self.r.to_be_bytes());
        out[32..64].copy_from_slice(&self.s.to_be_bytes());
        out[64] = 27 + u8::from(self.y_parity);
        out
    }

    /// Unpacks `r || s || v` with `v` in `{0, 1, 27, 28}`.
    pub fn from_rsv_bytes(bytes: &[u8]) -> Result<Self, SignatureError> {
        let bytes: &[u8; 65] = bytes
            .try_into()
            .map_err(|_| SignatureError::WrongLength(bytes.len()))?;
        let y_parity = match bytes[64] {
            0 | 27 => false,
            1 | 28 => true,
            v => return Err(SignatureError::InvalidParity(u64::from(v))),
        };
        let mut r = [0u8; 32];
        let mut s = [0u8; 32];
        r.copy_from_slice(&bytes[..32]);
        s.copy_from_slice(&bytes[32..64]);
        Ok(Self {
            r: U256::from_be_bytes(r),
            s: U256::from_be_bytes(s),
            y_parity,
        })
    }
}

/// A secp256k1 private key. Zeroised on drop; `Debug` shows only the derived address.
pub struct PrivateKey {
    inner: SigningKey,
}

impl PrivateKey {
    /// Builds a key from 32 big-endian bytes.
    pub fn from_bytes(bytes: &[u8; 32]) -> Result<Self, KeyError> {
        SigningKey::from_slice(bytes)
            .map(|inner| Self { inner })
            .map_err(|_| KeyError::InvalidScalar)
    }

    /// Parses 32 bytes of hex (optional `0x`), trimming surrounding whitespace.
    pub fn from_hex(s: &str) -> Result<Self, KeyError> {
        let bytes = Zeroizing::new(hex::decode(s.trim()).map_err(|_| KeyError::InvalidEncoding)?);
        let arr: Zeroizing<[u8; 32]> = Zeroizing::new(
            bytes
                .as_slice()
                .try_into()
                .map_err(|_| KeyError::InvalidEncoding)?,
        );
        Self::from_bytes(&arr)
    }

    /// Wraps a non-zero scalar (used by BIP-32 child derivation).
    pub(crate) fn from_nonzero_scalar(scalar: k256::NonZeroScalar) -> Self {
        Self {
            inner: SigningKey::from(scalar),
        }
    }

    /// The secret scalar (used by BIP-32 child derivation).
    pub(crate) fn scalar(&self) -> k256::Scalar {
        *self.inner.as_nonzero_scalar().as_ref()
    }

    /// Returns the secret scalar. The caller owns a zeroising buffer.
    pub fn to_bytes(&self) -> Zeroizing<[u8; 32]> {
        let mut field = self.inner.to_bytes();
        let mut out = Zeroizing::new([0u8; 32]);
        out.copy_from_slice(&field);
        field.as_mut_slice().zeroize();
        out
    }

    /// The public key.
    pub fn public_key(&self) -> k256::PublicKey {
        self.inner.verifying_key().into()
    }

    /// The Ethereum address of this key.
    pub fn address(&self) -> Address {
        Address::from_public_key(&self.public_key())
    }

    /// Signs a 32-byte prehash, returning a low-s recoverable signature.
    pub fn sign_hash(&self, hash: &[u8; 32]) -> Result<Signature, SignatureError> {
        let (sig, recid) = self
            .inner
            .sign_prehash_recoverable(hash)
            .map_err(|_| SignatureError::SigningFailed)?;
        // An x-reduced recovery id (probability ~2^-127) has no Ethereum encoding.
        if recid.is_x_reduced() {
            return Err(SignatureError::SigningFailed);
        }
        let (r, s) = sig.split_bytes();
        let sig = Signature {
            r: U256::from_be_bytes(r.into()),
            s: U256::from_be_bytes(s.into()),
            y_parity: recid.is_y_odd(),
        }
        .normalize_s();
        sig.validate()?;
        Ok(sig)
    }
}

impl fmt::Debug for PrivateKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PrivateKey")
            .field("address", &self.address())
            .field("secret", &"<redacted>")
            .finish()
    }
}

impl Clone for PrivateKey {
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hash::keccak256;
    use alloc::format;

    const ANVIL_0: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

    #[test]
    fn order_constants_are_consistent() {
        let twice = HALF_CURVE_ORDER.checked_add(&HALF_CURVE_ORDER).unwrap();
        assert_eq!(twice.checked_add(&U256::ONE).unwrap(), CURVE_ORDER);
    }

    #[test]
    fn address_and_redacted_debug() {
        let key = PrivateKey::from_hex(ANVIL_0).unwrap();
        assert_eq!(
            key.address().to_checksum(),
            "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
        );
        let dbg = format!("{key:?}");
        assert!(dbg.contains("<redacted>"));
        assert!(!dbg.contains("ac0974bec39a17e36ba4a6b4d238ff944bacb478"));
        assert_eq!(hex::encode_prefixed(key.to_bytes().as_ref()), ANVIL_0);
        assert_eq!(key.clone().address(), key.address());
    }

    #[test]
    fn rejects_invalid_scalars() {
        assert_eq!(
            PrivateKey::from_bytes(&[0u8; 32]).map(|_| ()),
            Err(KeyError::InvalidScalar)
        );
        assert_eq!(
            PrivateKey::from_bytes(&CURVE_ORDER.to_be_bytes()).map(|_| ()),
            Err(KeyError::InvalidScalar)
        );
        assert_eq!(
            PrivateKey::from_hex("0x1234").map(|_| ()),
            Err(KeyError::InvalidEncoding)
        );
        assert_eq!(
            PrivateKey::from_hex("zz").map(|_| ()),
            Err(KeyError::InvalidEncoding)
        );
    }

    #[test]
    fn sign_recover_and_malleability() {
        let key = PrivateKey::from_hex(ANVIL_0).unwrap();
        let hash = keccak256(b"keysmith");
        let sig = key.sign_hash(&hash).unwrap();
        assert!(sig.is_low_s());
        assert_eq!(sig.recover_address(&hash).unwrap(), key.address());
        // The high-s twin is mathematically valid ECDSA but must be rejected.
        let twin = Signature {
            r: sig.r,
            s: CURVE_ORDER.checked_sub(&sig.s).unwrap(),
            y_parity: !sig.y_parity,
        };
        assert_eq!(twin.recover_address(&hash), Err(SignatureError::HighS));
        assert_eq!(twin.normalize_s(), sig);
        let packed = sig.to_rsv_bytes();
        assert_eq!(Signature::from_rsv_bytes(&packed).unwrap(), sig);
        let mut zero_v = packed;
        zero_v[64] -= 27;
        assert_eq!(Signature::from_rsv_bytes(&zero_v).unwrap(), sig);
        zero_v[64] = 29;
        assert_eq!(
            Signature::from_rsv_bytes(&zero_v),
            Err(SignatureError::InvalidParity(29))
        );
        assert_eq!(
            Signature::from_rsv_bytes(&packed[..64]),
            Err(SignatureError::WrongLength(64))
        );
    }

    #[test]
    fn out_of_range_components() {
        let zero = Signature {
            r: U256::ZERO,
            s: U256::ONE,
            y_parity: false,
        };
        assert_eq!(zero.validate(), Err(SignatureError::OutOfRange));
        let big = Signature {
            r: U256::ONE,
            s: U256::MAX,
            y_parity: false,
        };
        assert_eq!(big.normalize_s(), big);
        assert_eq!(big.validate(), Err(SignatureError::OutOfRange));
        // x = 5 is not the x-coordinate of any curve point (5^3 + 7 is a non-residue mod p),
        // so no public key can be recovered.
        let off_curve = Signature {
            r: U256::from_u64(5),
            s: U256::ONE,
            y_parity: false,
        };
        assert_eq!(
            off_curve.recover_address(&[1u8; 32]),
            Err(SignatureError::RecoveryFailed)
        );
    }
}
