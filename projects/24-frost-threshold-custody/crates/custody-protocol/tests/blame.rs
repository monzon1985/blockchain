// SPDX-License-Identifier: MIT
//! Third-party verification of blame: genuine evidence verifies, and every
//! way of misusing evidence (wrong session, wrong party, missing context,
//! evidence that shows no fault) is rejected.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use common::*;
use custody_protocol::{
    Party, SessionId,
    blame::{AbortReport, Blame, BlameContext, BlameError, Dispute, Evidence, Fault},
    envelope::{Envelope, Recipient, SignedEnvelope},
    keygen::KeygenOutcome,
    messages::{KeygenMode, Message, Refused},
    signing::SigningOutcome,
};

fn aborted(outcome: KeygenOutcome) -> AbortReport {
    match outcome {
        KeygenOutcome::Aborted(report) => report,
        KeygenOutcome::Committed { .. } => panic!("expected an abort"),
    }
}

fn ctx<'a>(
    net: &'a custody_protocol::local::LocalNetwork<rand_chacha::ChaCha20Rng>,
    session: SessionId,
) -> BlameContext<'a> {
    BlameContext {
        roster: net.roster(),
        session,
        keygen_mode: Some(KeygenMode::Fresh),
        signing: None,
    }
}

#[test]
fn keygen_evidence_is_bound_to_session_mode_and_party() {
    // Dealer P2 publishes an invalid proof of knowledge.
    let mut net = network(3, 60);
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
    let report = aborted(net.dkg(2, &ids(1..=3)).unwrap());
    let blame = report.blame[0].clone();
    assert_eq!(
        blame.verify(&ctx(&net, report.session)),
        Ok(Evidence::Conclusive)
    );

    // Another session.
    assert_eq!(
        blame.verify(&ctx(&net, SessionId([7; 16]))),
        Err(BlameError::WrongSession)
    );
    // Refresh mode has no proof of knowledge to check.
    let mut refresh = ctx(&net, report.session);
    refresh.keygen_mode = Some(KeygenMode::Refresh { group_key: [2; 33] });
    assert!(matches!(
        blame.verify(&refresh),
        Err(BlameError::MissingContext(_))
    ));
    // Pinned on another party.
    let framed = Blame {
        participant: p(1),
        ..blame.clone()
    };
    assert!(matches!(
        framed.verify(&ctx(&net, report.session)),
        Err(BlameError::Unsigned(_))
    ));

    // An honest dealer's round-one envelope does not demonstrate an invalid PoK:
    // replay the DKG honestly and pin P1's valid package on P1.
    net.set_interceptor(None);
    let mut honest = network(3, 60);
    let envelopes = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let sink = envelopes.clone();
    honest.set_interceptor(Some(Box::new(Recorder(sink))));
    assert!(matches!(
        honest.dkg(2, &ids(1..=3)).unwrap(),
        KeygenOutcome::Committed { .. }
    ));
    let recorded = envelopes.borrow();
    let (session, round1) = recorded
        .iter()
        .find_map(|(from, env)| {
            let v = env.verify(honest.roster()).ok()?;
            (matches!(v.body(), Message::KeygenRound1(_)) && *from == Party::Participant(p(1)))
                .then(|| (v.session(), env.clone()))
        })
        .unwrap();
    let not_a_fault = Blame {
        participant: p(1),
        fault: Fault::InvalidProofOfKnowledge {
            round1: round1.clone(),
        },
    };
    assert!(matches!(
        not_a_fault.verify(&ctx(&honest, session)),
        Err(BlameError::NotDemonstrated(_))
    ));
    // Non-conflicting "equivocation" (the same message twice).
    let same = Blame {
        participant: p(1),
        fault: Fault::Equivocation {
            first: round1.clone(),
            second: round1.clone(),
        },
    };
    assert!(matches!(
        same.verify(&ctx(&honest, session)),
        Err(BlameError::NotDemonstrated(_))
    ));
    // A round-one envelope offered as round-two evidence.
    for fault in [
        Fault::MissingShare {
            round2: round1.clone(),
            recipient: p(2),
            round1_set: vec![round1.clone()],
        },
        Fault::InconsistentBroadcast {
            round2: round1.clone(),
            round1_set: vec![round1.clone()],
        },
    ] {
        let b = Blame {
            participant: p(1),
            fault,
        };
        assert!(matches!(
            b.verify(&ctx(&honest, session)),
            Err(BlameError::NotDemonstrated(_))
        ));
    }
    // Transcript-dependent faults only establish that the blamed party signed
    // the message in this session; they are never reported as conclusive.
    for fault in [
        Fault::MalformedMessage {
            envelope: round1.clone(),
            detail: "x".into(),
        },
        Fault::FalseComplaint {
            complaint: round1.clone(),
            dealer: p(2),
        },
        Fault::InconsistentResult {
            result: round1.clone(),
        },
        Fault::FailedReveal {
            recipient: p(2),
            reveal: Some(round1.clone()),
        },
    ] {
        let b = Blame {
            participant: p(1),
            fault,
        };
        assert_eq!(b.verify(&ctx(&honest, session)), Ok(Evidence::SignedOnly));
        assert_eq!(
            b.verify(&ctx(&honest, SessionId([1; 16]))),
            Err(BlameError::WrongSession)
        );
    }
    // An honest participant's round-two digest matches the recomputed digest
    // of the round-one set, so it cannot be framed as inconsistent.
    let (_, round2) = recorded
        .iter()
        .find(|(from, env)| {
            *from == Party::Participant(p(3))
                && matches!(
                    env.verify(honest.roster()).map(|v| v.envelope.body),
                    Ok(Message::KeygenRound2(_))
                )
        })
        .unwrap();
    let round1_set: Vec<SignedEnvelope> = recorded
        .iter()
        .filter(|(from, env)| {
            matches!(from, Party::Participant(_))
                && matches!(
                    env.verify(honest.roster()).map(|v| v.envelope.body),
                    Ok(Message::KeygenRound1(_))
                )
        })
        .map(|(_, env)| env.clone())
        .collect();
    assert_eq!(round1_set.len(), 3);
    let framed_digest = Blame {
        participant: p(3),
        fault: Fault::InconsistentBroadcast {
            round2: round2.clone(),
            round1_set: round1_set.clone(),
        },
    };
    assert!(matches!(
        framed_digest.verify(&ctx(&honest, session)),
        Err(BlameError::NotDemonstrated(_))
    ));
    let incomplete = Blame {
        participant: p(3),
        fault: Fault::InconsistentBroadcast {
            round2: round2.clone(),
            round1_set: round1_set[..1].to_vec(),
        },
    };
    assert!(incomplete.verify(&ctx(&honest, session)).is_err());
    let present = Blame {
        participant: p(3),
        fault: Fault::MissingShare {
            round2: round2.clone(),
            recipient: p(1),
            round1_set: round1_set.clone(),
        },
    };
    assert!(matches!(
        present.verify(&ctx(&honest, session)),
        Err(BlameError::NotDemonstrated(_))
    ));
}

