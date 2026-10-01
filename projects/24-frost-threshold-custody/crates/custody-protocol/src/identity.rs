// SPDX-License-Identifier: MIT
//! Long-term transport identities and the static roster.
//!
//! Every party owns two keys that are unrelated to its FROST share:
//! * an **ed25519** key that signs every protocol message (authentication and
//!   non-repudiation, which is what makes blame verifiable by third parties);
//! * an **X25519** key that receives sealed (end-to-end encrypted) secret
//!   material such as DKG shares, relayed through the untrusted coordinator.
//!
//! The roster is a static file listing the public halves; it is the root of
//! trust of the transport layer and must be distributed out of band.

use std::collections::BTreeMap;
use std::fmt;
use std::path::Path;

use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use rand_core::{CryptoRng, RngCore};
use serde::{Deserialize, Serialize};
use x25519_dalek::{PublicKey as X25519Public, StaticSecret};
use zeroize::Zeroizing;

use crate::error::{EnvelopeError, ProtocolError};
use crate::ids::{ParticipantId, Party, hexbytes};

/// Protocol version string embedded in rosters and envelopes.
pub const PROTOCOL_VERSION: &str = "frost-custody/v1";

/// Builds the byte string an ed25519 signature covers: `domain || 0x00 || message`.
#[must_use]
pub fn signing_input(domain: &[u8], message: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(domain.len() + 1 + message.len());
    out.extend_from_slice(domain);
    out.push(0);
    out.extend_from_slice(message);
    out
}

/// A party's secret transport keys.
pub struct PartyKeys {
    signing: SigningKey,
    encryption: StaticSecret,
}

impl PartyKeys {
    /// Generates fresh keys.
    pub fn generate<R: RngCore + CryptoRng>(rng: &mut R) -> Self {
        let mut seed = Zeroizing::new([0u8; 32]);
        rng.fill_bytes(seed.as_mut());
        let signing = SigningKey::from_bytes(&seed);
        let encryption = StaticSecret::random_from_rng(rng);
        Self {
            signing,
            encryption,
        }
    }

    /// Rebuilds keys from their 32-byte secrets.
    #[must_use]
    pub fn from_secrets(signing: &[u8; 32], encryption: &[u8; 32]) -> Self {
        Self {
            signing: SigningKey::from_bytes(signing),
            encryption: StaticSecret::from(*encryption),
        }
    }

    /// Public half of the keys.
    #[must_use]
    pub fn public(&self) -> PublicIdentity {
        PublicIdentity {
            signing_key: self.signing.verifying_key().to_bytes(),
            encryption_key: X25519Public::from(&self.encryption).to_bytes(),
        }
    }

    /// Signs `message` under `domain`.
    #[must_use]
    pub fn sign(&self, domain: &[u8], message: &[u8]) -> [u8; 64] {
        self.signing
            .sign(&signing_input(domain, message))
            .to_bytes()
    }

    /// X25519 secret used to open sealed boxes addressed to this party.
    #[must_use]
    pub fn encryption_secret(&self) -> &StaticSecret {
        &self.encryption
    }

    /// Serialisable secret key file (demo tooling only: production deployments
    /// keep these keys in an HSM or OS key store).
    #[must_use]
    pub fn to_key_file(&self, party: Party) -> KeyFile {
        KeyFile {
            party,
            signing_secret: self.signing.to_bytes(),
            encryption_secret: self.encryption.to_bytes(),
        }
    }
}

impl fmt::Debug for PartyKeys {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PartyKeys")
            .field("public", &self.public())
            .finish_non_exhaustive()
    }
}

/// Secret key file for one party.
#[derive(Serialize, Deserialize)]
pub struct KeyFile {
    /// Party the keys belong to.
    pub party: Party,
    /// ed25519 secret seed.
    #[serde(with = "hexbytes")]
    pub signing_secret: [u8; 32],
    /// X25519 static secret.
    #[serde(with = "hexbytes")]
    pub encryption_secret: [u8; 32],
}

impl KeyFile {
    /// Rebuilds the keys.
    #[must_use]
    pub fn keys(&self) -> PartyKeys {
        PartyKeys::from_secrets(&self.signing_secret, &self.encryption_secret)
    }
}

impl fmt::Debug for KeyFile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("KeyFile")
            .field("party", &self.party)
            .finish_non_exhaustive()
    }
}

impl Drop for KeyFile {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.signing_secret.zeroize();
        self.encryption_secret.zeroize();
    }
}

/// Public transport identity of a party.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublicIdentity {
    /// ed25519 verifying key.
    #[serde(with = "hexbytes")]
    pub signing_key: [u8; 32],
    /// X25519 public key.
    #[serde(with = "hexbytes")]
    pub encryption_key: [u8; 32],
}

/// One participant line of the roster file.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RosterEntry {
    /// 1-based participant index (also the FROST identifier).
    pub id: ParticipantId,
    /// Human-readable label.
    pub name: String,
    /// Public keys.
    #[serde(flatten)]
    pub identity: PublicIdentity,
}

/// On-disk roster format.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct RosterFile {
    protocol: String,
    coordinator: PublicIdentity,
    participants: Vec<RosterEntry>,
}

/// Validated static roster: who may speak, and with which keys.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Roster {
    coordinator: PublicIdentity,
    participants: BTreeMap<ParticipantId, RosterEntry>,
}

