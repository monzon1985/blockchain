// SPDX-License-Identifier: MIT
//! Protocol message bodies.

use frost_keccak::{
    SigningPackage,
    keys::{PublicKeyPackage, dkg},
    round1::SigningCommitments,
    round2::SignatureShare,
};
use serde::{Deserialize, Serialize};
use zeroize::Zeroize;

use crate::blame::AbortReport;
use crate::envelope::SignedEnvelope;
use crate::error::{EnvelopeError, ProtocolError};
use crate::identity::{PartyKeys, Roster};
use crate::ids::{ParticipantId, Party, SessionId, hexbytes};
use crate::intent::{Approval, CustodyAction, VaultDomain};
use crate::sealed::SealedBox;

/// Domain separator of dealer-signed DKG share statements.
pub const SHARE_STATEMENT_DOMAIN: &[u8] = b"frost-custody/v1/dkg-share";

/// A compressed SEC1 group key (33 bytes), used to name a key share set.
pub type GroupKeyBytes = [u8; 33];

/// Whether a keygen session creates a new key or refreshes an existing one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "snake_case")]
pub enum KeygenMode {
    /// Pedersen DKG with proofs of knowledge: creates a new group key.
    Fresh,
    /// Proactive refresh: re-randomises all shares, group key unchanged.
    Refresh {
        /// The group key whose shares are refreshed.
        #[serde(with = "hexbytes")]
        group_key: GroupKeyBytes,
    },
}

/// Coordinator → participants: start a keygen session.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeygenStart {
    /// Fresh DKG or refresh.
    pub mode: KeygenMode,
    /// Signing threshold `t`.
    pub threshold: u16,
    /// All `n` participants of the session.
    pub participants: Vec<ParticipantId>,
}

/// Participant → all (via coordinator): Feldman commitment and proof of knowledge.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeygenRound1 {
    /// frost-core round-one package.
    pub package: dkg::round1::Package,
}

/// Coordinator → participant: origin-signed envelopes relayed verbatim.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Bundle {
    /// The relayed envelopes.
    pub envelopes: Vec<SignedEnvelope>,
}

/// A sealed box and its addressee.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AddressedBox {
    /// Recipient.
    pub to: ParticipantId,
    /// Encrypted payload.
    pub sealed: SealedBox,
}

/// Participant → all (via coordinator): encrypted shares for every other
/// participant plus the digest of the round-one set it saw (echo check).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeygenRound2 {
    /// SHA-256 over the full round-one package set, sorted by participant.
    #[serde(with = "hexbytes")]
    pub round1_digest: [u8; 32],
    /// One sealed [`SignedShareStatement`] per other participant.
    pub shares: Vec<AddressedBox>,
}

/// Why a participant rejects a dealer's contribution.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "reason", rename_all = "snake_case")]
pub enum ComplaintReason {
    /// The dealer-signed share fails the Feldman check (self-proving evidence).
    InvalidShare {
        /// The dealer's signed statement, revealed as evidence.
        statement: SignedShareStatement,
    },
    /// The dealer's round-two message has no box for the complainant.
    MissingShare,
    /// The box could not be opened or did not contain a statement signed by
    /// the dealer for this recipient and session.
    Undecryptable,
    /// The dealer reported a different round-one digest (broadcast inconsistency).
    InconsistentRound1 {
        /// Digest the dealer reported.
        #[serde(with = "hexbytes")]
        reported: [u8; 32],
    },
    /// The dealer's round-one package is invalid (bad proof of knowledge or shape).
    InvalidRound1 {
        /// Human-readable reason.
        detail: String,
    },
}

/// A complaint against one dealer.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Complaint {
    /// Accused participant.
    pub dealer: ParticipantId,
    /// Reason and evidence.
    pub reason: ComplaintReason,
}

/// Participant → coordinator: outcome of the local keygen computation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum KeygenResult {
    /// Shares verified; the participant derived these public values.
    Success {
        /// Compressed group key.
        #[serde(with = "hexbytes")]
        group_key: GroupKeyBytes,
        /// SHA-256 of the serialised public key package.
        #[serde(with = "hexbytes")]
        public_key_package_digest: [u8; 32],
    },
    /// The participant refuses to finish and names the dealers at fault.
    Complaints {
        /// All complaints.
        complaints: Vec<Complaint>,
    },
}

