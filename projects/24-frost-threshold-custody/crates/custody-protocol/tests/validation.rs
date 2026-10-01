// SPDX-License-Identifier: MIT
//! Parameter validation, unexpected messages and phase timeouts across the
//! keygen, signing and repair state machines, plus a full-lifecycle transcript
//! check that every message type is exercised and round-trips through JSON.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::cell::RefCell;
use std::collections::BTreeSet;
use std::rc::Rc;
use std::time::Duration;

use common::*;
use custody_protocol::{
    Party, ProtocolError, SessionId,
    blame::Fault,
    envelope::{Envelope, Recipient, SignedEnvelope},
    identity::{PartyKeys, Roster},
    intent::SignerPolicy,
    keygen::{KeygenCoordinator, KeygenOutcome, KeygenParticipant},
    local::Interceptor,
    messages::{Bundle, KeygenMode, KeygenStart, Message, RepairStart, SignRequest},
    repair::{RepairCoordinator, RepairHelper, RepairOutcome, RepairRecipient},
    signing::{SessionJournal, SignerState, SigningCoordinator, SigningOutcome},
};
use rand_chacha::ChaCha20Rng;
use rand_core::SeedableRng;

fn start(
    mode: KeygenMode,
    threshold: u16,
    participants: Vec<custody_protocol::ParticipantId>,
) -> KeygenStart {
    KeygenStart {
        mode,
        threshold,
        participants,
    }
}

#[test]
fn keygen_parameters_are_validated() {
    let mut rng = ChaCha20Rng::seed_from_u64(70);
    let session = SessionId([1; 16]);
    let bad = [
        start(KeygenMode::Fresh, 1, ids(1..=3)),
        start(KeygenMode::Fresh, 4, ids(1..=3)),
        start(KeygenMode::Fresh, 2, vec![p(1), p(1), p(2)]),
        start(KeygenMode::Fresh, 2, vec![p(2), p(3)]),
    ];
    for s in &bad {
        assert!(KeygenParticipant::start(session, p(1), s, None, &mut rng).is_err());
    }
    // Refresh needs the share set being refreshed.
    let refresh = start(KeygenMode::Refresh { group_key: [2; 33] }, 2, ids(1..=3));
    assert!(matches!(
        KeygenParticipant::start(session, p(1), &refresh, None, &mut rng),
        Err(ProtocolError::NoKeyShare)
    ));
    let mut net = network(4, 70);
    let group_key = dkg(&mut net, 2, 3);
    let material = net.node(p(1)).unwrap().shares()[&group_key].clone();
    let wrong_group = start(KeygenMode::Refresh { group_key: [2; 33] }, 2, ids(1..=3));
    let wrong_threshold = start(KeygenMode::Refresh { group_key }, 3, ids(1..=3));
    let outsider = start(KeygenMode::Refresh { group_key }, 2, ids(1..=4));
    for s in [&wrong_group, &wrong_threshold, &outsider] {
        assert!(matches!(
            KeygenParticipant::start(session, p(1), s, Some(material.clone()), &mut rng),
            Err(ProtocolError::InvalidParameters(_))
        ));
    }
    // Coordinator side.
    let roster = net.roster().clone();
    assert!(
        KeygenCoordinator::new(
            session,
            start(KeygenMode::Fresh, 2, vec![p(1), p(9)]),
            roster.clone(),
            None
        )
        .is_err()
    );
    assert!(
        KeygenCoordinator::new(
            session,
            start(KeygenMode::Refresh { group_key }, 2, ids(1..=3)),
            roster.clone(),
            None
        )
        .is_err()
    );
    let public = net.group(&group_key).unwrap().clone();
    assert!(
        KeygenCoordinator::new(
            session,
            start(KeygenMode::Refresh { group_key: [2; 33] }, 2, ids(1..=3)),
            roster,
            Some(public)
        )
        .is_err()
    );
}

