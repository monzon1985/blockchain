// SPDX-License-Identifier: MIT
//! # frost-keccak
//!
//! `FROST(secp256k1, KECCAK-256)`: a [`frost_core::Ciphersuite`] that reuses the
//! secp256k1 group from `frost-secp256k1` (RFC 9591) and replaces only the
//! Schnorr challenge so that an aggregate FROST signature can be verified on the
//! EVM for roughly the price of one `ecrecover`:
//!
//! ```text
//! e = keccak256( address(R) || pkParity || pkX || msg )  mod n
//! z·G = R + e·P
//! ```
//!
//! * `address(R)` is the Ethereum address of the group commitment `R`
//!   (last 20 bytes of `keccak256(R.x || R.y)`).
//! * `pkParity` is one byte, `0` if the group key `P` has an even `y`, `1` otherwise.
//! * `pkX` is the 32-byte big-endian `x` coordinate of `P`.
//! * `msg` is the signed message; the custody protocol always signs a 32-byte
//!   EIP-712 digest.
//!
//! Every other hash (`H1`, `H3`, `H4`, `H5`, `HDKG`, `HID`) keeps the RFC 9591
//! construction (`hash_to_field` with `expand_message_xmd(SHA-256)`) under the
//! distinct context string [`CONTEXT_STRING`], so transcripts can never be
//! confused with the standard `FROST(secp256k1, SHA-256)` suite.
//!
//! The [`evm`] module converts keys and signatures into the representation the
//! Solidity verifier expects and contains a bit-exact Rust model of that
//! verifier (including an emulation of the `ecrecover` precompile) which the
//! test-suite uses as a differential oracle.

#![forbid(unsafe_code)]
#![allow(non_snake_case)]

use std::collections::BTreeMap;

use frost_core::{Challenge, Ciphersuite, Field, Group, GroupError};
use k256::{
    FieldBytes, Scalar, U256,
    elliptic_curve::{
        hash2curve::{ExpandMsgXmd, hash_to_field},
        ops::Reduce,
    },
};
use rand_core::{CryptoRng, RngCore};
use sha2::{Digest, Sha256};
use sha3::Keccak256;

pub mod evm;

pub use frost_core;
pub use frost_secp256k1::{Secp256K1Group, Secp256K1ScalarField};
pub use rand_core;

/// Context string of the ciphersuite. It domain-separates every hash from the
/// standard `FROST-secp256k1-SHA256-v1` suite.
pub const CONTEXT_STRING: &str = "FROST-secp256k1-KECCAK256-v1";

/// `FROST(secp256k1, KECCAK-256)`: the RFC 9591 secp256k1 group with an
/// EVM-verifiable Keccak-256 Schnorr challenge.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Secp256K1Keccak256;

/// FROST error specialised to this ciphersuite.
pub type Error = frost_core::Error<Secp256K1Keccak256>;

/// `keccak256(parts[0] || parts[1] || ...)`.
#[must_use]
pub fn keccak256(parts: &[&[u8]]) -> [u8; 32] {
    let mut hasher = Keccak256::new();
    for part in parts {
        hasher.update(part);
    }
    hasher.finalize().into()
}

/// Reduces a 32-byte big-endian integer modulo the secp256k1 group order `n`.
///
/// This is exactly what Solidity's `uint256(x) % n` computes.
#[must_use]
pub fn reduce_mod_n(bytes: &[u8; 32]) -> Scalar {
    let field_bytes: FieldBytes = (*bytes).into();
    <Scalar as Reduce<U256>>::reduce_bytes(&field_bytes)
}

fn sha256(parts: &[&[u8]]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update(part);
    }
    hasher.finalize().into()
}

fn hash_to_scalar(domain: &[&[u8]], msg: &[u8]) -> Scalar {
    let mut out = [Scalar::ZERO];
    // `expand_message_xmd` only fails when the requested output is longer than
    // 255 hash blocks or the DST is longer than 255 bytes. We request 48 bytes
    // with a DST shorter than 40 bytes, so the error branch is unreachable.
    #[allow(clippy::expect_used)]
    hash_to_field::<ExpandMsgXmd<Sha256>, Scalar>(&[msg], domain, &mut out)
        .expect("expand_message_xmd cannot fail for a 48-byte output and a short DST");
    out[0]
}