#[test]
fn liveness_faults_are_not_provable() {
    let mut net = network(2, 61);
    let session = SessionId([3; 16]);
    for fault in [
        Fault::Unresponsive {
            phase: "round1".into(),
        },
        Fault::Declined {
            reason: "policy".into(),
        },
        Fault::FailedReveal {
            recipient: p(2),
            reveal: None,
        },
    ] {
        assert!(!fault.is_provable());
        let b = Blame {
            participant: p(1),
            fault,
        };
        assert_eq!(b.verify(&ctx(&net, session)), Err(BlameError::NotProvable));
    }
    assert!(
        !Fault::Declined {
            reason: String::new()
        }
        .is_misbehaviour()
    );
    assert!(
        Fault::Unresponsive {
            phase: String::new()
        }
        .is_misbehaviour()
    );

    // Envelopes signed by the coordinator are never evidence against a participant.
    let coordinator_env = SignedEnvelope::sign(
        &Envelope::new(
            session,
            Party::Coordinator,
            Recipient::Participant(p(1)),
            Message::Refused(Refused {
                refused: "x".into(),
                reason: "y".into(),
            }),
        ),
        &custody_protocol::identity::PartyKeys::generate(net.rng()),
    )
    .unwrap();
    let b = Blame {
        participant: p(1),
        fault: Fault::InconsistentResult {
            result: coordinator_env,
        },
    };
    assert!(matches!(
        b.verify(&ctx(&net, session)),
        Err(BlameError::Unsigned(_))
    ));
}

