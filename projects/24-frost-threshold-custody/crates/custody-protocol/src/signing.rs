// SPDX-License-Identifier: MIT
//! Two-round FROST signing with identifiable aborts and nonce-reuse protection.
//!
//! Signer rules (enforced in [`SignerState`]):
//! 1. A session identifier is burned the moment nonces are generated for it;
//!    a second `SignRequest` or `SignPackage` for the same session is refused.
//! 2. Nonces live only in memory, are consumed by the first round-two call
//!    and are zeroised on drop (frost-core `SigningNonces: ZeroizeOnDrop`).
//! 3. The signer computes the EIP-712 digest itself from the structured
//!    action, checks it against its [`SignerPolicy`] and refuses a package
//!    whose message or signer set differs from the request it committed to.
//! 4. A key rotation is signed only towards a group key this signer holds a
//!    committed share of, with a threshold at least that of the signing group,
//!    so the coordinator can never move the vault to a key it controls.
//!
//! The coordinator aggregates with `CheaterDetection::AllCheaters`; every
//! culprit is reported with its own signed share as evidence.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use frost_keccak::{
    CheaterDetection, Signature, SigningPackage,
    evm::{EvmGroupKey, EvmSignature},
    keys::PublicKeyPackage,
    round1::{self, SigningCommitments, SigningNonces},
    round2::{self, SignatureShare},
};
use rand_core::{CryptoRng, RngCore};
use sha2::{Digest, Sha256};
use tracing::{info, warn};

use crate::blame::{AbortReport, Blame, Fault};
use crate::envelope::{Outbound, Recipient, SignedEnvelope, Verified};
use crate::error::ProtocolError;
use crate::ids::{ParticipantId, SessionId};
use crate::intent::{CustodyAction, KeyRotation, SignerPolicy};
use crate::keygen::{KeyMaterial, group_key_bytes};
use crate::messages::{
    GroupKeyBytes, Message, SignCommitment, SignPackage, SignRequest, SignShare,
};
use crate::sessions::SessionTable;

/// SHA-256 of a signing package's canonical serialisation.
pub fn signing_package_digest(package: &SigningPackage) -> Result<[u8; 32], ProtocolError> {
    Ok(Sha256::digest(package.serialize()?).into())
}

/// Durable set of session identifiers a node has used.
///
/// Every session a node takes part in (signing, keygen, repair) is burned
/// before the node's first message for it leaves, so a replayed start message
/// can never make an honest node answer the same step twice (which would
/// reuse nonces, or look like equivocation). With a journal path, every
/// identifier is appended and fsynced first, so this also holds across
/// restarts.
#[derive(Debug, Default)]
pub struct SessionJournal {
    used: BTreeSet<SessionId>,
    path: Option<PathBuf>,
}

impl SessionJournal {
    /// In-memory journal.
    #[must_use]
    pub fn in_memory() -> Self {
        Self::default()
    }

    /// Journal persisted at `path` (created if missing).
    pub fn open(path: PathBuf) -> Result<Self, ProtocolError> {
        let mut used = BTreeSet::new();
        if path.exists() {
            for line in BufReader::new(File::open(&path)?).lines() {
                let line = line?;
                let raw = hex::decode(line.trim())
                    .map_err(|e| ProtocolError::InvalidParameters(format!("journal: {e}")))?;
                let bytes: [u8; 16] = raw
                    .try_into()
                    .map_err(|_| ProtocolError::InvalidParameters("journal entry length".into()))?;
                used.insert(SessionId(bytes));
            }
        }
        Ok(Self {
            used,
            path: Some(path),
        })
    }

    /// Whether `session` was already used.
    #[must_use]
    pub fn contains(&self, session: &SessionId) -> bool {
        self.used.contains(session)
    }

    /// Burns `session`; fails if it was already burned.
    pub fn burn(&mut self, session: SessionId) -> Result<(), ProtocolError> {
        if self.used.contains(&session) {
            return Err(ProtocolError::SessionAlreadyUsed(session));
        }
        if let Some(path) = &self.path {
            let mut file = OpenOptions::new().create(true).append(true).open(path)?;
            writeln!(file, "{session}")?;
            file.sync_all()?;
        }
        self.used.insert(session);
        Ok(())
    }

