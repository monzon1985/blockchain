// SPDX-License-Identifier: MIT
//! RFC 9591 Appendix E.5 test vectors for `FROST(secp256k1, SHA-256)`.
//!
//! `frost-keccak` reuses the secp256k1 group, the scalar field, nonce
//! derivation, binding factors, Lagrange interpolation and aggregation from
//! frost-core. These vectors validate that shared base step by step against the
//! standard suite before the custom challenge is layered on top.
//!
//! The JSON file is the RFC's own vector set (as distributed with the Zcash
//! Foundation `frost-secp256k1` crate).
//!
//! `frost-keccak` re-implements `H1/H3/H4/H5/HDKG/HID` itself (under its own
//! context string). Those helpers are parameterised by the context string;
//! here they reproduce the vectors' nonces and binding factors under the RFC
//! context, and a property test shows they equal `frost-secp256k1`'s hashes
//! on random inputs. So the custom suite differs from RFC 9591 only in the
//! context string and the challenge.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::collections::BTreeMap;

use frost_core::{Ciphersuite, Field, Group};
use frost_keccak::{CONTEXT_STRING, RFC9591_CONTEXT_STRING, Secp256K1Keccak256, hashes};
use frost_secp256k1::{
    Identifier, Secp256K1Group, Secp256K1ScalarField, Secp256K1Sha256, Signature, SigningKey,
    SigningPackage,
    keys::{KeyPackage, PublicKeyPackage, SigningShare},
    round1::{SigningCommitments, SigningNonces},
};
use proptest::prelude::*;
use serde_json::Value;

type Nonce = frost_core::round1::Nonce<Secp256K1Sha256>;
type SecpScalar = k256::Scalar;

fn vectors() -> Value {
    serde_json::from_str(include_str!("vectors/rfc9591-secp256k1-sha256.json")).unwrap()
}

fn bytes(v: &Value) -> Vec<u8> {
    hex::decode(v.as_str().unwrap()).unwrap()
}

fn scalar(v: &Value) -> SecpScalar {
    let raw: [u8; 32] = bytes(v).try_into().unwrap();
    Secp256K1ScalarField::deserialize(&raw).unwrap()
}

fn id(v: &Value) -> Identifier {
    Identifier::try_from(u16::try_from(v.as_u64().unwrap()).unwrap()).unwrap()
}

#[test]
fn group_key_matches_secret() {
    let v = vectors();
    let secret = SigningKey::deserialize(&bytes(&v["inputs"]["group_secret_key"])).unwrap();
    let expected = bytes(&v["inputs"]["verifying_key_key"]);
    let verifying_key = frost_secp256k1::VerifyingKey::from(&secret);
    assert_eq!(verifying_key.serialize().unwrap(), expected);
}

#[test]
fn shamir_shares_match_polynomial() {
    let v = vectors();
    let secret = scalar(&v["inputs"]["group_secret_key"]);
    let coefficients: Vec<SecpScalar> = v["inputs"]["share_polynomial_coefficients"]
        .as_array()
        .unwrap()
        .iter()
        .map(scalar)
        .collect();
    for share in v["inputs"]["participant_shares"].as_array().unwrap() {
        let x = SecpScalar::from(share["identifier"].as_u64().unwrap());
        // Horner evaluation of f(x) = secret + a1·x + ... .
        let mut acc = SecpScalar::ZERO;
        for c in coefficients.iter().rev() {
            acc = acc * x + c;
        }
        let f_x = acc * x + secret;
        assert_eq!(f_x, scalar(&share["participant_share"]));
    }
}

