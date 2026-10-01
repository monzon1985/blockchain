// SPDX-License-Identifier: MIT
//! Pedersen DKG (fresh keys) and proactive refresh, with evidence-carrying
//! complaints.
//!
//! ```text
//! coordinator             participant i                       (all messages ed25519-signed)
//!   KeygenStart ───────────▶ part1 / refresh_dkg_part1
//!   ◀────────────────────── KeygenRound1 { commitment, PoK }
//!   (verify PoK + shape; relay the n signed envelopes to everyone)
//!   KeygenRound1Bundle ────▶ verify PoKs again, digest of the round-one set,
//!                            part2: seal( sign_i(share_i→j) ) for every j
//!   ◀────────────────────── KeygenRound2 { digest, sealed shares }
//!   (check digests + box presence; relay)
//!   KeygenRound2Bundle ────▶ open own boxes, check dealer signatures and the
//!                            Feldman equation, then part3 / refresh_dkg_shares
//!   ◀────────────────────── KeygenResult { Success{pk, digest} | Complaints }
//!   (resolve complaints; RevealRequest{complainant's signed complaint} for
//!    undecryptable boxes; the dealer reveals only against that evidence)
//!   KeygenFinished ────────▶ commit only if the certificate carries n signed
//!                            identical Success results and nothing was revealed
//! ```
//!
//! A complaint about an invalid share carries the dealer-signed statement, so
//! the coordinator (or anyone) can verify it: either the dealer signed a bad
//! share (dealer blamed) or the share is fine (complainant blamed). Nothing in
//! a failed session is ever committed, and a session in which a dealer
//! revealed a share is always failed.

use std::collections::{BTreeMap, BTreeSet};

use frost_core::{Group, keys::CoefficientCommitment};
use frost_keccak::{
    Identifier, Secp256K1Keccak256,
    keys::{
        KeyPackage, PublicKeyPackage, SecretShare, VerifiableSecretSharingCommitment,
        VerifyingShare,
        dkg::{self, round1, round2},
        refresh,
    },
};
use rand_core::{CryptoRng, RngCore};
use sha2::{Digest, Sha256};
use tracing::{debug, warn};

use crate::blame::{AbortReport, Blame, Dispute, Fault};
use crate::envelope::{Outbound, Recipient, SignedEnvelope, Verified};
use crate::error::ProtocolError;
use crate::identity::{PartyKeys, Roster};
use crate::ids::{ParticipantId, Party, SessionId};
use crate::messages::{
    AddressedBox, Bundle, Complaint, ComplaintReason, GroupKeyBytes, KeygenFinished, KeygenMode,
    KeygenResult, KeygenReveal, KeygenRound1, KeygenRound2, KeygenStart, Message, RevealRequest,
    ShareStatement, SignedShareStatement,
};
use crate::sealed::{self, SealContext};

/// Purpose label of sealed DKG shares.
pub const SHARE_PURPOSE: &str = "dkg-share";

/// A participant's long-lived key material for one group.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyMaterial {
    /// Secret share and group data.
    pub key_package: KeyPackage,
    /// Public data of the whole group.
    pub public_key_package: PublicKeyPackage,
}

impl KeyMaterial {
    /// Compressed group key naming this share set.
    pub fn group_key(&self) -> Result<GroupKeyBytes, ProtocolError> {
        group_key_bytes(&self.public_key_package)
    }
}

/// Compressed group key of a public key package.
pub fn group_key_bytes(public: &PublicKeyPackage) -> Result<GroupKeyBytes, ProtocolError> {
    let bytes = public.verifying_key().serialize()?;
    bytes
        .try_into()
        .map_err(|_| ProtocolError::InvalidParameters("group key is not 33 bytes".into()))
}

/// SHA-256 of a public key package's canonical serialisation.
pub fn public_key_package_digest(public: &PublicKeyPackage) -> Result<[u8; 32], ProtocolError> {
    Ok(Sha256::digest(public.serialize()?).into())
}

/// SHA-256 over the round-one package set, sorted by participant.
pub fn round1_digest(
    packages: &BTreeMap<ParticipantId, round1::Package>,
) -> Result<[u8; 32], ProtocolError> {
    let mut h = Sha256::new();
    h.update(b"frost-custody/v1/round1-set");
    for (id, package) in packages {
        h.update(id.get().to_be_bytes());
        let bytes = package.serialize()?;
        h.update((bytes.len() as u64).to_be_bytes());
        h.update(bytes);
    }
    Ok(h.finalize().into())
}

/// The Feldman commitment a recipient checks a dealer's share against. For a
/// refresh the dealer's polynomial has a zero constant term, whose commitment
/// (the identity) is implicit in the round-one package.
#[must_use]
pub fn share_commitment(
    mode: KeygenMode,
    package: &round1::Package,
) -> VerifiableSecretSharingCommitment {
    match mode {
        KeygenMode::Fresh => package.commitment().clone(),
        KeygenMode::Refresh { .. } => {
            let mut coefficients = vec![CoefficientCommitment::new(
                <Secp256K1Keccak256 as frost_core::Ciphersuite>::Group::identity(),
            )];
            coefficients.extend(package.commitment().coefficients().iter().copied());
            VerifiableSecretSharingCommitment::new(coefficients)
        }
    }
}

/// What is wrong with a round-one package.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Round1Defect {
    /// Wrong number of coefficient commitments.
    Shape(String),
    /// The proof of knowledge of the constant term does not verify.
    ProofOfKnowledge,
}