impl Roster {
    /// Builds and validates a roster.
    pub fn new(
        coordinator: PublicIdentity,
        participants: Vec<RosterEntry>,
    ) -> Result<Self, ProtocolError> {
        let mut map = BTreeMap::new();
        let mut seen_keys = vec![coordinator.signing_key];
        verifying_key(&coordinator.signing_key)
            .map_err(|_| ProtocolError::InvalidParameters("coordinator key is invalid".into()))?;
        for entry in participants {
            verifying_key(&entry.identity.signing_key).map_err(|_| {
                ProtocolError::InvalidParameters(format!("signing key of {} is invalid", entry.id))
            })?;
            if seen_keys.contains(&entry.identity.signing_key) {
                return Err(ProtocolError::InvalidParameters(format!(
                    "signing key of {} is reused",
                    entry.id
                )));
            }
            seen_keys.push(entry.identity.signing_key);
            if map.insert(entry.id, entry.clone()).is_some() {
                return Err(ProtocolError::InvalidParameters(format!(
                    "{} appears twice",
                    entry.id
                )));
            }
        }
        if map.len() < 2 {
            return Err(ProtocolError::InvalidParameters(
                "a roster needs at least two participants".into(),
            ));
        }
        Ok(Self {
            coordinator,
            participants: map,
        })
    }

    /// Parses a roster from JSON.
    pub fn from_json(json: &str) -> Result<Self, ProtocolError> {
        let file: RosterFile = serde_json::from_str(json)?;
        if file.protocol != PROTOCOL_VERSION {
            return Err(EnvelopeError::UnsupportedProtocol(file.protocol).into());
        }
        Self::new(file.coordinator, file.participants)
    }

    /// Loads a roster file.
    pub fn load(path: &Path) -> Result<Self, ProtocolError> {
        Self::from_json(&std::fs::read_to_string(path)?)
    }

    /// Serialises the roster to pretty JSON.
    pub fn to_json(&self) -> Result<String, ProtocolError> {
        Ok(serde_json::to_string_pretty(&RosterFile {
            protocol: PROTOCOL_VERSION.to_owned(),
            coordinator: self.coordinator,
            participants: self.participants.values().cloned().collect(),
        })?)
    }

    /// All participant identifiers, ascending.
    pub fn participant_ids(&self) -> impl Iterator<Item = ParticipantId> + '_ {
        self.participants.keys().copied()
    }

    /// Number of participants.
    #[must_use]
    pub fn len(&self) -> usize {
        self.participants.len()
    }

    /// Always false for a validated roster (at least two participants).
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.participants.is_empty()
    }

    /// Whether `id` is a roster member.
    #[must_use]
    pub fn contains(&self, id: ParticipantId) -> bool {
        self.participants.contains_key(&id)
    }

    /// Roster entry of a participant.
    pub fn entry(&self, id: ParticipantId) -> Result<&RosterEntry, ProtocolError> {
        self.participants
            .get(&id)
            .ok_or(ProtocolError::UnknownParticipant(id))
    }

    /// Public identity of any party.
    pub fn identity(&self, party: Party) -> Result<PublicIdentity, EnvelopeError> {
        match party {
            Party::Coordinator => Ok(self.coordinator),
            Party::Participant(id) => self
                .participants
                .get(&id)
                .map(|e| e.identity)
                .ok_or(EnvelopeError::UnknownSender(party)),
        }
    }

    /// X25519 public key of a participant.
    pub fn encryption_key(&self, id: ParticipantId) -> Result<X25519Public, ProtocolError> {
        Ok(X25519Public::from(self.entry(id)?.identity.encryption_key))
    }

    /// Verifies an ed25519 signature by `party` over `domain || 0 || message`
    /// (strict verification: rejects small-order keys and non-canonical signatures).
    pub fn verify(
        &self,
        party: Party,
        domain: &[u8],
        message: &[u8],
        signature: &[u8; 64],
    ) -> Result<(), EnvelopeError> {
        let identity = self.identity(party)?;
        let key = verifying_key(&identity.signing_key)
            .map_err(|_| EnvelopeError::UnknownSender(party))?;
        key.verify_strict(
            &signing_input(domain, message),
            &Signature::from_bytes(signature),
        )
        .map_err(|_| EnvelopeError::BadSignature(party))
    }
}

fn verifying_key(bytes: &[u8; 32]) -> Result<VerifyingKey, ed25519_dalek::SignatureError> {
    let key = VerifyingKey::from_bytes(bytes)?;
    if key.is_weak() {
        return Err(ed25519_dalek::SignatureError::new());
    }
    Ok(key)
}

/// A freshly generated roster together with every party's secret keys.
/// Used by tests, fixtures and the local demo.
pub struct GeneratedRoster {
    /// The public roster.
    pub roster: Roster,
    /// Coordinator keys.
    pub coordinator: PartyKeys,
    /// Participant keys by id.
    pub participants: BTreeMap<ParticipantId, PartyKeys>,
}

impl GeneratedRoster {
    /// Generates `n` participants (ids 1..=n) and a coordinator.
    pub fn generate<R: RngCore + CryptoRng>(n: u16, rng: &mut R) -> Result<Self, ProtocolError> {
        let coordinator = PartyKeys::generate(rng);
        let mut participants = BTreeMap::new();
        let mut entries = Vec::new();
        for i in 1..=n {
            let id = ParticipantId::new(i)?;
            let keys = PartyKeys::generate(rng);
            entries.push(RosterEntry {
                id,
                name: format!("signer-{i}"),
                identity: keys.public(),
            });
            participants.insert(id, keys);
        }
        let roster = Roster::new(coordinator.public(), entries)?;
        Ok(Self {
            roster,
            coordinator,
            participants,
        })
    }
}