#[test]
fn signing_parameters_are_validated() {
    let mut rng = ChaCha20Rng::seed_from_u64(71);
    let mut net = network(4, 71);
    let group_key = dkg(&mut net, 3, 4);
    let other_key = dkg(&mut net, 2, 2);
    let public = net.group(&group_key).unwrap().clone();
    let shares = net.node(p(1)).unwrap().shares().clone();
    let request = |signers: Vec<_>, key| SignRequest {
        group_key: key,
        action: withdrawal(1, 1),
        domain: DOMAIN,
        signers,
        approval: None,
    };
    let session = SessionId([2; 16]);
    // Coordinator side.
    assert!(
        SigningCoordinator::new(
            session,
            request(vec![p(1), p(1), p(2)], group_key),
            public.clone()
        )
        .is_err()
    );
    assert!(
        SigningCoordinator::new(session, request(ids(1..=3), other_key), public.clone()).is_err()
    );
    assert!(
        net.sign(group_key, withdrawal(1, 1), DOMAIN, &[p(1), p(2)])
            .is_err()
    );
    // Signer side: every rejection leaves the session unburned.
    let mut signer = SignerState::new(
        SignerPolicy::permissive(DOMAIN),
        SessionJournal::in_memory(),
    );
    for (req, why) in [
        (request(ids(1..=3), other_key), "wrong share set"),
        (request(ids(2..=4), group_key), "not a signer"),
        (request(vec![p(1), p(2), p(2)], group_key), "duplicate"),
        (request(vec![p(1), p(2)], group_key), "below threshold"),
        (request(vec![p(1), p(2), p(9)], group_key), "unknown signer"),
    ] {
        assert!(
            signer
                .on_sign_request(session, p(1), &req, &shares, &mut rng)
                .is_err(),
            "{why}"
        );
    }
    assert!(signer.journal().is_empty());
    // A package for a session committed under another share set is refused.
    let out = signer
        .on_sign_request(
            session,
            p(1),
            &request(ids(1..=3), group_key),
            &shares,
            &mut rng,
        )
        .unwrap();
    let Message::SignCommitment(c) = out.body else {
        panic!()
    };
    let other_material = net.node(p(1)).unwrap().shares()[&other_key].clone();
    let package = frost_keccak::SigningPackage::new(
        [(p(1).identifier(), c.commitments)].into_iter().collect(),
        &withdrawal(1, 1).signing_hash(&DOMAIN),
    );
    assert!(matches!(
        signer.on_sign_package(session, &package, &other_material),
        Err(ProtocolError::PackageMismatch(_))
    ));
}

#[test]
fn repair_parameters_are_validated() {
    let mut rng = ChaCha20Rng::seed_from_u64(72);
    let mut net = network(4, 72);
    let group_key = dkg(&mut net, 2, 4);
    let material = net.node(p(2)).unwrap().shares()[&group_key].clone();
    let session = SessionId([3; 16]);
    let repair = |lost, helpers: Vec<_>| RepairStart {
        group_key,
        lost,
        helpers,
    };
    assert!(
        RepairHelper::start(
            session,
            p(4),
            &repair(p(1), vec![p(2), p(3)]),
            &material,
            net.roster(),
            &mut rng
        )
        .is_err()
    );
    assert!(
        RepairHelper::start(
            session,
            p(2),
            &repair(p(1), vec![p(2), p(9)]),
            &material,
            net.roster(),
            &mut rng
        )
        .is_err()
    );
    let wrong_group = RepairStart {
        group_key: [2; 33],
        lost: p(1),
        helpers: vec![p(2), p(3)],
    };
    assert!(
        RepairHelper::start(
            session,
            p(2),
            &wrong_group,
            &material,
            net.roster(),
            &mut rng
        )
        .is_err()
    );
    assert!(RepairRecipient::start(session, p(2), &repair(p(1), vec![p(2), p(3)])).is_err());
    assert!(RepairRecipient::start(session, p(1), &repair(p(1), vec![p(2), p(2)])).is_err());
    assert!(RepairRecipient::start(session, p(1), &repair(p(1), vec![p(1), p(2)])).is_err());
    let public = net.group(&group_key).unwrap().clone();
    assert!(RepairCoordinator::new(session, repair(p(1), vec![p(2)]), &public).is_err());
}

