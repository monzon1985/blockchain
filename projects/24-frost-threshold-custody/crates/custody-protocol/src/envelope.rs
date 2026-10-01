// SPDX-License-Identifier: MIT
//! Signed envelopes: the unit of communication between parties.
//!
//! The signature covers the exact JSON bytes of the envelope (`payload`), so no
//! canonicalisation is needed and a relayed envelope can be re-verified by any
//! party holding the roster. Envelopes relayed by the coordinator keep their
//! origin signature, which is what turns protocol transcripts into evidence.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::{EnvelopeError, ProtocolError};
use crate::identity::{PROTOCOL_VERSION, PartyKeys, Roster};
use crate::ids::{ParticipantId, Party, SessionId, hexbytes};
use crate::messages::Message;

/// Domain separator of envelope signatures.
pub const ENVELOPE_DOMAIN: &[u8] = b"frost-custody/v1/envelope";

/// Addressee of an envelope.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Recipient {
    /// The coordinator.
    Coordinator,
    /// One participant.
    Participant(ParticipantId),
}

/// An unsigned protocol message with its routing header.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Envelope {
    /// Protocol version, always [`PROTOCOL_VERSION`].
    pub protocol: String,
    /// Session this message belongs to.
    pub session: SessionId,
    /// Sender (authenticated by the signature).
    pub from: Party,
    /// Addressee.
    pub to: Recipient,
    /// Message body.
    pub body: Message,
}

impl Envelope {
    /// Creates an envelope for the current protocol version.
    #[must_use]
    pub fn new(session: SessionId, from: Party, to: Recipient, body: Message) -> Self {
        Self {
            protocol: PROTOCOL_VERSION.to_owned(),
            session,
            from,
            to,
            body,
        }
    }
}

/// An envelope plus the sender's ed25519 signature over its JSON encoding.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignedEnvelope {
    /// JSON encoding of the [`Envelope`]; these exact bytes are signed.
    pub payload: String,
    /// ed25519 signature over `ENVELOPE_DOMAIN || 0 || payload`.
    #[serde(with = "hexbytes")]
    pub signature: [u8; 64],
}

impl SignedEnvelope {
    /// Serialises and signs `envelope` with the sender's keys.
    pub fn sign(envelope: &Envelope, keys: &PartyKeys) -> Result<Self, ProtocolError> {
        let payload = serde_json::to_string(envelope)?;
        let signature = keys.sign(ENVELOPE_DOMAIN, payload.as_bytes());
        Ok(Self { payload, signature })
    }

    /// Authenticates the envelope against the roster and decodes it.
    pub fn verify(&self, roster: &Roster) -> Result<Verified, EnvelopeError> {
        let envelope: Envelope = serde_json::from_str(&self.payload)
            .map_err(|e| EnvelopeError::Malformed(e.to_string()))?;
        if envelope.protocol != PROTOCOL_VERSION {
            return Err(EnvelopeError::UnsupportedProtocol(envelope.protocol));
        }
        roster.verify(
            envelope.from,
            ENVELOPE_DOMAIN,
            self.payload.as_bytes(),
            &self.signature,
        )?;
        Ok(Verified {
            envelope,
            raw: self.clone(),
        })
    }

    /// SHA-256 of the signed payload; identifies the envelope in reports.
    #[must_use]
    pub fn digest(&self) -> [u8; 32] {
        Sha256::digest(self.payload.as_bytes()).into()
    }
}

/// An authenticated, decoded envelope that remembers its signed form.
#[derive(Clone, Debug, PartialEq)]
pub struct Verified {
    /// Decoded envelope.
    pub envelope: Envelope,
    /// The signed form, kept as evidence.
    pub raw: SignedEnvelope,
}

impl Verified {
    /// The authenticated sender.
    #[must_use]
    pub fn from(&self) -> Party {
        self.envelope.from
    }

    /// The sender if it is a participant.
    pub fn participant(&self) -> Result<ParticipantId, ProtocolError> {
        match self.envelope.from {
            Party::Participant(p) => Ok(p),
            Party::Coordinator => Err(ProtocolError::UnauthorizedSender(Party::Coordinator)),
        }
    }

    /// Session of the envelope.
    #[must_use]
    pub fn session(&self) -> SessionId {
        self.envelope.session
    }

    /// Message body.
    #[must_use]
    pub fn body(&self) -> &Message {
        &self.envelope.body
    }
}

/// A message produced by a state machine, before the driver signs it.
#[derive(Clone, Debug, PartialEq)]
pub struct Outbound {
    /// Addressee.
    pub to: Recipient,
    /// Session.
    pub session: SessionId,
    /// Body.
    pub body: Message,
}

impl Outbound {
    /// Signs the message as `from`.
    pub fn sign(&self, from: Party, keys: &PartyKeys) -> Result<SignedEnvelope, ProtocolError> {
        SignedEnvelope::sign(
            &Envelope::new(self.session, from, self.to, self.body.clone()),
            keys,
        )
    }
}
