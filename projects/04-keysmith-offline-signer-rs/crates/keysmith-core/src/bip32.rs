// SPDX-License-Identifier: MIT
//! BIP-32 hierarchical deterministic keys and BIP-44 paths, built directly on HMAC-SHA512 and
//! `k256` scalar/point arithmetic.
//!
//! * `master`: `I = HMAC-SHA512("Bitcoin seed", seed)`, key `I_L`, chain code `I_R`.
//! * `CKDpriv`: `I = HMAC-SHA512(c_par, 0x00 || k_par || i)` (hardened) or
//!   `HMAC-SHA512(c_par, serP(K_par) || i)`; `k_i = I_L + k_par mod n`.
//! * `CKDpub`: `K_i = point(I_L) + K_par` (non-hardened only).
//!
//! If `I_L >= n` or the child key is zero/infinity the derivation fails with
//! [`Bip32Error::InvalidChildKey`] rather than silently skipping to another index, because a
//! wallet must never derive a different path than the one it was asked for.

use crate::address::Address;
use crate::base58::{self, Base58Error};
use crate::bip39::Seed;
use crate::hash::hash160;
use crate::keys::PrivateKey;
use alloc::string::String;
use alloc::vec::Vec;
use core::fmt;
use hmac::{Hmac, Mac};
use k256::elliptic_curve::PrimeField;
use k256::elliptic_curve::sec1::ToEncodedPoint;
use k256::{NonZeroScalar, ProjectivePoint, PublicKey, Scalar};
use zeroize::{Zeroize, Zeroizing};

type HmacSha512 = Hmac<sha2::Sha512>;

/// Index offset of hardened children.
pub const HARDENED: u32 = 0x8000_0000;

/// Maximum depth encodable in the 1-byte depth field.
pub const MAX_DEPTH: usize = 255;

/// Errors produced by BIP-32 derivation, paths and extended-key encoding.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum Bip32Error {
    /// Seed shorter than 128 bits or longer than 512 bits.
    #[error("seed must be 16..=64 bytes, got {0}")]
    InvalidSeedLength(usize),
    /// `I_L` of the master derivation is not a valid scalar.
    #[error("seed yields an invalid master key")]
    InvalidMasterKey,
    /// `I_L >= n` or the child key is zero / the point at infinity.
    #[error("child {index} is invalid (probability < 2^-127); use another index")]
    InvalidChildKey {
        /// The child number that failed.
        index: u32,
    },
    /// Hardened derivation requires the private key.
    #[error("cannot derive hardened child {index} from a public key")]
    HardenedFromPublic {
        /// The hardened child number requested.
        index: u32,
    },
    /// Deriving would exceed depth 255.
    #[error("derivation depth exceeds 255")]
    DepthOverflow,
    /// A derivation path component could not be parsed.
    #[error("invalid derivation path at component {position}")]
    InvalidPath {
        /// Zero-based component position (0 is the leading `m`).
        position: usize,
    },
    /// Base58 decoding failed.
    #[error("extended key is not valid base58")]
    InvalidEncoding,
    /// Base58Check checksum mismatch.
    #[error("extended key checksum mismatch")]
    InvalidChecksum,
    /// The decoded payload is not 78 bytes.
    #[error("extended key payload must be 78 bytes, got {0}")]
    InvalidLength(usize),
    /// Version bytes are not xprv/xpub/tprv/tpub.
    #[error("unknown extended key version {0:#010x}")]
    UnknownVersion(u32),
    /// Private version with public key data, or vice versa.
    #[error("extended key version does not match its key data")]
    VersionKeyMismatch,
    /// Key data starts with an invalid prefix byte.
    #[error("invalid key data prefix {0:#04x}")]
    InvalidKeyPrefix(u8),
    /// Private key is zero or not below the curve order.
    #[error("extended private key is not in [1, n-1]")]
    InvalidPrivateKey,
    /// Public key is not a point on the curve.
    #[error("extended public key is not a valid curve point")]
    InvalidPublicKey,
    /// Depth 0 with a non-zero parent fingerprint.
    #[error("depth 0 with non-zero parent fingerprint")]
    ZeroDepthWithParent,
    /// Depth 0 with a non-zero child number.
    #[error("depth 0 with non-zero child number")]
    ZeroDepthWithIndex,
}

/// Key-version bytes (BIP-32 "mainnet" and "testnet").
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Network {
    /// `xprv` / `xpub`.
    Mainnet,
    /// `tprv` / `tpub`.
    Testnet,
}