impl Round1Defect {
    fn detail(&self) -> String {
        match self {
            Self::Shape(s) => s.clone(),
            Self::ProofOfKnowledge => "invalid proof of knowledge".to_owned(),
        }
    }
}

/// Structural and cryptographic checks on a round-one package.
fn check_round1(
    mode: KeygenMode,
    threshold: u16,
    dealer: ParticipantId,
    package: &round1::Package,
) -> Result<(), Round1Defect> {
    let expected = match mode {
        KeygenMode::Fresh => usize::from(threshold),
        KeygenMode::Refresh { .. } => usize::from(threshold) - 1,
    };
    let got = package.commitment().coefficients().len();
    if got != expected {
        return Err(Round1Defect::Shape(format!(
            "commitment has {got} coefficients, expected {expected}"
        )));
    }
    if matches!(mode, KeygenMode::Fresh) {
        frost_core::keys::dkg::verify_proof_of_knowledge(
            dealer.identifier(),
            package.commitment(),
            package.proof_of_knowledge(),
        )
        .map_err(|_| Round1Defect::ProofOfKnowledge)?;
    }
    Ok(())
}

fn validate_start(start: &KeygenStart) -> Result<BTreeSet<ParticipantId>, ProtocolError> {
    let set: BTreeSet<_> = start.participants.iter().copied().collect();
    if set.len() != start.participants.len() {
        return Err(ProtocolError::InvalidParameters(
            "duplicate participants".into(),
        ));
    }
    if start.threshold < 2 || usize::from(start.threshold) > set.len() {
        return Err(ProtocolError::InvalidParameters(format!(
            "threshold {} is invalid for {} participants",
            start.threshold,
            set.len()
        )));
    }
    Ok(set)
}

fn to_identifier_map<T: Clone>(map: &BTreeMap<ParticipantId, T>) -> BTreeMap<Identifier, T> {
    map.iter()
        .map(|(k, v)| (k.identifier(), v.clone()))
        .collect()
}

