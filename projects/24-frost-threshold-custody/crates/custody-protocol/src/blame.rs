// SPDX-License-Identifier: MIT
//! Abort reports and third-party verification of blame.
//!
//! Every provable fault carries the offending party's own signed message(s).
//! [`Blame::verify`] re-checks that evidence from the roster and public
//! protocol data only, so an auditor does not have to trust the coordinator
//! that produced the report.

use std::collections::{BTreeMap, BTreeSet};

use frost_keccak::{
    SigningPackage,
    keys::{PublicKeyPackage, SecretShare},
};
use serde::{Deserialize, Serialize};

use crate::envelope::{SignedEnvelope, Verified};
use crate::identity::Roster;
use crate::ids::{ParticipantId, Party, SessionId};
use crate::keygen::{round1_digest, share_commitment};
use crate::messages::{KeygenMode, Message, SignedShareStatement};
use crate::signing::signing_package_digest;

/// Why a participant is blamed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "fault", rename_all = "snake_case")]
pub enum Fault {
    /// Did not answer before the phase deadline, or its messages never
    /// authenticated (dropped, delayed or corrupted in transit). Liveness
    /// fault: not provable to third parties.
    Unresponsive {
        /// Protocol phase that timed out.
        phase: String,
    },
    /// Refused the request (for example a policy violation). Honest behaviour,
    /// reported so the coordinator can pick another signer.
    Declined {
        /// Reason given by the participant.
        reason: String,
    },
    /// Sent two different signed answers to the same once-per-session protocol
    /// step (round-one or round-two package, keygen result, nonce commitment,
    /// signature share, repair delta/sigma/result, or reveal for one recipient).
    Equivocation {
        /// First signed message.
        first: SignedEnvelope,
        /// Conflicting signed message.
        second: SignedEnvelope,
    },
    /// Signed a message whose content is structurally invalid.
    MalformedMessage {
        /// The signed message.
        envelope: SignedEnvelope,
        /// What is wrong with it.
        detail: String,
    },
    /// The DKG proof of knowledge in the signed round-one package is invalid.
    InvalidProofOfKnowledge {
        /// The dealer's signed round-one envelope.
        round1: SignedEnvelope,
    },
    /// Reported a round-one digest that differs from the set every other
    /// participant received.
    InconsistentBroadcast {
        /// The participant's signed round-two envelope.
        round2: SignedEnvelope,
        /// The `n` origin-signed round-one envelopes that were relayed; the
        /// verifier recomputes the expected digest from them.
        round1_set: Vec<SignedEnvelope>,
    },
    /// The signed round-two message has no share for `recipient`.
    MissingShare {
        /// The dealer's signed round-two envelope.
        round2: SignedEnvelope,
        /// Participant without a share.
        recipient: ParticipantId,
        /// The `n` origin-signed round-one envelopes. Their digest must equal
        /// the one the dealer signed in `round2`, which fixes the member set
        /// the dealer itself attested to (so a non-member cannot be named).
        round1_set: Vec<SignedEnvelope>,
    },
    /// The dealer signed a share that fails the Feldman VSS check.
    InvalidShare {
        /// Dealer-signed share statement revealed by the recipient.
        statement: SignedShareStatement,
        /// Dealer-signed round-one envelope with the commitment.
        round1: SignedEnvelope,
    },
    /// Accused a dealer without valid evidence.
    FalseComplaint {
        /// The complainant's signed result envelope.
        complaint: SignedEnvelope,
        /// Dealer that was accused.
        dealer: ParticipantId,
    },
    /// Did not reveal (or revealed an invalid) share after an
    /// "undecryptable" complaint.
    FailedReveal {
        /// Complainant.
        recipient: ParticipantId,
        /// The dealer's signed reveal, if any.
        reveal: Option<SignedEnvelope>,
    },
    /// Reported a different public key package than everyone else.
    InconsistentResult {
        /// The participant's signed result.
        result: SignedEnvelope,
    },
    /// Signature share fails verification against the participant's
    /// verifying share (FROST identifiable abort).
    InvalidSignatureShare {
        /// The signer's signed share envelope.
        share: SignedEnvelope,
    },
}

impl Fault {
    /// Whether the fault is backed by signed evidence.
    #[must_use]
    pub fn is_provable(&self) -> bool {
        !matches!(
            self,
            Self::Unresponsive { .. }
                | Self::Declined { .. }
                | Self::FailedReveal { reveal: None, .. }
        )
    }

    /// Whether the fault is misbehaviour (as opposed to an honest refusal).
    #[must_use]
    pub fn is_misbehaviour(&self) -> bool {
        !matches!(self, Self::Declined { .. })
    }

