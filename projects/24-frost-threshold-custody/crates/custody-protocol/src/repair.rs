// SPDX-License-Identifier: MIT
//! Repair of a lost share with the repairable threshold scheme (RTS,
//! eprint 2017/1155) as implemented by frost-core, over sealed channels.
//!
//! ```text
//! helpers h ∈ H (|H| ≥ t)                       lost participant ℓ
//!   part1: δ_{h→j} for every j ∈ H  ── sealed ──▶ other helpers
//!   part2: σ_h = Σ_j δ_{j→h}        ── sealed ──▶ ℓ
//!                                                 part3: s_ℓ = Σ_h σ_h
//!                                                 check s_ℓ·G == Y_ℓ (public)
//! ```
//!
//! frost-core's `repair_share_part3` does not check the result; this module
//! does, against the verifying share every helper published. A wrong sigma
//! therefore makes the repair fail closed. The individual sigmas are uniformly
//! random, so the misbehaving helper cannot be identified from them (see the
//! threat model); the repair is then retried with another helper set.

use std::collections::{BTreeMap, BTreeSet};

use frost_keccak::{
    Identifier,
    keys::{
        PublicKeyPackage,
        repairable::{self, Delta, Sigma},
    },
};
use rand_core::{CryptoRng, RngCore};
use tracing::{info, warn};

use crate::blame::{AbortReport, Blame, Fault};
use crate::envelope::{Outbound, Recipient, SignedEnvelope, Verified};
use crate::error::ProtocolError;
use crate::identity::{PartyKeys, Roster};
use crate::ids::{ParticipantId, Party, SessionId};
use crate::keygen::{KeyMaterial, group_key_bytes, public_key_package_digest};
use crate::messages::{
    AddressedBox, Bundle, GroupKeyBytes, Message, RepairDeltas, RepairResult, RepairSigma,
    RepairStart,
};
use crate::sealed::{self, SealContext};

/// Purpose label of sealed deltas.
pub const DELTA_PURPOSE: &str = "repair-delta";
/// Purpose label of sealed sigmas.
pub const SIGMA_PURPOSE: &str = "repair-sigma";

fn validate(
    start: &RepairStart,
    public: &PublicKeyPackage,
) -> Result<BTreeSet<ParticipantId>, ProtocolError> {
    let helpers: BTreeSet<_> = start.helpers.iter().copied().collect();
    if helpers.len() != start.helpers.len() || helpers.contains(&start.lost) {
        return Err(ProtocolError::InvalidParameters(
            "invalid helper set".into(),
        ));
    }
    let threshold = public
        .min_signers()
        .ok_or(ProtocolError::InvalidParameters("unknown threshold".into()))?;
    if helpers.len() < usize::from(threshold) {
        return Err(ProtocolError::InvalidParameters(format!(
            "repair needs {threshold} helpers, got {}",
            helpers.len()
        )));
    }
    for p in helpers.iter().chain(std::iter::once(&start.lost)) {
        if !public.verifying_shares().contains_key(&p.identifier()) {
            return Err(ProtocolError::UnknownParticipant(*p));
        }
    }
    if group_key_bytes(public)? != start.group_key {
        return Err(ProtocolError::InvalidParameters(
            "repair of another group".into(),
        ));
    }
    Ok(helpers)
}

fn collect<T>(
    bundle: &Bundle,
    roster: &Roster,
    session: SessionId,
    expected: &BTreeSet<ParticipantId>,
    extract: impl Fn(&Message) -> Option<T>,
) -> Result<BTreeMap<ParticipantId, T>, ProtocolError> {
    let mut out = BTreeMap::new();
    for env in &bundle.envelopes {
        let v = env.verify(roster)?;
        let from = v.participant()?;
        if v.session() != session || !expected.contains(&from) {
            return Err(ProtocolError::UnauthorizedSender(Party::Participant(from)));
        }
        let body = extract(v.body()).ok_or(ProtocolError::UnexpectedMessage {
            got: v.body().kind(),
            state: "repair bundle",
        })?;
        if out.insert(from, body).is_some() {
            return Err(ProtocolError::InvalidParameters(format!(
                "bundle repeats {from}"
            )));
        }
    }
    if out.len() != expected.len() {
        return Err(ProtocolError::InvalidParameters(
            "incomplete repair bundle".into(),
        ));
    }
    Ok(out)
}

/// A helper's side of a repair session.
pub struct RepairHelper {
    session: SessionId,
    me: ParticipantId,
    lost: ParticipantId,
    helpers: BTreeSet<ParticipantId>,
    group_key: GroupKeyBytes,
    /// This helper's own delta, zeroised when the session ends or is evicted.
    own_delta: zeroize::Zeroizing<k256::Scalar>,
}