/// Decodes a relayed bundle: every envelope must verify, belong to `session`,
/// come from a distinct member of `expected`, and satisfy `extract`.
fn decode_bundle<T>(
    bundle: &Bundle,
    roster: &Roster,
    session: SessionId,
    expected: &BTreeSet<ParticipantId>,
    extract: impl Fn(&Message) -> Option<T>,
) -> Result<BTreeMap<ParticipantId, (T, SignedEnvelope)>, ProtocolError> {
    let mut out = BTreeMap::new();
    for env in &bundle.envelopes {
        let v = env.verify(roster)?;
        if v.session() != session {
            return Err(ProtocolError::WrongSession {
                expected: session,
                got: v.session(),
            });
        }
        let from = v.participant()?;
        if !expected.contains(&from) {
            return Err(ProtocolError::UnauthorizedSender(Party::Participant(from)));
        }
        let body = extract(v.body()).ok_or(ProtocolError::UnexpectedMessage {
            got: v.body().kind(),
            state: "bundle",
        })?;
        if out.insert(from, (body, env.clone())).is_some() {
            return Err(ProtocolError::InvalidParameters(format!(
                "bundle repeats {from}"
            )));
        }
    }
    if out.len() != expected.len() {
        return Err(ProtocolError::InvalidParameters(format!(
            "bundle has {} envelopes, expected {}",
            out.len(),
            expected.len()
        )));
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// Participant side
// ---------------------------------------------------------------------------

enum ParticipantState {
    AwaitRound1Bundle {
        secret: round1::SecretPackage,
        own: round1::Package,
    },
    AwaitRound2Bundle {
        secret: round2::SecretPackage,
        round1: BTreeMap<ParticipantId, round1::Package>,
        digest: [u8; 32],
    },
    AwaitFinish {
        material: Box<KeyMaterial>,
        digest: [u8; 32],
    },
    Failed,
    Done,
}

impl ParticipantState {
    fn name(&self) -> &'static str {
        match self {
            Self::AwaitRound1Bundle { .. } => "await_round1_bundle",
            Self::AwaitRound2Bundle { .. } => "await_round2_bundle",
            Self::AwaitFinish { .. } => "await_finish",
            Self::Failed => "failed",
            Self::Done => "done",
        }
    }
}

/// One participant's view of a keygen (DKG or refresh) session.
pub struct KeygenParticipant {
    session: SessionId,
    me: ParticipantId,
    mode: KeygenMode,
    threshold: u16,
    participants: BTreeSet<ParticipantId>,
    previous: Option<KeyMaterial>,
    statements: BTreeMap<ParticipantId, SignedShareStatement>,
    /// Set once this dealer revealed a share: the session is poisoned and can
    /// never commit, because a revealed evaluation of the dealer's polynomial
    /// is no longer secret.
    revealed: bool,
    state: ParticipantState,
}

impl KeygenParticipant {
    /// Handles `KeygenStart`: runs part one and returns the round-one message.
    ///
    /// For a refresh, `previous` must be the share set being refreshed.
    pub fn start<R: RngCore + CryptoRng>(
        session: SessionId,
        me: ParticipantId,
        start: &KeygenStart,
        previous: Option<KeyMaterial>,
        rng: &mut R,
    ) -> Result<(Self, Outbound), ProtocolError> {
        let participants = validate_start(start)?;
        if !participants.contains(&me) {
            return Err(ProtocolError::InvalidParameters(format!(
                "{me} is not in the session"
            )));
        }
        let n = u16::try_from(participants.len())
            .map_err(|_| ProtocolError::InvalidParameters("too many participants".into()))?;
        let (secret, own) = match start.mode {
            KeygenMode::Fresh => dkg::part1(me.identifier(), n, start.threshold, &mut *rng)?,
            KeygenMode::Refresh { group_key } => {
                let old = previous.as_ref().ok_or(ProtocolError::NoKeyShare)?;
                if old.group_key()? != group_key {
                    return Err(ProtocolError::InvalidParameters(
                        "refresh of an unknown group".into(),
                    ));
                }
                if old.public_key_package.min_signers() != Some(start.threshold) {
                    return Err(ProtocolError::InvalidParameters(
                        "a refresh cannot change the threshold".into(),
                    ));
                }
                if participants.iter().any(|p| {
                    !old.public_key_package
                        .verifying_shares()
                        .contains_key(&p.identifier())
                }) {
                    return Err(ProtocolError::InvalidParameters(
                        "refresh participants must already hold shares".into(),
                    ));
                }
                refresh::refresh_dkg_part1(me.identifier(), n, start.threshold, &mut *rng)?
            }
        };
        let message = Message::KeygenRound1(KeygenRound1 {
            package: own.clone(),
        });
        Ok((
            Self {
                session,
                me,
                mode: start.mode,
                threshold: start.threshold,
                participants,
                previous,
                statements: BTreeMap::new(),
                revealed: false,
                state: ParticipantState::AwaitRound1Bundle { secret, own },
            },
            Outbound {
                to: Recipient::Coordinator,
                session,
                body: message,
            },
        ))
    }

    fn others(&self) -> BTreeSet<ParticipantId> {
        self.participants
            .iter()
            .copied()
            .filter(|p| *p != self.me)
            .collect()
    }

    fn reply(&self, body: Message) -> Outbound {
        Outbound {
            to: Recipient::Coordinator,
            session: self.session,
            body,
        }
    }

    /// Handles the round-one bundle: verifies every dealer, then produces the
    /// sealed, dealer-signed shares (or complaints).
    pub fn on_round1_bundle<R: RngCore + CryptoRng>(
        &mut self,
        bundle: &Bundle,
        roster: &Roster,
        keys: &PartyKeys,
        rng: &mut R,
    ) -> Result<Outbound, ProtocolError> {
        let ParticipantState::AwaitRound1Bundle { secret, own } =
            std::mem::replace(&mut self.state, ParticipantState::Failed)
        else {
            return Err(ProtocolError::UnexpectedMessage {
                got: "keygen_round1_bundle",
                state: self.state.name(),
            });
        };
        let others = self.others();
        let received = decode_bundle(bundle, roster, self.session, &others, |m| match m {
            Message::KeygenRound1(r) => Some(r.package.clone()),
            _ => None,
        })?;

        let complaints: Vec<Complaint> = received
            .iter()
            .filter_map(|(dealer, (package, _))| {
                check_round1(self.mode, self.threshold, *dealer, package)
                    .err()
                    .map(|defect| Complaint {
                        dealer: *dealer,
                        reason: ComplaintReason::InvalidRound1 {
                            detail: defect.detail(),
                        },
                    })
            })
            .collect();
        if !complaints.is_empty() {
            warn!(me = %self.me, count = complaints.len(), "invalid round-one packages");
            return Ok(self.reply(Message::KeygenResult(KeygenResult::Complaints {
                complaints,
            })));
        }

        let others_round1: BTreeMap<ParticipantId, round1::Package> =
            received.into_iter().map(|(k, (p, _))| (k, p)).collect();
        let mut all = others_round1.clone();
        all.insert(self.me, own);
        let digest = round1_digest(&all)?;

        let round1_by_id = to_identifier_map(&others_round1);
        let (secret2, shares) = match self.mode {
            KeygenMode::Fresh => dkg::part2(secret, &round1_by_id)?,
            KeygenMode::Refresh { .. } => refresh::refresh_dkg_part2(secret, &round1_by_id)?,
        };

        let mut boxes = Vec::with_capacity(shares.len());
        for recipient in &others {
            let share = shares
                .get(&recipient.identifier())
                .ok_or(ProtocolError::UnknownParticipant(*recipient))?;
            let statement = SignedShareStatement::sign(
                &ShareStatement {
                    session: self.session,
                    dealer: self.me,
                    recipient: *recipient,
                    share: share.clone(),
                },
                keys,
            )?;
            let plaintext = zeroize::Zeroizing::new(serde_json::to_vec(&statement)?);
            let sealed = sealed::seal(
                rng,
                &roster.encryption_key(*recipient)?,
                &SealContext {
                    session: self.session,
                    from: Party::Participant(self.me),
                    to: *recipient,
                    purpose: SHARE_PURPOSE,
                },
                &plaintext,
            )?;
            self.statements.insert(*recipient, statement);
            boxes.push(AddressedBox {
                to: *recipient,
                sealed,
            });
        }
        self.state = ParticipantState::AwaitRound2Bundle {
            secret: secret2,
            round1: others_round1,
            digest,
        };
        Ok(self.reply(Message::KeygenRound2(KeygenRound2 {
            round1_digest: digest,
            shares: boxes,
        })))
    }

    /// Handles the round-two bundle: opens and checks every share addressed
    /// to this participant, then derives the key material (or complains).
    pub fn on_round2_bundle(
        &mut self,
        bundle: &Bundle,
        roster: &Roster,
        keys: &PartyKeys,
    ) -> Result<Outbound, ProtocolError> {
        let ParticipantState::AwaitRound2Bundle {
            secret,
            round1,
            digest,
        } = std::mem::replace(&mut self.state, ParticipantState::Failed)
        else {
            return Err(ProtocolError::UnexpectedMessage {
                got: "keygen_round2_bundle",
                state: self.state.name(),
            });
        };
        let others = self.others();
        let received = decode_bundle(bundle, roster, self.session, &others, |m| match m {
            Message::KeygenRound2(r) => Some(r.clone()),
            _ => None,
        })?;

        let mut complaints = Vec::new();
        let mut shares = BTreeMap::new();
        for (dealer, (r2, _)) in &received {
            match self.check_dealer_share(*dealer, r2, digest, &round1, roster, keys) {
                Ok(share) => {
                    shares.insert(dealer.identifier(), share);
                }
                Err(reason) => complaints.push(Complaint {
                    dealer: *dealer,
                    reason,
                }),
            }
        }
        if !complaints.is_empty() {
            warn!(me = %self.me, count = complaints.len(), "complaining about dealers");
            return Ok(self.reply(Message::KeygenResult(KeygenResult::Complaints {
                complaints,
            })));
        }

        let round1_by_id = to_identifier_map(&round1);
        let (key_package, public_key_package) = match self.mode {
            KeygenMode::Fresh => dkg::part3(&secret, &round1_by_id, &shares)?,
            KeygenMode::Refresh { group_key } => {
                let old = self.previous.clone().ok_or(ProtocolError::NoKeyShare)?;
                let refreshed = refresh::refresh_dkg_shares(
                    &secret,
                    &round1_by_id,
                    &shares,
                    old.public_key_package,
                    old.key_package,
                )?;
                if group_key_bytes(&refreshed.1)? != group_key {
                    return Err(ProtocolError::InvalidParameters(
                        "refresh changed the group key".into(),
                    ));
                }
                refreshed
            }
        };
        let material = KeyMaterial {
            key_package,
            public_key_package,
        };
        let group_key = material.group_key()?;
        let pkp_digest = public_key_package_digest(&material.public_key_package)?;
        debug!(me = %self.me, session = %self.session, "keygen shares verified");
        self.state = ParticipantState::AwaitFinish {
            material: Box::new(material),
            digest: pkp_digest,
        };
        Ok(self.reply(Message::KeygenResult(KeygenResult::Success {
            group_key,
            public_key_package_digest: pkp_digest,
        })))
    }

    fn check_dealer_share(
        &self,
        dealer: ParticipantId,
        r2: &KeygenRound2,
        expected_digest: [u8; 32],
        round1: &BTreeMap<ParticipantId, round1::Package>,
        roster: &Roster,
        keys: &PartyKeys,
    ) -> Result<round2::Package, ComplaintReason> {
        if r2.round1_digest != expected_digest {
            return Err(ComplaintReason::InconsistentRound1 {
                reported: r2.round1_digest,
            });
        }
        let boxed = r2
            .shares
            .iter()
            .find(|b| b.to == self.me)
            .ok_or(ComplaintReason::MissingShare)?;
        let plaintext = sealed::open(
            keys.encryption_secret(),
            &SealContext {
                session: self.session,
                from: Party::Participant(dealer),
                to: self.me,
                purpose: SHARE_PURPOSE,
            },
            &boxed.sealed,
        )
        .map_err(|_| ComplaintReason::Undecryptable)?;
        let signed: SignedShareStatement =
            serde_json::from_slice(&plaintext).map_err(|_| ComplaintReason::Undecryptable)?;
        let statement = signed
            .verify(roster)
            .map_err(|_| ComplaintReason::Undecryptable)?;
        if statement.session != self.session
            || statement.dealer != dealer
            || statement.recipient != self.me
        {
            return Err(ComplaintReason::Undecryptable);
        }
        let package = round1.get(&dealer).ok_or(ComplaintReason::Undecryptable)?;
        let check = SecretShare::new(
            self.me.identifier(),
            *statement.share.signing_share(),
            share_commitment(self.mode, package),
        );
        if check.verify().is_err() {
            return Err(ComplaintReason::InvalidShare { statement: signed });
        }
        Ok(statement.share)
    }

    /// Handles a reveal request: returns the signed statement sent to the
    /// complainant, but only against evidence. The request must carry the
    /// recipient's own signed `Complaints` result for this session naming this
    /// dealer as [`ComplaintReason::Undecryptable`]. The coordinator cannot
    /// forge that envelope, so it cannot harvest points of this dealer's
    /// polynomial; a complainant only learns (again) the share it was sent.
    /// After a reveal the session is poisoned and never commits.
    pub fn on_reveal_request(
        &mut self,
        request: &RevealRequest,
        roster: &Roster,
    ) -> Result<Outbound, ProtocolError> {
        let recipient = request.recipient;
        if recipient == self.me || !self.participants.contains(&recipient) {
            return Err(ProtocolError::UnknownParticipant(recipient));
        }
        let complaint = request.complaint.verify(roster)?;
        if complaint.from() != Party::Participant(recipient)
            || complaint.envelope.to != Recipient::Coordinator
        {
            return Err(ProtocolError::UnauthorizedSender(complaint.from()));
        }
        if complaint.session() != self.session {
            return Err(ProtocolError::WrongSession {
                expected: self.session,
                got: complaint.session(),
            });
        }
        let complained = matches!(
            complaint.body(),
            Message::KeygenResult(KeygenResult::Complaints { complaints })
                if complaints.iter().any(|c| {
                    c.dealer == self.me && matches!(c.reason, ComplaintReason::Undecryptable)
                })
        );
        if !complained {
            return Err(ProtocolError::InvalidParameters(format!(
                "no signed undecryptable complaint by {recipient} against {} backs the reveal request",
                self.me
            )));
        }
        let statement = self
            .statements
            .get(&recipient)
            .ok_or(ProtocolError::UnknownParticipant(recipient))?
            .clone();
        self.revealed = true;
        warn!(me = %self.me, %recipient, session = %self.session, "revealing a disputed share; this session can no longer commit");
        Ok(self.reply(Message::KeygenReveal(KeygenReveal {
            recipient,
            statement,
        })))
    }

    /// Whether this dealer revealed a share in this session (which then
    /// never commits).
    #[must_use]
    pub fn revealed(&self) -> bool {
        self.revealed
    }

    /// Handles the final decision. Returns the new key material only if the
    /// certificate proves that all participants derived the same public data
    /// and this participant never revealed a share in the session.
    pub fn on_finished(
        &mut self,
        finished: &KeygenFinished,
        roster: &Roster,
    ) -> Result<Option<KeyMaterial>, ProtocolError> {
        self.statements.clear();
        let state = std::mem::replace(&mut self.state, ParticipantState::Done);
        match finished {
            KeygenFinished::Aborted { report } => {
                warn!(me = %self.me, culprits = ?report.culprits(), "keygen aborted");
                Ok(None)
            }
            KeygenFinished::Committed { .. } if self.revealed => {
                Err(ProtocolError::InvalidParameters(
                    "a keygen session in which this dealer revealed a share can never commit"
                        .into(),
                ))
            }
            KeygenFinished::Committed { results } => {
                let ParticipantState::AwaitFinish { material, digest } = state else {
                    return Err(ProtocolError::UnexpectedMessage {
                        got: "keygen_finished",
                        state: "not awaiting finish",
                    });
                };
                let group_key = material.group_key()?;
                let certified = decode_bundle(
                    &Bundle {
                        envelopes: results.clone(),
                    },
                    roster,
                    self.session,
                    &self.participants,
                    |m| match m {
                        Message::KeygenResult(KeygenResult::Success {
                            group_key,
                            public_key_package_digest,
                        }) => Some((*group_key, *public_key_package_digest)),
                        _ => None,
                    },
                )?;
                if certified
                    .values()
                    .any(|((gk, d), _)| *gk != group_key || *d != digest)
                {
                    return Err(ProtocolError::InvalidParameters(
                        "commit certificate disagrees with the local result".into(),
                    ));
                }
                Ok(Some(*material))
            }
        }
    }

    /// Session identifier.
    #[must_use]
    pub fn session(&self) -> SessionId {
        self.session
    }

    /// Keygen mode.
    #[must_use]
    pub fn mode(&self) -> KeygenMode {
        self.mode
    }
}

// ---------------------------------------------------------------------------
// Coordinator side
// ---------------------------------------------------------------------------

/// Phase of the coordinator's keygen state machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeygenPhase {
    /// Collecting round-one packages.
    Round1,
    /// Collecting round-two sealed shares.
    Round2,
    /// Collecting results and complaints.
    Results,
    /// Waiting for dealers to reveal disputed shares.
    Reveal,
    /// Finished (committed or aborted).
    Done,
}