/// The RFC 9591 `FROST(secp256k1, SHA-256)` hash constructions (section
/// 6.5), parameterised by the context string.
///
/// The ciphersuite calls them with [`CONTEXT_STRING`]. The test-suite calls
/// them with [`RFC9591_CONTEXT_STRING`] and checks, on random inputs, that
/// they equal `frost-secp256k1`'s `H1/H3/H4/H5/HDKG/HID` (which the RFC 9591
/// vectors validate): the only difference from the standard suite is the
/// context string.
pub mod hashes {
    use super::{Scalar, hash_to_scalar, sha256};

    /// `H1(m)`: binding factor, `hash_to_field` under `context || "rho"`.
    #[must_use]
    pub fn h1(context: &str, m: &[u8]) -> Scalar {
        hash_to_scalar(&[context.as_bytes(), b"rho"], m)
    }

    /// `H3(m)`: nonce derivation, `hash_to_field` under `context || "nonce"`.
    #[must_use]
    pub fn h3(context: &str, m: &[u8]) -> Scalar {
        hash_to_scalar(&[context.as_bytes(), b"nonce"], m)
    }

    /// `H4(m) = SHA-256(context || "msg" || m)`.
    #[must_use]
    pub fn h4(context: &str, m: &[u8]) -> [u8; 32] {
        sha256(&[context.as_bytes(), b"msg", m])
    }

    /// `H5(m) = SHA-256(context || "com" || m)`.
    #[must_use]
    pub fn h5(context: &str, m: &[u8]) -> [u8; 32] {
        sha256(&[context.as_bytes(), b"com", m])
    }

    /// DKG proof-of-knowledge challenge, `hash_to_field` under `context || "dkg"`.
    #[must_use]
    pub fn hdkg(context: &str, m: &[u8]) -> Scalar {
        hash_to_scalar(&[context.as_bytes(), b"dkg"], m)
    }

    /// Identifier derivation, `hash_to_field` under `context || "id"`.
    #[must_use]
    pub fn hid(context: &str, m: &[u8]) -> Scalar {
        hash_to_scalar(&[context.as_bytes(), b"id"], m)
    }
}

/// Context string of the standard RFC 9591 `FROST(secp256k1, SHA-256)` suite.
pub const RFC9591_CONTEXT_STRING: &str = "FROST-secp256k1-SHA256-v1";

impl Ciphersuite for Secp256K1Keccak256 {
    const ID: &'static str = CONTEXT_STRING;

    type Group = Secp256K1Group;

    type HashOutput = [u8; 32];

    type SignatureSerialization = [u8; 65];

    /// `H1` (binding factor), RFC 9591 construction under [`CONTEXT_STRING`].
    fn H1(m: &[u8]) -> Scalar {
        hashes::h1(CONTEXT_STRING, m)
    }

    /// `H2` (challenge): `keccak256(m) mod n`, matching the Solidity verifier.
    fn H2(m: &[u8]) -> Scalar {
        reduce_mod_n(&keccak256(&[m]))
    }

    /// `H3` (nonce derivation), RFC 9591 construction under [`CONTEXT_STRING`].
    fn H3(m: &[u8]) -> Scalar {
        hashes::h3(CONTEXT_STRING, m)
    }

    /// `H4` (message hash inside the binding factor input).
    fn H4(m: &[u8]) -> [u8; 32] {
        hashes::h4(CONTEXT_STRING, m)
    }

    /// `H5` (commitment list hash inside the binding factor input).
    fn H5(m: &[u8]) -> [u8; 32] {
        hashes::h5(CONTEXT_STRING, m)
    }

    /// Hash used by the DKG proof of knowledge.
    fn HDKG(m: &[u8]) -> Option<Scalar> {
        Some(hashes::hdkg(CONTEXT_STRING, m))
    }