#[test]
fn silent_participants_are_named_in_every_keygen_phase() {
    for (kind, phase) in [("keygen_round2", "round2"), ("keygen_result", "results")] {
        let mut net = network(3, 73);
        net.set_interceptor(boxed(move |from, _to, env, _keys, _roster| {
            if from == Party::Participant(p(2)) && env.body.kind() == kind {
                return Verdict::Drop;
            }
            Verdict::Deliver
        }));
        let KeygenOutcome::Aborted(report) = net.dkg(2, &ids(1..=3)).unwrap() else {
            panic!("expected abort")
        };
        assert_eq!(report.phase, phase);
        assert_eq!(report.blame.len(), 1);
        assert_eq!(report.blame[0].participant, p(2));
        assert!(matches!(report.blame[0].fault, Fault::Unresponsive { .. }));
    }
}

#[test]
fn silent_signers_and_helpers_are_named() {
    // Signer silent in round two.
    let mut net = network(3, 74);
    let group_key = dkg(&mut net, 2, 3);
    net.set_interceptor(boxed(|from, _to, env, _keys, _roster| {
        if from == Party::Participant(p(1)) && matches!(env.body, Message::SignShare(_)) {
            return Verdict::Drop;
        }
        Verdict::Deliver
    }));
    let SigningOutcome::Aborted(report) = net
        .sign(group_key, withdrawal(1, 1), DOMAIN, &[p(1), p(2)])
        .unwrap()
    else {
        panic!("expected abort")
    };
    assert_eq!(report.phase, "share");
    assert_eq!(report.blame[0].participant, p(1));

    // Repair: a silent helper, then a silent lost participant.
    net.set_interceptor(None);
    net.node_mut(p(3))
        .unwrap()
        .forget_share(&group_key)
        .unwrap();
    net.set_offline(p(2), true);
    let RepairOutcome::Aborted(report) = net.repair(group_key, p(3), &[p(1), p(2)]).unwrap() else {
        panic!("expected abort")
    };
    assert_eq!(report.blame[0].participant, p(2));
    net.set_offline(p(2), false);
    net.set_offline(p(3), true);
    let RepairOutcome::Aborted(report) = net.repair(group_key, p(3), &[p(1), p(2)]).unwrap() else {
        panic!("expected abort")
    };
    assert_eq!(report.phase, "result");
    assert_eq!(report.blame[0].participant, p(3));
    net.set_offline(p(3), false);
    assert_eq!(
        net.repair(group_key, p(3), &[p(1), p(2)]).unwrap(),
        RepairOutcome::Repaired { participant: p(3) }
    );
}