    /// Short label.
    #[must_use]
    pub fn label(&self) -> &'static str {
        match self {
            Self::Unresponsive { .. } => "unresponsive",
            Self::Declined { .. } => "declined",
            Self::Equivocation { .. } => "equivocation",
            Self::MalformedMessage { .. } => "malformed_message",
            Self::InvalidProofOfKnowledge { .. } => "invalid_proof_of_knowledge",
            Self::InconsistentBroadcast { .. } => "inconsistent_broadcast",
            Self::MissingShare { .. } => "missing_share",
            Self::InvalidShare { .. } => "invalid_share",
            Self::FalseComplaint { .. } => "false_complaint",
            Self::FailedReveal { .. } => "failed_reveal",
            Self::InconsistentResult { .. } => "inconsistent_result",
            Self::InvalidSignatureShare { .. } => "invalid_signature_share",
        }
    }
}

/// One blamed participant.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Blame {
    /// Participant at fault.
    pub participant: ParticipantId,
    /// The fault and its evidence.
    pub fault: Fault,
}

/// An unresolved keygen dispute: the dealer revealed a valid share for a box
/// the recipient said it could not open. Either party may be lying; neither
/// is blamed, both are listed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Dispute {
    /// Dealer that revealed a valid share.
    pub dealer: ParticipantId,
    /// Recipient that could not open the box.
    pub recipient: ParticipantId,
}

/// Why a session aborted and who is responsible.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AbortReport {
    /// Aborted session.
    pub session: SessionId,
    /// Phase in which the abort was decided.
    pub phase: String,
    /// Blamed participants.
    pub blame: Vec<Blame>,
    /// Unresolved disputes.
    pub disputes: Vec<Dispute>,
    /// Free-form diagnostic.
    pub note: Option<String>,
}

impl AbortReport {
    /// Participants blamed for misbehaviour (excluding honest refusals).
    #[must_use]
    pub fn culprits(&self) -> BTreeSet<ParticipantId> {
        self.blame
            .iter()
            .filter(|b| b.fault.is_misbehaviour())
            .map(|b| b.participant)
            .collect()
    }

    /// Every participant named in the report (culprits, decliners, disputes);
    /// a retry should not select them.
    #[must_use]
    pub fn excluded(&self) -> BTreeSet<ParticipantId> {
        let mut out: BTreeSet<_> = self.blame.iter().map(|b| b.participant).collect();
        for d in &self.disputes {
            out.insert(d.dealer);
            out.insert(d.recipient);
        }
        out
    }
}

/// Public data needed to re-check blame.
#[derive(Clone, Debug)]
pub struct BlameContext<'a> {
    /// Roster (transport identities).
    pub roster: &'a Roster,
    /// Session the report refers to.
    pub session: SessionId,
    /// Keygen mode, for keygen faults.
    pub keygen_mode: Option<KeygenMode>,
    /// Signing package and group public data, for signing faults.
    pub signing: Option<(&'a SigningPackage, &'a PublicKeyPackage)>,
}

/// Why a piece of blame evidence was rejected.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum BlameError {
    /// The fault is a liveness fault and has no evidence.
    #[error("fault is not provable")]
    NotProvable,
    /// A signature in the evidence is invalid or from the wrong party.
    #[error("evidence is not signed by the blamed party: {0}")]
    Unsigned(String),
    /// The evidence belongs to another session.
    #[error("evidence belongs to another session")]
    WrongSession,
    /// The evidence does not show a fault.
    #[error("evidence does not demonstrate the fault: {0}")]
    NotDemonstrated(String),
    /// The context lacks data needed for verification.
    #[error("missing verification context: {0}")]
    MissingContext(&'static str),
}

fn open_from(
    env: &SignedEnvelope,
    ctx: &BlameContext<'_>,
    who: ParticipantId,
) -> Result<Verified, BlameError> {
    let v = env
        .verify(ctx.roster)
        .map_err(|e| BlameError::Unsigned(e.to_string()))?;
    if v.from() != Party::Participant(who) {
        return Err(BlameError::Unsigned(format!(
            "envelope is from {}",
            v.from()
        )));
    }
    if v.session() != ctx.session {
        return Err(BlameError::WrongSession);
    }
    Ok(v)
}

