// SPDX-License-Identifier: MIT
//! A deterministic in-memory network that drives the real state machines.
//!
//! Every message is signed, (optionally) passed through an [`Interceptor`]
//! that can drop, reorder or rewrite it, verified by the receiver and handled
//! by the same code the TCP services run. When no message is in flight and
//! the session has no outcome, the phase deadline "expires". This is what the
//! property tests, the chaos tests and `fixtures-gen` use.

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use frost_keccak::{SigningPackage, keys::PublicKeyPackage};
use rand_core::{CryptoRng, RngCore};
use tracing::debug;

use crate::blame::AbortReport;
use crate::envelope::{Recipient, SignedEnvelope};
use crate::error::ProtocolError;
use crate::identity::{GeneratedRoster, PartyKeys, Roster};
use crate::ids::{ParticipantId, Party, SessionId};
use crate::intent::{Approval, CustodyAction, SignerPolicy, VaultDomain};
use crate::keygen::{KeygenCoordinator, KeygenOutcome, group_key_bytes};
use crate::messages::{GroupKeyBytes, KeygenMode, KeygenStart, RepairStart, SignRequest};
use crate::node::{CoordinatorSession, ParticipantNode};
use crate::repair::{RepairCoordinator, RepairOutcome};
use crate::signing::{SessionJournal, SignerState, SigningCoordinator, SigningOutcome};

/// Hook applied to every envelope in flight.
pub trait Interceptor {
    /// Returns the envelopes to deliver in place of `envelope` (empty = drop).
    /// `sender_keys` lets a test play a Byzantine sender that re-signs
    /// modified messages with its own identity.
    fn intercept(
        &mut self,
        from: Party,
        to: Party,
        envelope: SignedEnvelope,
        sender_keys: &PartyKeys,
        roster: &Roster,
    ) -> Vec<SignedEnvelope>;
}

/// Picks the first `t` candidates that hold a share and are not excluded.
#[must_use]
pub fn select_signers(
    public: &PublicKeyPackage,
    candidates: impl IntoIterator<Item = ParticipantId>,
    excluded: &BTreeSet<ParticipantId>,
) -> Option<Vec<ParticipantId>> {
    let threshold = usize::from(public.min_signers()?);
    let chosen: Vec<_> = candidates
        .into_iter()
        .filter(|p| !excluded.contains(p))
        .filter(|p| public.verifying_shares().contains_key(&p.identifier()))
        .take(threshold)
        .collect();
    (chosen.len() == threshold).then_some(chosen)
}

/// Result of [`LocalNetwork::sign_with_retry`].
#[derive(Clone, Debug, PartialEq)]
pub struct SignReport {
    /// Outcome of the last attempt.
    pub outcome: SigningOutcome,
    /// Reports of the failed attempts, in order.
    pub failed_attempts: Vec<AbortReport>,
}

/// An in-memory coordinator plus `n` participant nodes.
pub struct LocalNetwork<R: RngCore + CryptoRng> {
    roster: Roster,
    coordinator: PartyKeys,
    nodes: BTreeMap<ParticipantId, ParticipantNode>,
    groups: BTreeMap<GroupKeyBytes, PublicKeyPackage>,
    offline: BTreeSet<ParticipantId>,
    interceptor: Option<Box<dyn Interceptor>>,
    last_signing_package: Option<SigningPackage>,
    rng: R,
}

impl<R: RngCore + CryptoRng> LocalNetwork<R> {
    /// Generates a roster of `n` participants whose signers are pinned to `domain`.
    pub fn new(n: u16, domain: VaultDomain, mut rng: R) -> Result<Self, ProtocolError> {
        let generated = GeneratedRoster::generate(n, &mut rng)?;
        let mut nodes = BTreeMap::new();
        for (id, keys) in generated.participants {
            let signer = SignerState::new(
                SignerPolicy::permissive(domain),
                SessionJournal::in_memory(),
            );
            nodes.insert(
                id,
                ParticipantNode::new(id, keys, generated.roster.clone(), signer)?,
            );
        }
        Ok(Self {
            roster: generated.roster,
            coordinator: generated.coordinator,
            nodes,
            groups: BTreeMap::new(),
            offline: BTreeSet::new(),
            interceptor: None,
            last_signing_package: None,
            rng,
        })
    }

    /// The roster.
    #[must_use]
    pub fn roster(&self) -> &Roster {
        &self.roster
    }

    /// All participant ids.
    #[must_use]
    pub fn participants(&self) -> Vec<ParticipantId> {
        self.nodes.keys().copied().collect()
    }

    /// A participant node.
    pub fn node(&self, id: ParticipantId) -> Result<&ParticipantNode, ProtocolError> {
        self.nodes
            .get(&id)
            .ok_or(ProtocolError::UnknownParticipant(id))
    }