#[test]
fn every_fault_has_a_stable_label() {
    let env = SignedEnvelope {
        payload: String::new(),
        signature: [0; 64],
    };
    let statement = custody_protocol::messages::SignedShareStatement {
        statement: String::new(),
        signature: [0; 64],
    };
    let faults = vec![
        Fault::Unresponsive {
            phase: String::new(),
        },
        Fault::Declined {
            reason: String::new(),
        },
        Fault::Equivocation {
            first: env.clone(),
            second: env.clone(),
        },
        Fault::MalformedMessage {
            envelope: env.clone(),
            detail: String::new(),
        },
        Fault::InvalidProofOfKnowledge {
            round1: env.clone(),
        },
        Fault::InconsistentBroadcast {
            round2: env.clone(),
            round1_set: vec![],
        },
        Fault::MissingShare {
            round2: env.clone(),
            recipient: p(1),
            round1_set: vec![],
        },
        Fault::InvalidShare {
            statement,
            round1: env.clone(),
        },
        Fault::FalseComplaint {
            complaint: env.clone(),
            dealer: p(1),
        },
        Fault::FailedReveal {
            recipient: p(1),
            reveal: None,
        },
        Fault::InconsistentResult {
            result: env.clone(),
        },
        Fault::InvalidSignatureShare { share: env },
    ];
    let labels: std::collections::BTreeSet<_> = faults.iter().map(Fault::label).collect();
    assert_eq!(labels.len(), faults.len(), "labels are unique");
    for f in &faults {
        let json = serde_json::to_string(f).unwrap();
        assert!(json.contains(f.label()), "{json}");
        let back: Fault = serde_json::from_str(&json).unwrap();
        assert_eq!(&back, f);
    }
    let report = AbortReport {
        session: SessionId([0; 16]),
        phase: "x".into(),
        blame: vec![
            Blame {
                participant: p(1),
                fault: faults[1].clone(),
            },
            Blame {
                participant: p(2),
                fault: faults[0].clone(),
            },
        ],
        disputes: vec![Dispute {
            dealer: p(3),
            recipient: p(4),
        }],
        note: None,
    };
    assert_eq!(
        report.culprits().into_iter().collect::<Vec<_>>(),
        vec![p(2)]
    );
    assert_eq!(report.excluded().len(), 4);
}

#[test]
fn signing_evidence_needs_the_signing_context() {
    let mut net = network(3, 62);
    let group_key = dkg(&mut net, 2, 3);
    net.set_interceptor(boxed(|from, _to, env, _keys, _roster| {
        if from == Party::Participant(p(1))
            && let Message::SignShare(s) = &mut env.body
        {
            s.share = frost_keccak::round2::SignatureShare::deserialize(&[9u8; 32]).unwrap();
            return Verdict::Resign;
        }
        Verdict::Deliver
    }));
    let SigningOutcome::Aborted(report) = net
        .sign(group_key, withdrawal(1, 1), DOMAIN, &[p(1), p(2)])
        .unwrap()
    else {
        panic!("expected abort")
    };
    let blame = &report.blame[0];
    assert!(matches!(
        blame.verify(&ctx(&net, report.session)),
        Err(BlameError::MissingContext(_))
    ));
    let package = net.last_signing_package().unwrap().clone();
    let public = net.group(&group_key).unwrap().clone();
    let full = BlameContext {
        roster: net.roster(),
        session: report.session,
        keygen_mode: None,
        signing: Some((&package, &public)),
    };
    blame.verify(&full).unwrap();
    // An honest signer's valid share offered as evidence does not demonstrate a fault.
    net.set_interceptor(None);
    let recorded = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    net.set_interceptor(Some(Box::new(Recorder(recorded.clone()))));
    assert!(matches!(
        net.sign(group_key, withdrawal(2, 1), DOMAIN, &[p(1), p(2)])
            .unwrap(),
        SigningOutcome::Signed { .. }
    ));
    let (session, share) = recorded
        .borrow()
        .iter()
        .find_map(|(from, env)| {
            let v = env.verify(net.roster()).ok()?;
            (*from == Party::Participant(p(2)) && matches!(v.body(), Message::SignShare(_)))
                .then(|| (v.session(), env.clone()))
        })
        .unwrap();
    let package = net.last_signing_package().unwrap().clone();
    let honest = Blame {
        participant: p(2),
        fault: Fault::InvalidSignatureShare { share },
    };
    let full = BlameContext {
        roster: net.roster(),
        session,
        keygen_mode: None,
        signing: Some((&package, &public)),
    };
    assert!(matches!(
        honest.verify(&full),
        Err(BlameError::NotDemonstrated(_))
    ));
}