#[test]
fn nodes_refuse_unexpected_or_unknown_messages() {
    let mut net = network(2, 75);
    let group_key = dkg(&mut net, 2, 2);
    // Build a fresh node and feed it messages directly, signed by a coordinator
    // key from a hand-made roster.
    let mut rng = ChaCha20Rng::seed_from_u64(75);
    let generated = custody_protocol::identity::GeneratedRoster::generate(2, &mut rng).unwrap();
    let keys = generated.participants[&p(1)]
        .to_key_file(Party::Participant(p(1)))
        .keys();
    let mut node = custody_protocol::node::ParticipantNode::new(
        p(1),
        keys,
        generated.roster.clone(),
        SignerState::new(
            SignerPolicy::permissive(DOMAIN),
            SessionJournal::in_memory(),
        ),
    )
    .unwrap();
    let send = |node: &mut custody_protocol::node::ParticipantNode,
                body: Message,
                rng: &mut ChaCha20Rng| {
        let env = SignedEnvelope::sign(
            &Envelope::new(
                SessionId([9; 16]),
                Party::Coordinator,
                Recipient::Participant(p(1)),
                body,
            ),
            &generated.coordinator,
        )
        .unwrap();
        node.handle(&env, rng)
    };
    let refused = |replies: Vec<SignedEnvelope>, roster: &Roster| -> String {
        assert_eq!(replies.len(), 1);
        match replies[0].verify(roster).unwrap().envelope.body {
            Message::Refused(r) => r.reason,
            other => panic!("expected a refusal, got {other:?}"),
        }
    };
    let bundle = Bundle { envelopes: vec![] };
    for body in [
        Message::KeygenRound1Bundle(bundle.clone()),
        Message::KeygenRound2Bundle(bundle.clone()),
        Message::RepairDeltaBundle(bundle.clone()),
        Message::RepairSigmaBundle(bundle.clone()),
        Message::SignPackage(custody_protocol::messages::SignPackage {
            package: frost_keccak::SigningPackage::new(Default::default(), &[0u8; 32]),
        }),
    ] {
        let reason = refused(send(&mut node, body, &mut rng), &generated.roster);
        assert!(reason.contains("no pending state"), "{reason}");
    }
    let reason = refused(
        send(
            &mut node,
            Message::SignRequest(SignRequest {
                group_key,
                action: withdrawal(1, 1),
                domain: DOMAIN,
                signers: ids(1..=2),
                approval: None,
            }),
            &mut rng,
        ),
        &generated.roster,
    );
    assert!(reason.contains("no key share"), "{reason}");
    let reason = refused(
        send(
            &mut node,
            Message::Refused(custody_protocol::messages::Refused {
                refused: "x".into(),
                reason: "y".into(),
            }),
            &mut rng,
        ),
        &generated.roster,
    );
    assert!(reason.contains("unexpected"), "{reason}");

    // Envelopes addressed to someone else, or not from the coordinator, are dropped silently.
    let misrouted = SignedEnvelope::sign(
        &Envelope::new(
            SessionId([9; 16]),
            Party::Coordinator,
            Recipient::Participant(p(2)),
            Message::KeygenRound1Bundle(bundle.clone()),
        ),
        &generated.coordinator,
    )
    .unwrap();
    assert!(node.handle(&misrouted, &mut rng).is_empty());
    let from_peer = SignedEnvelope::sign(
        &Envelope::new(
            SessionId([9; 16]),
            Party::Participant(p(2)),
            Recipient::Participant(p(1)),
            Message::KeygenRound1Bundle(bundle),
        ),
        &generated.participants[&p(2)],
    )
    .unwrap();
    assert!(node.handle(&from_peer, &mut rng).is_empty());
    let forged = SignedEnvelope {
        payload: from_peer.payload.clone(),
        signature: [0; 64],
    };
    assert!(node.handle(&forged, &mut rng).is_empty());
}