/// Decodes a relayed round-one set: every envelope must be an origin-signed
/// round-one message of this session, one per dealer, including `who`.
fn round1_packages(
    round1_set: &[SignedEnvelope],
    ctx: &BlameContext<'_>,
    who: ParticipantId,
) -> Result<BTreeMap<ParticipantId, frost_keccak::keys::dkg::round1::Package>, BlameError> {
    let mut packages = BTreeMap::new();
    for env in round1_set {
        let r1 = env
            .verify(ctx.roster)
            .map_err(|e| BlameError::Unsigned(e.to_string()))?;
        if r1.session() != ctx.session {
            return Err(BlameError::WrongSession);
        }
        let Message::KeygenRound1(body) = r1.body() else {
            return Err(BlameError::NotDemonstrated(
                "not a round-one message".into(),
            ));
        };
        let from = r1
            .participant()
            .map_err(|e| BlameError::Unsigned(e.to_string()))?;
        if packages.insert(from, body.package.clone()).is_some() {
            return Err(BlameError::NotDemonstrated(
                "round-one set repeats a dealer".into(),
            ));
        }
    }
    if !packages.contains_key(&who) {
        return Err(BlameError::NotDemonstrated(
            "round-one set lacks the participant".into(),
        ));
    }
    Ok(packages)
}

/// Whether two messages answer the same protocol step, which an honest party
/// answers exactly once per session. Refusals are excluded (an honest node
/// refuses every unexpected message), and reveals only conflict when they
/// concern the same recipient (a dealer answers one reveal per complainant).
fn same_protocol_step(a: &Message, b: &Message) -> bool {
    match (a, b) {
        (Message::KeygenReveal(x), Message::KeygenReveal(y)) => x.recipient == y.recipient,
        (Message::KeygenRound1(_), Message::KeygenRound1(_))
        | (Message::KeygenRound2(_), Message::KeygenRound2(_))
        | (Message::KeygenResult(_), Message::KeygenResult(_))
        | (Message::SignCommitment(_), Message::SignCommitment(_))
        | (Message::SignShare(_), Message::SignShare(_))
        | (Message::RepairDeltas(_), Message::RepairDeltas(_))
        | (Message::RepairSigma(_), Message::RepairSigma(_))
        | (Message::RepairResult(_), Message::RepairResult(_)) => true,
        _ => false,
    }
}

/// How much a piece of verified evidence establishes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Evidence {
    /// The evidence alone proves the fault (invalid proof of knowledge,
    /// invalid or missing share, inconsistent broadcast, equivocation, invalid
    /// signature share). An honest party cannot be framed with it. For
    /// equivocation this relies on honest nodes answering each step once per
    /// session id, which the node's session journal enforces (across restarts
    /// only when the journal is persisted).
    Conclusive,
    /// The blamed party did sign the message in this session, but whether the
    /// message was faulty depends on session state (for example the complaint
    /// being judged) that the verifier must replay from the full transcript.
    SignedOnly,
}