    /// Hash used to derive identifiers from strings.
    fn HID(m: &[u8]) -> Option<Scalar> {
        Some(hashes::hid(CONTEXT_STRING, m))
    }

    /// The EVM-verifiable challenge
    /// `keccak256(address(R) || pkParity || pkX || msg) mod n`.
    fn challenge(
        R: &k256::ProjectivePoint,
        verifying_key: &frost_core::VerifyingKey<Self>,
        message: &[u8],
    ) -> Result<Challenge<Self>, Error> {
        let r_address = evm::eth_address(R).map_err(|_| GroupError::InvalidIdentityElement)?;
        let key = evm::EvmGroupKey::from_verifying_key_unchecked(verifying_key)?;
        Ok(Challenge::from_scalar(evm::challenge_scalar(
            &r_address, &key, message,
        )))
    }

    /// Rejects a DKG output whose group key cannot be verified on-chain
    /// (`P.x >= n`, probability about 2^-128). Participants then re-run the DKG.
    fn post_dkg(
        key_package: frost_core::keys::KeyPackage<Self>,
        public_key_package: frost_core::keys::PublicKeyPackage<Self>,
    ) -> Result<
        (
            frost_core::keys::KeyPackage<Self>,
            frost_core::keys::PublicKeyPackage<Self>,
        ),
        Error,
    > {
        evm::EvmGroupKey::from_verifying_key(public_key_package.verifying_key())
            .map_err(|_| Error::MalformedVerifyingKey)?;
        Ok((key_package, public_key_package))
    }

    /// Same guard as [`Self::post_dkg`] for trusted-dealer key generation.
    #[allow(clippy::type_complexity)]
    fn post_generate(
        secret_shares: BTreeMap<frost_core::Identifier<Self>, frost_core::keys::SecretShare<Self>>,
        public_key_package: frost_core::keys::PublicKeyPackage<Self>,
    ) -> Result<
        (
            BTreeMap<frost_core::Identifier<Self>, frost_core::keys::SecretShare<Self>>,
            frost_core::keys::PublicKeyPackage<Self>,
        ),
        Error,
    > {
        evm::EvmGroupKey::from_verifying_key(public_key_package.verifying_key())
            .map_err(|_| Error::MalformedVerifyingKey)?;
        Ok((secret_shares, public_key_package))
    }
}

type S = Secp256K1Keccak256;

/// A participant identifier (a non-zero scalar).
pub type Identifier = frost_core::Identifier<S>;
/// A Schnorr signature `(R, z)`.
pub type Signature = frost_core::Signature<S>;
/// A secret key for plain (single-party) Schnorr signing under this suite.
pub type SigningKey = frost_core::SigningKey<S>;
/// The group public key.
pub type VerifyingKey = frost_core::VerifyingKey<S>;
/// The package the coordinator sends to every signer in round two.
pub type SigningPackage = frost_core::SigningPackage<S>;
/// Cheater-detection strategy used by [`aggregate_custom`].
pub type CheaterDetection = frost_core::CheaterDetection;
/// Scalar of the secp256k1 group.
pub type SecpScalar = <<<S as Ciphersuite>::Group as Group>::Field as Field>::Scalar;

/// Key material types and key generation.
pub mod keys {
    use super::S;

    /// Secret share distributed by a trusted dealer.
    pub type SecretShare = frost_core::keys::SecretShare<S>;
    /// A participant's secret signing share.
    pub type SigningShare = frost_core::keys::SigningShare<S>;
    /// A participant's public verifying share.
    pub type VerifyingShare = frost_core::keys::VerifyingShare<S>;
    /// A participant's long-lived key material.
    pub type KeyPackage = frost_core::keys::KeyPackage<S>;
    /// Public data about the whole group.
    pub type PublicKeyPackage = frost_core::keys::PublicKeyPackage<S>;
    /// Feldman commitment to a secret polynomial.
    pub type VerifiableSecretSharingCommitment =
        frost_core::keys::VerifiableSecretSharingCommitment<S>;
    /// Commitment to a single polynomial coefficient.
    pub type CoefficientCommitment = frost_core::keys::CoefficientCommitment<S>;
    /// Identifier list used by trusted-dealer key generation.
    pub type IdentifierList<'a> = frost_core::keys::IdentifierList<'a, S>;

