// SPDX-License-Identifier: MIT
//! Signing: identifiable aborts, retries, nonce-reuse protection, signer
//! policy, refresh (old shares become useless) and repair.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::collections::BTreeSet;

use alloy_primitives::{Address, U256, address};
use common::*;
use custody_protocol::{
    Party, ProtocolError, SessionId,
    blame::{BlameContext, Fault},
    envelope::Recipient,
    intent::{CustodyAction, SignerPolicy, VaultDomain, WithdrawalIntent},
    keygen::KeygenOutcome,
    messages::{Message, SignRequest},
    repair::RepairOutcome,
    signing::{SessionJournal, SignerState, SigningOutcome},
};
use frost_keccak::evm;
use rand_chacha::ChaCha20Rng;
use rand_core::SeedableRng;

fn signed(
    outcome: SigningOutcome,
) -> (
    frost_keccak::Signature,
    evm::EvmSignature,
    BTreeSet<custody_protocol::ParticipantId>,
) {
    match outcome {
        SigningOutcome::Signed {
            signature,
            evm,
            signers,
        } => (signature, evm, signers),
        SigningOutcome::Aborted(report) => panic!("signing aborted: {report:?}"),
    }
}

fn verify_onchain(
    net: &custody_protocol::local::LocalNetwork<ChaCha20Rng>,
    group_key: &[u8; 33],
    action: &CustodyAction,
    sig: &evm::EvmSignature,
) -> bool {
    let key = evm::EvmGroupKey::from_verifying_key(net.group(group_key).unwrap().verifying_key())
        .unwrap();
    evm::verify(&key, &action.signing_hash(&DOMAIN), sig)
}

#[test]
fn honest_signing_produces_an_evm_verifiable_signature() {
    let mut net = network(5, 20);
    let group_key = dkg(&mut net, 3, 5);
    let action = withdrawal(1, 1_000);
    let (signature, onchain, signers) = signed(
        net.sign(group_key, action.clone(), DOMAIN, &[p(1), p(3), p(5)])
            .unwrap(),
    );
    assert_eq!(signers, BTreeSet::from([p(1), p(3), p(5)]));
    net.group(&group_key)
        .unwrap()
        .verifying_key()
        .verify(&action.signing_hash(&DOMAIN), &signature)
        .unwrap();
    assert!(verify_onchain(&net, &group_key, &action, &onchain));
}