    /// Number of burned sessions.
    #[must_use]
    pub fn len(&self) -> usize {
        self.used.len()
    }

    /// Whether no session was burned yet.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.used.is_empty()
    }
}

struct PendingSignature {
    group_key: GroupKeyBytes,
    nonces: SigningNonces,
    commitments: SigningCommitments,
    digest: [u8; 32],
    signers: BTreeSet<ParticipantId>,
}

/// Upper bound on in-flight sessions of each kind (signing nonces, keygen
/// secrets, repair deltas) a node keeps. When exceeded, the oldest session is
/// dropped (its secrets are zeroised and it can no longer complete), so
/// abandoned sessions cannot accumulate secrets in memory.
pub const MAX_PENDING_SESSIONS: usize = 64;

/// How long an in-flight session may stay open before
/// [`crate::node::ParticipantNode::expire_sessions`] drops it.
pub const SESSION_TTL: Duration = Duration::from_secs(600);

/// Signer-side state: policy, pending nonces and the session journal.
pub struct SignerState {
    policy: SignerPolicy,
    pending: SessionTable<PendingSignature>,
    journal: SessionJournal,
}

impl SignerState {
    /// Creates a signer with the given policy and journal.
    #[must_use]
    pub fn new(policy: SignerPolicy, journal: SessionJournal) -> Self {
        Self {
            policy,
            pending: SessionTable::new(MAX_PENDING_SESSIONS),
            journal,
        }
    }

    /// The local policy.
    #[must_use]
    pub fn policy(&self) -> &SignerPolicy {
        &self.policy
    }

    /// Replaces the local policy (operator action).
    pub fn set_policy(&mut self, policy: SignerPolicy) {
        self.policy = policy;
    }

    /// The session journal.
    #[must_use]
    pub fn journal(&self) -> &SessionJournal {
        &self.journal
    }

    /// Burns a (keygen or repair) session identifier in the journal.
    pub fn burn_session(&mut self, session: SessionId) -> Result<(), ProtocolError> {
        if self.pending.contains(&session) {
            return Err(ProtocolError::SessionAlreadyUsed(session));
        }
        self.journal.burn(session)
    }

    /// Number of sessions holding live nonces.
    #[must_use]
    pub fn pending_len(&self) -> usize {
        self.pending.len()
    }

    /// Group key a pending session committed to, if the session is still live.
    #[must_use]
    pub fn pending_group_key(&self, session: &SessionId) -> Option<GroupKeyBytes> {
        self.pending.get(session).map(|p| p.group_key)
    }

    /// Drops (and zeroises) nonces of sessions opened before `now - max_age`.
    pub fn expire(&mut self, now: Instant, max_age: Duration) -> usize {
        self.pending.expire(now, max_age).len()
    }

    /// Round one: validates the request against the policy and the shares
    /// this signer holds, burns the session and commits to fresh nonces.
    pub fn on_sign_request<R: RngCore + CryptoRng>(
        &mut self,
        session: SessionId,
        me: ParticipantId,
        request: &SignRequest,
        shares: &BTreeMap<GroupKeyBytes, KeyMaterial>,
        rng: &mut R,
    ) -> Result<Outbound, ProtocolError> {
        if self.journal.contains(&session) || self.pending.contains(&session) {
            return Err(ProtocolError::SessionAlreadyUsed(session));
        }
        let material = shares
            .get(&request.group_key)
            .ok_or(ProtocolError::NoKeyShare)?;
        if group_key_bytes(&material.public_key_package)? != request.group_key {
            return Err(ProtocolError::InvalidParameters(
                "wrong key share set".into(),
            ));
        }
        let signers: BTreeSet<ParticipantId> = request.signers.iter().copied().collect();
        if signers.len() != request.signers.len() || !signers.contains(&me) {
            return Err(ProtocolError::InvalidParameters(
                "invalid signer set".into(),
            ));
        }
        if signers.len() < usize::from(*material.key_package.min_signers()) {
            return Err(ProtocolError::InvalidParameters(
                "signer set below threshold".into(),
            ));
        }
        if signers.iter().any(|p| {
            !material
                .public_key_package
                .verifying_shares()
                .contains_key(&p.identifier())
        }) {
            return Err(ProtocolError::InvalidParameters(
                "unknown signer in set".into(),
            ));
        }
        self.policy
            .check(&request.action, &request.domain, request.approval.as_ref())?;
        if let CustodyAction::KeyRotation(rotation) = &request.action {
            check_rotation_target(rotation, material, shares)?;
        }

        let digest = request.action.signing_hash(&request.domain);
        self.journal.burn(session)?;
        let (nonces, commitments) = round1::commit(material.key_package.signing_share(), rng);
        let evicted = self.pending.insert(
            session,
            PendingSignature {
                group_key: request.group_key,
                nonces,
                commitments,
                digest,
                signers,
            },
        );
        for oldest in evicted {
            warn!(%me, session = %oldest, "dropping nonces of an abandoned session");
        }
        info!(%me, %session, action = request.action.kind(), "committed to nonces");
        Ok(Outbound {
            to: Recipient::Coordinator,
            session,
            body: Message::SignCommitment(SignCommitment { commitments }),
        })
    }