impl RepairHelper {
    /// Runs part one and returns the sealed deltas for the other helpers.
    pub fn start<R: RngCore + CryptoRng>(
        session: SessionId,
        me: ParticipantId,
        start: &RepairStart,
        material: &KeyMaterial,
        roster: &Roster,
        rng: &mut R,
    ) -> Result<(Self, Outbound), ProtocolError> {
        let helpers = validate(start, &material.public_key_package)?;
        if !helpers.contains(&me) {
            return Err(ProtocolError::InvalidParameters(format!(
                "{me} is not a helper"
            )));
        }
        let helper_ids: Vec<Identifier> = helpers.iter().map(|h| h.identifier()).collect();
        let mut deltas = repairable::repair_share_part1(
            &helper_ids,
            &material.key_package,
            rng,
            start.lost.identifier(),
        )?;
        let own_delta = deltas
            .remove(&me.identifier())
            .ok_or(ProtocolError::UnknownParticipant(me))?;
        let mut boxes = Vec::with_capacity(deltas.len());
        for helper in helpers.iter().filter(|h| **h != me) {
            let delta = deltas
                .get(&helper.identifier())
                .ok_or(ProtocolError::UnknownParticipant(*helper))?;
            let plaintext = zeroize::Zeroizing::new(delta.serialize());
            boxes.push(AddressedBox {
                to: *helper,
                sealed: sealed::seal(
                    rng,
                    &roster.encryption_key(*helper)?,
                    &SealContext {
                        session,
                        from: Party::Participant(me),
                        to: *helper,
                        purpose: DELTA_PURPOSE,
                    },
                    &plaintext,
                )?,
            });
        }
        Ok((
            Self {
                session,
                me,
                lost: start.lost,
                helpers,
                group_key: start.group_key,
                own_delta: zeroize::Zeroizing::new(own_delta.to_scalar()),
            },
            Outbound {
                to: Recipient::Coordinator,
                session,
                body: Message::RepairDeltas(RepairDeltas { deltas: boxes }),
            },
        ))
    }

    /// Group whose share is being repaired.
    #[must_use]
    pub fn group_key(&self) -> GroupKeyBytes {
        self.group_key
    }

    /// Combines the received deltas into a sigma sealed for the lost participant.
    pub fn on_delta_bundle<R: RngCore + CryptoRng>(
        &self,
        bundle: &Bundle,
        material: &KeyMaterial,
        roster: &Roster,
        keys: &PartyKeys,
        rng: &mut R,
    ) -> Result<Outbound, ProtocolError> {
        let others: BTreeSet<_> = self
            .helpers
            .iter()
            .copied()
            .filter(|h| *h != self.me)
            .collect();
        let received = collect(bundle, roster, self.session, &others, |m| match m {
            Message::RepairDeltas(d) => Some(d.clone()),
            _ => None,
        })?;
        let mut deltas = vec![Delta::new(*self.own_delta)];
        for (helper, message) in &received {
            let boxed = message.deltas.iter().find(|b| b.to == self.me).ok_or(
                ProtocolError::InvalidParameters(format!("{helper} sent no delta")),
            )?;
            let plaintext = sealed::open(
                keys.encryption_secret(),
                &SealContext {
                    session: self.session,
                    from: Party::Participant(*helper),
                    to: self.me,
                    purpose: DELTA_PURPOSE,
                },
                &boxed.sealed,
            )?;
            deltas.push(Delta::deserialize(&plaintext)?);
        }
        let sigma = repairable::repair_share_part2(&deltas);
        let plaintext = zeroize::Zeroizing::new(sigma.serialize());
        let sealed = sealed::seal(
            rng,
            &roster.encryption_key(self.lost)?,
            &SealContext {
                session: self.session,
                from: Party::Participant(self.me),
                to: self.lost,
                purpose: SIGMA_PURPOSE,
            },
            &plaintext,
        )?;
        Ok(Outbound {
            to: Recipient::Coordinator,
            session: self.session,
            body: Message::RepairSigma(RepairSigma {
                sigma: sealed,
                public_key_package: material.public_key_package.clone(),
            }),
        })
    }
}

/// The lost participant's side of a repair session.
pub struct RepairRecipient {
    session: SessionId,
    me: ParticipantId,
    helpers: BTreeSet<ParticipantId>,
    group_key: GroupKeyBytes,
}

impl RepairRecipient {
    /// Records the session parameters.
    pub fn start(
        session: SessionId,
        me: ParticipantId,
        start: &RepairStart,
    ) -> Result<Self, ProtocolError> {
        if start.lost != me {
            return Err(ProtocolError::InvalidParameters(
                "repair is for another participant".into(),
            ));
        }
        let helpers: BTreeSet<_> = start.helpers.iter().copied().collect();
        if helpers.len() != start.helpers.len() || helpers.contains(&me) {
            return Err(ProtocolError::InvalidParameters(
                "invalid helper set".into(),
            ));
        }
        Ok(Self {
            session,
            me,
            helpers,
            group_key: start.group_key,
        })
    }

