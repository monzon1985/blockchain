// SPDX-License-Identifier: MIT
//! A malicious coordinator (holding the coordinator's signing key, so every
//! message it injects authenticates) tries to break confidentiality and
//! authorisation: harvest DKG shares with unsolicited reveal requests,
//! commit a session in which a share was revealed, and get the honest group
//! to rotate the vault to a key it controls. Every attempt must fail.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

use alloy_primitives::U256;
use common::*;
use custody_protocol::{
    ParticipantId, Party,
    blame::Fault,
    envelope::{Envelope, Recipient, SignedEnvelope},
    identity::{PartyKeys, Roster},
    intent::{Approval, CustodyAction, SignerPolicy, rotation_to},
    keygen::{KeygenOutcome, group_key_bytes},
    local::Interceptor,
    messages::{Complaint, ComplaintReason, KeygenFinished, KeygenResult, Message, RevealRequest},
    signing::SigningOutcome,
};
use frost_keccak::evm::{self, EvmGroupKey};
use rand_chacha::ChaCha20Rng;
use rand_core::SeedableRng;

type Shared<T> = Rc<RefCell<T>>;

fn coordinator_envelope(
    session: custody_protocol::SessionId,
    to: ParticipantId,
    body: Message,
    keys: &PartyKeys,
) -> SignedEnvelope {
    SignedEnvelope::sign(
        &Envelope::new(
            session,
            Party::Coordinator,
            Recipient::Participant(to),
            body,
        ),
        keys,
    )
    .unwrap()
}

/// Before delivering the commit certificate to each dealer, the coordinator
/// asks it to reveal the share it sent to every other participant, backed by
/// every kind of "evidence" it can produce on its own.
struct HarvestReveals {
    n: u16,
    results: Shared<BTreeMap<ParticipantId, SignedEnvelope>>,
    reveals: Shared<Vec<SignedEnvelope>>,
    refusals: Shared<Vec<String>>,
}

impl Interceptor for HarvestReveals {
    fn intercept(
        &mut self,
        from: Party,
        to: Party,
        envelope: SignedEnvelope,
        keys: &PartyKeys,
        roster: &Roster,
    ) -> Vec<SignedEnvelope> {
        let Ok(v) = envelope.verify(roster) else {
            return vec![envelope];
        };
        match (from, v.body()) {
            (Party::Participant(p), Message::KeygenResult(_)) => {
                self.results.borrow_mut().insert(p, envelope.clone());
            }
            (Party::Participant(_), Message::KeygenReveal(_)) => {
                self.reveals.borrow_mut().push(envelope.clone());
            }
            (Party::Participant(_), Message::Refused(r))
                if r.refused == "keygen_reveal_request" =>
            {
                self.refusals.borrow_mut().push(r.reason.clone());
            }
            (Party::Coordinator, Message::KeygenFinished(_)) => {
                let Party::Participant(dealer) = to else {
                    return vec![envelope];
                };
                let mut out = Vec::new();
                for j in ids(1..=self.n).into_iter().filter(|j| *j != dealer) {
                    // (a) the complainant's genuine, but successful, result;
                    let honest = self.results.borrow()[&j].clone();
                    // (b) an undecryptable complaint "by j" that the
                    //     coordinator signs itself;
                    let mut forged = Envelope::new(
                        v.session(),
                        Party::Participant(j),
                        Recipient::Coordinator,
                        Message::KeygenResult(KeygenResult::Complaints {
                            complaints: vec![Complaint {
                                dealer,
                                reason: ComplaintReason::Undecryptable,
                            }],
                        }),
                    );
                    let forged_by_coordinator = SignedEnvelope::sign(&forged, keys).unwrap();
                    // (c) the same complaint, openly from the coordinator.
                    forged.from = Party::Coordinator;
                    let from_coordinator = SignedEnvelope::sign(&forged, keys).unwrap();
                    for complaint in [honest, forged_by_coordinator, from_coordinator] {
                        out.push(coordinator_envelope(
                            v.session(),
                            dealer,
                            Message::KeygenRevealRequest(RevealRequest {
                                recipient: j,
                                complaint,
                            }),
                            keys,
                        ));
                    }
                }
                out.push(envelope);
                return out;
            }
            _ => {}
        }
        vec![envelope]
    }
}

/// Reviewer PoC 1, inverted: with t < n, `n-1` revealed points of every
/// dealer's polynomial would let the coordinator interpolate the group
/// secret. No dealer reveals anything without the complainant's own signed
/// undecryptable complaint, so the DKG commits and nothing leaks.
#[test]
fn unsolicited_reveal_requests_are_refused() {
    let n = 5;
    let mut net = network(n, 400);
    let results = Rc::new(RefCell::new(BTreeMap::new()));
    let reveals = Rc::new(RefCell::new(Vec::new()));
    let refusals = Rc::new(RefCell::new(Vec::new()));
    net.set_interceptor(Some(Box::new(HarvestReveals {
        n,
        results,
        reveals: reveals.clone(),
        refusals: refusals.clone(),
    })));
    let KeygenOutcome::Committed { public_key_package } = net.dkg(3, &ids(1..=n)).unwrap() else {
        panic!("the DKG itself is honest and must commit");
    };
    assert!(reveals.borrow().is_empty(), "a dealer revealed a share");
    let refusals = refusals.borrow();
    assert_eq!(refusals.len(), usize::from(n * (n - 1) * 3));
    assert!(refusals.iter().all(|r| {
        r.contains("undecryptable complaint")
            || r.contains("bad signature")
            || r.contains("not allowed")
    }));
    // The session was not poisoned: every participant committed.
    let group_key = group_key_bytes(&public_key_package).unwrap();
    for id in ids(1..=n) {
        assert!(net.node(id).unwrap().shares().contains_key(&group_key));
    }
}