impl Network {
    fn private_version(self) -> u32 {
        match self {
            Network::Mainnet => 0x0488_ADE4,
            Network::Testnet => 0x0435_8394,
        }
    }

    fn public_version(self) -> u32 {
        match self {
            Network::Mainnet => 0x0488_B21E,
            Network::Testnet => 0x0435_87CF,
        }
    }
}

/// A BIP-32 derivation path such as `m/44'/60'/0'/0/0`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DerivationPath(Vec<u32>);

impl DerivationPath {
    /// Parses `m/...`; hardened components may use `'`, `h` or `H`.
    pub fn parse(s: &str) -> Result<Self, Bip32Error> {
        let mut parts = s.trim().split('/');
        if parts.next() != Some("m") {
            return Err(Bip32Error::InvalidPath { position: 0 });
        }
        let mut out = Vec::new();
        for (i, part) in parts.enumerate() {
            let position = i + 1;
            let (digits, hardened) = match part
                .strip_suffix('\'')
                .or_else(|| part.strip_suffix('h'))
                .or_else(|| part.strip_suffix('H'))
            {
                Some(d) => (d, true),
                None => (part, false),
            };
            if digits.is_empty() || !digits.bytes().all(|c| c.is_ascii_digit()) {
                return Err(Bip32Error::InvalidPath { position });
            }
            let index: u32 = digits
                .parse()
                .map_err(|_| Bip32Error::InvalidPath { position })?;
            if index >= HARDENED {
                return Err(Bip32Error::InvalidPath { position });
            }
            out.push(if hardened { index | HARDENED } else { index });
        }
        if out.len() > MAX_DEPTH {
            return Err(Bip32Error::DepthOverflow);
        }
        Ok(Self(out))
    }

    /// The BIP-44 Ethereum path `m/44'/60'/0'/0/{index}` used by MetaMask, Foundry and anvil.
    pub fn ethereum(index: u32) -> Result<Self, Bip32Error> {
        if index >= HARDENED {
            return Err(Bip32Error::InvalidPath { position: 5 });
        }
        Ok(Self(alloc::vec![
            44 | HARDENED,
            60 | HARDENED,
            HARDENED,
            0,
            index
        ]))
    }

    /// The raw child numbers (hardened ones have the top bit set).
    pub fn children(&self) -> &[u32] {
        &self.0
    }
}

impl fmt::Display for DerivationPath {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("m")?;
        for c in &self.0 {
            if c & HARDENED != 0 {
                write!(f, "/{}'", c & !HARDENED)?;
            } else {
                write!(f, "/{c}")?;
            }
        }
        Ok(())
    }
}

fn hmac_sha512(key: &[u8], data: &[u8]) -> Zeroizing<[u8; 64]> {
    // HMAC accepts keys of any length, so `new_from_slice` cannot fail here.
    let mut out = Zeroizing::new([0u8; 64]);
    if let Ok(mut mac) = HmacSha512::new_from_slice(key) {
        mac.update(data);
        out.copy_from_slice(&mac.finalize().into_bytes());
    }
    out
}

fn split(i: &[u8; 64]) -> (Zeroizing<[u8; 32]>, Zeroizing<[u8; 32]>) {
    let mut il = Zeroizing::new([0u8; 32]);
    let mut ir = Zeroizing::new([0u8; 32]);
    il.copy_from_slice(&i[..32]);
    ir.copy_from_slice(&i[32..]);
    (il, ir)
}

fn scalar_from_bytes(bytes: &[u8; 32]) -> Option<Scalar> {
    Option::from(Scalar::from_repr((*bytes).into()))
}

fn serialize(
    version: u32,
    depth: u8,
    parent: [u8; 4],
    child: u32,
    chain_code: &[u8; 32],
    key_data: &[u8; 33],
) -> String {
    let mut buf = Zeroizing::new(Vec::with_capacity(78));
    buf.extend_from_slice(&version.to_be_bytes());
    buf.push(depth);
    buf.extend_from_slice(&parent);
    buf.extend_from_slice(&child.to_be_bytes());
    buf.extend_from_slice(chain_code);
    buf.extend_from_slice(key_data);
    base58::encode_check(&buf)
}

fn compressed(key: &PublicKey) -> [u8; 33] {
    let point = key.to_encoded_point(true);
    let mut out = [0u8; 33];
    out.copy_from_slice(point.as_bytes());
    out
}