/// Coordinator → dealer: reveal the share you sent to `recipient`.
///
/// A dealer only reveals against evidence: `complaint` must be the
/// recipient's own signed `KeygenResult::Complaints` envelope for this session
/// that names the dealer with [`ComplaintReason::Undecryptable`]. Without it a
/// coordinator could collect `n-1` points of every dealer's polynomial and
/// interpolate the group secret.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RevealRequest {
    /// Complainant whose share must be revealed.
    pub recipient: ParticipantId,
    /// The complainant's signed result envelope (evidence of the complaint).
    pub complaint: SignedEnvelope,
}

/// Dealer → coordinator: the plaintext signed share statement.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeygenReveal {
    /// Complainant.
    pub recipient: ParticipantId,
    /// The dealer's signed statement.
    pub statement: SignedShareStatement,
}

/// Coordinator → participants: final keygen decision.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "decision", rename_all = "snake_case")]
pub enum KeygenFinished {
    /// Every participant reported the same public key package. The signed
    /// results form a certificate each participant checks before committing.
    Committed {
        /// Signed `KeygenResult::Success` envelopes of all participants.
        results: Vec<SignedEnvelope>,
    },
    /// The session failed; the report names the parties at fault.
    Aborted {
        /// Blame report.
        report: AbortReport,
    },
}

/// Coordinator → signers: request to sign a custody action.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignRequest {
    /// Which group key (share set) to sign with.
    #[serde(with = "hexbytes")]
    pub group_key: GroupKeyBytes,
    /// The structured action; signers derive the digest themselves.
    pub action: CustodyAction,
    /// Vault the action targets.
    pub domain: VaultDomain,
    /// The signing set chosen by the coordinator.
    pub signers: Vec<ParticipantId>,
    /// Approval of the action by the operator key a signer's policy may
    /// require (see [`crate::intent::SignerPolicy::approver`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval: Option<Approval>,
}

/// Signer → coordinator: round-one nonce commitments.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignCommitment {
    /// Hiding and binding commitments.
    pub commitments: SigningCommitments,
}

/// Coordinator → signers: the round-two signing package.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignPackage {
    /// Commitments of all signers and the message.
    pub package: SigningPackage,
}

/// Signer → coordinator: signature share bound to the package it signed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignShare {
    /// The share.
    pub share: SignatureShare,
    /// SHA-256 of the serialised signing package the share was computed for.
    #[serde(with = "hexbytes")]
    pub package_digest: [u8; 32],
}

/// Participant → coordinator: an honest refusal (policy or safety rule).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Refused {
    /// Kind of the message that was refused (see [`Message::kind`]).
    pub refused: String,
    /// Why the participant refused.
    pub reason: String,
}

/// Coordinator → helpers and the lost participant: start a share repair.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepairStart {
    /// Group whose share is repaired.
    #[serde(with = "hexbytes")]
    pub group_key: GroupKeyBytes,
    /// Participant that lost its share.
    pub lost: ParticipantId,
    /// At least `t` helpers holding valid shares.
    pub helpers: Vec<ParticipantId>,
}

/// Helper → helpers (via coordinator): sealed delta values.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepairDeltas {
    /// One sealed delta per other helper.
    pub deltas: Vec<AddressedBox>,
}

/// Helper → lost participant (via coordinator): sealed sigma and public data.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepairSigma {
    /// Sealed sigma for the lost participant.
    pub sigma: SealedBox,
    /// The helper's public key package.
    pub public_key_package: PublicKeyPackage,
}

/// Lost participant → coordinator: the repaired share verifies.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepairResult {
    /// Recovered verifying share (matches the public key package).
    #[serde(with = "hexbytes")]
    pub verifying_share: GroupKeyBytes,
}