/// A corrupt participant (P3) colluding with the coordinator signs an
/// undecryptable complaint against P1 but reports success to the session.
/// P1 must honour the signed complaint, which only discloses the share P3
/// already holds, and then refuse to commit the poisoned session.
struct CorruptComplainant {
    forged: Shared<Option<SignedEnvelope>>,
    reveals: Shared<Vec<SignedEnvelope>>,
    finished_refusals: Shared<Vec<String>>,
}

impl Interceptor for CorruptComplainant {
    fn intercept(
        &mut self,
        from: Party,
        to: Party,
        envelope: SignedEnvelope,
        keys: &PartyKeys,
        roster: &Roster,
    ) -> Vec<SignedEnvelope> {
        let Ok(v) = envelope.verify(roster) else {
            return vec![envelope];
        };
        match (from, v.body()) {
            (Party::Participant(p), Message::KeygenResult(KeygenResult::Success { .. }))
                if p == common::p(3) =>
            {
                let mut complaint = v.envelope.clone();
                complaint.body = Message::KeygenResult(KeygenResult::Complaints {
                    complaints: vec![Complaint {
                        dealer: common::p(1),
                        reason: ComplaintReason::Undecryptable,
                    }],
                });
                *self.forged.borrow_mut() = Some(SignedEnvelope::sign(&complaint, keys).unwrap());
            }
            (Party::Coordinator, Message::KeygenFinished(KeygenFinished::Committed { .. }))
                if to == Party::Participant(common::p(1)) =>
            {
                let complaint = self.forged.borrow().clone().unwrap();
                let request = coordinator_envelope(
                    v.session(),
                    common::p(1),
                    Message::KeygenRevealRequest(RevealRequest {
                        recipient: common::p(3),
                        complaint,
                    }),
                    keys,
                );
                return vec![request, envelope];
            }
            (Party::Participant(_), Message::KeygenReveal(_)) => {
                self.reveals.borrow_mut().push(envelope.clone());
            }
            (Party::Participant(_), Message::Refused(r)) if r.refused == "keygen_finished" => {
                self.finished_refusals.borrow_mut().push(r.reason.clone());
            }
            _ => {}
        }
        vec![envelope]
    }
}

#[test]
fn a_session_with_a_reveal_never_commits() {
    let mut net = network(5, 401);
    let reveals = Rc::new(RefCell::new(Vec::new()));
    let finished_refusals = Rc::new(RefCell::new(Vec::new()));
    net.set_interceptor(Some(Box::new(CorruptComplainant {
        forged: Rc::new(RefCell::new(None)),
        reveals: reveals.clone(),
        finished_refusals: finished_refusals.clone(),
    })));
    let KeygenOutcome::Committed { public_key_package } = net.dkg(3, &ids(1..=5)).unwrap() else {
        panic!("the coordinator reports a commit");
    };
    let group_key = group_key_bytes(&public_key_package).unwrap();

    // P1 revealed exactly the share it had sent to P3...
    let reveals = reveals.borrow();
    assert_eq!(reveals.len(), 1);
    let v = reveals[0].verify(net.roster()).unwrap();
    assert_eq!(v.from(), Party::Participant(p(1)));
    let Message::KeygenReveal(reveal) = v.body() else {
        panic!("not a reveal")
    };
    assert_eq!(reveal.recipient, p(3));
    let statement = reveal.statement.verify(net.roster()).unwrap();
    assert_eq!((statement.dealer, statement.recipient), (p(1), p(3)));

    // ...and then refused to commit the poisoned session.
    let refusals = finished_refusals.borrow();
    assert_eq!(refusals.len(), 1);
    assert!(refusals[0].contains("revealed"), "{}", refusals[0]);
    assert!(!net.node(p(1)).unwrap().shares().contains_key(&group_key));
    for id in ids(2..=5) {
        assert!(net.node(id).unwrap().shares().contains_key(&group_key));
    }
}

fn rotation(key: &EvmGroupKey, nonce: u64) -> CustodyAction {
    CustodyAction::KeyRotation(rotation_to(
        key,
        U256::from(nonce),
        U256::from(4_102_444_800u64),
    ))
}

fn evm_key(net: &custody_protocol::local::LocalNetwork<ChaCha20Rng>, g: &[u8; 33]) -> EvmGroupKey {
    EvmGroupKey::from_verifying_key(net.group(g).unwrap().verifying_key()).unwrap()
}

