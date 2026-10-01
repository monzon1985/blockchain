// SPDX-License-Identifier: MIT
//! # keysmith-relay
//!
//! The **online** half of Keysmith. It never sees key material:
//!
//! * [`prepare`] reads chain state (chain id, nonce, fees, gas estimate) from a JSON-RPC node and
//!   writes a `keysmith/unsigned-tx@1` envelope for the offline signer;
//! * [`broadcast`] takes the `keysmith/signed-tx@1` envelope the signer produced, re-verifies it
//!   offline (decode, recompute hash, recover signer), checks the node's chain id and only then
//!   calls `eth_sendRawTransaction`.
//!
//! This crate is the positive control of `cargo xtask check-airgap`: it depends on an HTTP
//! client, and the check must flag it, which proves the check would catch the same dependency
//! in the signer path.

pub mod broadcast;
pub mod error;
pub mod prepare;
pub mod rpc;

pub use broadcast::{BroadcastOutcome, broadcast, wait_for_receipt};
pub use error::RelayError;
pub use prepare::{PrepareRequest, prepare};
pub use rpc::{HttpTransport, Receipt, RpcClient, Transport};
