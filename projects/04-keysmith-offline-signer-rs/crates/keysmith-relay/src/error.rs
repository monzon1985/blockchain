// SPDX-License-Identifier: MIT
//! Errors of the online half.

use keysmith_core::envelope::EnvelopeError;

/// Everything that can go wrong while talking to a node or handling envelopes.
#[derive(Debug, thiserror::Error)]
pub enum RelayError {
    /// The HTTP request failed (connection refused, TLS, non-2xx status, timeout).
    #[error("transport error: {0}")]
    Transport(String),
    /// The node answered with a JSON-RPC error object.
    #[error("node returned JSON-RPC error {code}: {message}")]
    Rpc {
        /// JSON-RPC error code.
        code: i64,
        /// Error message from the node.
        message: String,
    },
    /// The node's answer does not have the expected shape.
    #[error("unexpected response to {method}: {reason}")]
    BadResponse {
        /// The RPC method called.
        method: &'static str,
        /// What was wrong.
        reason: String,
    },
    /// The envelope is malformed or fails its offline consistency checks.
    #[error("{0}")]
    Envelope(#[from] EnvelopeError),
    /// The signed transaction targets a different chain than the node serves.
    #[error(
        "refusing to broadcast: transaction is for chain {envelope} but the node serves chain {node}"
    )]
    ChainMismatch {
        /// Chain id inside the signed transaction.
        envelope: u64,
        /// Chain id reported by `eth_chainId`.
        node: u64,
    },
    /// The node reported a different hash than the one recomputed offline.
    #[error("node reported transaction hash {node}, expected {expected}")]
    HashMismatch {
        /// Hash recomputed from the raw bytes.
        expected: String,
        /// Hash returned by `eth_sendRawTransaction`.
        node: String,
    },
    /// No receipt appeared in time.
    #[error("no receipt for {hash} after {seconds} s")]
    ReceiptTimeout {
        /// Transaction hash.
        hash: String,
        /// How long we waited.
        seconds: u64,
    },
    /// The request cannot be prepared as given.
    #[error("{0}")]
    Input(String),
}
