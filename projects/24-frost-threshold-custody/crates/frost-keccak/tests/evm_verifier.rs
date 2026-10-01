// SPDX-License-Identifier: MIT
//! Differential and property tests for the EVM model of the Schnorr verifier:
//! frost-core's own verification (`z·G == R + e·P`) and the ecrecover-based
//! model of the Solidity contract must agree on every valid and tampered input.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::collections::BTreeMap;

use frost_core::Ciphersuite;
use frost_keccak::{
    Identifier, Secp256K1Keccak256, Signature, SigningKey, SigningPackage, VerifyingKey,
    evm::{self, EvmError, EvmGroupKey, EvmSignature, SECP256K1_ORDER},
    keccak256,
    keys::{KeyPackage, PublicKeyPackage},
    reduce_mod_n, round1, round2,
};
use k256::{
    AffinePoint, ProjectivePoint, Scalar,
    elliptic_curve::{PrimeField, point::DecompressPoint, sec1::ToEncodedPoint, subtle::Choice},
};
use proptest::prelude::*;
use rand_chacha::ChaCha20Rng;
use rand_core::SeedableRng;

/// Trusted-dealer key generation followed by a FROST signature from the first
/// `signers` participants. The dealer keeps these tests fast; the DKG path is
/// covered by the conformance suite and by custody-protocol.
fn frost_sign(
    seed: u64,
    threshold: u16,
    total: u16,
    signers: u16,
    message: &[u8],
) -> (Signature, PublicKeyPackage) {
    let mut rng = ChaCha20Rng::seed_from_u64(seed);
    let (shares, public) = frost_keccak::generate_with_dealer(total, threshold, &mut rng).unwrap();
    let key_packages: BTreeMap<Identifier, KeyPackage> = shares
        .into_iter()
        .map(|(id, share)| (id, KeyPackage::try_from(share).unwrap()))
        .collect();
    let chosen: Vec<_> = key_packages
        .keys()
        .take(usize::from(signers))
        .copied()
        .collect();
    let mut nonces = BTreeMap::new();
    let mut commitments = BTreeMap::new();
    for id in &chosen {
        let (n, c) = round1::commit(key_packages[id].signing_share(), &mut rng);
        nonces.insert(*id, n);
        commitments.insert(*id, c);
    }
    let package = SigningPackage::new(commitments, message);
    let shares = chosen
        .iter()
        .map(|id| {
            (
                *id,
                round2::sign(&package, &nonces[id], &key_packages[id]).unwrap(),
            )
        })
        .collect();
    let signature = frost_keccak::aggregate(&package, &shares, &public).unwrap();
    (signature, public)
}

fn onchain(signature: &Signature, public: &PublicKeyPackage) -> (EvmGroupKey, EvmSignature) {
    (
        EvmGroupKey::from_verifying_key(public.verifying_key()).unwrap(),
        EvmSignature::from_signature(signature).unwrap(),
    )
}

fn add_one(word: [u8; 32]) -> [u8; 32] {
    let s = Option::<Scalar>::from(Scalar::from_repr(word.into())).unwrap() + Scalar::ONE;
    s.to_bytes().into()
}

#[test]
fn challenge_matches_cast_keccak_known_answer() {
    // cast keccak 0x1111..11 || 01 || Gx || 00..01
    let r_address = [0x11u8; 20];
    let gx = ProjectivePoint::GENERATOR
        .to_affine()
        .to_encoded_point(true);
    let key = EvmGroupKey::from_compressed(gx.as_bytes()).unwrap();
    assert_eq!(key.y_parity, 0);
    let key = EvmGroupKey { y_parity: 1, ..key };
    let mut message = [0u8; 32];
    message[31] = 1;
    let e = evm::challenge_scalar(&r_address, &key, &message);
    let expected =
        hex::decode("e4f56ad819f25681ea2ed3c41c82c84d86ed74641e4ee9bb4bbb7c2ff47f1a30").unwrap();
    assert_eq!(e.to_bytes().to_vec(), expected);
}