    /// A participant node, mutably.
    pub fn node_mut(&mut self, id: ParticipantId) -> Result<&mut ParticipantNode, ProtocolError> {
        self.nodes
            .get_mut(&id)
            .ok_or(ProtocolError::UnknownParticipant(id))
    }

    /// Public data of a group known to the coordinator.
    pub fn group(&self, group_key: &GroupKeyBytes) -> Result<&PublicKeyPackage, ProtocolError> {
        self.groups.get(group_key).ok_or(ProtocolError::NoKeyShare)
    }

    /// Takes a participant offline (all its traffic is dropped) or back online.
    pub fn set_offline(&mut self, id: ParticipantId, offline: bool) {
        if offline {
            self.offline.insert(id);
        } else {
            self.offline.remove(&id);
        }
    }

    /// Installs (or removes) the in-flight message hook.
    pub fn set_interceptor(&mut self, interceptor: Option<Box<dyn Interceptor>>) {
        self.interceptor = interceptor;
    }

    /// Signing package of the most recent signing attempt (blame context).
    #[must_use]
    pub fn last_signing_package(&self) -> Option<&SigningPackage> {
        self.last_signing_package.as_ref()
    }

    /// Mutable access to the network's RNG.
    pub fn rng(&mut self) -> &mut R {
        &mut self.rng
    }

    fn keys_of(&self, party: Party) -> Option<&PartyKeys> {
        match party {
            Party::Coordinator => Some(&self.coordinator),
            Party::Participant(p) => self.nodes.get(&p).map(ParticipantNode::keys),
        }
    }

    fn drive(
        &mut self,
        session: &mut CoordinatorSession,
        initial: Vec<crate::envelope::Outbound>,
    ) -> Result<(), ProtocolError> {
        let mut queue: VecDeque<(Party, Party, SignedEnvelope)> = VecDeque::new();
        let push_outbound = |queue: &mut VecDeque<_>,
                             coordinator: &PartyKeys,
                             outs: Vec<crate::envelope::Outbound>|
         -> Result<(), ProtocolError> {
            for o in outs {
                let to = match o.to {
                    Recipient::Participant(p) => Party::Participant(p),
                    Recipient::Coordinator => Party::Coordinator,
                };
                queue.push_back((
                    Party::Coordinator,
                    to,
                    o.sign(Party::Coordinator, coordinator)?,
                ));
            }
            Ok(())
        };
        push_outbound(&mut queue, &self.coordinator, initial)?;
        let mut deadlines = 0u32;
        loop {
            while let Some((from, to, envelope)) = queue.pop_front() {
                let delivered = match self.interceptor.take() {
                    Some(mut interceptor) => {
                        let out = match self.keys_of(from) {
                            Some(keys) => {
                                interceptor.intercept(from, to, envelope, keys, &self.roster)
                            }
                            None => vec![envelope],
                        };
                        self.interceptor = Some(interceptor);
                        out
                    }
                    None => vec![envelope],
                };
                for envelope in delivered {
                    match to {
                        Party::Participant(p) => {
                            if self.offline.contains(&p) {
                                continue;
                            }
                            let Some(node) = self.nodes.get_mut(&p) else {
                                continue;
                            };
                            for reply in node.handle(&envelope, &mut self.rng) {
                                queue.push_back((Party::Participant(p), Party::Coordinator, reply));
                            }
                        }
                        Party::Coordinator => match envelope.verify(&self.roster) {
                            Ok(v) => {
                                let outs = session.handle(&v);
                                push_outbound(&mut queue, &self.coordinator, outs)?;
                            }
                            Err(e) => debug!(error = %e, "coordinator dropped envelope"),
                        },
                    }
                }
            }
            if session.is_done() {
                return Ok(());
            }
            deadlines += 1;
            if deadlines > 16 {
                return Err(ProtocolError::InvalidParameters(
                    "session never terminates".into(),
                ));
            }
            let outs = session.on_timeout();
            push_outbound(&mut queue, &self.coordinator, outs)?;
        }
    }

    fn keygen_session(
        &mut self,
        start: KeygenStart,
        previous: Option<PublicKeyPackage>,
    ) -> Result<KeygenOutcome, ProtocolError> {
        let session = SessionId::random(&mut self.rng);
        let (coordinator, initial) =
            KeygenCoordinator::new(session, start, self.roster.clone(), previous)?;
        let mut state = CoordinatorSession::Keygen(coordinator);
        self.drive(&mut state, initial)?;
        let CoordinatorSession::Keygen(coordinator) = state else {
            return Err(ProtocolError::InvalidParameters(
                "session type changed".into(),
            ));
        };
        let outcome = coordinator
            .outcome()
            .cloned()
            .ok_or(ProtocolError::InvalidParameters(
                "keygen did not finish".into(),
            ))?;
        if let KeygenOutcome::Committed { public_key_package } = &outcome {
            self.groups.insert(
                group_key_bytes(public_key_package)?,
                public_key_package.clone(),
            );
        }
        Ok(outcome)
    }

