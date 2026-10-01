// SPDX-License-Identifier: MIT
//! Property tests over random group parameters, signer sets and seeds.
//! Seeds are reproducible in CI through `PROPTEST_RNG_SEED`.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::collections::BTreeSet;

use common::*;
use custody_protocol::{
    ParticipantId, Party, SessionId,
    envelope::{Envelope, Recipient, SignedEnvelope},
    identity::GeneratedRoster,
    keygen::KeygenOutcome,
    messages::{Message, Refused},
    repair::RepairOutcome,
    sealed::{self, SealContext},
    signing::SigningOutcome,
};
use frost_keccak::evm;
use proptest::prelude::*;
use rand_chacha::ChaCha20Rng;
use rand_core::SeedableRng;

fn config(cases: u32) -> ProptestConfig {
    ProptestConfig {
        cases,
        failure_persistence: None,
        ..ProptestConfig::default()
    }
}

/// (t, n, subset mask) with 2 <= t <= n <= 5 and a subset of size >= t.
fn group_and_subset() -> impl Strategy<Value = (u16, u16, Vec<ParticipantId>)> {
    (2u16..=5)
        .prop_flat_map(|n| (2u16..=n, Just(n)))
        .prop_flat_map(|(t, n)| (Just(t), Just(n), 1u32..(1 << n)))
        .prop_filter_map("subset below threshold", |(t, n, mask)| {
            let subset: Vec<_> = (1..=n)
                .filter(|i| mask & (1 << (i - 1)) != 0)
                .map(p)
                .collect();
            (subset.len() >= usize::from(t)).then_some((t, n, subset))
        })
}