/// Every protocol message.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "data", rename_all = "snake_case")]
pub enum Message {
    /// See [`KeygenStart`].
    KeygenStart(KeygenStart),
    /// See [`KeygenRound1`].
    KeygenRound1(KeygenRound1),
    /// Relay of all round-one envelopes.
    KeygenRound1Bundle(Bundle),
    /// See [`KeygenRound2`].
    KeygenRound2(KeygenRound2),
    /// Relay of all round-two envelopes.
    KeygenRound2Bundle(Bundle),
    /// See [`KeygenResult`].
    KeygenResult(KeygenResult),
    /// See [`RevealRequest`].
    KeygenRevealRequest(RevealRequest),
    /// See [`KeygenReveal`].
    KeygenReveal(KeygenReveal),
    /// See [`KeygenFinished`].
    KeygenFinished(KeygenFinished),
    /// See [`SignRequest`].
    SignRequest(SignRequest),
    /// See [`SignCommitment`].
    SignCommitment(SignCommitment),
    /// See [`SignPackage`].
    SignPackage(SignPackage),
    /// See [`SignShare`].
    SignShare(SignShare),
    /// See [`Refused`].
    Refused(Refused),
    /// See [`RepairStart`].
    RepairStart(RepairStart),
    /// See [`RepairDeltas`].
    RepairDeltas(RepairDeltas),
    /// Relay of the deltas addressed to one helper.
    RepairDeltaBundle(Bundle),
    /// See [`RepairSigma`].
    RepairSigma(RepairSigma),
    /// Relay of all sigmas to the lost participant.
    RepairSigmaBundle(Bundle),
    /// See [`RepairResult`].
    RepairResult(RepairResult),
}

impl Message {
    /// Short name for logs and errors.
    #[must_use]
    pub fn kind(&self) -> &'static str {
        match self {
            Self::KeygenStart(_) => "keygen_start",
            Self::KeygenRound1(_) => "keygen_round1",
            Self::KeygenRound1Bundle(_) => "keygen_round1_bundle",
            Self::KeygenRound2(_) => "keygen_round2",
            Self::KeygenRound2Bundle(_) => "keygen_round2_bundle",
            Self::KeygenResult(_) => "keygen_result",
            Self::KeygenRevealRequest(_) => "keygen_reveal_request",
            Self::KeygenReveal(_) => "keygen_reveal",
            Self::KeygenFinished(_) => "keygen_finished",
            Self::SignRequest(_) => "sign_request",
            Self::SignCommitment(_) => "sign_commitment",
            Self::SignPackage(_) => "sign_package",
            Self::SignShare(_) => "sign_share",
            Self::Refused(_) => "refused",
            Self::RepairStart(_) => "repair_start",
            Self::RepairDeltas(_) => "repair_deltas",
            Self::RepairDeltaBundle(_) => "repair_delta_bundle",
            Self::RepairSigma(_) => "repair_sigma",
            Self::RepairSigmaBundle(_) => "repair_sigma_bundle",
            Self::RepairResult(_) => "repair_result",
        }
    }
}

/// A dealer's claim "I sent `share` to `recipient` in `session`".
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ShareStatement {
    /// Keygen session.
    pub session: SessionId,
    /// Dealer (signer of the statement).
    pub dealer: ParticipantId,
    /// Intended recipient.
    pub recipient: ParticipantId,
    /// The secret share `f_dealer(recipient)`.
    pub share: dkg::round2::Package,
}

/// A [`ShareStatement`] signed by the dealer's transport key.
///
/// It travels inside a sealed box; if the share is invalid the recipient
/// reveals the signed statement, which convinces anyone holding the roster
/// that the dealer misbehaved.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignedShareStatement {
    /// JSON of the statement; these bytes are signed.
    pub statement: String,
    /// ed25519 signature over `SHARE_STATEMENT_DOMAIN || 0 || statement`.
    #[serde(with = "hexbytes")]
    pub signature: [u8; 64],
}

impl SignedShareStatement {
    /// Signs a statement with the dealer's keys.
    pub fn sign(statement: &ShareStatement, keys: &PartyKeys) -> Result<Self, ProtocolError> {
        let statement = serde_json::to_string(statement)?;
        let signature = keys.sign(SHARE_STATEMENT_DOMAIN, statement.as_bytes());
        Ok(Self {
            statement,
            signature,
        })
    }

    /// Parses the statement and checks the claimed dealer's signature.
    pub fn verify(&self, roster: &Roster) -> Result<ShareStatement, EnvelopeError> {
        let statement: ShareStatement = serde_json::from_str(&self.statement)
            .map_err(|e| EnvelopeError::Malformed(e.to_string()))?;
        roster.verify(
            Party::Participant(statement.dealer),
            SHARE_STATEMENT_DOMAIN,
            self.statement.as_bytes(),
            &self.signature,
        )?;
        Ok(statement)
    }
}

impl Drop for SignedShareStatement {
    fn drop(&mut self) {
        self.statement.zeroize();
    }
}