/// Two honest refusals in one session (the node refuses every unexpected
/// message) and two honest reveals by one dealer to two complainants are
/// not equivocation.
#[test]
fn honest_repeated_answers_are_not_equivocation() {
    use rand_core::SeedableRng;
    let mut rng = rand_chacha::ChaCha20Rng::seed_from_u64(63);
    let generated = custody_protocol::identity::GeneratedRoster::generate(2, &mut rng).unwrap();
    let mut node = custody_protocol::node::ParticipantNode::new(
        p(1),
        generated.participants[&p(1)]
            .to_key_file(Party::Participant(p(1)))
            .keys(),
        generated.roster.clone(),
        custody_protocol::signing::SignerState::new(
            custody_protocol::intent::SignerPolicy::permissive(DOMAIN),
            custody_protocol::signing::SessionJournal::in_memory(),
        ),
    )
    .unwrap();
    let session = SessionId([9; 16]);
    let mut refusals = Vec::new();
    for body in [
        Message::KeygenRound1Bundle(custody_protocol::messages::Bundle { envelopes: vec![] }),
        Message::KeygenRound2Bundle(custody_protocol::messages::Bundle { envelopes: vec![] }),
    ] {
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
        let mut replies = node.handle(&env, &mut rng);
        assert_eq!(replies.len(), 1);
        refusals.push(replies.remove(0));
    }
    assert_ne!(refusals[0].payload, refusals[1].payload);
    let refusal_ctx = BlameContext {
        roster: &generated.roster,
        session,
        keygen_mode: Some(KeygenMode::Fresh),
        signing: None,
    };
    let framed = Blame {
        participant: p(1),
        fault: Fault::Equivocation {
            first: refusals[0].clone(),
            second: refusals[1].clone(),
        },
    };
    assert!(matches!(
        framed.verify(&refusal_ctx),
        Err(BlameError::NotDemonstrated(_))
    ));

    // Dealer P2 garbles the boxes for P1 and P3, then honestly reveals both
    // statements when the complaints arrive: two different reveals.
    let mut net = network(3, 64);
    let recorded = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    net.set_interceptor(Some(Box::new(GarbleForAll(
        p(2),
        Recorder(recorded.clone()),
    ))));
    let report = aborted(net.dkg(2, &ids(1..=3)).unwrap());
    assert_eq!(report.disputes.len(), 2, "{report:?}");
    let reveals: Vec<SignedEnvelope> = recorded
        .borrow()
        .iter()
        .filter(|(from, env)| {
            *from == Party::Participant(p(2))
                && matches!(
                    env.verify(net.roster()).map(|v| v.envelope.body),
                    Ok(Message::KeygenReveal(_))
                )
        })
        .map(|(_, env)| env.clone())
        .collect();
    assert_eq!(reveals.len(), 2);
    let framed = Blame {
        participant: p(2),
        fault: Fault::Equivocation {
            first: reveals[0].clone(),
            second: reveals[1].clone(),
        },
    };
    assert!(matches!(
        framed.verify(&ctx(&net, report.session)),
        Err(BlameError::NotDemonstrated(_))
    ));
}

/// A replayed `KeygenStart` (from a network attacker or the coordinator)
/// never makes an honest participant produce a second round-one package for
/// a session, even after the session finished and its state was dropped.
#[test]
fn replayed_keygen_start_is_refused_after_the_session() {
    let mut net = network(3, 65);
    let recorded = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    net.set_interceptor(Some(Box::new(Recorder(recorded.clone()))));
    assert!(matches!(
        net.dkg(2, &ids(1..=3)).unwrap(),
        KeygenOutcome::Committed { .. }
    ));
    net.set_interceptor(None);
    let start = recorded
        .borrow()
        .iter()
        .find_map(|(from, env)| {
            let v = env.verify(net.roster()).ok()?;
            (*from == Party::Coordinator
                && v.envelope.to == Recipient::Participant(p(1))
                && matches!(v.body(), Message::KeygenStart(_)))
            .then(|| env.clone())
        })
        .unwrap();
    let mut rng = <rand_chacha::ChaCha20Rng as rand_core::SeedableRng>::seed_from_u64(1);
    let replies = net.node_mut(p(1)).unwrap().handle(&start, &mut rng);
    assert_eq!(replies.len(), 1);
    match replies[0].verify(net.roster()).unwrap().envelope.body {
        Message::Refused(r) => assert!(r.reason.contains("already used"), "{}", r.reason),
        other => panic!("replay answered with {other:?}"),
    }
}