#[test]
fn corrupted_share_is_identified_with_verifiable_evidence() {
    let mut net = network(5, 21);
    let group_key = dkg(&mut net, 3, 5);
    net.set_interceptor(boxed(|from, _to, env, _keys, _roster| {
        if from == Party::Participant(p(2))
            && let Message::SignShare(s) = &mut env.body
        {
            let bumped = frost_keccak::round2::SignatureShare::deserialize(
                &(k256::Scalar::from(3u64)).to_bytes(),
            )
            .unwrap();
            s.share = bumped;
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let outcome = net
        .sign(group_key, withdrawal(2, 5), DOMAIN, &[p(1), p(2), p(3)])
        .unwrap();
    let SigningOutcome::Aborted(report) = outcome else {
        panic!("expected abort")
    };
    assert_eq!(
        report.culprits().into_iter().collect::<Vec<_>>(),
        vec![p(2)]
    );
    assert!(matches!(
        report.blame[0].fault,
        Fault::InvalidSignatureShare { .. }
    ));
    let package = net.last_signing_package().unwrap().clone();
    let public = net.group(&group_key).unwrap().clone();
    let ctx = BlameContext {
        roster: net.roster(),
        session: report.session,
        keygen_mode: None,
        signing: Some((&package, &public)),
    };
    report.blame[0].verify(&ctx).unwrap();
    // The same evidence cannot be pinned on another signer.
    let mut framed = report.blame[0].clone();
    framed.participant = p(3);
    assert!(framed.verify(&ctx).is_err());
}

#[test]
fn share_bound_to_another_package_is_malformed() {
    let mut net = network(3, 37);
    let group_key = dkg(&mut net, 2, 3);
    net.set_interceptor(boxed(|from, _to, env, _keys, _roster| {
        if from == Party::Participant(p(2))
            && let Message::SignShare(s) = &mut env.body
        {
            s.package_digest = [0u8; 32];
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let SigningOutcome::Aborted(report) = net
        .sign(group_key, withdrawal(50, 1), DOMAIN, &[p(1), p(2)])
        .unwrap()
    else {
        panic!("a share bound to another package must not be aggregated")
    };
    assert_eq!(report.culprits(), BTreeSet::from([p(2)]));
    assert!(matches!(
        report.blame[0].fault,
        Fault::MalformedMessage { .. }
    ));
}

#[test]
fn all_cheaters_are_named_not_just_the_first() {
    let mut net = network(5, 22);
    let group_key = dkg(&mut net, 4, 5);
    net.set_interceptor(boxed(|from, _to, env, _keys, _roster| {
        if matches!(from, Party::Participant(x) if x == p(1) || x == p(4))
            && let Message::SignShare(s) = &mut env.body
        {
            s.share = frost_keccak::round2::SignatureShare::deserialize(&[1u8; 32]).unwrap();
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let SigningOutcome::Aborted(report) = net
        .sign(group_key, withdrawal(3, 5), DOMAIN, &ids(1..=4))
        .unwrap()
    else {
        panic!("expected abort")
    };
    assert_eq!(report.culprits(), BTreeSet::from([p(1), p(4)]));
}

#[test]
fn retry_excludes_cheaters_and_unresponsive_signers() {
    let mut net = network(5, 23);
    let group_key = dkg(&mut net, 3, 5);
    net.set_offline(p(1), true);
    net.set_interceptor(boxed(|from, _to, env, _keys, _roster| {
        if from == Party::Participant(p(2))
            && let Message::SignShare(s) = &mut env.body
        {
            s.share = frost_keccak::round2::SignatureShare::deserialize(&[5u8; 32]).unwrap();
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let action = withdrawal(4, 42);
    let report = net
        .sign_with_retry(group_key, action.clone(), DOMAIN)
        .unwrap();
    // Attempt 1: {1,2,3} → P1 silent. Attempt 2: {2,3,4} → P2 cheats.
    assert_eq!(report.failed_attempts.len(), 2);
    assert!(matches!(
        report.failed_attempts[0].blame[0].fault,
        Fault::Unresponsive { .. }
    ));
    assert_eq!(report.failed_attempts[0].blame[0].participant, p(1));
    assert_eq!(report.failed_attempts[1].culprits(), BTreeSet::from([p(2)]));
    let (_, onchain, signers) = signed(report.outcome);
    assert_eq!(signers, BTreeSet::from([p(3), p(4), p(5)]));
    assert!(verify_onchain(&net, &group_key, &action, &onchain));
}

#[test]
fn retry_gives_up_when_fewer_than_t_honest_signers_remain() {
    let mut net = network(3, 24);
    let group_key = dkg(&mut net, 3, 3);
    net.set_offline(p(3), true);
    let report = net
        .sign_with_retry(group_key, withdrawal(5, 1), DOMAIN)
        .unwrap();
    assert!(matches!(report.outcome, SigningOutcome::Aborted(_)));
    assert_eq!(report.failed_attempts.len(), 1);
}

#[test]
fn fewer_than_t_signers_are_rejected_up_front() {
    let mut net = network(4, 25);
    let group_key = dkg(&mut net, 3, 4);
    let err = net
        .sign(group_key, withdrawal(6, 1), DOMAIN, &[p(1), p(2)])
        .unwrap_err();
    assert!(matches!(err, ProtocolError::InvalidParameters(_)));
}

#[test]
fn signer_policy_violations_are_declined() {
    let mut net = network(3, 26);
    let group_key = dkg(&mut net, 2, 3);
    // Wrong vault: every signer is pinned to DOMAIN.
    let other = VaultDomain {
        chain_id: 1,
        vault: address!("00000000000000000000000000000000000000aa"),
    };
    let SigningOutcome::Aborted(report) = net
        .sign(group_key, withdrawal(7, 1), other, &[p(1), p(2)])
        .unwrap()
    else {
        panic!("expected abort")
    };
    assert!(
        report
            .blame
            .iter()
            .all(|b| matches!(b.fault, Fault::Declined { .. }))
    );
    assert!(
        report.culprits().is_empty(),
        "declining is not misbehaviour"
    );

    // Zero recipient.
    let bad = CustodyAction::Withdrawal(WithdrawalIntent {
        to: Address::ZERO,
        token: Address::ZERO,
        amount: U256::from(1),
        nonce: U256::from(8),
        deadline: U256::from(1),
    });
    assert!(matches!(
        net.sign(group_key, bad, DOMAIN, &[p(1), p(2)]).unwrap(),
        SigningOutcome::Aborted(_)
    ));
}

#[test]
fn per_signer_amount_cap_is_enforced() {
    let mut rng = ChaCha20Rng::seed_from_u64(27);
    let mut net = network(3, 27);
    let group_key = dkg(&mut net, 2, 3);
    let shares = net.node(p(1)).unwrap().shares().clone();
    let mut policy = SignerPolicy::permissive(DOMAIN);
    policy.max_withdrawal = Some(U256::from(100));
    let mut signer = SignerState::new(policy, SessionJournal::in_memory());
    let request = |amount| SignRequest {
        group_key,
        action: withdrawal(9, amount),
        domain: DOMAIN,
        signers: vec![p(1), p(2)],
        approval: None,
    };
    let session = SessionId::random(&mut rng);
    assert!(matches!(
        signer.on_sign_request(session, p(1), &request(101), &shares, &mut rng),
        Err(ProtocolError::PolicyViolation(_))
    ));
    // A refused request does not burn the session.
    signer
        .on_sign_request(session, p(1), &request(100), &shares, &mut rng)
        .unwrap();
}

/// Nonce-reuse protection at the signer: one commitment per session, one
/// share per commitment, and a package for a different message consumes the
/// nonces without producing a share.
#[test]
fn signer_never_reuses_nonces() {
    let mut rng = ChaCha20Rng::seed_from_u64(28);
    let mut net = network(3, 28);
    let group_key = dkg(&mut net, 2, 3);
    let m1 = net.node(p(1)).unwrap().shares()[&group_key].clone();
    let m2 = net.node(p(2)).unwrap().shares()[&group_key].clone();
    let sh1 = net.node(p(1)).unwrap().shares().clone();
    let sh2 = net.node(p(2)).unwrap().shares().clone();
    let mut s1 = SignerState::new(
        SignerPolicy::permissive(DOMAIN),
        SessionJournal::in_memory(),
    );
    let mut s2 = SignerState::new(
        SignerPolicy::permissive(DOMAIN),
        SessionJournal::in_memory(),
    );
    let request = SignRequest {
        group_key,
        action: withdrawal(10, 1),
        domain: DOMAIN,
        signers: vec![p(1), p(2)],
        approval: None,
    };
    let session = SessionId::random(&mut rng);
    let commit = |out: custody_protocol::envelope::Outbound| match out.body {
        Message::SignCommitment(c) => c.commitments,
        other => panic!("unexpected {other:?}"),
    };
    let c1 = commit(
        s1.on_sign_request(session, p(1), &request, &sh1, &mut rng)
            .unwrap(),
    );
    let c2 = commit(
        s2.on_sign_request(session, p(2), &request, &sh2, &mut rng)
            .unwrap(),
    );

    // (1) Same session again → refused, even with a different action.
    let mut other = request.clone();
    other.action = withdrawal(11, 1);
    assert!(matches!(
        s1.on_sign_request(session, p(1), &other, &sh1, &mut rng),
        Err(ProtocolError::SessionAlreadyUsed(_))
    ));

    // (2) A package for a different message → refused, nonces consumed.
    let commitments = [(p(1).identifier(), c1), (p(2).identifier(), c2)]
        .into_iter()
        .collect();
    let evil = frost_keccak::SigningPackage::new(
        commitments,
        &withdrawal(11, 1_000_000).signing_hash(&DOMAIN),
    );
    assert!(matches!(
        s1.on_sign_package(session, &evil, &m1),
        Err(ProtocolError::PackageMismatch(_))
    ));
    let commitments = [(p(1).identifier(), c1), (p(2).identifier(), c2)]
        .into_iter()
        .collect();
    let honest =
        frost_keccak::SigningPackage::new(commitments, &request.action.signing_hash(&DOMAIN));
    assert!(matches!(
        s1.on_sign_package(session, &honest, &m1),
        Err(ProtocolError::UnknownSession(_))
    ));

    // (3) Honest signer 2 signs once; a replayed package is refused.
    s2.on_sign_package(session, &honest, &m2).unwrap();
    assert!(matches!(
        s2.on_sign_package(session, &honest, &m2),
        Err(ProtocolError::UnknownSession(_))
    ));
    assert_eq!(s2.pending_len(), 0);
    assert_eq!(s2.journal().len(), 1);
}

#[test]
fn abandoned_sessions_cannot_accumulate_nonces() {
    use custody_protocol::signing::MAX_PENDING_SESSIONS;
    let mut rng = ChaCha20Rng::seed_from_u64(36);
    let mut net = network(2, 36);
    let group_key = dkg(&mut net, 2, 2);
    let sh1 = net.node(p(1)).unwrap().shares().clone();
    let mut s1 = SignerState::new(
        SignerPolicy::permissive(DOMAIN),
        SessionJournal::in_memory(),
    );
    let request = SignRequest {
        group_key,
        action: withdrawal(40, 1),
        domain: DOMAIN,
        signers: vec![p(1), p(2)],
        approval: None,
    };
    let first = SessionId([0u8; 16]);
    s1.on_sign_request(first, p(1), &request, &sh1, &mut rng)
        .unwrap();
    for i in 1..=MAX_PENDING_SESSIONS {
        let mut id = [0u8; 16];
        id[..8].copy_from_slice(&(i as u64).to_be_bytes());
        s1.on_sign_request(SessionId(id), p(1), &request, &sh1, &mut rng)
            .unwrap();
    }
    assert_eq!(s1.pending_len(), MAX_PENDING_SESSIONS);
    assert_eq!(
        s1.pending_group_key(&first),
        None,
        "the oldest session was evicted"
    );
    assert_eq!(s1.journal().len(), MAX_PENDING_SESSIONS + 1);
}

#[test]
fn signer_rejects_packages_with_altered_commitments_or_signer_sets() {
    let mut rng = ChaCha20Rng::seed_from_u64(29);
    let mut net = network(3, 29);
    let group_key = dkg(&mut net, 2, 3);
    let m1 = net.node(p(1)).unwrap().shares()[&group_key].clone();
    let sh1 = net.node(p(1)).unwrap().shares().clone();
    let mut s1 = SignerState::new(
        SignerPolicy::permissive(DOMAIN),
        SessionJournal::in_memory(),
    );
    let request = SignRequest {
        group_key,
        action: withdrawal(12, 1),
        domain: DOMAIN,
        signers: vec![p(1), p(2)],
        approval: None,
    };
    let digest = request.action.signing_hash(&DOMAIN);
    fn make(
        signer: &mut SignerState,
        session: SessionId,
        request: &SignRequest,
        shares: &std::collections::BTreeMap<
            custody_protocol::messages::GroupKeyBytes,
            custody_protocol::keygen::KeyMaterial,
        >,
        rng: &mut ChaCha20Rng,
    ) -> frost_keccak::round1::SigningCommitments {
        let out = signer
            .on_sign_request(session, p(1), request, shares, rng)
            .unwrap();
        let Message::SignCommitment(c) = out.body else {
            panic!()
        };
        c.commitments
    }
    let fake = frost_keccak::round1::commit(
        m1.key_package.signing_share(),
        &mut ChaCha20Rng::seed_from_u64(1),
    )
    .1;

    let session = SessionId([1u8; 16]);
    let _mine = make(&mut s1, session, &request, &sh1, &mut rng);
    // Coordinator substitutes P1's commitment.
    let pkg = frost_keccak::SigningPackage::new(
        [(p(1).identifier(), fake), (p(2).identifier(), fake)]
            .into_iter()
            .collect(),
        &digest,
    );
    assert!(matches!(
        s1.on_sign_package(session, &pkg, &m1),
        Err(ProtocolError::PackageMismatch(_))
    ));

    let session = SessionId([2u8; 16]);
    let mine = make(&mut s1, session, &request, &sh1, &mut rng);
    // Coordinator adds a signer that was not in the request.
    let pkg = frost_keccak::SigningPackage::new(
        [
            (p(1).identifier(), mine),
            (p(2).identifier(), fake),
            (p(3).identifier(), fake),
        ]
        .into_iter()
        .collect(),
        &digest,
    );
    assert!(matches!(
        s1.on_sign_package(session, &pkg, &m1),
        Err(ProtocolError::PackageMismatch(_))
    ));
}

#[test]
fn session_journal_survives_restarts() {
    let dir = std::env::temp_dir().join(format!("frost-journal-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("sessions.log");
    let _ = std::fs::remove_file(&path);
    let session = SessionId([9u8; 16]);
    {
        let mut journal = SessionJournal::open(path.clone()).unwrap();
        journal.burn(session).unwrap();
        assert!(matches!(
            journal.burn(session),
            Err(ProtocolError::SessionAlreadyUsed(_))
        ));
    }
    let reopened = SessionJournal::open(path.clone()).unwrap();
    assert!(reopened.contains(&session));
    assert_eq!(reopened.len(), 1);
    std::fs::write(&path, "not-hex\n").unwrap();
    assert!(SessionJournal::open(path.clone()).is_err());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn replayed_sign_request_is_refused_by_the_node() {
    use std::cell::Cell;
    use std::rc::Rc;
    let mut net = network(3, 30);
    let group_key = dkg(&mut net, 2, 3);
    // Deliver every SignRequest twice. The node commits once and refuses the
    // replay; the coordinator ignores refusals from signers that already
    // answered, so the attempt still succeeds.
    let refusals = Rc::new(Cell::new(0u32));
    let seen = refusals.clone();
    net.set_interceptor(boxed(move |from, _to, env, _keys, _roster| {
        match (&from, &env.body) {
            (Party::Coordinator, Message::SignRequest(_)) => Verdict::DeliverBoth,
            (Party::Participant(_), Message::Refused(r)) => {
                assert!(r.reason.contains("already used"), "{}", r.reason);
                seen.set(seen.get() + 1);
                Verdict::Deliver
            }
            _ => Verdict::Deliver,
        }
    }));
    let action = withdrawal(13, 1);
    let (_, onchain, _) = signed(
        net.sign(group_key, action.clone(), DOMAIN, &[p(1), p(2)])
            .unwrap(),
    );
    assert!(verify_onchain(&net, &group_key, &action, &onchain));
    assert_eq!(refusals.get(), 2, "each signer refused exactly one replay");
    for id in [p(1), p(2)] {
        // The journal holds the DKG session and the one signing session.
        assert_eq!(net.node(id).unwrap().signer().journal().len(), 2);
        assert_eq!(net.node(id).unwrap().signer().pending_len(), 0);
    }
}

#[test]
fn stolen_pre_refresh_share_is_useless_after_refresh() {
    let mut net = network(4, 31);
    let group_key = dkg(&mut net, 2, 4);
    let stolen = net.node(p(4)).unwrap().shares()[&group_key].clone();
    assert!(matches!(
        net.refresh(group_key, &ids(1..=4)).unwrap(),
        KeygenOutcome::Committed { .. }
    ));
    // Refreshed shares sign.
    signed(
        net.sign(group_key, withdrawal(14, 1), DOMAIN, &[p(1), p(4)])
            .unwrap(),
    );
    // An attacker who stole P4's old share (and impersonates P4) is caught.
    net.node_mut(p(4)).unwrap().install_share(stolen).unwrap();
    let SigningOutcome::Aborted(report) = net
        .sign(group_key, withdrawal(15, 1), DOMAIN, &[p(1), p(4)])
        .unwrap()
    else {
        panic!("old share must not produce a valid signature")
    };
    assert_eq!(report.culprits(), BTreeSet::from([p(4)]));
}

#[test]
fn lost_share_is_repaired_by_t_helpers() {
    let mut net = network(5, 32);
    let group_key = dkg(&mut net, 3, 5);
    let original = net.node(p(2)).unwrap().shares()[&group_key].clone();
    net.node_mut(p(2))
        .unwrap()
        .forget_share(&group_key)
        .unwrap();
    assert!(matches!(
        net.sign(group_key, withdrawal(16, 1), DOMAIN, &[p(1), p(2), p(3)])
            .unwrap(),
        SigningOutcome::Aborted(_)
    ));
    let outcome = net.repair(group_key, p(2), &[p(1), p(4), p(5)]).unwrap();
    assert_eq!(outcome, RepairOutcome::Repaired { participant: p(2) });
    let repaired = &net.node(p(2)).unwrap().shares()[&group_key];
    assert_eq!(
        repaired.key_package.signing_share(),
        original.key_package.signing_share()
    );
    assert_eq!(repaired.public_key_package, original.public_key_package);
    signed(
        net.sign(group_key, withdrawal(17, 1), DOMAIN, &[p(1), p(2), p(3)])
            .unwrap(),
    );
}

#[test]
fn bad_sigma_makes_the_repair_fail_closed() {
    let mut net = network(4, 33);
    let group_key = dkg(&mut net, 2, 4);
    net.node_mut(p(1))
        .unwrap()
        .forget_share(&group_key)
        .unwrap();
    let mut rng = ChaCha20Rng::seed_from_u64(34);
    net.set_interceptor(boxed(move |from, _to, env, _keys, roster| {
        if from == Party::Participant(p(3))
            && let Message::RepairSigma(s) = &mut env.body
        {
            let random = frost_keccak::keys::repairable::Sigma::deserialize(&[4u8; 32]).unwrap();
            s.sigma = custody_protocol::sealed::seal(
                &mut rng,
                &roster.encryption_key(p(1)).unwrap(),
                &custody_protocol::sealed::SealContext {
                    session: env.session,
                    from: Party::Participant(p(3)),
                    to: p(1),
                    purpose: custody_protocol::repair::SIGMA_PURPOSE,
                },
                &random.serialize(),
            )
            .unwrap();
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let outcome = net.repair(group_key, p(1), &[p(2), p(3)]).unwrap();
    assert!(matches!(outcome, RepairOutcome::Aborted(_)));
    assert!(
        net.node(p(1)).unwrap().shares().is_empty(),
        "no unverified share is installed"
    );
}

#[test]
fn repair_rejects_invalid_helper_sets() {
    let mut net = network(4, 35);
    let group_key = dkg(&mut net, 3, 4);
    assert!(
        net.repair(group_key, p(1), &[p(2), p(3)]).is_err(),
        "below threshold"
    );
    assert!(
        net.repair(group_key, p(1), &[p(1), p(2), p(3)]).is_err(),
        "lost participant helps"
    );
    assert!(
        net.repair(group_key, p(1), &[p(2), p(2), p(3)]).is_err(),
        "duplicate helper"
    );
    let _ = Recipient::Coordinator;
}