    /// Recovers and verifies the share from the helpers' sigmas.
    pub fn on_sigma_bundle(
        &self,
        bundle: &Bundle,
        roster: &Roster,
        keys: &PartyKeys,
    ) -> Result<(KeyMaterial, Outbound), ProtocolError> {
        let received = collect(bundle, roster, self.session, &self.helpers, |m| match m {
            Message::RepairSigma(s) => Some(s.clone()),
            _ => None,
        })?;
        let mut public: Option<(PublicKeyPackage, [u8; 32])> = None;
        let mut sigmas = Vec::with_capacity(received.len());
        for (helper, message) in &received {
            let digest = public_key_package_digest(&message.public_key_package)?;
            match &public {
                None => public = Some((message.public_key_package.clone(), digest)),
                Some((_, d)) if *d != digest => {
                    return Err(ProtocolError::InvalidParameters(format!(
                        "{helper} sent a different public key package"
                    )));
                }
                Some(_) => {}
            }
            let plaintext = sealed::open(
                keys.encryption_secret(),
                &SealContext {
                    session: self.session,
                    from: Party::Participant(*helper),
                    to: self.me,
                    purpose: SIGMA_PURPOSE,
                },
                &message.sigma,
            )?;
            sigmas.push(Sigma::deserialize(&plaintext)?);
        }
        let (public, _) = public.ok_or(ProtocolError::InvalidParameters("no helpers".into()))?;
        if group_key_bytes(&public)? != self.group_key {
            return Err(ProtocolError::InvalidParameters(
                "helpers sent another group".into(),
            ));
        }
        let key_package = repairable::repair_share_part3(&sigmas, self.me.identifier(), &public)?;
        let expected = public
            .verifying_shares()
            .get(&self.me.identifier())
            .ok_or(ProtocolError::UnknownParticipant(self.me))?;
        if key_package.verifying_share() != expected {
            warn!(me = %self.me, "repaired share does not match the published verifying share");
            return Err(ProtocolError::InvalidParameters(
                "repaired share does not match the verifying share".into(),
            ));
        }
        let verifying_share: GroupKeyBytes = key_package
            .verifying_share()
            .serialize()?
            .try_into()
            .map_err(|_| ProtocolError::InvalidParameters("verifying share length".into()))?;
        info!(me = %self.me, "share repaired");
        Ok((
            KeyMaterial {
                key_package,
                public_key_package: public,
            },
            Outbound {
                to: Recipient::Coordinator,
                session: self.session,
                body: Message::RepairResult(RepairResult { verifying_share }),
            },
        ))
    }
}

/// Result of a repair session.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RepairOutcome {
    /// The lost participant holds a verified share again.
    Repaired {
        /// Repaired participant.
        participant: ParticipantId,
    },
    /// The session failed.
    Aborted(AbortReport),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RepairPhase {
    Deltas,
    Sigmas,
    Result,
    Done,
}

impl RepairPhase {
    fn name(self) -> &'static str {
        match self {
            Self::Deltas => "deltas",
            Self::Sigmas => "sigmas",
            Self::Result => "result",
            Self::Done => "done",
        }
    }
}

/// Coordinator state machine for one repair session.
pub struct RepairCoordinator {
    session: SessionId,
    lost: ParticipantId,
    helpers: BTreeSet<ParticipantId>,
    expected_share: GroupKeyBytes,
    phase: RepairPhase,
    deltas: BTreeMap<ParticipantId, SignedEnvelope>,
    sigmas: BTreeMap<ParticipantId, SignedEnvelope>,
    blame: Vec<Blame>,
    outcome: Option<RepairOutcome>,
}

impl RepairCoordinator {
    /// Starts a repair and returns the `RepairStart` messages.
    pub fn new(
        session: SessionId,
        start: RepairStart,
        public: &PublicKeyPackage,
    ) -> Result<(Self, Vec<Outbound>), ProtocolError> {
        let helpers = validate(&start, public)?;
        let expected_share: GroupKeyBytes = public
            .verifying_shares()
            .get(&start.lost.identifier())
            .ok_or(ProtocolError::UnknownParticipant(start.lost))?
            .serialize()?
            .try_into()
            .map_err(|_| ProtocolError::InvalidParameters("verifying share length".into()))?;
        let out = helpers
            .iter()
            .chain(std::iter::once(&start.lost))
            .map(|p| Outbound {
                to: Recipient::Participant(*p),
                session,
                body: Message::RepairStart(start.clone()),
            })
            .collect();
        Ok((
            Self {
                session,
                lost: start.lost,
                helpers,
                expected_share,
                phase: RepairPhase::Deltas,
                deltas: BTreeMap::new(),
                sigmas: BTreeMap::new(),
                blame: Vec::new(),
                outcome: None,
            },
            out,
        ))
    }

