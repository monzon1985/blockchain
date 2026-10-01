// SPDX-License-Identifier: MIT
//! Length-prefixed JSON frames and the mutually authenticated handshake.
//!
//! Frame format: a 4-byte big-endian length followed by that many bytes of
//! JSON ([`Frame`]). Frames above [`MAX_FRAME_LEN`] close the connection;
//! before authentication (challenge, hello, welcome) the cap is
//! [`HANDSHAKE_MAX_FRAME_LEN`], so an unauthenticated peer cannot make the
//! other side allocate more than a few kilobytes.
//!
//! Handshake (binds the TCP connection to a roster identity for routing):
//!
//! ```text
//! coordinator → participant   Challenge { server_nonce }
//! participant → coordinator   Hello { id, server_nonce, client_nonce, sig_participant }
//! coordinator → participant   Welcome { client_nonce, sig_coordinator }
//! ```
//!
//! Both signatures cover `(id, server_nonce, client_nonce)` under distinct
//! labels, so neither message can be replayed on another connection. After
//! the handshake every frame carries an origin-signed [`SignedEnvelope`];
//! the handshake only decides where the coordinator routes messages.

use custody_protocol::{
    ParticipantId, envelope::SignedEnvelope, identity::PROTOCOL_VERSION, ids::hexbytes,
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::error::NetError;

/// Largest accepted frame (4 MiB).
pub const MAX_FRAME_LEN: usize = 4 * 1024 * 1024;

/// Largest accepted handshake frame (4 KiB); a hello is about 400 bytes.
pub const HANDSHAKE_MAX_FRAME_LEN: usize = 4 * 1024;

/// Domain separator of handshake signatures.
pub const HANDSHAKE_DOMAIN: &[u8] = b"frost-custody/v1/handshake";

/// Every frame on the wire.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Frame {
    /// Coordinator's fresh challenge.
    Challenge {
        /// Protocol version.
        protocol: String,
        /// Random nonce chosen by the coordinator.
        #[serde(with = "hexbytes")]
        server_nonce: [u8; 32],
    },
    /// Participant's signed identification.
    Hello {
        /// Claimed participant id.
        participant: ParticipantId,
        /// Echo of the coordinator's nonce.
        #[serde(with = "hexbytes")]
        server_nonce: [u8; 32],
        /// Random nonce chosen by the participant.
        #[serde(with = "hexbytes")]
        client_nonce: [u8; 32],
        /// ed25519 signature over the hello transcript.
        #[serde(with = "hexbytes")]
        signature: [u8; 64],
    },
    /// Coordinator's signed acceptance.
    Welcome {
        /// Echo of the participant's nonce.
        #[serde(with = "hexbytes")]
        client_nonce: [u8; 32],
        /// ed25519 signature over the welcome transcript.
        #[serde(with = "hexbytes")]
        signature: [u8; 64],
    },
    /// A protocol envelope.
    Envelope(SignedEnvelope),
}

fn transcript(
    label: &[u8],
    participant: ParticipantId,
    server: &[u8; 32],
    client: &[u8; 32],
) -> Vec<u8> {
    let mut out = Vec::with_capacity(label.len() + PROTOCOL_VERSION.len() + 2 + 64 + 2);
    out.extend_from_slice(label);
    out.push(0);
    out.extend_from_slice(PROTOCOL_VERSION.as_bytes());
    out.push(0);
    out.extend_from_slice(&participant.get().to_be_bytes());
    out.extend_from_slice(server);
    out.extend_from_slice(client);
    out
}

/// Bytes the participant signs in `Hello`.
#[must_use]
pub fn hello_transcript(
    participant: ParticipantId,
    server: &[u8; 32],
    client: &[u8; 32],
) -> Vec<u8> {
    transcript(b"hello", participant, server, client)
}

/// Bytes the coordinator signs in `Welcome`.
#[must_use]
pub fn welcome_transcript(
    participant: ParticipantId,
    server: &[u8; 32],
    client: &[u8; 32],
) -> Vec<u8> {
    transcript(b"welcome", participant, server, client)
}

/// Writes one length-prefixed frame.
pub async fn write_frame<W: AsyncWrite + Unpin>(
    writer: &mut W,
    bytes: &[u8],
) -> Result<(), NetError> {
    if bytes.len() > MAX_FRAME_LEN {
        return Err(NetError::FrameTooLarge(bytes.len()));
    }
    let len = u32::try_from(bytes.len()).map_err(|_| NetError::FrameTooLarge(bytes.len()))?;
    writer.write_u32(len).await?;
    writer.write_all(bytes).await?;
    writer.flush().await?;
    Ok(())
}

/// Maps the ways a peer can go away to [`NetError::Closed`].
fn closed_or_io(e: std::io::Error) -> NetError {
    use std::io::ErrorKind;
    match e.kind() {
        ErrorKind::UnexpectedEof
        | ErrorKind::ConnectionReset
        | ErrorKind::ConnectionAborted
        | ErrorKind::BrokenPipe => NetError::Closed,
        _ => NetError::Io(e),
    }
}

/// Reads one length-prefixed frame of at most [`MAX_FRAME_LEN`] bytes.
pub async fn read_frame<R: AsyncRead + Unpin>(reader: &mut R) -> Result<Vec<u8>, NetError> {
    read_frame_limited(reader, MAX_FRAME_LEN).await
}

/// Reads one length-prefixed frame of at most `limit` bytes. The length is
/// checked before anything is allocated.
pub async fn read_frame_limited<R: AsyncRead + Unpin>(
    reader: &mut R,
    limit: usize,
) -> Result<Vec<u8>, NetError> {
    let len = reader.read_u32().await.map_err(closed_or_io)? as usize;
    if len > limit.min(MAX_FRAME_LEN) {
        return Err(NetError::FrameTooLarge(len));
    }
    let mut buf = vec![0u8; len];
    reader.read_exact(&mut buf).await.map_err(closed_or_io)?;
    Ok(buf)
}

/// Serialises `value` as JSON and writes it as one frame.
pub async fn write_json<W: AsyncWrite + Unpin, T: Serialize>(
    writer: &mut W,
    value: &T,
) -> Result<(), NetError> {
    let bytes = serde_json::to_vec(value).map_err(|e| NetError::Malformed(e.to_string()))?;
    write_frame(writer, &bytes).await
}

/// Reads one frame and parses it as JSON. A frame that is not valid JSON
/// yields [`NetError::Malformed`] and leaves the stream aligned on the next frame.
pub async fn read_json<R: AsyncRead + Unpin, T: DeserializeOwned>(
    reader: &mut R,
) -> Result<T, NetError> {
    read_json_limited(reader, MAX_FRAME_LEN).await
}

/// [`read_json`] with a frame limit of `limit` bytes (handshake frames).
pub async fn read_json_limited<R: AsyncRead + Unpin, T: DeserializeOwned>(
    reader: &mut R,
    limit: usize,
) -> Result<T, NetError> {
    let bytes = read_frame_limited(reader, limit).await?;
    serde_json::from_slice(&bytes).map_err(|e| NetError::Malformed(e.to_string()))
}