proptest! {
    #![proptest_config(config(32))]

    /// Any subset of at least t participants produces a signature that both
    /// frost-core and the EVM model accept.
    #[test]
    fn any_t_subset_signs((t, n, subset) in group_and_subset(), seed in any::<u64>(), nonce in any::<u64>()) {
        let mut net = network(n, seed);
        let group_key = dkg(&mut net, t, n);
        let action = withdrawal(nonce, 1 + nonce % 1_000);
        let outcome = net.sign(group_key, action.clone(), DOMAIN, &subset).unwrap();
        let SigningOutcome::Signed { signature, evm: onchain, signers } = outcome else {
            return Err(TestCaseError::fail("signing aborted"));
        };
        prop_assert_eq!(signers, subset.iter().copied().collect::<BTreeSet<_>>());
        let public = net.group(&group_key).unwrap();
        let digest = action.signing_hash(&DOMAIN);
        prop_assert!(public.verifying_key().verify(&digest, &signature).is_ok());
        let key = evm::EvmGroupKey::from_verifying_key(public.verifying_key()).unwrap();
        prop_assert!(evm::verify(&key, &digest, &onchain));
    }

    /// Interpolation sanity check: t-1 shares, forced through frost-core as a
    /// threshold-(t-1) set, reconstruct some other key, while any t shares
    /// reconstruct the group key. (Secrecy itself is the Shamir argument; the
    /// signing property below is the one that matters for custody.)
    #[test]
    fn fewer_than_t_shares_cannot_recover_the_key(
        (t, n) in (3u16..=5).prop_flat_map(|n| (2u16..=n, Just(n))),
        seed in any::<u64>(),
        rotate in 0usize..5,
    ) {
        let mut net = network(n, seed);
        let group_key = dkg(&mut net, t, n);
        let mut holders = ids(1..=n);
        holders.rotate_left(rotate % usize::from(n));
        let packages: Vec<_> = holders
            .iter()
            .map(|id| net.node(*id).unwrap().shares()[&group_key].key_package.clone())
            .collect();
        let expected = *net.group(&group_key).unwrap().verifying_key();
        let t_usize = usize::from(t);
        // A coalition of t-1 holders interpolates its shares as if the
        // threshold were t-1 (frost-core refuses outright with the real t).
        prop_assert!(frost_core::keys::reconstruct(&packages[..t_usize - 1]).is_err());
        let coalition: Vec<_> = packages[..t_usize - 1]
            .iter()
            .map(|k| frost_keccak::keys::KeyPackage::new(
                *k.identifier(), *k.signing_share(), *k.verifying_share(), *k.verifying_key(), t - 1,
            ))
            .collect();
        let below = frost_core::keys::reconstruct(&coalition).unwrap();
        prop_assert_ne!(frost_keccak::VerifyingKey::from(&below), expected);
        let at = frost_core::keys::reconstruct(&packages[..t_usize]).unwrap();
        prop_assert_eq!(frost_keccak::VerifyingKey::from(&at), expected);
    }

    /// Fewer than t signers cannot produce a signature, even when every
    /// parameter check is bypassed: t-1 real shares, re-labelled as a
    /// threshold-(t-1) set, produce shares that frost-core's aggregation
    /// rejects, and the hand-assembled `(R, z)` fails both frost-core and the
    /// EVM verifier model.
    #[test]
    fn fewer_than_t_signers_cannot_sign(
        (t, n) in (3u16..=5).prop_flat_map(|n| (2u16..=n, Just(n))),
        seed in any::<u64>(),
        rotate in 0usize..5,
    ) {
        let mut net = network(n, seed);
        let group_key = dkg(&mut net, t, n);
        let public = net.group(&group_key).unwrap().clone();
        let mut holders = ids(1..=n);
        holders.rotate_left(rotate % usize::from(n));
        holders.truncate(usize::from(t - 1));
        let below = t - 1;
        let coalition: Vec<frost_keccak::keys::KeyPackage> = holders
            .iter()
            .map(|id| {
                let k = &net.node(*id).unwrap().shares()[&group_key].key_package;
                frost_keccak::keys::KeyPackage::new(
                    *k.identifier(), *k.signing_share(), *k.verifying_share(), *k.verifying_key(), below,
                )
            })
            .collect();
        let digest = withdrawal(7, 7).signing_hash(&DOMAIN);
        let mut rng = ChaCha20Rng::seed_from_u64(seed ^ 0x5eed);
        let mut nonces = std::collections::BTreeMap::new();
        let mut commitments = std::collections::BTreeMap::new();
        for k in &coalition {
            let (n_i, c_i) = frost_keccak::round1::commit(k.signing_share(), &mut rng);
            nonces.insert(*k.identifier(), n_i);
            commitments.insert(*k.identifier(), c_i);
        }
        let package = frost_keccak::SigningPackage::new(commitments, &digest);
        let mut shares = std::collections::BTreeMap::new();
        for k in &coalition {
            shares.insert(
                *k.identifier(),
                frost_keccak::round2::sign(&package, &nonces[k.identifier()], k).unwrap(),
            );
        }
        // The real group data (threshold t) refuses the set outright...
        prop_assert!(frost_keccak::aggregate(&package, &shares, &public).is_err());
        // ...and so does the same data re-labelled with threshold t-1.
        let relabelled = frost_keccak::keys::PublicKeyPackage::new(
            public.verifying_shares().clone(), *public.verifying_key(), Some(below),
        );
        prop_assert!(frost_keccak::aggregate(&package, &shares, &relabelled).is_err());
        // Assemble (R, z) by hand: R from the commitments, z = sum of shares.
        let binding = frost_core::compute_binding_factor_list(&package, public.verifying_key(), &[]).unwrap();
        let r = frost_core::compute_group_commitment(&package, &binding).unwrap().to_element();
        let z = shares.values().fold(k256::Scalar::ZERO, |acc, s| {
            let bytes: [u8; 32] = s.serialize().try_into().unwrap();
            acc + frost_keccak::reduce_mod_n(&bytes)
        });
        let forged = frost_keccak::Signature::new(r, z);
        prop_assert!(public.verifying_key().verify(&digest, &forged).is_err());
        let onchain = evm::EvmSignature::from_signature(&forged).unwrap();
        let key = evm::EvmGroupKey::from_verifying_key(public.verifying_key()).unwrap();
        prop_assert!(!evm::verify(&key, &digest, &onchain));
    }

    /// Refresh keeps the group key, re-randomises every share, and any t
    /// refreshed shares still sign.
    #[test]
    fn refresh_preserves_the_group_key((t, n, subset) in group_and_subset(), seed in any::<u64>()) {
        let mut net = network(n, seed);
        let group_key = dkg(&mut net, t, n);
        let before: Vec<_> = ids(1..=n)
            .iter()
            .map(|id| *net.node(*id).unwrap().shares()[&group_key].key_package.signing_share())
            .collect();
        let KeygenOutcome::Committed { public_key_package } = net.refresh(group_key, &ids(1..=n)).unwrap() else {
            return Err(TestCaseError::fail("refresh aborted"));
        };
        prop_assert_eq!(custody_protocol::keygen::group_key_bytes(&public_key_package).unwrap(), group_key);
        for (id, old) in ids(1..=n).iter().zip(before) {
            prop_assert_ne!(*net.node(*id).unwrap().shares()[&group_key].key_package.signing_share(), old);
        }
        let outcome = net.sign(group_key, withdrawal(1, 1), DOMAIN, &subset).unwrap();
        prop_assert!(
            matches!(outcome, SigningOutcome::Signed { .. }),
            "refreshed shares must sign"
        );
    }

    /// Repair restores exactly the lost share from any t helpers.
    #[test]
    fn repair_restores_the_lost_share(
        (t, n) in (3u16..=5).prop_flat_map(|n| (2u16..n, Just(n))),
        seed in any::<u64>(),
        lost_index in 1u16..=5,
        rotate in 0usize..5,
    ) {
        let lost = p(1 + (lost_index - 1) % n);
        let mut net = network(n, seed);
        let group_key = dkg(&mut net, t, n);
        let original = net.node(lost).unwrap().shares()[&group_key].clone();
        net.node_mut(lost).unwrap().forget_share(&group_key).unwrap();
        let mut helpers: Vec<_> = ids(1..=n).into_iter().filter(|h| *h != lost).collect();
        let len = helpers.len();
        helpers.rotate_left(rotate % len);
        helpers.truncate(usize::from(t));
        let outcome = net.repair(group_key, lost, &helpers).unwrap();
        prop_assert_eq!(outcome, RepairOutcome::Repaired { participant: lost });
        prop_assert_eq!(&net.node(lost).unwrap().shares()[&group_key], &original);
    }
}