    /// Final outcome, once decided.
    #[must_use]
    pub fn outcome(&self) -> Option<&RepairOutcome> {
        self.outcome.as_ref()
    }

    /// Participants the current phase is waiting for.
    #[must_use]
    pub fn awaiting(&self) -> BTreeSet<ParticipantId> {
        match self.phase {
            RepairPhase::Deltas => self
                .helpers
                .iter()
                .copied()
                .filter(|h| !self.deltas.contains_key(h))
                .collect(),
            RepairPhase::Sigmas => self
                .helpers
                .iter()
                .copied()
                .filter(|h| !self.sigmas.contains_key(h))
                .collect(),
            RepairPhase::Result => BTreeSet::from([self.lost]),
            RepairPhase::Done => BTreeSet::new(),
        }
    }

    fn abort(&mut self, note: String) -> Vec<Outbound> {
        let report = AbortReport {
            session: self.session,
            phase: self.phase.name().to_owned(),
            blame: std::mem::take(&mut self.blame),
            disputes: Vec::new(),
            note: Some(note),
        };
        self.phase = RepairPhase::Done;
        self.outcome = Some(RepairOutcome::Aborted(report));
        Vec::new()
    }

    /// Handles an authenticated message.
    pub fn handle(&mut self, message: &Verified) -> Vec<Outbound> {
        let Ok(from) = message.participant() else {
            return Vec::new();
        };
        if message.session() != self.session || self.phase == RepairPhase::Done {
            return Vec::new();
        }
        let is_helper = self.helpers.contains(&from);
        match (self.phase, message.body()) {
            (phase, Message::Refused(r))
                if (is_helper || from == self.lost)
                    && r.refused
                        == match phase {
                            RepairPhase::Deltas => "repair_start",
                            RepairPhase::Sigmas => "repair_delta_bundle",
                            _ => "repair_sigma_bundle",
                        } =>
            {
                if from == self.lost && self.phase == RepairPhase::Result {
                    // The lost participant could not verify the recovered
                    // share: some helper sent a bad sigma (unattributable).
                    return self.abort(format!("repaired share rejected: {}", r.reason));
                }
                self.blame.push(Blame {
                    participant: from,
                    fault: Fault::Declined {
                        reason: r.reason.clone(),
                    },
                });
                self.abort(format!("{from} refused: {}", r.reason))
            }
            (RepairPhase::Deltas, Message::RepairDeltas(_)) if is_helper => {
                self.deltas
                    .entry(from)
                    .or_insert_with(|| message.raw.clone());
                if !self.awaiting().is_empty() {
                    return Vec::new();
                }
                self.phase = RepairPhase::Sigmas;
                self.helpers
                    .iter()
                    .map(|h| Outbound {
                        to: Recipient::Participant(*h),
                        session: self.session,
                        body: Message::RepairDeltaBundle(Bundle {
                            envelopes: self
                                .deltas
                                .iter()
                                .filter(|(k, _)| *k != h)
                                .map(|(_, e)| e.clone())
                                .collect(),
                        }),
                    })
                    .collect()
            }
            (RepairPhase::Sigmas, Message::RepairSigma(_)) if is_helper => {
                self.sigmas
                    .entry(from)
                    .or_insert_with(|| message.raw.clone());
                if !self.awaiting().is_empty() {
                    return Vec::new();
                }
                self.phase = RepairPhase::Result;
                vec![Outbound {
                    to: Recipient::Participant(self.lost),
                    session: self.session,
                    body: Message::RepairSigmaBundle(Bundle {
                        envelopes: self.sigmas.values().cloned().collect(),
                    }),
                }]
            }
            (RepairPhase::Result, Message::RepairResult(r)) if from == self.lost => {
                if r.verifying_share == self.expected_share {
                    self.phase = RepairPhase::Done;
                    self.outcome = Some(RepairOutcome::Repaired {
                        participant: self.lost,
                    });
                    Vec::new()
                } else {
                    self.abort("repaired verifying share mismatch".into())
                }
            }
            _ => Vec::new(),
        }
    }

    /// Declares every awaited participant unresponsive and aborts.
    pub fn on_timeout(&mut self) -> Vec<Outbound> {
        if self.phase == RepairPhase::Done {
            return Vec::new();
        }
        for p in self.awaiting() {
            self.blame.push(Blame {
                participant: p,
                fault: Fault::Unresponsive {
                    phase: self.phase.name().to_owned(),
                },
            });
        }
        self.abort("phase deadline expired".into())
    }
}
