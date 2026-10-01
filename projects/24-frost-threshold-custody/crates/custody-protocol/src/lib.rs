// SPDX-License-Identifier: MIT
//! # custody-protocol
//!
//! Transport-agnostic threshold custody protocol on top of
//! [`frost_keccak`] (`FROST(secp256k1, KECCAK-256)`).
//!
//! * [`keygen`]: Pedersen DKG with proofs of knowledge and proactive refresh,
//!   with evidence-carrying complaints and a commit certificate.
//! * [`signing`]: two-round signing with identifiable aborts and nonce-reuse
//!   protection; signers derive the EIP-712 digest from a structured
//!   [`intent::CustodyAction`] and check it against a local policy.
//! * [`repair`]: recovery of a lost share by `t` helpers (RTS), verified
//!   against the published verifying share.
//! * [`blame`]: abort reports whose evidence third parties can re-verify.
//! * [`envelope`], [`identity`], [`sealed`]: ed25519-signed envelopes, the
//!   static roster, and X25519/ChaCha20-Poly1305 sealed boxes.
//! * [`node`]: the participant node and coordinator session wrapper; bounded,
//!   expiring [`sessions`] tables for in-flight secret state.
//! * [`local`]: a deterministic in-memory network driving the same state
//!   machines as the TCP services (tests, fixtures, fault injection).
//!
//! All state machines are sans-IO: they consume authenticated messages and
//! return messages to send; drivers own sockets, timers and signing keys.

#![forbid(unsafe_code)]

pub mod blame;
pub mod envelope;
pub mod error;
pub mod identity;
pub mod ids;
pub mod intent;
pub mod keygen;
pub mod local;
pub mod messages;
pub mod node;
pub mod repair;
pub mod sealed;
pub mod sessions;
pub mod signing;

pub use error::ProtocolError;
pub use ids::{ParticipantId, Party, SessionId};