    /// Pedersen DKG with proofs of knowledge.
    pub mod dkg {
        use super::S;
        pub use frost_core::keys::dkg::{part1, part2, part3};

        /// Round one types.
        pub mod round1 {
            use super::S;
            /// Broadcast package (commitment + proof of knowledge).
            pub type Package = frost_core::keys::dkg::round1::Package<S>;
            /// Secret state kept between round one and round two.
            pub type SecretPackage = frost_core::keys::dkg::round1::SecretPackage<S>;
        }
        /// Round two types.
        pub mod round2 {
            use super::S;
            /// Secret share sent to exactly one other participant.
            pub type Package = frost_core::keys::dkg::round2::Package<S>;
            /// Secret state kept between round two and finalisation.
            pub type SecretPackage = frost_core::keys::dkg::round2::SecretPackage<S>;
        }
    }

    /// Proactive share refresh (group key unchanged).
    pub mod refresh {
        pub use frost_core::keys::refresh::{
            compute_refreshing_shares, refresh_dkg_part1, refresh_dkg_part2, refresh_dkg_shares,
            refresh_share,
        };
    }

    /// Repairable threshold scheme (recover a lost share with `t` helpers).
    pub mod repairable {
        use super::S;
        pub use frost_core::keys::repairable::{
            repair_share_part1, repair_share_part2, repair_share_part3,
        };
        /// Value sent by a helper to another helper.
        pub type Delta = frost_core::keys::repairable::Delta<S>;
        /// Value sent by a helper to the participant being repaired.
        pub type Sigma = frost_core::keys::repairable::Sigma<S>;
    }
}

/// Signing round one: nonce generation and commitments.
pub mod round1 {
    use super::S;
    /// Secret nonces. They must be used for exactly one signature.
    pub type SigningNonces = frost_core::round1::SigningNonces<S>;
    /// Public commitments to the nonces.
    pub type SigningCommitments = frost_core::round1::SigningCommitments<S>;
    /// Commitment to a single nonce.
    pub type NonceCommitment = frost_core::round1::NonceCommitment<S>;
    pub use frost_core::round1::commit;
}

/// Signing round two: signature shares.
pub mod round2 {
    use super::S;
    /// A signer's share of the final signature.
    pub type SignatureShare = frost_core::round2::SignatureShare<S>;
    pub use frost_core::round2::sign;
}

/// Aggregates signature shares, identifying the first cheater on failure.
pub fn aggregate(
    signing_package: &SigningPackage,
    signature_shares: &BTreeMap<Identifier, round2::SignatureShare>,
    pubkeys: &keys::PublicKeyPackage,
) -> Result<Signature, Error> {
    frost_core::aggregate(signing_package, signature_shares, pubkeys)
}

/// Aggregates signature shares with an explicit cheater-detection strategy.
/// The custody coordinator uses [`CheaterDetection::AllCheaters`].
pub fn aggregate_custom(
    signing_package: &SigningPackage,
    signature_shares: &BTreeMap<Identifier, round2::SignatureShare>,
    pubkeys: &keys::PublicKeyPackage,
    cheater_detection: CheaterDetection,
) -> Result<Signature, Error> {
    frost_core::aggregate_custom(
        signing_package,
        signature_shares,
        pubkeys,
        cheater_detection,
    )
}

/// Trusted-dealer key generation (used by tests and fixtures only; production
/// groups are created with the DKG).
pub fn generate_with_dealer<R: RngCore + CryptoRng>(
    max_signers: u16,
    min_signers: u16,
    rng: &mut R,
) -> Result<
    (
        BTreeMap<Identifier, keys::SecretShare>,
        keys::PublicKeyPackage,
    ),
    Error,
> {
    frost_core::keys::generate_with_dealer(
        max_signers,
        min_signers,
        frost_core::keys::IdentifierList::Default,
        rng,
    )
}