impl KeygenPhase {
    fn name(self) -> &'static str {
        match self {
            Self::Round1 => "round1",
            Self::Round2 => "round2",
            Self::Results => "results",
            Self::Reveal => "reveal",
            Self::Done => "done",
        }
    }
}

/// Final outcome of a keygen session, as seen by the coordinator.
#[derive(Clone, Debug, PartialEq)]
pub enum KeygenOutcome {
    /// All participants hold verified shares of `public_key_package`.
    Committed {
        /// The group's public data (recomputed by the coordinator from the
        /// commitments and cross-checked against every participant's digest).
        public_key_package: PublicKeyPackage,
    },
    /// The session failed.
    Aborted(AbortReport),
}

/// Coordinator state machine for one keygen session.
pub struct KeygenCoordinator {
    session: SessionId,
    mode: KeygenMode,
    threshold: u16,
    participants: BTreeSet<ParticipantId>,
    roster: Roster,
    previous: Option<PublicKeyPackage>,
    phase: KeygenPhase,
    round1: BTreeMap<ParticipantId, (round1::Package, SignedEnvelope)>,
    round2: BTreeMap<ParticipantId, (KeygenRound2, SignedEnvelope)>,
    results: BTreeMap<ParticipantId, (KeygenResult, SignedEnvelope)>,
    reveals: BTreeMap<(ParticipantId, ParticipantId), Option<SignedEnvelope>>,
    /// The complainant's signed result backing each reveal request.
    reveal_evidence: BTreeMap<(ParticipantId, ParticipantId), SignedEnvelope>,
    expected_digest: Option<[u8; 32]>,
    blame: Vec<Blame>,
    disputes: Vec<Dispute>,
    outcome: Option<KeygenOutcome>,
}