proptest! {
    #![proptest_config(config(256))]

    /// Sealed boxes open only with the right key and the exact context, and
    /// any bit flip in the box is detected.
    #[test]
    fn sealed_boxes_are_bound_to_key_context_and_content(
        seed in any::<u64>(),
        plaintext in proptest::collection::vec(any::<u8>(), 0..256),
        flip in any::<prop::sample::Index>(),
        which in 0u8..6,
    ) {
        let mut rng = ChaCha20Rng::seed_from_u64(seed);
        let roster = GeneratedRoster::generate(3, &mut rng).unwrap();
        let session = SessionId::random(&mut rng);
        let ctx = SealContext { session, from: Party::Participant(p(1)), to: p(2), purpose: "test" };
        let sealed = sealed::seal(&mut rng, &roster.roster.encryption_key(p(2)).unwrap(), &ctx, &plaintext).unwrap();
        let recipient_keys = &roster.participants[&p(2)];
        let recipient = recipient_keys.encryption_secret();
        let opened = sealed::open(recipient, &ctx, &sealed).unwrap();
        prop_assert_eq!(opened.as_slice(), plaintext.as_slice());

        let wrong_keys = &roster.participants[&p(3)];
        let wrong_key = wrong_keys.encryption_secret();
        prop_assert!(sealed::open(wrong_key, &ctx, &sealed).is_err());
        let mut tampered = sealed.clone();
        let mut wrong_ctx = ctx;
        match which {
            0 => { let i = flip.index(tampered.ciphertext.len()); tampered.ciphertext[i] ^= 1; }
            1 => { let i = flip.index(32); tampered.ephemeral_key[i] ^= 1; }
            2 => wrong_ctx.session = SessionId([0xaa; 16]),
            3 => wrong_ctx.from = Party::Participant(p(3)),
            4 => wrong_ctx.to = p(3),
            _ => wrong_ctx.purpose = "other",
        }
        prop_assert!(sealed::open(recipient, &wrong_ctx, &tampered).is_err());
    }

    /// Any change to a signed envelope's payload or signature is rejected, and
    /// a valid envelope cannot be re-attributed to another sender.
    #[test]
    fn envelopes_are_authenticated(seed in any::<u64>(), flip in any::<prop::sample::Index>(), bit in 0u8..8) {
        let mut rng = ChaCha20Rng::seed_from_u64(seed);
        let roster = GeneratedRoster::generate(3, &mut rng).unwrap();
        let envelope = Envelope::new(
            SessionId::random(&mut rng),
            Party::Participant(p(1)),
            Recipient::Coordinator,
            Message::Refused(Refused { refused: "sign_request".into(), reason: "test".into() }),
        );
        let signed = SignedEnvelope::sign(&envelope, &roster.participants[&p(1)]).unwrap();
        prop_assert_eq!(&signed.verify(&roster.roster).unwrap().envelope, &envelope);

        let mut bad_sig = signed.clone();
        bad_sig.signature[flip.index(64)] ^= 1 << bit;
        prop_assert!(bad_sig.verify(&roster.roster).is_err());

        let mut bytes = signed.payload.clone().into_bytes();
        let i = flip.index(bytes.len());
        bytes[i] ^= 1 << bit;
        if let Ok(payload) = String::from_utf8(bytes) {
            let bad_payload = SignedEnvelope { payload, signature: signed.signature };
            prop_assert!(bad_payload.verify(&roster.roster).is_err());
        }

        let mut forged = envelope.clone();
        forged.from = Party::Participant(p(2));
        let reattributed = SignedEnvelope::sign(&forged, &roster.participants[&p(1)]).unwrap();
        prop_assert!(reattributed.verify(&roster.roster).is_err());
    }
}
