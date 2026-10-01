// SPDX-License-Identifier: MIT
//! Long-lived participant node and the coordinator session wrapper.
//!
//! [`ParticipantNode`] is the complete participant: it authenticates every
//! incoming envelope, dispatches it to the right session state machine, and
//! signs its replies. Transport drivers (the in-memory [`crate::local`]
//! network, the TCP service in `custody-net`) only move bytes.
//!
//! Every session id is burned in the node's
//! [`SessionJournal`](crate::signing::SessionJournal) before the node's first
//! message for it leaves, so a replayed start message never makes
//! the node answer the same step twice. In-flight sessions live in bounded
//! [`SessionTable`]s and expire, so the coordinator cannot make a node
//! accumulate secret state.

use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant};

use rand_core::{CryptoRng, RngCore};
use tracing::warn;

use crate::envelope::{Outbound, Recipient, SignedEnvelope, Verified};
use crate::error::ProtocolError;
use crate::identity::{PartyKeys, Roster};
use crate::ids::{ParticipantId, Party, SessionId};
use crate::intent::SignerPolicy;
use crate::keygen::{KeyMaterial, KeygenCoordinator, KeygenParticipant};
use crate::messages::{GroupKeyBytes, KeygenMode, Message, Refused};
use crate::repair::{RepairCoordinator, RepairHelper, RepairRecipient};
use crate::sessions::SessionTable;
use crate::signing::{MAX_PENDING_SESSIONS, SignerState, SigningCoordinator};

/// Number of in-flight sessions a node holds, by kind.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PendingSessions {
    /// DKG or refresh sessions (secret polynomials, sent shares).
    pub keygen: usize,
    /// Signing sessions (nonces).
    pub signing: usize,
    /// Repair sessions as a helper (deltas).
    pub repair_helper: usize,
    /// Repair sessions as the participant being repaired.
    pub repair_recipient: usize,
}

/// A participant: identity, key shares and all in-flight sessions.
pub struct ParticipantNode {
    me: ParticipantId,
    keys: PartyKeys,
    roster: Roster,
    shares: BTreeMap<GroupKeyBytes, KeyMaterial>,
    keygen: SessionTable<KeygenParticipant>,
    signer: SignerState,
    helpers: SessionTable<RepairHelper>,
    recipients: SessionTable<RepairRecipient>,
}

impl ParticipantNode {
    /// Creates a node; its keys must match its roster entry.
    pub fn new(
        me: ParticipantId,
        keys: PartyKeys,
        roster: Roster,
        signer: SignerState,
    ) -> Result<Self, ProtocolError> {
        if roster.entry(me)?.identity != keys.public() {
            return Err(ProtocolError::InvalidParameters(format!(
                "keys of {me} do not match the roster"
            )));
        }
        Ok(Self {
            me,
            keys,
            roster,
            shares: BTreeMap::new(),
            keygen: SessionTable::new(MAX_PENDING_SESSIONS),
            signer,
            helpers: SessionTable::new(MAX_PENDING_SESSIONS),
            recipients: SessionTable::new(MAX_PENDING_SESSIONS),
        })
    }

    /// This participant's id.
    #[must_use]
    pub fn id(&self) -> ParticipantId {
        self.me
    }

    /// Transport keys (used by drivers to authenticate the connection).
    #[must_use]
    pub fn keys(&self) -> &PartyKeys {
        &self.keys
    }

    /// The roster.
    #[must_use]
    pub fn roster(&self) -> &Roster {
        &self.roster
    }

    /// Key shares held, by group key.
    #[must_use]
    pub fn shares(&self) -> &BTreeMap<GroupKeyBytes, KeyMaterial> {
        &self.shares
    }

    /// Installs key material (e.g. loaded from sealed storage).
    pub fn install_share(&mut self, material: KeyMaterial) -> Result<(), ProtocolError> {
        self.shares.insert(material.group_key()?, material);
        Ok(())
    }

    /// Drops a share (used to simulate share loss before a repair).
    pub fn forget_share(&mut self, group_key: &GroupKeyBytes) -> Option<KeyMaterial> {
        self.shares.remove(group_key)
    }

    /// Signer state (policy, journal).
    #[must_use]
    pub fn signer(&self) -> &SignerState {
        &self.signer
    }

    /// Replaces the signer policy (operator action).
    pub fn set_policy(&mut self, policy: SignerPolicy) {
        self.signer.set_policy(policy);
    }

    /// In-flight sessions, by kind.
    #[must_use]
    pub fn pending_sessions(&self) -> PendingSessions {
        PendingSessions {
            keygen: self.keygen.len(),
            signing: self.signer.pending_len(),
            repair_helper: self.helpers.len(),
            repair_recipient: self.recipients.len(),
        }
    }