impl KeygenCoordinator {
    /// Creates the session and returns the `KeygenStart` messages.
    ///
    /// For a refresh, `previous` is the current public key package of the group.
    pub fn new(
        session: SessionId,
        start: KeygenStart,
        roster: Roster,
        previous: Option<PublicKeyPackage>,
    ) -> Result<(Self, Vec<Outbound>), ProtocolError> {
        let participants = validate_start(&start)?;
        for p in &participants {
            roster.entry(*p)?;
        }
        if let KeygenMode::Refresh { group_key } = start.mode {
            let old = previous.as_ref().ok_or(ProtocolError::NoKeyShare)?;
            if group_key_bytes(old)? != group_key {
                return Err(ProtocolError::InvalidParameters(
                    "refresh of an unknown group".into(),
                ));
            }
        }
        let out = participants
            .iter()
            .map(|p| Outbound {
                to: Recipient::Participant(*p),
                session,
                body: Message::KeygenStart(start.clone()),
            })
            .collect();
        Ok((
            Self {
                session,
                mode: start.mode,
                threshold: start.threshold,
                participants,
                roster,
                previous,
                phase: KeygenPhase::Round1,
                round1: BTreeMap::new(),
                round2: BTreeMap::new(),
                results: BTreeMap::new(),
                reveals: BTreeMap::new(),
                reveal_evidence: BTreeMap::new(),
                expected_digest: None,
                blame: Vec::new(),
                disputes: Vec::new(),
                outcome: None,
            },
            out,
        ))
    }