#[test]
fn two_round_signing_matches_every_intermediate_value() {
    let v = vectors();
    let inputs = &v["inputs"];
    let verifying_key =
        frost_secp256k1::VerifyingKey::deserialize(&bytes(&inputs["verifying_key_key"])).unwrap();
    let message = bytes(&inputs["message"]);
    let min_signers = u16::try_from(
        inputs["share_polynomial_coefficients"]
            .as_array()
            .unwrap()
            .len()
            + 1,
    )
    .unwrap();

    // Key packages for every participant.
    let mut key_packages = BTreeMap::new();
    let mut verifying_shares = BTreeMap::new();
    for share in inputs["participant_shares"].as_array().unwrap() {
        let identifier = id(&share["identifier"]);
        let signing_share = SigningShare::deserialize(&bytes(&share["participant_share"])).unwrap();
        let verifying_share = signing_share.into();
        verifying_shares.insert(identifier, verifying_share);
        key_packages.insert(
            identifier,
            KeyPackage::new(
                identifier,
                signing_share,
                verifying_share,
                verifying_key,
                min_signers,
            ),
        );
    }
    let public_key_package =
        PublicKeyPackage::new(verifying_shares, verifying_key, Some(min_signers));

    // Round one: nonce derivation H3(random || share) and commitments.
    let mut nonces = BTreeMap::new();
    let mut commitments = BTreeMap::new();
    for out in v["round_one_outputs"]["outputs"].as_array().unwrap() {
        let identifier = id(&out["identifier"]);
        let share = key_packages[&identifier].signing_share().serialize();
        let derive = |randomness: &Value| {
            let mut preimage = bytes(randomness);
            preimage.extend_from_slice(&share);
            let upstream = <Secp256K1Sha256 as Ciphersuite>::H3(&preimage);
            assert_eq!(
                hashes::h3(RFC9591_CONTEXT_STRING, &preimage),
                upstream,
                "project H3 under the RFC context"
            );
            Nonce::from_scalar(upstream)
        };
        let hiding = derive(&out["hiding_nonce_randomness"]);
        let binding = derive(&out["binding_nonce_randomness"]);
        assert_eq!(
            hiding.serialize(),
            bytes(&out["hiding_nonce"]),
            "hiding nonce"
        );
        assert_eq!(
            binding.serialize(),
            bytes(&out["binding_nonce"]),
            "binding nonce"
        );

        let signing_nonces = SigningNonces::from_nonces(hiding, binding);
        let signing_commitments: SigningCommitments = (&signing_nonces).into();
        assert_eq!(
            signing_commitments.hiding().serialize().unwrap(),
            bytes(&out["hiding_nonce_commitment"])
        );
        assert_eq!(
            signing_commitments.binding().serialize().unwrap(),
            bytes(&out["binding_nonce_commitment"])
        );
        nonces.insert(identifier, signing_nonces);
        commitments.insert(identifier, signing_commitments);
    }

    // Binding factors.
    let signing_package = SigningPackage::new(commitments, &message);
    let preimages = signing_package
        .binding_factor_preimages(&verifying_key, &[])
        .unwrap();
    for (out, (identifier, preimage)) in v["round_one_outputs"]["outputs"]
        .as_array()
        .unwrap()
        .iter()
        .zip(preimages.iter())
    {
        assert_eq!(*identifier, id(&out["identifier"]));
        assert_eq!(
            *preimage,
            bytes(&out["binding_factor_input"]),
            "binding factor input"
        );
        let rho = <Secp256K1Sha256 as Ciphersuite>::H1(preimage);
        assert_eq!(
            hashes::h1(RFC9591_CONTEXT_STRING, preimage),
            rho,
            "project H1 under the RFC context"
        );
        assert_eq!(
            Secp256K1ScalarField::serialize(&rho).to_vec(),
            bytes(&out["binding_factor"]),
            "binding factor"
        );
    }

    // Round two: signature shares.
    let mut shares = BTreeMap::new();
    for out in v["round_two_outputs"]["outputs"].as_array().unwrap() {
        let identifier = id(&out["identifier"]);
        let share = frost_secp256k1::round2::sign(
            &signing_package,
            &nonces[&identifier],
            &key_packages[&identifier],
        )
        .unwrap();
        assert_eq!(
            share.serialize(),
            bytes(&out["sig_share"]),
            "signature share"
        );
        shares.insert(identifier, share);
    }

    // Aggregation.
    let signature =
        frost_secp256k1::aggregate(&signing_package, &shares, &public_key_package).unwrap();
    assert_eq!(
        signature.serialize().unwrap(),
        bytes(&v["final_output"]["sig"])
    );
    verifying_key.verify(&message, &signature).unwrap();

    // The published signature also deserialises and verifies on its own.
    let parsed = Signature::deserialize(&bytes(&v["final_output"]["sig"])).unwrap();
    verifying_key.verify(&message, &parsed).unwrap();
}