    /// Drops (and zeroises) every in-flight session older than `max_age`.
    /// Returns how many were dropped. Drivers call this periodically.
    pub fn expire_sessions(&mut self, max_age: Duration) -> usize {
        self.expire_sessions_at(Instant::now(), max_age)
    }

    /// [`Self::expire_sessions`] with an explicit clock.
    pub fn expire_sessions_at(&mut self, now: Instant, max_age: Duration) -> usize {
        let dropped = self.keygen.expire(now, max_age).len()
            + self.helpers.expire(now, max_age).len()
            + self.recipients.expire(now, max_age).len()
            + self.signer.expire(now, max_age);
        if dropped > 0 {
            warn!(me = %self.me, dropped, "expired abandoned sessions");
        }
        dropped
    }

    /// Handles one envelope from the coordinator and returns the signed replies.
    /// Envelopes that fail authentication are dropped; protocol errors are
    /// answered with a signed [`Refused`] so the coordinator can abort early.
    pub fn handle<R: RngCore + CryptoRng>(
        &mut self,
        envelope: &SignedEnvelope,
        rng: &mut R,
    ) -> Vec<SignedEnvelope> {
        let verified = match envelope.verify(&self.roster) {
            Ok(v) => v,
            Err(e) => {
                warn!(me = %self.me, error = %e, "dropping unauthenticated envelope");
                return Vec::new();
            }
        };
        if verified.from() != Party::Coordinator
            || verified.envelope.to != Recipient::Participant(self.me)
        {
            warn!(me = %self.me, from = %verified.from(), "dropping misrouted envelope");
            return Vec::new();
        }
        let session = verified.session();
        let reply = match self.dispatch(&verified, rng) {
            Ok(reply) => reply,
            Err(e) => {
                warn!(me = %self.me, %session, error = %e, kind = verified.body().kind(), "refusing");
                Some(Outbound {
                    to: Recipient::Coordinator,
                    session,
                    body: Message::Refused(Refused {
                        refused: verified.body().kind().to_owned(),
                        reason: e.to_string(),
                    }),
                })
            }
        };
        reply
            .into_iter()
            .filter_map(|o| match o.sign(Party::Participant(self.me), &self.keys) {
                Ok(env) => Some(env),
                Err(e) => {
                    warn!(me = %self.me, error = %e, "cannot sign reply");
                    None
                }
            })
            .collect()
    }

    fn session_is_fresh(&self, session: &SessionId) -> Result<(), ProtocolError> {
        if self.keygen.contains(session)
            || self.helpers.contains(session)
            || self.recipients.contains(session)
            || self.signer.journal().contains(session)
        {
            return Err(ProtocolError::SessionAlreadyUsed(*session));
        }
        Ok(())
    }

    fn log_evicted(&self, kind: &str, evicted: Vec<SessionId>) {
        for session in evicted {
            warn!(me = %self.me, %session, kind, "dropping the oldest abandoned session");
        }
    }