/// `MissingShare` evidence is checked against the member set the dealer
/// itself attested to (the digest of the round-one set in its signed
/// round-two message): naming the dealer itself, a non-member, or pairing the
/// message with another round-one set cannot frame an honest dealer.
#[test]
fn missing_share_blame_cannot_frame_an_honest_dealer() {
    let mut net = network(3, 66);
    let recorded = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    net.set_interceptor(Some(Box::new(Recorder(recorded.clone()))));
    assert!(matches!(
        net.dkg(2, &ids(1..=3)).unwrap(),
        KeygenOutcome::Committed { .. }
    ));
    let recorded = recorded.borrow();
    let from_participants = |kind: &str| -> Vec<(Party, SignedEnvelope, SessionId)> {
        recorded
            .iter()
            .filter_map(|(from, env)| {
                let v = env.verify(net.roster()).ok()?;
                (matches!(from, Party::Participant(_)) && v.body().kind() == kind)
                    .then(|| (*from, env.clone(), v.session()))
            })
            .collect()
    };
    let round1_set: Vec<SignedEnvelope> = from_participants("keygen_round1")
        .into_iter()
        .map(|(_, env, _)| env)
        .collect();
    assert_eq!(round1_set.len(), 3);
    let (_, round2, session) = from_participants("keygen_round2")
        .into_iter()
        .find(|(from, _, _)| *from == Party::Participant(p(1)))
        .unwrap();
    let blame = |recipient, set: Vec<SignedEnvelope>| Blame {
        participant: p(1),
        fault: Fault::MissingShare {
            round2: round2.clone(),
            recipient,
            round1_set: set,
        },
    };
    for (recipient, set, why) in [
        (p(1), round1_set.clone(), "the dealer itself"),
        (p(9), round1_set.clone(), "a non-member"),
        (p(2), round1_set.clone(), "a member with a box"),
        (p(9), round1_set[..2].to_vec(), "another member set"),
    ] {
        assert!(
            matches!(
                blame(recipient, set).verify(&ctx(&net, session)),
                Err(BlameError::NotDemonstrated(_))
            ),
            "framed via {why}"
        );
    }
}

/// Seals garbage for every recipient of `dealer`'s round-two message.
struct GarbleForAll(custody_protocol::ParticipantId, Recorder);

impl custody_protocol::local::Interceptor for GarbleForAll {
    fn intercept(
        &mut self,
        from: Party,
        to: Party,
        envelope: SignedEnvelope,
        keys: &custody_protocol::identity::PartyKeys,
        roster: &custody_protocol::identity::Roster,
    ) -> Vec<SignedEnvelope> {
        let mut out = envelope;
        if from == Party::Participant(self.0)
            && let Ok(v) = out.verify(roster)
            && let Message::KeygenRound2(mut r2) = v.envelope.body.clone()
        {
            for b in &mut r2.shares {
                b.sealed.ciphertext[0] ^= 1;
            }
            let mut e = v.envelope;
            e.body = Message::KeygenRound2(r2);
            out = SignedEnvelope::sign(&e, keys).unwrap();
        }
        self.1.intercept(from, to, out, keys, roster)
    }
}

/// Records every envelope in flight (sender, envelope) and delivers it unchanged.
struct Recorder(std::rc::Rc<std::cell::RefCell<Vec<(Party, SignedEnvelope)>>>);

impl custody_protocol::local::Interceptor for Recorder {
    fn intercept(
        &mut self,
        from: Party,
        _to: Party,
        envelope: SignedEnvelope,
        _sender_keys: &custody_protocol::identity::PartyKeys,
        _roster: &custody_protocol::identity::Roster,
    ) -> Vec<SignedEnvelope> {
        self.0.borrow_mut().push((from, envelope.clone()));
        vec![envelope]
    }
}