/// The coordinator opens sessions; a node never keeps more than
/// `MAX_PENDING_SESSIONS` of each kind (the oldest is dropped and zeroised),
/// drops all of them after `SESSION_TTL`, and still refuses to restart any
/// dropped session.
#[test]
fn abandoned_keygen_and_repair_sessions_are_bounded_and_expire() {
    use custody_protocol::signing::{MAX_PENDING_SESSIONS, SESSION_TTL};
    let mut rng = ChaCha20Rng::seed_from_u64(78);
    // A real 2-of-3 group, so the node can act as a repair helper.
    let mut net = network(3, 78);
    let group_key = dkg(&mut net, 2, 3);
    let material = net.node(p(1)).unwrap().shares()[&group_key].clone();
    // The same participant ids under a roster whose coordinator key we hold.
    let generated = custody_protocol::identity::GeneratedRoster::generate(3, &mut rng).unwrap();
    let keys = generated.participants[&p(1)]
        .to_key_file(Party::Participant(p(1)))
        .keys();
    let mut node = custody_protocol::node::ParticipantNode::new(
        p(1),
        keys,
        generated.roster.clone(),
        SignerState::new(
            SignerPolicy::permissive(DOMAIN),
            SessionJournal::in_memory(),
        ),
    )
    .unwrap();
    node.install_share(material).unwrap();
    let send = |node: &mut custody_protocol::node::ParticipantNode,
                session: SessionId,
                body: Message,
                rng: &mut ChaCha20Rng| {
        let env = SignedEnvelope::sign(
            &Envelope::new(
                session,
                Party::Coordinator,
                Recipient::Participant(p(1)),
                body,
            ),
            &generated.coordinator,
        )
        .unwrap();
        node.handle(&env, rng)
    };
    let session = |kind: u8, i: usize| {
        let mut id = [kind; 16];
        id[8..].copy_from_slice(&(i as u64).to_be_bytes());
        SessionId(id)
    };
    let extra = 6;
    for i in 0..MAX_PENDING_SESSIONS + extra {
        let replies = send(
            &mut node,
            session(1, i),
            Message::KeygenStart(start(KeygenMode::Fresh, 2, ids(1..=3))),
            &mut rng,
        );
        assert!(matches!(
            replies[0].verify(&generated.roster).unwrap().envelope.body,
            Message::KeygenRound1(_)
        ));
        let helper = send(
            &mut node,
            session(2, i),
            Message::RepairStart(RepairStart {
                group_key,
                lost: p(3),
                helpers: vec![p(1), p(2)],
            }),
            &mut rng,
        );
        assert!(matches!(
            helper[0].verify(&generated.roster).unwrap().envelope.body,
            Message::RepairDeltas(_)
        ));
        assert!(
            send(
                &mut node,
                session(3, i),
                Message::RepairStart(RepairStart {
                    group_key,
                    lost: p(1),
                    helpers: vec![p(2), p(3)],
                }),
                &mut rng,
            )
            .is_empty()
        );
    }
    let pending = node.pending_sessions();
    assert_eq!(pending.keygen, MAX_PENDING_SESSIONS);
    assert_eq!(pending.repair_helper, MAX_PENDING_SESSIONS);
    assert_eq!(pending.repair_recipient, MAX_PENDING_SESSIONS);
    assert_eq!(
        node.signer().journal().len(),
        3 * (MAX_PENDING_SESSIONS + extra)
    );
    // An evicted session cannot be restarted either.
    let replay = send(
        &mut node,
        session(1, 0),
        Message::KeygenStart(start(KeygenMode::Fresh, 2, ids(1..=3))),
        &mut rng,
    );
    match &replay[0].verify(&generated.roster).unwrap().envelope.body {
        Message::Refused(r) => assert!(r.reason.contains("already used"), "{}", r.reason),
        other => panic!("evicted session restarted: {other:?}"),
    }
    // Nothing expires early; everything expires after the TTL.
    let now = std::time::Instant::now();
    assert_eq!(node.expire_sessions_at(now, SESSION_TTL), 0);
    let dropped = node.expire_sessions_at(now + SESSION_TTL + Duration::from_secs(1), SESSION_TTL);
    assert_eq!(dropped, 3 * MAX_PENDING_SESSIONS);
    assert_eq!(
        node.pending_sessions(),
        custody_protocol::node::PendingSessions::default()
    );
}