/// An extended private key. Chain code and key are zeroised on drop; `Debug` is redacted.
#[derive(Clone)]
pub struct ExtendedPrivateKey {
    depth: u8,
    parent_fingerprint: [u8; 4],
    child_number: u32,
    chain_code: Zeroizing<[u8; 32]>,
    key: PrivateKey,
}

impl ExtendedPrivateKey {
    /// Derives the master key from a 16..=64-byte seed.
    pub fn master(seed: &[u8]) -> Result<Self, Bip32Error> {
        if !(16..=64).contains(&seed.len()) {
            return Err(Bip32Error::InvalidSeedLength(seed.len()));
        }
        let i = hmac_sha512(b"Bitcoin seed", seed);
        let (il, ir) = split(&i);
        let key = PrivateKey::from_bytes(&il).map_err(|_| Bip32Error::InvalidMasterKey)?;
        Ok(Self {
            depth: 0,
            parent_fingerprint: [0; 4],
            child_number: 0,
            chain_code: ir,
            key,
        })
    }

    /// Derives the master key from a BIP-39 seed.
    pub fn from_seed(seed: &Seed) -> Result<Self, Bip32Error> {
        Self::master(seed.as_bytes())
    }

    /// `CKDpriv`: derives child `index` (hardened if `index >= 2^31`).
    pub fn derive_child(&self, index: u32) -> Result<Self, Bip32Error> {
        let depth = self.depth.checked_add(1).ok_or(Bip32Error::DepthOverflow)?;
        let mut data = Zeroizing::new(Vec::with_capacity(37));
        if index & HARDENED != 0 {
            data.push(0);
            data.extend_from_slice(self.key.to_bytes().as_ref());
        } else {
            data.extend_from_slice(&compressed(&self.key.public_key()));
        }
        data.extend_from_slice(&index.to_be_bytes());
        let i = hmac_sha512(self.chain_code.as_ref(), &data);
        let (il, ir) = split(&i);
        let mut tweak = scalar_from_bytes(&il).ok_or(Bip32Error::InvalidChildKey { index })?;
        let mut parent = self.key.scalar();
        let mut child = tweak + parent;
        tweak.zeroize();
        parent.zeroize();
        let nonzero = Option::<NonZeroScalar>::from(NonZeroScalar::new(child))
            .ok_or(Bip32Error::InvalidChildKey { index })?;
        child.zeroize();
        Ok(Self {
            depth,
            parent_fingerprint: self.fingerprint(),
            child_number: index,
            chain_code: ir,
            key: PrivateKey::from_nonzero_scalar(nonzero),
        })
    }

    /// Derives every component of `path` from this key.
    pub fn derive_path(&self, path: &DerivationPath) -> Result<Self, Bip32Error> {
        let mut key = self.clone();
        for index in path.children() {
            key = key.derive_child(*index)?;
        }
        Ok(key)
    }

    /// The neutered extended public key `N(self)`.
    pub fn public(&self) -> ExtendedPublicKey {
        ExtendedPublicKey {
            depth: self.depth,
            parent_fingerprint: self.parent_fingerprint,
            child_number: self.child_number,
            chain_code: *self.chain_code,
            key: self.key.public_key(),
        }
    }

    /// First 4 bytes of `HASH160(serP(K))`.
    pub fn fingerprint(&self) -> [u8; 4] {
        self.public().fingerprint()
    }

    /// The underlying private key.
    pub fn private_key(&self) -> &PrivateKey {
        &self.key
    }

    /// Consumes the extended key, returning the private key.
    pub fn into_private_key(self) -> PrivateKey {
        self.key
    }

    /// Depth in the tree (0 for the master key).
    pub fn depth(&self) -> u8 {
        self.depth
    }

    /// Base58Check serialisation (`xprv...` / `tprv...`).
    pub fn to_extended_string(&self, network: Network) -> Zeroizing<String> {
        let mut key_data = Zeroizing::new([0u8; 33]);
        key_data[1..].copy_from_slice(self.key.to_bytes().as_ref());
        Zeroizing::new(serialize(
            network.private_version(),
            self.depth,
            self.parent_fingerprint,
            self.child_number,
            &self.chain_code,
            &key_data,
        ))
    }
}

impl fmt::Debug for ExtendedPrivateKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ExtendedPrivateKey")
            .field("depth", &self.depth)
            .field("address", &self.key.address())
            .field("secret", &"<redacted>")
            .finish()
    }
}