#[test]
fn ecrecover_model_recovers_known_ethereum_address() {
    // Private key 1 controls 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf.
    let sk = k256::ecdsa::SigningKey::from_bytes(&Scalar::ONE.to_bytes()).unwrap();
    let hash = keccak256(&[b"ecrecover model"]);
    let (sig, recid) = sk.sign_prehash_recoverable(&hash).unwrap();
    let r: [u8; 32] = sig.r().to_bytes().into();
    let s: [u8; 32] = sig.s().to_bytes().into();
    let recovered = evm::ecrecover(&hash, 27 + recid.to_byte(), &r, &s).unwrap();
    assert_eq!(
        hex::encode(recovered),
        "7e5f4552091a69125d5dfcb7b8c2659029395bdf"
    );

    // High-s form of the same signature is accepted by the precompile (no
    // EIP-2 rule there) and recovers the same key with the flipped parity.
    let high_s: [u8; 32] = (-*sig.s()).to_bytes().into();
    let flipped = 27 + (recid.to_byte() ^ 1);
    assert_eq!(evm::ecrecover(&hash, flipped, &r, &high_s), Some(recovered));

    // Precompile input validation.
    assert_eq!(evm::ecrecover(&hash, 29, &r, &s), None);
    assert_eq!(evm::ecrecover(&hash, 26, &r, &s), None);
    assert_eq!(evm::ecrecover(&hash, 27, &[0u8; 32], &s), None);
    assert_eq!(evm::ecrecover(&hash, 27, &r, &[0u8; 32]), None);
    assert_eq!(evm::ecrecover(&hash, 27, &SECP256K1_ORDER, &s), None);
    assert_eq!(evm::ecrecover(&hash, 27, &r, &SECP256K1_ORDER), None);
}

#[test]
fn scalar_word_range_checks() {
    let mut n_minus_one = SECP256K1_ORDER;
    n_minus_one[31] -= 1;
    assert!(!evm::is_valid_scalar_word(&[0u8; 32]));
    assert!(evm::is_valid_scalar_word(&{
        let mut one = [0u8; 32];
        one[31] = 1;
        one
    }));
    assert!(evm::is_valid_scalar_word(&n_minus_one));
    assert!(!evm::is_valid_scalar_word(&SECP256K1_ORDER));
    assert!(!evm::is_valid_scalar_word(&[0xffu8; 32]));

    // reduce_mod_n is Solidity's `uint256(x) % n`.
    assert_eq!(reduce_mod_n(&SECP256K1_ORDER), Scalar::ZERO);
    let mut n_plus_one = SECP256K1_ORDER;
    n_plus_one[31] += 1;
    assert_eq!(reduce_mod_n(&n_plus_one), Scalar::ONE);
}

/// Finds a curve point whose x-coordinate lies in `[n, p)`.
fn point_with_x_above_order() -> ([u8; 32], AffinePoint) {
    let mut x = SECP256K1_ORDER;
    loop {
        if let Some(p) =
            Option::<AffinePoint>::from(AffinePoint::decompress(&x.into(), Choice::from(0)))
        {
            return (x, p);
        }
        x[31] += 1;
    }
}

#[test]
fn keys_with_x_above_order_are_rejected_everywhere() {
    let (x, point) = point_with_x_above_order();
    let compressed = point.to_encoded_point(true);
    let verifying_key = VerifyingKey::deserialize(compressed.as_bytes()).unwrap();

    let err = EvmGroupKey::from_verifying_key(&verifying_key).unwrap_err();
    assert!(matches!(err, EvmError::KeyNotEcrecoverCompatible(w) if w.0 == x));

    // The ciphersuite refuses to finish a DKG or dealer run with such a key.
    let mut rng = ChaCha20Rng::seed_from_u64(99);
    let (shares, public) = frost_keccak::generate_with_dealer(3, 2, &mut rng).unwrap();
    let bad_public =
        PublicKeyPackage::new(public.verifying_shares().clone(), verifying_key, Some(2));
    let any_key_package = KeyPackage::try_from(shares.values().next().unwrap().clone()).unwrap();
    assert_eq!(
        Secp256K1Keccak256::post_dkg(any_key_package, bad_public.clone()).unwrap_err(),
        frost_keccak::Error::MalformedVerifyingKey
    );
    assert_eq!(
        Secp256K1Keccak256::post_generate(shares, bad_public).unwrap_err(),
        frost_keccak::Error::MalformedVerifyingKey
    );
}