#[test]
fn keccak_suite_shares_the_group_but_not_the_transcript() {
    // Same generator and serialisation (group reuse)...
    assert_eq!(
        Secp256K1Group::serialize(&Secp256K1Group::generator()).unwrap(),
        <frost_keccak::Secp256K1Keccak256 as Ciphersuite>::Group::serialize(
            &<frost_keccak::Secp256K1Keccak256 as Ciphersuite>::Group::generator()
        )
        .unwrap()
    );
    // ...but a different context string, so every hash is domain separated.
    assert_ne!(
        <Secp256K1Sha256 as Ciphersuite>::ID,
        <frost_keccak::Secp256K1Keccak256 as Ciphersuite>::ID
    );
    let m = b"domain separation";
    assert_ne!(
        <Secp256K1Sha256 as Ciphersuite>::H1(m),
        <frost_keccak::Secp256K1Keccak256 as Ciphersuite>::H1(m)
    );
    assert_ne!(
        <Secp256K1Sha256 as Ciphersuite>::H3(m),
        <frost_keccak::Secp256K1Keccak256 as Ciphersuite>::H3(m)
    );
    assert_ne!(
        <Secp256K1Sha256 as Ciphersuite>::H4(m),
        <frost_keccak::Secp256K1Keccak256 as Ciphersuite>::H4(m)
    );
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 256, failure_persistence: None, ..ProptestConfig::default() })]

    /// The project's hash helpers under the RFC 9591 context string equal the
    /// standard suite's hashes, and the custom suite is exactly those helpers
    /// under its own context string. A mis-built DST, prefix or hash would
    /// break the first half; the second pins the ciphersuite to the helpers.
    #[test]
    fn project_hashes_differ_from_rfc9591_only_in_the_context_string(
        m in proptest::collection::vec(any::<u8>(), 0..512),
    ) {
        type Std = Secp256K1Sha256;
        type Kec = Secp256K1Keccak256;
        let std = RFC9591_CONTEXT_STRING;
        prop_assert_eq!(<Std as Ciphersuite>::ID, std);
        prop_assert_eq!(hashes::h1(std, &m), <Std as Ciphersuite>::H1(&m));
        prop_assert_eq!(hashes::h3(std, &m), <Std as Ciphersuite>::H3(&m));
        prop_assert_eq!(hashes::h4(std, &m), <Std as Ciphersuite>::H4(&m));
        prop_assert_eq!(hashes::h5(std, &m), <Std as Ciphersuite>::H5(&m));
        prop_assert_eq!(Some(hashes::hdkg(std, &m)), <Std as Ciphersuite>::HDKG(&m));
        prop_assert_eq!(Some(hashes::hid(std, &m)), <Std as Ciphersuite>::HID(&m));

        prop_assert_eq!(hashes::h1(CONTEXT_STRING, &m), <Kec as Ciphersuite>::H1(&m));
        prop_assert_eq!(hashes::h3(CONTEXT_STRING, &m), <Kec as Ciphersuite>::H3(&m));
        prop_assert_eq!(hashes::h4(CONTEXT_STRING, &m), <Kec as Ciphersuite>::H4(&m));
        prop_assert_eq!(hashes::h5(CONTEXT_STRING, &m), <Kec as Ciphersuite>::H5(&m));
        prop_assert_eq!(Some(hashes::hdkg(CONTEXT_STRING, &m)), <Kec as Ciphersuite>::HDKG(&m));
        prop_assert_eq!(Some(hashes::hid(CONTEXT_STRING, &m)), <Kec as Ciphersuite>::HID(&m));
    }
}