impl Blame {
    /// Re-verifies the evidence of a provable fault.
    pub fn verify(&self, ctx: &BlameContext<'_>) -> Result<Evidence, BlameError> {
        let who = self.participant;
        match &self.fault {
            Fault::InvalidProofOfKnowledge { round1 } => {
                let v = open_from(round1, ctx, who)?;
                let Message::KeygenRound1(r1) = v.body() else {
                    return Err(BlameError::NotDemonstrated(
                        "not a round-one message".into(),
                    ));
                };
                if !matches!(ctx.keygen_mode, Some(KeygenMode::Fresh)) {
                    return Err(BlameError::MissingContext("fresh keygen mode"));
                }
                match frost_core::keys::dkg::verify_proof_of_knowledge(
                    who.identifier(),
                    r1.package.commitment(),
                    r1.package.proof_of_knowledge(),
                ) {
                    Ok(()) => Err(BlameError::NotDemonstrated(
                        "proof of knowledge is valid".into(),
                    )),
                    Err(_) => Ok(Evidence::Conclusive),
                }
            }
            Fault::InvalidShare { statement, round1 } => {
                let mode = ctx
                    .keygen_mode
                    .ok_or(BlameError::MissingContext("keygen mode"))?;
                let s = statement
                    .verify(ctx.roster)
                    .map_err(|e| BlameError::Unsigned(e.to_string()))?;
                if s.dealer != who {
                    return Err(BlameError::Unsigned(
                        "statement is from another dealer".into(),
                    ));
                }
                if s.session != ctx.session {
                    return Err(BlameError::WrongSession);
                }
                let v = open_from(round1, ctx, who)?;
                let Message::KeygenRound1(r1) = v.body() else {
                    return Err(BlameError::NotDemonstrated(
                        "not a round-one message".into(),
                    ));
                };
                let commitment = share_commitment(mode, &r1.package);
                let share = SecretShare::new(
                    s.recipient.identifier(),
                    *s.share.signing_share(),
                    commitment,
                );
                match share.verify() {
                    Ok(_) => Err(BlameError::NotDemonstrated("the share is valid".into())),
                    Err(_) => Ok(Evidence::Conclusive),
                }
            }
            Fault::MissingShare {
                round2,
                recipient,
                round1_set,
            } => {
                let v = open_from(round2, ctx, who)?;
                let Message::KeygenRound2(r2) = v.body() else {
                    return Err(BlameError::NotDemonstrated(
                        "not a round-two message".into(),
                    ));
                };
                if *recipient == who {
                    return Err(BlameError::NotDemonstrated(
                        "a dealer sends no share to itself".into(),
                    ));
                }
                // The member set is the one the dealer attested to by signing
                // the digest of the round-one set; the verifier does not have
                // to trust whoever assembled the report.
                let members = round1_packages(round1_set, ctx, who)?;
                let attested = round1_digest(&members)
                    .map_err(|e| BlameError::NotDemonstrated(e.to_string()))?;
                if r2.round1_digest != attested {
                    return Err(BlameError::NotDemonstrated(
                        "the round-one set is not the one the dealer attested to".into(),
                    ));
                }
                if !members.contains_key(recipient) {
                    return Err(BlameError::NotDemonstrated(
                        "the recipient is not a member of the session".into(),
                    ));
                }
                if r2.shares.iter().any(|b| b.to == *recipient) {
                    return Err(BlameError::NotDemonstrated("the share is present".into()));
                }
                Ok(Evidence::Conclusive)
            }
            Fault::InconsistentBroadcast { round2, round1_set } => {
                let v = open_from(round2, ctx, who)?;
                let Message::KeygenRound2(r2) = v.body() else {
                    return Err(BlameError::NotDemonstrated(
                        "not a round-two message".into(),
                    ));
                };
                let packages = round1_packages(round1_set, ctx, who)?;
                let expected = round1_digest(&packages)
                    .map_err(|e| BlameError::NotDemonstrated(e.to_string()))?;
                if r2.round1_digest == expected {
                    return Err(BlameError::NotDemonstrated("digests match".into()));
                }
                Ok(Evidence::Conclusive)
            }
            Fault::Equivocation { first, second } => {
                let a = open_from(first, ctx, who)?;
                let b = open_from(second, ctx, who)?;
                if !same_protocol_step(a.body(), b.body()) {
                    return Err(BlameError::NotDemonstrated(
                        "the messages do not answer the same once-per-session step".into(),
                    ));
                }
                if a.raw.payload == b.raw.payload {
                    return Err(BlameError::NotDemonstrated(
                        "messages do not conflict".into(),
                    ));
                }
                Ok(Evidence::Conclusive)
            }
            Fault::MalformedMessage { envelope, .. }
            | Fault::FalseComplaint {
                complaint: envelope,
                ..
            }
            | Fault::InconsistentResult { result: envelope }
            | Fault::FailedReveal {
                reveal: Some(envelope),
                ..
            } => {
                // These faults are judged against session state the verifier
                // must reconstruct; here we check that the blamed party did
                // sign the message in this session.
                open_from(envelope, ctx, who).map(|_| Evidence::SignedOnly)
            }
            Fault::InvalidSignatureShare { share } => {
                let (package, public) = ctx.signing.ok_or(BlameError::MissingContext("signing"))?;
                let v = open_from(share, ctx, who)?;
                let Message::SignShare(msg) = v.body() else {
                    return Err(BlameError::NotDemonstrated("not a signature share".into()));
                };
                // The signer attested which package it signed; evidence against
                // any other package would let a coordinator frame it.
                let attested = signing_package_digest(package)
                    .map_err(|e| BlameError::NotDemonstrated(e.to_string()))?;
                if msg.package_digest != attested {
                    return Err(BlameError::NotDemonstrated(
                        "the share was computed for another signing package".into(),
                    ));
                }
                let verifying_share = public
                    .verifying_shares()
                    .get(&who.identifier())
                    .ok_or(BlameError::MissingContext("verifying share"))?;
                match frost_core::verify_signature_share(
                    who.identifier(),
                    verifying_share,
                    &msg.share,
                    package,
                    public.verifying_key(),
                ) {
                    Ok(()) => Err(BlameError::NotDemonstrated("the share is valid".into())),
                    Err(_) => Ok(Evidence::Conclusive),
                }
            }
            Fault::Unresponsive { .. }
            | Fault::Declined { .. }
            | Fault::FailedReveal { reveal: None, .. } => Err(BlameError::NotProvable),
        }
    }
}
