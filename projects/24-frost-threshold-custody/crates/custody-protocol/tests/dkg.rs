// SPDX-License-Identifier: MIT
//! Pedersen DKG and refresh: honest runs, every complaint path, and
//! third-party verification of the resulting blame.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use common::*;
use custody_protocol::{
    Party,
    blame::{BlameContext, Fault},
    keygen::{KeygenOutcome, group_key_bytes, share_commitment},
    messages::{
        ComplaintReason, KeygenFinished, KeygenMode, KeygenResult, Message, ShareStatement,
        SignedShareStatement,
    },
    sealed::{self, SealContext, SealedBox},
};
use frost_keccak::keys::SecretShare;
use rand_chacha::ChaCha20Rng;
use rand_core::SeedableRng;

fn aborted(outcome: KeygenOutcome) -> custody_protocol::blame::AbortReport {
    match outcome {
        KeygenOutcome::Aborted(report) => report,
        KeygenOutcome::Committed { .. } => panic!("expected an abort"),
    }
}

#[test]
fn honest_dkg_gives_every_participant_a_consistent_share() {
    for (t, n) in [(2u16, 2u16), (2, 3), (3, 5), (5, 7)] {
        let mut net = network(n, u64::from(t * 10 + n));
        let group_key = dkg(&mut net, t, n);
        let public = net.group(&group_key).unwrap().clone();
        assert_eq!(public.min_signers(), Some(t));
        assert_eq!(public.verifying_shares().len(), usize::from(n));
        for id in ids(1..=n) {
            let material = &net.node(id).unwrap().shares()[&group_key];
            // Participants and the coordinator derived identical public data.
            assert_eq!(material.public_key_package, public);
            // Each secret share matches its published verifying share.
            let expected = public.verifying_shares()[&id.identifier()];
            assert_eq!(
                frost_keccak::keys::VerifyingShare::from(*material.key_package.signing_share()),
                expected
            );
        }
        // The group key is usable by the on-chain verifier.
        frost_keccak::evm::EvmGroupKey::from_verifying_key(public.verifying_key()).unwrap();
    }
}

#[test]
fn offline_participant_is_named_unresponsive() {
    let mut net = network(3, 1);
    net.set_offline(p(3), true);
    let report = aborted(net.dkg(2, &ids(1..=3)).unwrap());
    assert_eq!(report.phase, "round1");
    assert_eq!(report.blame.len(), 1);
    assert_eq!(report.blame[0].participant, p(3));
    assert!(matches!(report.blame[0].fault, Fault::Unresponsive { .. }));
    // Nobody committed anything.
    for id in ids(1..=2) {
        assert!(net.node(id).unwrap().shares().is_empty());
    }
}