    /// Round two: checks the package against the pending request and returns
    /// the signature share. The nonces are consumed whatever the outcome.
    pub fn on_sign_package(
        &mut self,
        session: SessionId,
        package: &SigningPackage,
        material: &KeyMaterial,
    ) -> Result<Outbound, ProtocolError> {
        let pending = self
            .pending
            .remove(&session)
            .ok_or(ProtocolError::UnknownSession(session))?;
        if group_key_bytes(&material.public_key_package)? != pending.group_key {
            return Err(ProtocolError::PackageMismatch("key share set"));
        }
        if package.message().as_slice() != pending.digest {
            return Err(ProtocolError::PackageMismatch(
                "message differs from the request",
            ));
        }
        let in_package: BTreeSet<_> = package.signing_commitments().keys().copied().collect();
        let expected: BTreeSet<_> = pending.signers.iter().map(|p| p.identifier()).collect();
        if in_package != expected {
            return Err(ProtocolError::PackageMismatch(
                "signer set differs from the request",
            ));
        }
        let mine = package.signing_commitment(material.key_package.identifier());
        if mine != Some(pending.commitments) {
            return Err(ProtocolError::PackageMismatch("own commitment altered"));
        }
        let share = round2::sign(package, &pending.nonces, &material.key_package)?;
        Ok(Outbound {
            to: Recipient::Coordinator,
            session,
            body: Message::SignShare(SignShare {
                share,
                package_digest: signing_package_digest(package)?,
            }),
        })
    }
}

/// A rotation moves the vault to a key that authorises everything, so a
/// signer only helps rotate towards a group it is itself a committed member
/// of (a DKG it took part in, whose key the coordinator never learns), and
/// never towards a group with a lower threshold than the one signing. The
/// new group's own proof-of-possession signature is a rotation towards itself
/// and passes the same rule.
fn check_rotation_target(
    rotation: &KeyRotation,
    signing: &KeyMaterial,
    shares: &BTreeMap<GroupKeyBytes, KeyMaterial>,
) -> Result<(), ProtocolError> {
    let target = EvmGroupKey {
        x: rotation.newPubKeyX.to_be_bytes(),
        y_parity: rotation.newPubKeyYParity,
    };
    let held = shares
        .values()
        .find(|m| {
            EvmGroupKey::from_verifying_key(m.public_key_package.verifying_key()) == Ok(target)
        })
        .ok_or_else(|| {
            ProtocolError::PolicyViolation(
                "rotation target is not a group key this signer holds a committed share of".into(),
            )
        })?;
    let (Some(new_threshold), Some(threshold)) = (
        held.public_key_package.min_signers(),
        signing.public_key_package.min_signers(),
    ) else {
        return Err(ProtocolError::PolicyViolation(
            "rotation between groups of unknown threshold".into(),
        ));
    };
    if new_threshold < threshold {
        return Err(ProtocolError::PolicyViolation(format!(
            "rotation would lower the threshold from {threshold} to {new_threshold}"
        )));
    }
    Ok(())
}