/// A coordinator that drops an envelope from a relayed bundle is refused.
#[test]
fn incomplete_bundles_are_refused() {
    let mut net = network(3, 76);
    net.set_interceptor(boxed(|from, to, env, _keys, _roster| {
        if from == Party::Coordinator
            && to == Party::Participant(p(1))
            && let Message::KeygenRound1Bundle(bundle) = &mut env.body
        {
            bundle.envelopes.pop();
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let KeygenOutcome::Aborted(report) = net.dkg(2, &ids(1..=3)).unwrap() else {
        panic!("expected abort")
    };
    assert!(
        report.culprits().is_empty(),
        "an honest participant is never blamed for the relay"
    );
    assert!(
        matches!(&report.blame[0].fault, Fault::Declined { reason } if reason.contains("bundle"))
    );
}

/// Records the kind of every message in flight.
struct Kinds(
    Rc<RefCell<BTreeSet<&'static str>>>,
    Rc<RefCell<Vec<SignedEnvelope>>>,
);

impl Interceptor for Kinds {
    fn intercept(
        &mut self,
        _from: Party,
        _to: Party,
        envelope: SignedEnvelope,
        _keys: &PartyKeys,
        roster: &Roster,
    ) -> Vec<SignedEnvelope> {
        if let Ok(v) = envelope.verify(roster) {
            self.0.borrow_mut().insert(v.body().kind());
        }
        self.1.borrow_mut().push(envelope.clone());
        vec![envelope]
    }
}

#[test]
fn a_full_lifecycle_exercises_every_message_type() {
    let kinds = Rc::new(RefCell::new(BTreeSet::new()));
    let log = Rc::new(RefCell::new(Vec::new()));
    let mut net = network(3, 77);
    net.set_interceptor(Some(Box::new(Kinds(kinds.clone(), log.clone()))));
    let group_key = dkg(&mut net, 2, 3);
    assert!(matches!(
        net.sign(group_key, withdrawal(1, 1), DOMAIN, &[p(1), p(2)])
            .unwrap(),
        SigningOutcome::Signed { .. }
    ));
    // A refusal (wrong vault).
    let mut other = DOMAIN;
    other.chain_id = 1;
    assert!(matches!(
        net.sign(group_key, withdrawal(2, 1), other, &[p(1), p(2)])
            .unwrap(),
        SigningOutcome::Aborted(_)
    ));
    net.node_mut(p(3))
        .unwrap()
        .forget_share(&group_key)
        .unwrap();
    assert!(matches!(
        net.repair(group_key, p(3), &[p(1), p(2)]).unwrap(),
        RepairOutcome::Repaired { .. }
    ));
    // A reveal: P2 garbles the box it sends to P1 in a second DKG.
    net.set_interceptor(None);
    let kinds2 = kinds.clone();
    let log2 = log.clone();
    net.set_interceptor(Some(Box::new(GarbleThenRecord(Kinds(kinds2, log2)))));
    assert!(matches!(
        net.dkg(2, &ids(1..=3)).unwrap(),
        KeygenOutcome::Aborted(_)
    ));

    let seen = kinds.borrow();
    let expected = [
        "keygen_start",
        "keygen_round1",
        "keygen_round1_bundle",
        "keygen_round2",
        "keygen_round2_bundle",
        "keygen_result",
        "keygen_reveal_request",
        "keygen_reveal",
        "keygen_finished",
        "sign_request",
        "sign_commitment",
        "sign_package",
        "sign_share",
        "refused",
        "repair_start",
        "repair_deltas",
        "repair_delta_bundle",
        "repair_sigma",
        "repair_sigma_bundle",
        "repair_result",
    ];
    for kind in expected {
        assert!(seen.contains(kind), "{kind} never seen");
    }
    assert_eq!(seen.len(), expected.len());
    // Every recorded envelope decodes, re-encodes identically and verifies.
    for env in log.borrow().iter() {
        let decoded: Envelope = serde_json::from_str(&env.payload).unwrap();
        let reencoded = serde_json::to_string(&decoded).unwrap();
        assert_eq!(reencoded, env.payload);
        env.verify(net.roster()).unwrap();
    }
}

struct GarbleThenRecord(Kinds);

impl Interceptor for GarbleThenRecord {
    fn intercept(
        &mut self,
        from: Party,
        to: Party,
        envelope: SignedEnvelope,
        keys: &PartyKeys,
        roster: &Roster,
    ) -> Vec<SignedEnvelope> {
        let mut out = envelope;
        if from == Party::Participant(p(2))
            && let Ok(v) = out.verify(roster)
            && let Message::KeygenRound2(mut r2) = v.envelope.body.clone()
        {
            for b in &mut r2.shares {
                if b.to == p(1) {
                    b.sealed.ciphertext[0] ^= 1;
                }
            }
            let mut e = v.envelope;
            e.body = Message::KeygenRound2(r2);
            out = SignedEnvelope::sign(&e, keys).unwrap();
        }
        self.0.intercept(from, to, out, keys, roster)
    }
}