    fn dispatch<R: RngCore + CryptoRng>(
        &mut self,
        v: &Verified,
        rng: &mut R,
    ) -> Result<Option<Outbound>, ProtocolError> {
        let session = v.session();
        match v.body() {
            Message::KeygenStart(start) => {
                self.session_is_fresh(&session)?;
                let previous = match start.mode {
                    KeygenMode::Fresh => None,
                    KeygenMode::Refresh { group_key } => Some(
                        self.shares
                            .get(&group_key)
                            .cloned()
                            .ok_or(ProtocolError::NoKeyShare)?,
                    ),
                };
                let (state, out) =
                    KeygenParticipant::start(session, self.me, start, previous, rng)?;
                // Burned before the round-one message leaves: a replayed
                // KeygenStart (even after the session finished) is refused.
                self.signer.burn_session(session)?;
                let evicted = self.keygen.insert(session, state);
                self.log_evicted("keygen", evicted);
                Ok(Some(out))
            }
            Message::KeygenRound1Bundle(bundle) => {
                let state = self
                    .keygen
                    .get_mut(&session)
                    .ok_or(ProtocolError::UnknownSession(session))?;
                Ok(Some(state.on_round1_bundle(
                    bundle,
                    &self.roster,
                    &self.keys,
                    rng,
                )?))
            }
            Message::KeygenRound2Bundle(bundle) => {
                let state = self
                    .keygen
                    .get_mut(&session)
                    .ok_or(ProtocolError::UnknownSession(session))?;
                Ok(Some(state.on_round2_bundle(
                    bundle,
                    &self.roster,
                    &self.keys,
                )?))
            }
            Message::KeygenRevealRequest(request) => {
                let state = self
                    .keygen
                    .get_mut(&session)
                    .ok_or(ProtocolError::UnknownSession(session))?;
                Ok(Some(state.on_reveal_request(request, &self.roster)?))
            }
            Message::KeygenFinished(finished) => {
                let mut state = self
                    .keygen
                    .remove(&session)
                    .ok_or(ProtocolError::UnknownSession(session))?;
                if let Some(material) = state.on_finished(finished, &self.roster)? {
                    self.install_share(material)?;
                }
                Ok(None)
            }
            Message::SignRequest(request) => Ok(Some(self.signer.on_sign_request(
                session,
                self.me,
                request,
                &self.shares,
                rng,
            )?)),
            Message::SignPackage(package) => {
                let group_key = self
                    .signer
                    .pending_group_key(&session)
                    .ok_or(ProtocolError::UnknownSession(session))?;
                let material = self
                    .shares
                    .get(&group_key)
                    .ok_or(ProtocolError::NoKeyShare)?;
                Ok(Some(self.signer.on_sign_package(
                    session,
                    &package.package,
                    material,
                )?))
            }
            Message::RepairStart(start) => {
                self.session_is_fresh(&session)?;
                if start.lost == self.me {
                    let state = RepairRecipient::start(session, self.me, start)?;
                    self.signer.burn_session(session)?;
                    let evicted = self.recipients.insert(session, state);
                    self.log_evicted("repair recipient", evicted);
                    Ok(None)
                } else {
                    let material = self
                        .shares
                        .get(&start.group_key)
                        .ok_or(ProtocolError::NoKeyShare)?;
                    let (state, out) =
                        RepairHelper::start(session, self.me, start, material, &self.roster, rng)?;
                    // Burned before the deltas leave: a replayed RepairStart
                    // can never make this helper split its share twice.
                    self.signer.burn_session(session)?;
                    let evicted = self.helpers.insert(session, state);
                    self.log_evicted("repair helper", evicted);
                    Ok(Some(out))
                }
            }
            Message::RepairDeltaBundle(bundle) => {
                let state = self
                    .helpers
                    .remove(&session)
                    .ok_or(ProtocolError::UnknownSession(session))?;
                let material = self
                    .shares
                    .get(&state.group_key())
                    .ok_or(ProtocolError::NoKeyShare)?;
                Ok(Some(state.on_delta_bundle(
                    bundle,
                    material,
                    &self.roster,
                    &self.keys,
                    rng,
                )?))
            }
            Message::RepairSigmaBundle(bundle) => {
                let state = self
                    .recipients
                    .remove(&session)
                    .ok_or(ProtocolError::UnknownSession(session))?;
                let (material, out) = state.on_sigma_bundle(bundle, &self.roster, &self.keys)?;
                self.install_share(material)?;
                Ok(Some(out))
            }
            other => Err(ProtocolError::UnexpectedMessage {
                got: other.kind(),
                state: "participant",
            }),
        }
    }
}

/// Any coordinator-side session.
pub enum CoordinatorSession {
    /// DKG or refresh.
    Keygen(KeygenCoordinator),
    /// Signing attempt.
    Signing(SigningCoordinator),
    /// Share repair.
    Repair(RepairCoordinator),
}

impl CoordinatorSession {
    /// Handles an authenticated message.
    pub fn handle(&mut self, message: &Verified) -> Vec<Outbound> {
        match self {
            Self::Keygen(s) => s.handle(message),
            Self::Signing(s) => s.handle(message),
            Self::Repair(s) => s.handle(message),
        }
    }

    /// Handles the expiry of the current phase deadline.
    pub fn on_timeout(&mut self) -> Vec<Outbound> {
        match self {
            Self::Keygen(s) => s.on_timeout(),
            Self::Signing(s) => s.on_timeout(),
            Self::Repair(s) => s.on_timeout(),
        }
    }

    /// Participants the current phase waits for.
    #[must_use]
    pub fn awaiting(&self) -> BTreeSet<ParticipantId> {
        match self {
            Self::Keygen(s) => s.awaiting(),
            Self::Signing(s) => s.awaiting(),
            Self::Repair(s) => s.awaiting(),
        }
    }

    /// Whether an outcome was decided.
    #[must_use]
    pub fn is_done(&self) -> bool {
        match self {
            Self::Keygen(s) => s.outcome().is_some(),
            Self::Signing(s) => s.outcome().is_some(),
            Self::Repair(s) => s.outcome().is_some(),
        }
    }
}