/// Result of a signing session.
#[derive(Clone, Debug, PartialEq)]
pub enum SigningOutcome {
    /// Aggregate signature, valid under the group key.
    Signed {
        /// FROST signature.
        signature: Signature,
        /// `(address(R), z)` form accepted by the vault.
        evm: EvmSignature,
        /// Signing set.
        signers: BTreeSet<ParticipantId>,
    },
    /// The session failed.
    Aborted(AbortReport),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SigningPhase {
    Commit,
    Share,
    Done,
}

impl SigningPhase {
    fn name(self) -> &'static str {
        match self {
            Self::Commit => "commit",
            Self::Share => "share",
            Self::Done => "done",
        }
    }
}

/// Coordinator state machine for one signing attempt.
pub struct SigningCoordinator {
    session: SessionId,
    signers: BTreeSet<ParticipantId>,
    digest: [u8; 32],
    public_key_package: PublicKeyPackage,
    phase: SigningPhase,
    commitments: BTreeMap<ParticipantId, (SigningCommitments, SignedEnvelope)>,
    package: Option<(SigningPackage, [u8; 32])>,
    shares: BTreeMap<ParticipantId, (SignatureShare, [u8; 32], SignedEnvelope)>,
    blame: Vec<Blame>,
    outcome: Option<SigningOutcome>,
}

impl SigningCoordinator {
    /// Starts a signing attempt: returns the `SignRequest` messages.
    pub fn new(
        session: SessionId,
        request: SignRequest,
        public_key_package: PublicKeyPackage,
    ) -> Result<(Self, Vec<Outbound>), ProtocolError> {
        let signers: BTreeSet<_> = request.signers.iter().copied().collect();
        let threshold = public_key_package
            .min_signers()
            .ok_or(ProtocolError::InvalidParameters("unknown threshold".into()))?;
        if signers.len() != request.signers.len() || signers.len() < usize::from(threshold) {
            return Err(ProtocolError::InvalidParameters(format!(
                "need {threshold} distinct signers, got {}",
                signers.len()
            )));
        }
        if group_key_bytes(&public_key_package)? != request.group_key {
            return Err(ProtocolError::InvalidParameters(
                "request names another group".into(),
            ));
        }
        let digest = request.action.signing_hash(&request.domain);
        let out = signers
            .iter()
            .map(|p| Outbound {
                to: Recipient::Participant(*p),
                session,
                body: Message::SignRequest(request.clone()),
            })
            .collect();
        Ok((
            Self {
                session,
                signers,
                digest,
                public_key_package,
                phase: SigningPhase::Commit,
                commitments: BTreeMap::new(),
                package: None,
                shares: BTreeMap::new(),
                blame: Vec::new(),
                outcome: None,
            },
            out,
        ))
    }

    /// Final outcome, once decided.
    #[must_use]
    pub fn outcome(&self) -> Option<&SigningOutcome> {
        self.outcome.as_ref()
    }

    /// The signing package sent in round two (evidence context for blame).
    #[must_use]
    pub fn signing_package(&self) -> Option<&SigningPackage> {
        self.package.as_ref().map(|(p, _)| p)
    }

    /// Signers the current phase is waiting for.
    #[must_use]
    pub fn awaiting(&self) -> BTreeSet<ParticipantId> {
        let have: BTreeSet<ParticipantId> = match self.phase {
            SigningPhase::Commit => self.commitments.keys().copied().collect(),
            SigningPhase::Share => self.shares.keys().copied().collect(),
            SigningPhase::Done => return BTreeSet::new(),
        };
        self.signers.difference(&have).copied().collect()
    }

    fn abort(&mut self, note: String) -> Vec<Outbound> {
        let report = AbortReport {
            session: self.session,
            phase: self.phase.name().to_owned(),
            blame: std::mem::take(&mut self.blame),
            disputes: Vec::new(),
            note: Some(note),
        };
        warn!(session = %self.session, culprits = ?report.culprits(), "signing aborted");
        self.phase = SigningPhase::Done;
        self.outcome = Some(SigningOutcome::Aborted(report));
        Vec::new()
    }