fn declined_by_policy(outcome: SigningOutcome, why: &str) {
    let SigningOutcome::Aborted(report) = outcome else {
        panic!("the group must not sign ({why})");
    };
    assert!(
        report.blame.iter().any(|b| matches!(
            &b.fault,
            Fault::Declined { reason } if reason.contains(why)
        )),
        "{report:?}"
    );
}

fn dkg_among(
    net: &mut custody_protocol::local::LocalNetwork<ChaCha20Rng>,
    t: u16,
    members: &[ParticipantId],
) -> [u8; 33] {
    match net.dkg(t, members).unwrap() {
        KeygenOutcome::Committed { public_key_package } => {
            group_key_bytes(&public_key_package).unwrap()
        }
        KeygenOutcome::Aborted(report) => panic!("DKG aborted: {report:?}"),
    }
}

/// Reviewer PoC 3, inverted: honest signers never rotate the vault to a key
/// the coordinator chose. They only rotate towards a group they hold a
/// committed share of, at no lower threshold.
#[test]
fn signers_only_rotate_to_groups_they_hold_at_the_same_threshold() {
    let mut net = network(5, 402);
    let current = dkg(&mut net, 3, 5);
    let signers = [p(1), p(2), p(3)];

    // A key the coordinator alone holds (it can sign its own proof of possession).
    let attacker = frost_keccak::SigningKey::new(&mut ChaCha20Rng::seed_from_u64(9));
    let attacker_key =
        EvmGroupKey::from_verifying_key(&frost_keccak::VerifyingKey::from(&attacker)).unwrap();
    declined_by_policy(
        net.sign(current, rotation(&attacker_key, 1), DOMAIN, &signers)
            .unwrap(),
        "holds a committed share",
    );

    // A group P3 is not a member of.
    let partial = dkg_among(&mut net, 3, &[p(1), p(2), p(4), p(5)]);
    declined_by_policy(
        net.sign(
            current,
            rotation(&evm_key(&net, &partial), 2),
            DOMAIN,
            &signers,
        )
        .unwrap(),
        "holds a committed share",
    );

    // A group every signer holds, but with a lower threshold (2 corrupt
    // participants could then control it).
    let weaker = dkg_among(&mut net, 2, &ids(1..=5));
    declined_by_policy(
        net.sign(
            current,
            rotation(&evm_key(&net, &weaker), 3),
            DOMAIN,
            &signers,
        )
        .unwrap(),
        "lower the threshold",
    );

    // A fresh group of the same members and threshold: the current group
    // authorises, the new group proves possession by signing the same intent.
    let next = dkg(&mut net, 3, 5);
    let action = rotation(&evm_key(&net, &next), 4);
    let digest = action.signing_hash(&DOMAIN);
    for (group, set) in [(current, signers), (next, [p(3), p(4), p(5)])] {
        let SigningOutcome::Signed { evm: sig, .. } =
            net.sign(group, action.clone(), DOMAIN, &set).unwrap()
        else {
            panic!("legitimate rotation refused");
        };
        assert!(evm::verify(&evm_key(&net, &group), &digest, &sig));
    }
}

/// With an approver configured, the coordinator cannot get anything signed
/// on its own: every request needs the operator's signature over exactly
/// this action on exactly this vault.
#[test]
fn signers_with_an_approver_need_its_signature() {
    let mut net = network(3, 403);
    let group_key = dkg(&mut net, 2, 3);
    let operator = ed25519_dalek::SigningKey::from_bytes(&[42u8; 32]);
    let impostor = ed25519_dalek::SigningKey::from_bytes(&[43u8; 32]);
    let mut policy = SignerPolicy::permissive(DOMAIN);
    policy.approver = Some(operator.verifying_key().to_bytes());
    for id in ids(1..=3) {
        net.node_mut(id).unwrap().set_policy(policy.clone());
    }
    let signers = [p(1), p(2)];
    let action = withdrawal(1, 1_000);

    declined_by_policy(
        net.sign(group_key, action.clone(), DOMAIN, &signers)
            .unwrap(),
        "no operator approval",
    );
    for (approval, why) in [
        (Approval::sign(&impostor, &action, &DOMAIN), "wrong key"),
        (
            Approval::sign(&operator, &withdrawal(1, 1_001), &DOMAIN),
            "another action",
        ),
        (
            Approval::sign(
                &operator,
                &action,
                &custody_protocol::intent::VaultDomain {
                    chain_id: 1,
                    ..DOMAIN
                },
            ),
            "another chain",
        ),
    ] {
        let outcome = net
            .sign_approved(group_key, action.clone(), DOMAIN, &signers, Some(approval))
            .unwrap();
        assert!(
            matches!(outcome, SigningOutcome::Aborted(_)),
            "approval by {why} accepted"
        );
    }
    let approval = Approval::sign(&operator, &action, &DOMAIN);
    let SigningOutcome::Signed { evm: sig, .. } = net
        .sign_approved(group_key, action.clone(), DOMAIN, &signers, Some(approval))
        .unwrap()
    else {
        panic!("approved action refused");
    };
    assert!(evm::verify(
        &evm_key(&net, &group_key),
        &action.signing_hash(&DOMAIN),
        &sig
    ));
}
