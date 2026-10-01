// SPDX-License-Identifier: MIT
//! Runs the Zcash Foundation's generic frost-core conformance suite
//! (`frost-core/test-impl`) against the custom `FROST(secp256k1, KECCAK-256)`
//! ciphersuite: dealer and DKG key generation, signing with every error path,
//! share refresh (dealer and DKG), the repairable threshold scheme, batch
//! verification and serialisation round trips.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use frost_core::tests::{
    batch, ciphersuite_generic as generic, coefficient_commitment, refresh, repairable,
    vss_commitment,
};
use frost_keccak::{Error, Identifier, Secp256K1Keccak256 as S};
use rand_chacha::ChaCha20Rng;
use rand_core::SeedableRng;

fn rng(seed: u64) -> ChaCha20Rng {
    ChaCha20Rng::seed_from_u64(seed)
}

#[test]
fn zero_key_is_rejected() {
    generic::check_zero_key_fails::<S>();
}

#[test]
fn share_generation() {
    generic::check_share_generation::<S, _>(rng(1));
}

#[test]
fn share_generation_rejects_invalid_parameters() {
    generic::check_share_generation_fails_with_invalid_signers::<S, _>(
        1,
        3,
        Error::InvalidMinSigners,
        rng(2),
    );
    generic::check_share_generation_fails_with_invalid_signers::<S, _>(
        3,
        1,
        Error::InvalidMaxSigners,
        rng(3),
    );
}

#[test]
fn sign_with_dealer() {
    generic::check_sign_with_dealer::<S, _>(rng(4));
}

#[test]
fn sign_with_dealer_and_custom_identifiers() {
    generic::check_sign_with_dealer_and_identifiers::<S, _>(rng(5));
}

#[test]
fn sign_with_dkg() {
    generic::check_sign_with_dkg::<S, _>(rng(6));
}

#[test]
fn dkg_rejects_invalid_parameters() {
    generic::check_dkg_part1_fails_with_invalid_signers::<S, _>(
        1,
        3,
        Error::InvalidMinSigners,
        rng(7),
    );
    generic::check_dkg_part1_fails_with_invalid_signers::<S, _>(
        3,
        1,
        Error::InvalidMaxSigners,
        rng(8),
    );
}

#[test]
fn sign_with_missing_identifier_fails() {
    generic::check_sign_with_missing_identifier::<S, _>(rng(9));
}

#[test]
fn sign_with_incorrect_commitments_fails() {
    generic::check_sign_with_incorrect_commitments::<S, _>(rng(10));
}

#[test]
fn error_culprits_are_reported() {
    generic::check_error_culprit::<S>();
}

#[test]
fn identifiers_can_be_derived() {
    generic::check_identifier_derivation::<S>();
    let a = Identifier::derive(b"alice").unwrap();
    let b = Identifier::derive(b"bob").unwrap();
    assert_ne!(a, b);
}

#[test]
fn refresh_with_dealer() {
    refresh::check_refresh_shares_with_dealer::<S, _>(rng(11));
    refresh::check_refresh_shares_with_dealer_serialisation::<S, _>(rng(12));
    refresh::check_refresh_shares_with_dealer_fails_with_invalid_public_key_package::<S, _>(rng(
        13,
    ));
}

#[test]
fn refresh_with_dkg() {
    refresh::check_refresh_shares_with_dkg::<S, _>(rng(14));
    refresh::check_refresh_shares_with_dkg_smaller_threshold::<S, _>(rng(15));
}

#[test]
fn repairable_threshold_scheme() {
    repairable::check_rts::<S, _>(rng(16));
    repairable::check_repair_share_part1::<S, _>(rng(17));
    repairable::check_repair_share_part1_fails_with_invalid_min_signers::<S, _>(rng(18));
}

#[test]
fn batch_verification() {
    batch::batch_verify::<S, _>(rng(19));
    batch::bad_batch_verify::<S, _>(rng(20));
    batch::empty_batch_verify::<S, _>(rng(21));
}

#[test]
fn commitment_serialisation() {
    coefficient_commitment::check_serialization_of_coefficient_commitment::<S, _>(rng(22));
    coefficient_commitment::check_create_coefficient_commitment::<S, _>(rng(23));
    coefficient_commitment::check_get_value_of_coefficient_commitment::<S, _>(rng(24));
    vss_commitment::check_serialize_vss_commitment::<S, _>(rng(25));
    vss_commitment::check_serialize_whole_vss_commitment::<S, _>(rng(26));
    vss_commitment::check_deserialize_vss_commitment::<S, _>(rng(27));
    vss_commitment::check_deserialize_whole_vss_commitment::<S, _>(rng(28));
    vss_commitment::check_compute_public_key_package::<S, _>(rng(29));
}
