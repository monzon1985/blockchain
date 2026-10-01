// SPDX-License-Identifier: MIT
//! Identifiers for parties and protocol sessions, plus hex serde helpers.

use std::fmt;

use frost_keccak::Identifier;
use rand_core::{CryptoRng, RngCore};
use serde::{Deserialize, Serialize};

use crate::error::ProtocolError;

/// A participant's 1-based index in the roster. It maps one-to-one onto the
/// FROST [`Identifier`] with the same integer value.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(try_from = "u16", into = "u16")]
pub struct ParticipantId(u16);

impl ParticipantId {
    /// Creates an identifier; zero is not a valid FROST identifier.
    pub fn new(value: u16) -> Result<Self, ProtocolError> {
        if value == 0 {
            return Err(ProtocolError::InvalidParticipantId(value));
        }
        Ok(Self(value))
    }

    /// The raw index.
    #[must_use]
    pub fn get(self) -> u16 {
        self.0
    }

    /// The FROST identifier (the scalar `index`).
    #[must_use]
    pub fn identifier(self) -> Identifier {
        // `Identifier::try_from(u16)` only fails for zero, which `new` excludes.
        Identifier::try_from(self.0).unwrap_or_else(|_| unreachable!("non-zero identifier"))
    }

    /// Finds the participant whose FROST identifier is `identifier`.
    #[must_use]
    pub fn from_identifier<'a>(
        identifier: &Identifier,
        candidates: impl IntoIterator<Item = &'a ParticipantId>,
    ) -> Option<ParticipantId> {
        candidates
            .into_iter()
            .copied()
            .find(|p| p.identifier() == *identifier)
    }
}

impl TryFrom<u16> for ParticipantId {
    type Error = ProtocolError;
    fn try_from(value: u16) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<ParticipantId> for u16 {
    fn from(value: ParticipantId) -> Self {
        value.0
    }
}

impl fmt::Display for ParticipantId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "P{}", self.0)
    }
}

/// A 128-bit protocol session identifier chosen by the coordinator.
///
/// Every DKG, refresh, repair and signing attempt runs under a fresh session.
/// Signers refuse to reuse a session identifier (nonce-reuse protection).
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct SessionId(#[serde(with = "hexbytes")] pub [u8; 16]);

impl SessionId {
    /// Samples a uniformly random session identifier.
    pub fn random<R: RngCore + CryptoRng>(rng: &mut R) -> Self {
        let mut bytes = [0u8; 16];
        rng.fill_bytes(&mut bytes);
        Self(bytes)
    }
}

impl fmt::Display for SessionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&hex::encode(self.0))
    }
}

impl fmt::Debug for SessionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "SessionId({self})")
    }
}

/// A protocol party: the coordinator or a participant.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Party {
    /// The (untrusted) coordinator that relays messages and aggregates signatures.
    Coordinator,
    /// A key-share holder.
    Participant(ParticipantId),
}

impl fmt::Display for Party {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Party::Coordinator => f.write_str("coordinator"),
            Party::Participant(p) => write!(f, "{p}"),
        }
    }
}

/// `0x`-prefixed hex serde for fixed-size byte arrays.
pub mod hexbytes {
    use serde::{Deserialize, Deserializer, Serializer, de::Error};

    /// Serialises as a `0x`-prefixed lower-case hex string.
    pub fn serialize<S: Serializer, const N: usize>(
        value: &[u8; N],
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&format!("0x{}", hex::encode(value)))
    }

    /// Parses a hex string (with or without `0x`) of exactly `N` bytes.
    pub fn deserialize<'de, D: Deserializer<'de>, const N: usize>(
        deserializer: D,
    ) -> Result<[u8; N], D::Error> {
        let s = String::deserialize(deserializer)?;
        let raw = hex::decode(s.strip_prefix("0x").unwrap_or(&s)).map_err(D::Error::custom)?;
        raw.try_into()
            .map_err(|v: Vec<u8>| D::Error::custom(format!("expected {N} bytes, got {}", v.len())))
    }
}

/// `0x`-prefixed hex serde for byte vectors.
pub mod hexvec {
    use serde::{Deserialize, Deserializer, Serializer, de::Error};

    /// Serialises as a `0x`-prefixed lower-case hex string.
    pub fn serialize<S: Serializer>(value: &[u8], serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&format!("0x{}", hex::encode(value)))
    }

    /// Parses a hex string (with or without `0x`).
    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<u8>, D::Error> {
        let s = String::deserialize(deserializer)?;
        hex::decode(s.strip_prefix("0x").unwrap_or(&s)).map_err(D::Error::custom)
    }
}