/// An extended public key (watch-only derivation of non-hardened children).
#[derive(Clone, PartialEq, Eq)]
pub struct ExtendedPublicKey {
    depth: u8,
    parent_fingerprint: [u8; 4],
    child_number: u32,
    chain_code: [u8; 32],
    key: PublicKey,
}

impl ExtendedPublicKey {
    /// `CKDpub`: derives non-hardened child `index`.
    pub fn derive_child(&self, index: u32) -> Result<Self, Bip32Error> {
        if index & HARDENED != 0 {
            return Err(Bip32Error::HardenedFromPublic { index });
        }
        let depth = self.depth.checked_add(1).ok_or(Bip32Error::DepthOverflow)?;
        let mut data = Vec::with_capacity(37);
        data.extend_from_slice(&compressed(&self.key));
        data.extend_from_slice(&index.to_be_bytes());
        let i = hmac_sha512(&self.chain_code, &data);
        let (il, ir) = split(&i);
        let tweak = scalar_from_bytes(&il).ok_or(Bip32Error::InvalidChildKey { index })?;
        let point = ProjectivePoint::GENERATOR * tweak + self.key.to_projective();
        let key = PublicKey::from_affine(point.to_affine())
            .map_err(|_| Bip32Error::InvalidChildKey { index })?;
        Ok(Self {
            depth,
            parent_fingerprint: self.fingerprint(),
            child_number: index,
            chain_code: *ir,
            key,
        })
    }

    /// Derives every (non-hardened) component of `path`.
    pub fn derive_path(&self, path: &DerivationPath) -> Result<Self, Bip32Error> {
        let mut key = self.clone();
        for index in path.children() {
            key = key.derive_child(*index)?;
        }
        Ok(key)
    }

    /// First 4 bytes of `HASH160(serP(K))`.
    pub fn fingerprint(&self) -> [u8; 4] {
        let h = hash160(&compressed(&self.key));
        [h[0], h[1], h[2], h[3]]
    }

    /// The public key.
    pub fn public_key(&self) -> &PublicKey {
        &self.key
    }

    /// The Ethereum address of the public key.
    pub fn address(&self) -> Address {
        Address::from_public_key(&self.key)
    }

    /// Base58Check serialisation (`xpub...` / `tpub...`).
    pub fn to_extended_string(&self, network: Network) -> String {
        serialize(
            network.public_version(),
            self.depth,
            self.parent_fingerprint,
            self.child_number,
            &self.chain_code,
            &compressed(&self.key),
        )
    }
}

impl fmt::Debug for ExtendedPublicKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.to_extended_string(Network::Mainnet))
    }
}

/// A parsed extended key of either kind.
#[derive(Debug, Clone)]
pub enum ExtendedKey {
    /// `xprv` / `tprv`.
    Private(ExtendedPrivateKey),
    /// `xpub` / `tpub`.
    Public(ExtendedPublicKey),
}

/// Parses and fully validates a Base58Check extended key (all BIP-32 vector-5 rules).
pub fn parse_extended_key(s: &str) -> Result<(ExtendedKey, Network), Bip32Error> {
    let payload = base58::decode_check(s.trim()).map_err(|e| match e {
        Base58Error::BadChecksum => Bip32Error::InvalidChecksum,
        Base58Error::InvalidChar { .. } | Base58Error::TooShort => Bip32Error::InvalidEncoding,
    })?;
    if payload.len() != 78 {
        return Err(Bip32Error::InvalidLength(payload.len()));
    }
    let version = u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
    let depth = payload[4];
    let parent_fingerprint = [payload[5], payload[6], payload[7], payload[8]];
    let child_number = u32::from_be_bytes([payload[9], payload[10], payload[11], payload[12]]);
    let mut chain_code = Zeroizing::new([0u8; 32]);
    chain_code.copy_from_slice(&payload[13..45]);
    let key_data = &payload[45..78];

    let (network, private) = match version {
        0x0488_ADE4 => (Network::Mainnet, true),
        0x0488_B21E => (Network::Mainnet, false),
        0x0435_8394 => (Network::Testnet, true),
        0x0435_87CF => (Network::Testnet, false),
        other => return Err(Bip32Error::UnknownVersion(other)),
    };
    if depth == 0 && parent_fingerprint != [0; 4] {
        return Err(Bip32Error::ZeroDepthWithParent);
    }
    if depth == 0 && child_number != 0 {
        return Err(Bip32Error::ZeroDepthWithIndex);
    }
    let key = if private {
        match key_data[0] {
            0x00 => {}
            0x02 | 0x03 => return Err(Bip32Error::VersionKeyMismatch),
            other => return Err(Bip32Error::InvalidKeyPrefix(other)),
        }
        let mut secret = Zeroizing::new([0u8; 32]);
        secret.copy_from_slice(&key_data[1..]);
        let key = PrivateKey::from_bytes(&secret).map_err(|_| Bip32Error::InvalidPrivateKey)?;
        ExtendedKey::Private(ExtendedPrivateKey {
            depth,
            parent_fingerprint,
            child_number,
            chain_code,
            key,
        })
    } else {
        match key_data[0] {
            0x02 | 0x03 => {}
            0x00 => return Err(Bip32Error::VersionKeyMismatch),
            other => return Err(Bip32Error::InvalidKeyPrefix(other)),
        }
        let key = PublicKey::from_sec1_bytes(key_data).map_err(|_| Bip32Error::InvalidPublicKey)?;
        ExtendedKey::Public(ExtendedPublicKey {
            depth,
            parent_fingerprint,
            child_number,
            chain_code: *chain_code,
            key,
        })
    };
    Ok((key, network))
}