    /// Runs a Pedersen DKG among `participants` with threshold `threshold`.
    pub fn dkg(
        &mut self,
        threshold: u16,
        participants: &[ParticipantId],
    ) -> Result<KeygenOutcome, ProtocolError> {
        self.keygen_session(
            KeygenStart {
                mode: KeygenMode::Fresh,
                threshold,
                participants: participants.to_vec(),
            },
            None,
        )
    }

    /// Proactively refreshes the shares of `group_key` among `participants`
    /// (a subset of the current holders; omitted holders are evicted).
    pub fn refresh(
        &mut self,
        group_key: GroupKeyBytes,
        participants: &[ParticipantId],
    ) -> Result<KeygenOutcome, ProtocolError> {
        let previous = self.group(&group_key)?.clone();
        let threshold = previous
            .min_signers()
            .ok_or(ProtocolError::InvalidParameters("unknown threshold".into()))?;
        self.keygen_session(
            KeygenStart {
                mode: KeygenMode::Refresh { group_key },
                threshold,
                participants: participants.to_vec(),
            },
            Some(previous),
        )
    }

    /// One signing attempt with an explicit signer set.
    pub fn sign(
        &mut self,
        group_key: GroupKeyBytes,
        action: CustodyAction,
        domain: VaultDomain,
        signers: &[ParticipantId],
    ) -> Result<SigningOutcome, ProtocolError> {
        self.sign_approved(group_key, action, domain, signers, None)
    }

    /// One signing attempt carrying an operator approval (required by
    /// signers whose policy names an approver).
    pub fn sign_approved(
        &mut self,
        group_key: GroupKeyBytes,
        action: CustodyAction,
        domain: VaultDomain,
        signers: &[ParticipantId],
        approval: Option<Approval>,
    ) -> Result<SigningOutcome, ProtocolError> {
        let public = self.group(&group_key)?.clone();
        let session = SessionId::random(&mut self.rng);
        let (coordinator, initial) = SigningCoordinator::new(
            session,
            SignRequest {
                group_key,
                action,
                domain,
                signers: signers.to_vec(),
                approval,
            },
            public,
        )?;
        let mut state = CoordinatorSession::Signing(coordinator);
        self.drive(&mut state, initial)?;
        let CoordinatorSession::Signing(coordinator) = state else {
            return Err(ProtocolError::InvalidParameters(
                "session type changed".into(),
            ));
        };
        self.last_signing_package = coordinator.signing_package().cloned();
        coordinator
            .outcome()
            .cloned()
            .ok_or(ProtocolError::InvalidParameters(
                "signing did not finish".into(),
            ))
    }

    /// Signs with automatic retries: after an abort, every participant named
    /// in the report is excluded and a fresh session is started with the next
    /// eligible signers, until a signature is produced or fewer than `t`
    /// eligible participants remain.
    pub fn sign_with_retry(
        &mut self,
        group_key: GroupKeyBytes,
        action: CustodyAction,
        domain: VaultDomain,
    ) -> Result<SignReport, ProtocolError> {
        let public = self.group(&group_key)?.clone();
        let mut excluded = BTreeSet::new();
        let mut failed_attempts = Vec::new();
        loop {
            let Some(signers) = select_signers(&public, self.participants(), &excluded) else {
                let outcome = failed_attempts
                    .last()
                    .cloned()
                    .map(SigningOutcome::Aborted)
                    .ok_or(ProtocolError::InvalidParameters(
                        "not enough signers".into(),
                    ))?;
                return Ok(SignReport {
                    outcome,
                    failed_attempts,
                });
            };
            match self.sign(group_key, action.clone(), domain, &signers)? {
                SigningOutcome::Aborted(report) => {
                    excluded.extend(report.excluded());
                    failed_attempts.push(report);
                }
                signed => {
                    return Ok(SignReport {
                        outcome: signed,
                        failed_attempts,
                    });
                }
            }
        }
    }

    /// Repairs `lost`'s share of `group_key` with the given helpers.
    pub fn repair(
        &mut self,
        group_key: GroupKeyBytes,
        lost: ParticipantId,
        helpers: &[ParticipantId],
    ) -> Result<RepairOutcome, ProtocolError> {
        let public = self.group(&group_key)?.clone();
        let session = SessionId::random(&mut self.rng);
        let (coordinator, initial) = RepairCoordinator::new(
            session,
            RepairStart {
                group_key,
                lost,
                helpers: helpers.to_vec(),
            },
            &public,
        )?;
        let mut state = CoordinatorSession::Repair(coordinator);
        self.drive(&mut state, initial)?;
        let CoordinatorSession::Repair(coordinator) = state else {
            return Err(ProtocolError::InvalidParameters(
                "session type changed".into(),
            ));
        };
        coordinator
            .outcome()
            .cloned()
            .ok_or(ProtocolError::InvalidParameters(
                "repair did not finish".into(),
            ))
    }
}