    /// Handles an authenticated message from a signer.
    pub fn handle(&mut self, message: &Verified) -> Vec<Outbound> {
        let Ok(from) = message.participant() else {
            return Vec::new();
        };
        if message.session() != self.session || !self.signers.contains(&from) {
            return Vec::new();
        }
        match (self.phase, message.body()) {
            (SigningPhase::Commit | SigningPhase::Share, Message::Refused(refused)) => {
                // A refusal from a signer that already answered the current
                // phase concerns a duplicate delivery and is ignored.
                let current = match self.phase {
                    SigningPhase::Commit => "sign_request",
                    _ => "sign_package",
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
                self.abort(format!("{from} refused: {}", refused.reason))
            }
            (SigningPhase::Commit, Message::SignCommitment(c)) => {
                if let Some((_, first)) = self.commitments.get(&from) {
                    if first.payload != message.raw.payload {
                        self.blame.push(Blame {
                            participant: from,
                            fault: Fault::Equivocation {
                                first: first.clone(),
                                second: message.raw.clone(),
                            },
                        });
                        return self.abort(format!("{from} equivocated on its commitments"));
                    }
                    return Vec::new();
                }
                self.commitments
                    .insert(from, (c.commitments, message.raw.clone()));
                if !self.awaiting().is_empty() {
                    return Vec::new();
                }
                let commitments = self
                    .commitments
                    .iter()
                    .map(|(k, (c, _))| (k.identifier(), *c))
                    .collect();
                let package = SigningPackage::new(commitments, &self.digest);
                let digest = match signing_package_digest(&package) {
                    Ok(d) => d,
                    Err(e) => return self.abort(e.to_string()),
                };
                self.package = Some((package.clone(), digest));
                self.phase = SigningPhase::Share;
                self.signers
                    .iter()
                    .map(|p| Outbound {
                        to: Recipient::Participant(*p),
                        session: self.session,
                        body: Message::SignPackage(SignPackage {
                            package: package.clone(),
                        }),
                    })
                    .collect()
            }
            (SigningPhase::Share, Message::SignShare(s)) => {
                if self.shares.contains_key(&from) {
                    return Vec::new();
                }
                self.shares
                    .insert(from, (s.share, s.package_digest, message.raw.clone()));
                if self.awaiting().is_empty() {
                    self.aggregate();
                }
                Vec::new()
            }
            _ => Vec::new(),
        }
    }

    fn aggregate(&mut self) {
        let Some((package, package_digest)) = self.package.clone() else {
            return;
        };
        // A share bound to a different package digest is reported as invalid
        // even if the scalar happened to verify.
        for (p, (_, digest, raw)) in &self.shares {
            if *digest != package_digest {
                self.blame.push(Blame {
                    participant: *p,
                    fault: Fault::MalformedMessage {
                        envelope: raw.clone(),
                        detail: "share bound to another signing package".into(),
                    },
                });
            }
        }
        let shares = self
            .shares
            .iter()
            .map(|(k, (s, _, _))| (k.identifier(), *s))
            .collect();
        match frost_keccak::aggregate_custom(
            &package,
            &shares,
            &self.public_key_package,
            CheaterDetection::AllCheaters,
        ) {
            Ok(signature) if self.blame.is_empty() => {
                match EvmSignature::from_signature(&signature) {
                    Ok(evm) => {
                        info!(session = %self.session, "aggregate signature produced");
                        self.phase = SigningPhase::Done;
                        self.outcome = Some(SigningOutcome::Signed {
                            signature,
                            evm,
                            signers: self.signers.clone(),
                        });
                    }
                    Err(e) => {
                        self.abort(e.to_string());
                    }
                }
            }
            Ok(_) => {
                self.abort("share bound to another package".into());
            }
            Err(frost_core::Error::InvalidSignatureShare { culprits }) => {
                for culprit in culprits {
                    if let Some(p) = ParticipantId::from_identifier(&culprit, self.signers.iter())
                        && let Some((_, _, raw)) = self.shares.get(&p)
                    {
                        self.blame.push(Blame {
                            participant: p,
                            fault: Fault::InvalidSignatureShare { share: raw.clone() },
                        });
                    }
                }
                self.abort("invalid signature shares".into());
            }
            Err(e) => {
                self.abort(format!("aggregation failed: {e}"));
            }
        }
    }

    /// Declares every awaited signer unresponsive and aborts.
    pub fn on_timeout(&mut self) -> Vec<Outbound> {
        if self.phase == SigningPhase::Done {
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