    /// Current phase.
    #[must_use]
    pub fn phase(&self) -> KeygenPhase {
        self.phase
    }

    /// Final outcome, once decided.
    #[must_use]
    pub fn outcome(&self) -> Option<&KeygenOutcome> {
        self.outcome.as_ref()
    }

    /// Participants the current phase is still waiting for.
    #[must_use]
    pub fn awaiting(&self) -> BTreeSet<ParticipantId> {
        match self.phase {
            KeygenPhase::Round1 => self.missing(self.round1.keys()),
            KeygenPhase::Round2 => self.missing(self.round2.keys()),
            KeygenPhase::Results => self.missing(self.results.keys()),
            KeygenPhase::Reveal => self
                .reveals
                .iter()
                .filter(|(_, v)| v.is_none())
                .map(|((dealer, _), _)| *dealer)
                .collect(),
            KeygenPhase::Done => BTreeSet::new(),
        }
    }

    fn missing<'a>(
        &self,
        have: impl Iterator<Item = &'a ParticipantId>,
    ) -> BTreeSet<ParticipantId> {
        let have: BTreeSet<_> = have.copied().collect();
        self.participants.difference(&have).copied().collect()
    }

    fn to_all(&self, body: impl Fn(ParticipantId) -> Message) -> Vec<Outbound> {
        self.participants
            .iter()
            .map(|p| Outbound {
                to: Recipient::Participant(*p),
                session: self.session,
                body: body(*p),
            })
            .collect()
    }

    fn abort(&mut self, note: Option<String>) -> Vec<Outbound> {
        let report = AbortReport {
            session: self.session,
            phase: self.phase.name().to_owned(),
            blame: std::mem::take(&mut self.blame),
            disputes: std::mem::take(&mut self.disputes),
            note,
        };
        warn!(session = %self.session, culprits = ?report.culprits(), "keygen aborted");
        self.phase = KeygenPhase::Done;
        self.outcome = Some(KeygenOutcome::Aborted(report.clone()));
        self.to_all(|_| {
            Message::KeygenFinished(KeygenFinished::Aborted {
                report: report.clone(),
            })
        })
    }

    fn record(
        store: &mut BTreeMap<ParticipantId, (impl Clone, SignedEnvelope)>,
        blame: &mut Vec<Blame>,
        from: ParticipantId,
        raw: &SignedEnvelope,
    ) -> bool {
        if let Some((_, first)) = store.get(&from) {
            if first.payload != raw.payload && !blame.iter().any(|b| b.participant == from) {
                blame.push(Blame {
                    participant: from,
                    fault: Fault::Equivocation {
                        first: first.clone(),
                        second: raw.clone(),
                    },
                });
            }
            return false;
        }
        true
    }

    /// Handles an authenticated message from a participant.
    pub fn handle(&mut self, message: &Verified) -> Vec<Outbound> {
        let Ok(from) = message.participant() else {
            return Vec::new();
        };
        if message.session() != self.session || !self.participants.contains(&from) {
            return Vec::new();
        }
        if let Message::Refused(refused) = message.body() {
            // A refusal from a participant that already answered the current
            // phase concerns a duplicate delivery and is ignored.
            let current = match self.phase {
                KeygenPhase::Round1 => "keygen_start",
                KeygenPhase::Round2 => "keygen_round1_bundle",
                KeygenPhase::Results => "keygen_round2_bundle",
                KeygenPhase::Reveal => "keygen_reveal_request",
                KeygenPhase::Done => return Vec::new(),
            };
            if refused.refused != current || !self.awaiting().contains(&from) {
                return Vec::new();
            }
            self.blame.push(Blame {
                participant: from,
                fault: Fault::Declined {
                    reason: refused.reason.clone(),
                },
            });
            return self.abort(Some(format!("{from} refused: {}", refused.reason)));
        }
        match (self.phase, message.body()) {
            (KeygenPhase::Round1, Message::KeygenRound1(r1)) => {
                if !Self::record(&mut self.round1, &mut self.blame, from, &message.raw) {
                    return Vec::new();
                }
                if let Err(defect) = check_round1(self.mode, self.threshold, from, &r1.package) {
                    let fault = match defect {
                        Round1Defect::ProofOfKnowledge => Fault::InvalidProofOfKnowledge {
                            round1: message.raw.clone(),
                        },
                        Round1Defect::Shape(detail) => Fault::MalformedMessage {
                            envelope: message.raw.clone(),
                            detail,
                        },
                    };
                    self.blame.push(Blame {
                        participant: from,
                        fault,
                    });
                }
                self.round1
                    .insert(from, (r1.package.clone(), message.raw.clone()));
                self.advance()
            }
            (KeygenPhase::Round2, Message::KeygenRound2(r2)) => {
                if !Self::record(&mut self.round2, &mut self.blame, from, &message.raw) {
                    return Vec::new();
                }
                if let Some(expected) = self.expected_digest
                    && r2.round1_digest != expected
                {
                    self.blame.push(Blame {
                        participant: from,
                        fault: Fault::InconsistentBroadcast {
                            round2: message.raw.clone(),
                            round1_set: self.round1.values().map(|(_, env)| env.clone()).collect(),
                        },
                    });
                }
                for recipient in self.participants.iter().filter(|p| **p != from) {
                    if !r2.shares.iter().any(|b| b.to == *recipient) {
                        self.blame.push(Blame {
                            participant: from,
                            fault: Fault::MissingShare {
                                round2: message.raw.clone(),
                                recipient: *recipient,
                                round1_set: self
                                    .round1
                                    .values()
                                    .map(|(_, env)| env.clone())
                                    .collect(),
                            },
                        });
                    }
                }
                self.round2.insert(from, (r2.clone(), message.raw.clone()));
                self.advance()
            }
            (KeygenPhase::Results, Message::KeygenResult(result)) => {
                if !Self::record(&mut self.results, &mut self.blame, from, &message.raw) {
                    return Vec::new();
                }
                self.results
                    .insert(from, (result.clone(), message.raw.clone()));
                self.advance()
            }
            (KeygenPhase::Reveal, Message::KeygenReveal(reveal)) => {
                let key = (from, reveal.recipient);
                if let Some(slot @ None) = self.reveals.get_mut(&key) {
                    *slot = Some(message.raw.clone());
                    self.judge_reveal(from, reveal);
                }
                self.advance()
            }
            _ => Vec::new(),
        }
    }

    /// Declares every awaited participant unresponsive and aborts.
    pub fn on_timeout(&mut self) -> Vec<Outbound> {
        if self.phase == KeygenPhase::Done {
            return Vec::new();
        }
        if self.phase == KeygenPhase::Reveal {
            for ((dealer, recipient), slot) in &self.reveals {
                if slot.is_none() {
                    self.blame.push(Blame {
                        participant: *dealer,
                        fault: Fault::FailedReveal {
                            recipient: *recipient,
                            reveal: None,
                        },
                    });
                }
            }
            return self.abort(Some("keygen aborted after complaints".into()));
        }
        for p in self.awaiting() {
            self.blame.push(Blame {
                participant: p,
                fault: Fault::Unresponsive {
                    phase: self.phase.name().to_owned(),
                },
            });
        }
        self.abort(Some("phase deadline expired".into()))
    }

    fn advance(&mut self) -> Vec<Outbound> {
        if !self.awaiting().is_empty() {
            return Vec::new();
        }
        match self.phase {
            KeygenPhase::Round1 => {
                if !self.blame.is_empty() {
                    return self.abort(Some("invalid round-one packages".into()));
                }
                let packages: BTreeMap<_, _> = self
                    .round1
                    .iter()
                    .map(|(k, (p, _))| (*k, p.clone()))
                    .collect();
                match round1_digest(&packages) {
                    Ok(d) => self.expected_digest = Some(d),
                    Err(e) => return self.abort(Some(e.to_string())),
                }
                self.phase = KeygenPhase::Round2;
                let round1 = self.round1.clone();
                self.to_all(|p| {
                    Message::KeygenRound1Bundle(Bundle {
                        envelopes: round1
                            .iter()
                            .filter(|(k, _)| **k != p)
                            .map(|(_, (_, env))| env.clone())
                            .collect(),
                    })
                })
            }
            KeygenPhase::Round2 => {
                if !self.blame.is_empty() {
                    return self.abort(Some("invalid round-two messages".into()));
                }
                self.phase = KeygenPhase::Results;
                let round2 = self.round2.clone();
                self.to_all(|p| {
                    Message::KeygenRound2Bundle(Bundle {
                        envelopes: round2
                            .iter()
                            .filter(|(k, _)| **k != p)
                            .map(|(_, (_, env))| env.clone())
                            .collect(),
                    })
                })
            }
            KeygenPhase::Results => self.resolve_results(),
            KeygenPhase::Reveal => self.abort(Some("keygen aborted after complaints".into())),
            KeygenPhase::Done => Vec::new(),
        }
    }

    fn expected_public_key_package(&self) -> Result<PublicKeyPackage, ProtocolError> {
        let commitments: BTreeMap<Identifier, VerifiableSecretSharingCommitment> = self
            .round1
            .iter()
            .map(|(k, (p, _))| (k.identifier(), share_commitment(self.mode, p)))
            .collect();
        let refs: BTreeMap<Identifier, &VerifiableSecretSharingCommitment> =
            commitments.iter().map(|(k, v)| (*k, v)).collect();
        let derived = PublicKeyPackage::from_dkg_commitments(&refs)?;
        match self.mode {
            KeygenMode::Fresh => {
                frost_keccak::evm::EvmGroupKey::from_verifying_key(derived.verifying_key())?;
                Ok(derived)
            }
            KeygenMode::Refresh { .. } => {
                let old = self.previous.as_ref().ok_or(ProtocolError::NoKeyShare)?;
                let mut shares = BTreeMap::new();
                for (id, zero_share) in derived.verifying_shares() {
                    let old_share =
                        old.verifying_shares()
                            .get(id)
                            .ok_or(ProtocolError::InvalidParameters(
                                "unknown refresh member".into(),
                            ))?;
                    shares.insert(
                        *id,
                        VerifyingShare::new(zero_share.to_element() + old_share.to_element()),
                    );
                }
                Ok(PublicKeyPackage::new(
                    shares,
                    *old.verifying_key(),
                    Some(self.threshold),
                ))
            }
        }
    }

    fn resolve_results(&mut self) -> Vec<Outbound> {
        let expected = match self.expected_public_key_package() {
            Ok(p) => p,
            Err(e) => return self.abort(Some(format!("cannot derive public data: {e}"))),
        };
        let (Ok(expected_key), Ok(expected_digest)) = (
            group_key_bytes(&expected),
            public_key_package_digest(&expected),
        ) else {
            return self.abort(Some("cannot serialise public data".into()));
        };

        let results = self.results.clone();
        for (accuser, (result, raw)) in &results {
            match result {
                KeygenResult::Success {
                    group_key,
                    public_key_package_digest,
                } => {
                    if *group_key != expected_key || *public_key_package_digest != expected_digest {
                        self.blame.push(Blame {
                            participant: *accuser,
                            fault: Fault::InconsistentResult {
                                result: raw.clone(),
                            },
                        });
                    }
                }
                KeygenResult::Complaints { complaints } => {
                    for complaint in complaints {
                        self.judge_complaint(*accuser, raw, complaint);
                    }
                }
            }
        }

        if !self.reveals.is_empty() {
            self.phase = KeygenPhase::Reveal;
            let session = self.session;
            return self
                .reveal_evidence
                .iter()
                .map(|((dealer, recipient), complaint)| Outbound {
                    to: Recipient::Participant(*dealer),
                    session,
                    body: Message::KeygenRevealRequest(RevealRequest {
                        recipient: *recipient,
                        complaint: complaint.clone(),
                    }),
                })
                .collect();
        }
        let all_success = results
            .values()
            .all(|(r, _)| matches!(r, KeygenResult::Success { .. }));
        if !self.blame.is_empty() || !all_success {
            return self.abort(Some("keygen aborted after complaints".into()));
        }
        self.phase = KeygenPhase::Done;
        self.outcome = Some(KeygenOutcome::Committed {
            public_key_package: expected,
        });
        let certificate: Vec<SignedEnvelope> =
            results.values().map(|(_, raw)| raw.clone()).collect();
        self.to_all(|_| {
            Message::KeygenFinished(KeygenFinished::Committed {
                results: certificate.clone(),
            })
        })
    }

    fn blame_false(&mut self, accuser: ParticipantId, raw: &SignedEnvelope, dealer: ParticipantId) {
        self.blame.push(Blame {
            participant: accuser,
            fault: Fault::FalseComplaint {
                complaint: raw.clone(),
                dealer,
            },
        });
    }

    fn judge_complaint(
        &mut self,
        accuser: ParticipantId,
        raw: &SignedEnvelope,
        complaint: &Complaint,
    ) {
        let dealer = complaint.dealer;
        if !self.participants.contains(&dealer) || dealer == accuser {
            self.blame_false(accuser, raw, dealer);
            return;
        }
        match &complaint.reason {
            ComplaintReason::InvalidShare { statement } => {
                if self.share_statement_is_invalid(dealer, accuser, statement) {
                    let round1 = self.round1.get(&dealer).map(|(_, env)| env.clone());
                    if let Some(round1) = round1 {
                        self.blame.push(Blame {
                            participant: dealer,
                            fault: Fault::InvalidShare {
                                statement: statement.clone(),
                                round1,
                            },
                        });
                    }
                } else {
                    self.blame_false(accuser, raw, dealer);
                }
            }
            ComplaintReason::Undecryptable => {
                self.reveals.insert((dealer, accuser), None);
                self.reveal_evidence.insert((dealer, accuser), raw.clone());
            }
            // The coordinator already checked round-one validity, box presence
            // and digests before relaying; such complaints are unfounded.
            ComplaintReason::MissingShare
            | ComplaintReason::InconsistentRound1 { .. }
            | ComplaintReason::InvalidRound1 { .. } => self.blame_false(accuser, raw, dealer),
        }
    }

    /// True iff `statement` is a dealer-signed share for `recipient` in this
    /// session that fails the Feldman check.
    fn share_statement_is_invalid(
        &self,
        dealer: ParticipantId,
        recipient: ParticipantId,
        statement: &SignedShareStatement,
    ) -> bool {
        let Ok(s) = statement.verify(&self.roster) else {
            return false;
        };
        if s.dealer != dealer || s.recipient != recipient || s.session != self.session {
            return false;
        }
        let Some((package, _)) = self.round1.get(&dealer) else {
            return false;
        };
        SecretShare::new(
            recipient.identifier(),
            *s.share.signing_share(),
            share_commitment(self.mode, package),
        )
        .verify()
        .is_err()
    }

    fn judge_reveal(&mut self, dealer: ParticipantId, reveal: &KeygenReveal) {
        let valid = reveal
            .statement
            .verify(&self.roster)
            .ok()
            .filter(|s| {
                s.dealer == dealer && s.recipient == reveal.recipient && s.session == self.session
            })
            .is_some()
            && !self.share_statement_is_invalid(dealer, reveal.recipient, &reveal.statement);
        if valid {
            self.disputes.push(Dispute {
                dealer,
                recipient: reveal.recipient,
            });
        } else {
            let raw = self
                .reveals
                .get(&(dealer, reveal.recipient))
                .cloned()
                .flatten();
            self.blame.push(Blame {
                participant: dealer,
                fault: Fault::FailedReveal {
                    recipient: reveal.recipient,
                    reveal: raw,
                },
            });
        }
    }
}