#[test]
fn malformed_inputs_are_rejected() {
    assert_eq!(
        EvmGroupKey::from_compressed(&[0x04; 33]),
        Err(EvmError::Malformed)
    );
    assert_eq!(
        EvmGroupKey::from_compressed(&[0x02; 10]),
        Err(EvmError::Malformed)
    );
    assert_eq!(EvmGroupKey::from_compressed(&[]), Err(EvmError::Malformed));
    let bad_parity = EvmGroupKey {
        x: [1u8; 32],
        y_parity: 2,
    };
    assert_eq!(bad_parity.to_point(), Err(EvmError::InvalidParity(2)));
    assert_eq!(bad_parity.ecrecover_v(), 29);
    assert_eq!(
        evm::eth_address(&ProjectivePoint::IDENTITY),
        Err(EvmError::IdentityPoint)
    );
}

#[test]
fn single_party_signing_uses_the_same_challenge() {
    // SigningKey::sign goes through Ciphersuite::challenge too, so a plain
    // Schnorr signature under this suite is accepted by the EVM model.
    let mut rng = ChaCha20Rng::seed_from_u64(7);
    let sk = SigningKey::new(&mut rng);
    let vk = VerifyingKey::from(&sk);
    let msg = keccak256(&[b"single"]);
    let sig = sk.sign(&mut rng, &msg);
    vk.verify(&msg, &sig).unwrap();
    if let Ok(key) = EvmGroupKey::from_verifying_key(&vk) {
        assert!(evm::verify(
            &key,
            &msg,
            &EvmSignature::from_signature(&sig).unwrap()
        ));
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 64, failure_persistence: None, ..ProptestConfig::default() })]

    /// Any t-of-n signing set produces a signature that frost-core and the
    /// EVM model both accept, and ecrecover returns exactly address(R).
    #[test]
    fn valid_threshold_signatures_verify_on_both_paths(
        seed in any::<u64>(),
        (threshold, total, signers) in (2u16..=5).prop_flat_map(|t| (Just(t), t..=7))
            .prop_flat_map(|(t, n)| (Just(t), Just(n), t..=n)),
        message in any::<[u8; 32]>(),
    ) {
        let (signature, public) = frost_sign(seed, threshold, total, signers, &message);
        public.verifying_key().verify(&message, &signature).unwrap();
        let (key, sig) = onchain(&signature, &public);
        prop_assert!(evm::verify(&key, &message, &sig));

        let call = evm::ecrecover_inputs(&key, &message, &sig).unwrap();
        prop_assert_eq!(evm::ecrecover(&call.hash, call.v, &call.r, &call.s), Some(sig.r_address));

        // The ciphersuite challenge is the EVM challenge.
        let e = Secp256K1Keccak256::challenge(signature.R(), public.verifying_key(), &message).unwrap();
        let direct = evm::challenge_scalar(&sig.r_address, &key, &message);
        prop_assert_eq!(e.to_scalar(), direct);
    }

    /// Every single-field tampering is rejected by both verifiers.
    #[test]
    fn tampered_signatures_are_rejected_by_both_paths(
        seed in any::<u64>(),
        message in any::<[u8; 32]>(),
        other_message in any::<[u8; 32]>(),
        bit in 0usize..160,
    ) {
        prop_assume!(message != other_message);
        let (signature, public) = frost_sign(seed, 2, 3, 2, &message);
        let (key, sig) = onchain(&signature, &public);

        // Wrong message.
        prop_assert!(public.verifying_key().verify(&other_message, &signature).is_err());
        prop_assert!(!evm::verify(&key, &other_message, &sig));

        // Tampered z.
        let tampered_z = EvmSignature { z: add_one(sig.z), ..sig };
        prop_assert!(!evm::verify(&key, &message, &tampered_z));
        let frost_tampered = Signature::new(*signature.R(), *signature.z() + Scalar::ONE);
        prop_assert!(public.verifying_key().verify(&message, &frost_tampered).is_err());

        // Tampered address(R): flip one bit.
        let mut r_address = sig.r_address;
        r_address[bit / 8] ^= 1 << (bit % 8);
        let tampered_r = EvmSignature { r_address, ..sig };
        prop_assert!(!evm::verify(&key, &message, &tampered_r));

        // Tampered R in the FROST encoding (R + G).
        let frost_tampered_r = Signature::new(*signature.R() + ProjectivePoint::GENERATOR, *signature.z());
        prop_assert!(public.verifying_key().verify(&message, &frost_tampered_r).is_err());
        prop_assert!(!evm::verify(&key, &message, &EvmSignature::from_signature(&frost_tampered_r).unwrap()));

        // Wrong key parity (i.e. the negated group key).
        let flipped = EvmGroupKey { y_parity: key.y_parity ^ 1, ..key };
        prop_assert!(!evm::verify(&flipped, &message, &sig));

        // Out-of-range or zero fields short-circuit before ecrecover.
        let zero_z = EvmSignature { z: [0u8; 32], ..sig };
        let order_z = EvmSignature { z: SECP256K1_ORDER, ..sig };
        let zero_r = EvmSignature { r_address: [0u8; 20], ..sig };
        let zero_key = EvmGroupKey { x: [0u8; 32], ..key };
        prop_assert!(!evm::verify(&key, &message, &zero_z));
        prop_assert!(!evm::verify(&key, &message, &order_z));
        prop_assert!(!evm::verify(&key, &message, &zero_r));
        prop_assert!(!evm::verify(&zero_key, &message, &sig));
    }

    /// Every 256-bit word at or above the group order is rejected as `z`
    /// (the Solidity verifier checks `z < n` before calling ecrecover), so a
    /// signature has exactly one accepted encoding of its response.
    #[test]
    fn response_words_at_or_above_order_are_rejected(
        seed in any::<u64>(),
        message in any::<[u8; 32]>(),
        excess in any::<[u8; 16]>(),
    ) {
        let (signature, public) = frost_sign(seed, 2, 2, 2, &message);
        let (key, sig) = onchain(&signature, &public);
        // n + k for k < 2^128 never overflows 256 bits (2^256 - n > 2^128).
        let n = k256::U256::from_be_slice(&SECP256K1_ORDER);
        let mut k_bytes = [0u8; 32];
        k_bytes[16..].copy_from_slice(&excess);
        let word = n.wrapping_add(&k256::U256::from_be_slice(&k_bytes));
        let mut z = [0u8; 32];
        z.copy_from_slice(&k256::elliptic_curve::bigint::Encoding::to_be_bytes(&word));
        let out_of_range = EvmSignature { z, ..sig };
        prop_assert!(!evm::verify(&key, &message, &out_of_range));
    }
}

#[test]
fn packed_encoding_and_display_helpers() {
    let (signature, public) = frost_sign(5, 2, 3, 2, &[1u8; 32]);
    let (key, sig) = onchain(&signature, &public);
    let packed = sig.to_packed();
    assert_eq!(&packed[..20], &sig.r_address);
    assert_eq!(&packed[20..], &sig.z);
    assert_eq!(key.to_point().unwrap(), public.verifying_key().to_element());
    let word = evm::HexWord([0xab; 32]);
    assert_eq!(word.to_string(), "ab".repeat(32));
    assert_eq!(format!("{word:?}"), format!("0x{}", "ab".repeat(32)));
    let err = EvmError::KeyNotEcrecoverCompatible(word);
    assert!(err.to_string().contains(&"ab".repeat(32)));
}
