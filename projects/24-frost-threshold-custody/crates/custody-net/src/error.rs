// SPDX-License-Identifier: MIT
//! Transport errors.

use custody_protocol::{ParticipantId, ProtocolError};

use crate::wire::MAX_FRAME_LEN;

/// Errors of the TCP services.
#[derive(Debug, thiserror::Error)]
pub enum NetError {
    /// Socket error.
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    /// Peer announced a frame above the size limit.
    #[error("frame of {0} bytes exceeds the size limit (at most {MAX_FRAME_LEN} bytes)")]
    FrameTooLarge(usize),
    /// Peer closed the connection.
    #[error("connection closed by peer")]
    Closed,
    /// Frame is not valid JSON for the expected type.
    #[error("malformed frame: {0}")]
    Malformed(String),
    /// Mutual authentication failed.
    #[error("handshake failed: {0}")]
    Handshake(String),
    /// Protocol-level failure.
    #[error(transparent)]
    Protocol(#[from] ProtocolError),
    /// An operation did not finish in time.
    #[error("timed out: {0}")]
    Timeout(String),
    /// A participant needed for the operation is not connected.
    #[error("{0} is not connected")]
    NotConnected(ParticipantId),
    /// The service was shut down.
    #[error("service stopped")]
    Stopped,
}
