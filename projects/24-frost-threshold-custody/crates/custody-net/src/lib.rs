// SPDX-License-Identifier: MIT
//! # custody-net
//!
//! Tokio services that run the [`custody_protocol`] state machines over local
//! TCP:
//!
//! * [`wire`]: length-prefixed JSON frames (4 KiB cap before authentication,
//!   4 MiB after) and the mutually authenticated challenge/hello/welcome
//!   handshake;
//! * [`coordinator`]: accepts participants on an OS-assigned port, relays
//!   origin-signed envelopes and enforces per-phase deadlines;
//! * [`participant`]: one connection per participant, feeding a
//!   [`custody_protocol::node::ParticipantNode`];
//! * [`cluster`]: an in-process deployment for tests and demos.
//!
//! Every protocol message is end-to-end ed25519-signed by its origin and
//! secret material is sealed to its recipient, so the TCP layer (and the
//! coordinator) can drop or delay messages but cannot forge or read them.

#![forbid(unsafe_code)]

pub mod cluster;
pub mod coordinator;
pub mod error;
pub mod participant;
pub mod wire;

pub use error::NetError;