#[test]
fn invalid_proof_of_knowledge_is_blamed_with_verifiable_evidence() {
    let mut net = network(4, 2);
    net.set_interceptor(boxed(|from, _to, env, _keys, _roster| {
        if from == Party::Participant(p(2))
            && let Message::KeygenRound1(r1) = &mut env.body
        {
            let pok = r1.package.proof_of_knowledge();
            let forged = frost_keccak::Signature::new(*pok.R(), *pok.z() + k256::Scalar::ONE);
            r1.package = frost_keccak::keys::dkg::round1::Package::new(
                r1.package.commitment().clone(),
                forged,
            );
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let report = aborted(net.dkg(3, &ids(1..=4)).unwrap());
    assert_eq!(report.phase, "round1");
    assert_eq!(
        report.culprits().into_iter().collect::<Vec<_>>(),
        vec![p(2)]
    );
    let ctx = BlameContext {
        roster: net.roster(),
        session: report.session,
        keygen_mode: Some(KeygenMode::Fresh),
        signing: None,
    };
    assert!(matches!(
        report.blame[0].fault,
        Fault::InvalidProofOfKnowledge { .. }
    ));
    report.blame[0].verify(&ctx).unwrap();
    // Evidence does not transfer to an innocent participant.
    let mut framed = report.blame[0].clone();
    framed.participant = p(1);
    assert!(framed.verify(&ctx).is_err());
}

/// Dealer 1 sends participant 3 a share that fails the Feldman check, signed
/// and sealed exactly like an honest share.
#[test]
fn invalid_share_complaint_names_the_dealer() {
    let mut net = network(4, 3);
    let mut rng = ChaCha20Rng::seed_from_u64(33);
    net.set_interceptor(boxed(move |from, _to, env, keys, roster| {
        if from == Party::Participant(p(1))
            && let Message::KeygenRound2(r2) = &mut env.body
        {
            for boxed in &mut r2.shares {
                if boxed.to != p(3) {
                    continue;
                }
                let bogus = frost_keccak::keys::SigningShare::deserialize(&[7u8; 32]).unwrap();
                let statement = ShareStatement {
                    session: env.session,
                    dealer: p(1),
                    recipient: p(3),
                    share: frost_keccak::keys::dkg::round2::Package::new(bogus),
                };
                let signed = SignedShareStatement::sign(&statement, keys).unwrap();
                boxed.sealed = sealed::seal(
                    &mut rng,
                    &roster.encryption_key(p(3)).unwrap(),
                    &SealContext {
                        session: env.session,
                        from: Party::Participant(p(1)),
                        to: p(3),
                        purpose: custody_protocol::keygen::SHARE_PURPOSE,
                    },
                    &serde_json::to_vec(&signed).unwrap(),
                )
                .unwrap();
            }
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let report = aborted(net.dkg(3, &ids(1..=4)).unwrap());
    assert_eq!(report.phase, "results");
    assert_eq!(
        report.culprits().into_iter().collect::<Vec<_>>(),
        vec![p(1)]
    );
    let blame = &report.blame[0];
    let Fault::InvalidShare { statement, .. } = &blame.fault else {
        panic!("expected InvalidShare, got {:?}", blame.fault);
    };
    let ctx = BlameContext {
        roster: net.roster(),
        session: report.session,
        keygen_mode: Some(KeygenMode::Fresh),
        signing: None,
    };
    blame.verify(&ctx).unwrap();
    // The statement really is signed by the dealer and addressed to P3.
    let s = statement.verify(net.roster()).unwrap();
    assert_eq!((s.dealer, s.recipient), (p(1), p(3)));
}

/// Participant 2 accuses dealer 4 with a statement it forged itself: the
/// signature check fails, so the complainant is blamed instead.
#[test]
fn false_complaint_names_the_accuser() {
    let mut net = network(4, 4);
    net.set_interceptor(boxed(|from, _to, env, keys, _roster| {
        if from == Party::Participant(p(2))
            && let Message::KeygenResult(result) = &mut env.body
        {
            let forged = SignedShareStatement::sign(
                &ShareStatement {
                    session: env.session,
                    dealer: p(4),
                    recipient: p(2),
                    share: frost_keccak::keys::dkg::round2::Package::new(
                        frost_keccak::keys::SigningShare::deserialize(&[9u8; 32]).unwrap(),
                    ),
                },
                keys, // signed by P2, not by the accused dealer
            )
            .unwrap();
            *result = KeygenResult::Complaints {
                complaints: vec![custody_protocol::messages::Complaint {
                    dealer: p(4),
                    reason: ComplaintReason::InvalidShare { statement: forged },
                }],
            };
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let report = aborted(net.dkg(2, &ids(1..=4)).unwrap());
    assert_eq!(
        report.culprits().into_iter().collect::<Vec<_>>(),
        vec![p(2)]
    );
    assert!(
        matches!(report.blame[0].fault, Fault::FalseComplaint { dealer, .. } if dealer == p(4))
    );
}

#[test]
fn unfounded_missing_share_complaint_names_the_accuser() {
    let mut net = network(3, 5);
    net.set_interceptor(boxed(|from, _to, env, _keys, _roster| {
        if from == Party::Participant(p(3))
            && let Message::KeygenResult(result) = &mut env.body
        {
            *result = KeygenResult::Complaints {
                complaints: vec![custody_protocol::messages::Complaint {
                    dealer: p(1),
                    reason: ComplaintReason::MissingShare,
                }],
            };
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let report = aborted(net.dkg(2, &ids(1..=3)).unwrap());
    assert_eq!(
        report.culprits().into_iter().collect::<Vec<_>>(),
        vec![p(3)]
    );
}

#[test]
fn missing_share_is_detected_before_relay() {
    let mut net = network(4, 6);
    net.set_interceptor(boxed(|from, _to, env, _keys, _roster| {
        if from == Party::Participant(p(4))
            && let Message::KeygenRound2(r2) = &mut env.body
        {
            r2.shares.retain(|b| b.to != p(1));
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let report = aborted(net.dkg(3, &ids(1..=4)).unwrap());
    assert_eq!(report.phase, "round2");
    assert_eq!(
        report.culprits().into_iter().collect::<Vec<_>>(),
        vec![p(4)]
    );
    let ctx = BlameContext {
        roster: net.roster(),
        session: report.session,
        keygen_mode: Some(KeygenMode::Fresh),
        signing: None,
    };
    assert!(
        matches!(report.blame[0].fault, Fault::MissingShare { recipient, .. } if recipient == p(1))
    );
    report.blame[0].verify(&ctx).unwrap();
}

#[test]
fn inconsistent_round1_digest_is_blamed() {
    let mut net = network(3, 7);
    net.set_interceptor(boxed(|from, _to, env, _keys, _roster| {
        if from == Party::Participant(p(2))
            && let Message::KeygenRound2(r2) = &mut env.body
        {
            r2.round1_digest[0] ^= 1;
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let report = aborted(net.dkg(2, &ids(1..=3)).unwrap());
    assert_eq!(
        report.culprits().into_iter().collect::<Vec<_>>(),
        vec![p(2)]
    );
    assert!(matches!(
        report.blame[0].fault,
        Fault::InconsistentBroadcast { .. }
    ));
    let ctx = BlameContext {
        roster: net.roster(),
        session: report.session,
        keygen_mode: Some(KeygenMode::Fresh),
        signing: None,
    };
    report.blame[0].verify(&ctx).unwrap();
}

#[test]
fn equivocating_dealer_is_blamed() {
    let mut net = network(3, 8);
    net.set_interceptor(boxed(|from, _to, env, _keys, _roster| {
        if from == Party::Participant(p(1))
            && let Message::KeygenRound1(r1) = &mut env.body
        {
            // A second, different (but validly signed) round-one package.
            let pok = r1.package.proof_of_knowledge();
            let other = frost_keccak::Signature::new(*pok.R(), *pok.z() + k256::Scalar::ONE);
            r1.package = frost_keccak::keys::dkg::round1::Package::new(
                r1.package.commitment().clone(),
                other,
            );
            return Verdict::DeliverBoth;
        }
        Verdict::Deliver
    }));
    let report = aborted(net.dkg(2, &ids(1..=3)).unwrap());
    assert_eq!(
        report.culprits().into_iter().collect::<Vec<_>>(),
        vec![p(1)]
    );
    assert!(matches!(report.blame[0].fault, Fault::Equivocation { .. }));
    let ctx = BlameContext {
        roster: net.roster(),
        session: report.session,
        keygen_mode: Some(KeygenMode::Fresh),
        signing: None,
    };
    report.blame[0].verify(&ctx).unwrap();
}

/// Dealer 2 seals garbage for participant 1, then reveals a valid share when
/// asked: the dispute cannot be attributed, so both are listed and nobody is
/// blamed; the session still aborts.
#[test]
fn undecryptable_box_triggers_reveal_and_dispute() {
    let mut net = network(3, 9);
    net.set_interceptor(boxed(|from, _to, env, _keys, _roster| {
        if from == Party::Participant(p(2))
            && let Message::KeygenRound2(r2) = &mut env.body
        {
            for b in &mut r2.shares {
                if b.to == p(1) {
                    b.sealed = SealedBox {
                        ephemeral_key: b.sealed.ephemeral_key,
                        ciphertext: vec![0u8; 48],
                    };
                }
            }
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let report = aborted(net.dkg(2, &ids(1..=3)).unwrap());
    assert_eq!(report.phase, "reveal");
    assert!(report.blame.is_empty(), "{report:?}");
    assert_eq!(report.disputes.len(), 1);
    assert_eq!(
        (report.disputes[0].dealer, report.disputes[0].recipient),
        (p(2), p(1))
    );
    assert_eq!(report.excluded().len(), 2);
}

#[test]
fn dealer_that_withholds_the_reveal_is_blamed() {
    let mut net = network(3, 10);
    net.set_interceptor(boxed(|from, _to, env, _keys, _roster| {
        if from == Party::Participant(p(2)) {
            match &mut env.body {
                Message::KeygenRound2(r2) => {
                    for b in &mut r2.shares {
                        if b.to == p(3) {
                            b.sealed.ciphertext[0] ^= 0xff;
                        }
                    }
                    return Verdict::Resign;
                }
                Message::KeygenReveal(_) => return Verdict::Drop,
                _ => {}
            }
        }
        Verdict::Deliver
    }));
    let report = aborted(net.dkg(2, &ids(1..=3)).unwrap());
    assert_eq!(
        report.culprits().into_iter().collect::<Vec<_>>(),
        vec![p(2)]
    );
    assert!(matches!(
        report.blame[0].fault,
        Fault::FailedReveal { recipient, reveal: None } if recipient == p(3)
    ));
}

/// A malicious coordinator forges a commit certificate that omits one
/// participant's result: nobody commits.
#[test]
fn participants_refuse_an_incomplete_commit_certificate() {
    let mut net = network(3, 11);
    net.set_interceptor(boxed(|from, to, env, _keys, _roster| {
        if from == Party::Coordinator
            && to == Party::Participant(p(1))
            && let Message::KeygenFinished(KeygenFinished::Committed { results }) = &mut env.body
        {
            results.pop();
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let outcome = net.dkg(2, &ids(1..=3)).unwrap();
    assert!(matches!(outcome, KeygenOutcome::Committed { .. }));
    assert!(
        net.node(p(1)).unwrap().shares().is_empty(),
        "P1 must not commit"
    );
    assert_eq!(net.node(p(2)).unwrap().shares().len(), 1);
}

#[test]
fn participants_ignore_envelopes_not_signed_by_the_coordinator() {
    let mut net = network(3, 12);
    net.set_interceptor(boxed(|from, to, env, _keys, _roster| {
        if from == Party::Coordinator && to == Party::Participant(p(3)) {
            // Re-address the envelope so that it claims to come from P2; the
            // coordinator's signature no longer matches the claimed sender.
            env.from = Party::Participant(p(2));
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let report = aborted(net.dkg(2, &ids(1..=3)).unwrap());
    // P3 never sees a valid KeygenStart and is reported unresponsive.
    assert_eq!(
        report.culprits().into_iter().collect::<Vec<_>>(),
        vec![p(3)]
    );
    assert!(matches!(report.blame[0].fault, Fault::Unresponsive { .. }));
}

#[test]
fn refresh_keeps_the_group_key_and_rerandomises_shares() {
    let mut net = network(4, 13);
    let group_key = dkg(&mut net, 3, 4);
    let before: Vec<_> = ids(1..=4)
        .into_iter()
        .map(|id| net.node(id).unwrap().shares()[&group_key].clone())
        .collect();
    let outcome = net.refresh(group_key, &ids(1..=4)).unwrap();
    let KeygenOutcome::Committed { public_key_package } = outcome else {
        panic!("refresh aborted");
    };
    assert_eq!(group_key_bytes(&public_key_package).unwrap(), group_key);
    for (id, old) in ids(1..=4).into_iter().zip(before) {
        let new = &net.node(id).unwrap().shares()[&group_key];
        assert_ne!(
            new.key_package.signing_share(),
            old.key_package.signing_share()
        );
        assert_eq!(new.public_key_package, public_key_package);
    }
}

#[test]
fn refresh_can_evict_a_participant() {
    let mut net = network(4, 14);
    let group_key = dkg(&mut net, 2, 4);
    let KeygenOutcome::Committed { public_key_package } =
        net.refresh(group_key, &ids(1..=3)).unwrap()
    else {
        panic!("refresh aborted");
    };
    assert_eq!(public_key_package.verifying_shares().len(), 3);
    assert!(
        !public_key_package
            .verifying_shares()
            .contains_key(&p(4).identifier())
    );
}

#[test]
fn refresh_share_check_uses_the_zero_constant_commitment() {
    // Refresh round-one packages omit the (zero) constant term; the commitment
    // a recipient checks a refresh share against must re-insert the identity.
    let mut rng = ChaCha20Rng::seed_from_u64(15);
    let mut secrets = std::collections::BTreeMap::new();
    let mut packages = std::collections::BTreeMap::new();
    for id in ids(1..=3) {
        let (secret, package) =
            frost_keccak::keys::refresh::refresh_dkg_part1(id.identifier(), 3, 2, &mut rng)
                .unwrap();
        secrets.insert(id, secret);
        packages.insert(id, package);
    }
    let others: std::collections::BTreeMap<_, _> = packages
        .iter()
        .filter(|(id, _)| **id != p(1))
        .map(|(id, pkg)| (id.identifier(), pkg.clone()))
        .collect();
    let (_, shares) =
        frost_keccak::keys::refresh::refresh_dkg_part2(secrets.remove(&p(1)).unwrap(), &others)
            .unwrap();
    let share_for_2 = *shares[&p(2).identifier()].signing_share();

    let refresh = share_commitment(
        KeygenMode::Refresh {
            group_key: [2u8; 33],
        },
        &packages[&p(1)],
    );
    let fresh = share_commitment(KeygenMode::Fresh, &packages[&p(1)]);
    assert_eq!(fresh.coefficients().len() + 1, refresh.coefficients().len());
    SecretShare::new(p(2).identifier(), share_for_2, refresh)
        .verify()
        .unwrap();
    assert!(
        SecretShare::new(p(2).identifier(), share_for_2, fresh)
            .verify()
            .is_err()
    );
}

/// A dealer whose Feldman commitment has the wrong number of coefficients
/// (i.e. claims a different threshold) is rejected before any relay.
#[test]
fn wrong_commitment_length_is_a_malformed_message() {
    let mut net = network(3, 16);
    net.set_interceptor(boxed(|from, _to, env, _keys, _roster| {
        if from == Party::Participant(p(3))
            && let Message::KeygenRound1(r1) = &mut env.body
        {
            let mut coefficients = r1.package.commitment().coefficients().to_vec();
            coefficients.push(coefficients[0]);
            r1.package = frost_keccak::keys::dkg::round1::Package::new(
                frost_keccak::keys::VerifiableSecretSharingCommitment::new(coefficients),
                *r1.package.proof_of_knowledge(),
            );
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let report = aborted(net.dkg(2, &ids(1..=3)).unwrap());
    assert_eq!(report.phase, "round1");
    assert_eq!(
        report.culprits().into_iter().collect::<Vec<_>>(),
        vec![p(3)]
    );
    assert!(
        matches!(&report.blame[0].fault, Fault::MalformedMessage { detail, .. } if detail.contains("coefficients"))
    );
}

/// A participant that reports different public data than everyone else is
/// blamed, and nobody commits.
#[test]
fn inconsistent_result_is_blamed() {
    let mut net = network(3, 17);
    net.set_interceptor(boxed(|from, _to, env, _keys, _roster| {
        if from == Party::Participant(p(1))
            && let Message::KeygenResult(KeygenResult::Success {
                public_key_package_digest,
                ..
            }) = &mut env.body
        {
            public_key_package_digest[0] ^= 1;
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let report = aborted(net.dkg(2, &ids(1..=3)).unwrap());
    assert_eq!(report.phase, "results");
    assert_eq!(
        report.culprits().into_iter().collect::<Vec<_>>(),
        vec![p(1)]
    );
    assert!(matches!(
        report.blame[0].fault,
        Fault::InconsistentResult { .. }
    ));
    for id in ids(1..=3) {
        assert!(net.node(id).unwrap().shares().is_empty());
    }
}