/// Convenience: BIP-39 seed + path to a private key.
pub fn derive_private_key(seed: &Seed, path: &DerivationPath) -> Result<PrivateKey, Bip32Error> {
    Ok(ExtendedPrivateKey::from_seed(seed)?
        .derive_path(path)?
        .into_private_key())
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::format;
    use alloc::string::ToString;

    #[test]
    fn path_parsing() {
        let p = DerivationPath::parse("m/44'/60'/0h/0/7H").unwrap();
        assert_eq!(p.to_string(), "m/44'/60'/0'/0/7'");
        assert_eq!(DerivationPath::parse("m").unwrap().children().len(), 0);
        assert_eq!(
            DerivationPath::ethereum(3).unwrap().to_string(),
            "m/44'/60'/0'/0/3"
        );
        for (bad, pos) in [
            ("44'/60'", 0),
            ("m/", 1),
            ("m/x", 1),
            ("m/0/-1", 2),
            ("m/2147483648", 1),
            ("m/1''", 1),
            ("m/+1", 1),
        ] {
            assert_eq!(
                DerivationPath::parse(bad),
                Err(Bip32Error::InvalidPath { position: pos }),
                "{bad}"
            );
        }
        assert_eq!(
            DerivationPath::ethereum(HARDENED),
            Err(Bip32Error::InvalidPath { position: 5 })
        );
        let deep = format!("m{}", "/0".repeat(256));
        assert_eq!(DerivationPath::parse(&deep), Err(Bip32Error::DepthOverflow));
    }

    #[test]
    fn seed_length_and_public_derivation_rules() {
        assert_eq!(
            ExtendedPrivateKey::master(&[1u8; 15]).map(|_| ()),
            Err(Bip32Error::InvalidSeedLength(15))
        );
        assert_eq!(
            ExtendedPrivateKey::master(&[1u8; 65]).map(|_| ()),
            Err(Bip32Error::InvalidSeedLength(65))
        );
        let master = ExtendedPrivateKey::master(&[7u8; 32]).unwrap();
        let xpub = master.public();
        assert_eq!(
            xpub.derive_child(HARDENED),
            Err(Bip32Error::HardenedFromPublic { index: HARDENED })
        );
        // CKDpub(N(k)) == N(CKDpriv(k)) for non-hardened children.
        assert_eq!(
            xpub.derive_child(5).unwrap(),
            master.derive_child(5).unwrap().public()
        );
        let dbg = format!("{master:?}");
        assert!(dbg.contains("<redacted>"));
        assert!(!dbg.contains("xprv"));
    }

    #[test]
    fn depth_overflow() {
        let mut key = ExtendedPrivateKey::master(&[9u8; 16]).unwrap();
        key.depth = 255;
        assert_eq!(
            key.derive_child(0).map(|_| ()),
            Err(Bip32Error::DepthOverflow)
        );
        let mut public = key.public();
        public.depth = 255;
        assert_eq!(
            public.derive_child(0).map(|_| ()),
            Err(Bip32Error::DepthOverflow)
        );
    }

    #[test]
    fn extended_key_parse_errors() {
        assert_eq!(
            parse_extended_key("0OIl").map(|_| ()),
            Err(Bip32Error::InvalidEncoding)
        );
        let short = base58::encode_check(&[0u8; 10]);
        assert_eq!(
            parse_extended_key(&short).map(|_| ()),
            Err(Bip32Error::InvalidLength(10))
        );
    }
}
