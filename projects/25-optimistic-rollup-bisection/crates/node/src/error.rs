// SPDX-License-Identifier: MIT
//! Error type of the node library.

use alloy::primitives::B256;
use thiserror::Error;

/// Errors raised by derivation and the services.
#[derive(Debug, Error)]
pub enum NodeError {
    /// L1 access failed.
    #[error(transparent)]
    L1(#[from] rollup_l1::L1Error),
    /// A contract call failed (including reverts).
    #[error(transparent)]
    Contract(#[from] alloy::contract::Error),
    /// RPC transport failure.
    #[error(transparent)]
    Transport(#[from] alloy::transports::TransportError),
    /// A transaction was not confirmed.
    #[error(transparent)]
    Pending(#[from] alloy::providers::PendingTransactionError),
    /// A transaction was mined but reverted.
    #[error("transaction {0} reverted")]
    Reverted(B256),
    /// Epoch execution failed (never happens for inbox-accepted batches).
    #[error(transparent)]
    Stf(#[from] rollup_stf::StfError),
    /// Malformed tape.
    #[error(transparent)]
    Vm(#[from] rollup_vm::VmError),
    /// L1 data is inconsistent with what derivation reconstructed.
    #[error("derivation: {0}")]
    Derivation(String),
    /// A log could not be decoded.
    #[error("log decoding: {0}")]
    Decode(#[from] alloy::sol_types::Error),
    /// The HTTP server failed.
    #[error("http: {0}")]
    Io(#[from] std::io::Error),
}

/// Convenience alias.
pub type Result<T, E = NodeError> = std::result::Result<T, E>;
