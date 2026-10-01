// SPDX-License-Identifier: MIT
//! Error type shared by every protocol state machine.

use crate::ids::{ParticipantId, Party, SessionId};

/// Errors raised by the custody protocol.
#[derive(Debug, thiserror::Error)]
pub enum ProtocolError {
    /// Participant indices start at 1.
    #[error("participant id {0} is invalid (must be >= 1)")]
    InvalidParticipantId(u16),
    /// The party is not listed in the roster.
    #[error("{0} is not in the roster")]
    UnknownParticipant(ParticipantId),
    /// Threshold or participant set is not usable.
    #[error("invalid group parameters: {0}")]
    InvalidParameters(String),
    /// An envelope failed authentication or decoding.
    #[error(transparent)]
    Envelope(#[from] EnvelopeError),
    /// A sealed box could not be opened.
    #[error(transparent)]
    Seal(#[from] SealError),
    /// frost-core rejected an operation.
    #[error("FROST error: {0}")]
    Frost(#[from] frost_keccak::Error),
    /// A key or signature could not be expressed in EVM form.
    #[error("EVM encoding error: {0}")]
    Evm(#[from] frost_keccak::evm::EvmError),
    /// JSON (de)serialisation failed.
    #[error("serialization error: {0}")]
    Serialization(#[from] serde_json::Error),
    /// A message arrived in a state that does not expect it.
    #[error("unexpected {got} message in state {state}")]
    UnexpectedMessage {
        /// Message kind received.
        got: &'static str,
        /// State of the receiving state machine.
        state: &'static str,
    },
    /// The message belongs to a different session.
    #[error("message for session {got} delivered to session {expected}")]
    WrongSession {
        /// Session of the state machine.
        expected: SessionId,
        /// Session named by the message.
        got: SessionId,
    },
    /// The sender is not allowed to send this message.
    #[error("{0} is not allowed to send this message")]
    UnauthorizedSender(Party),
    /// A signer was asked to reuse a session identifier (and thus nonces).
    #[error("session {0} was already used for signing; refusing to sign twice")]
    SessionAlreadyUsed(SessionId),
    /// No state exists for the referenced session.
    #[error("no pending state for session {0}")]
    UnknownSession(SessionId),
    /// The request violates the signer's local policy.
    #[error("signing policy violation: {0}")]
    PolicyViolation(String),
    /// Key material is required but absent (before DKG or after share loss).
    #[error("participant has no key share")]
    NoKeyShare,
    /// The coordinator's signing package does not match what the signer committed to.
    #[error("signing package mismatch: {0}")]
    PackageMismatch(&'static str),
    /// A durable journal could not be written.
    #[error("journal I/O error: {0}")]
    Journal(#[from] std::io::Error),
}

/// Authentication and decoding failures of signed envelopes.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum EnvelopeError {
    /// The ed25519 signature does not verify under the claimed sender's key.
    #[error("bad signature from {0}")]
    BadSignature(Party),
    /// The claimed sender is not in the roster.
    #[error("sender {0} is not in the roster")]
    UnknownSender(Party),
    /// The payload is not a valid envelope.
    #[error("malformed envelope: {0}")]
    Malformed(String),
    /// The envelope speaks a different protocol version.
    #[error("unsupported protocol {0}")]
    UnsupportedProtocol(String),
}

/// Failures of the X25519 + ChaCha20-Poly1305 sealed boxes.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SealError {
    /// Authentication tag mismatch: wrong key, wrong context or tampered ciphertext.
    #[error("sealed box failed to authenticate")]
    Authentication,
    /// The shared secret is all-zero (low-order ephemeral key).
    #[error("non-contributory key exchange")]
    NonContributory,
}
