// SPDX-License-Identifier: MIT
//! End-to-end test crate. The test lives in `tests/anvil.rs` and only compiles
//! with `--features anvil`:
//!
//! ```text
//! (cd contracts && forge build)
//! cargo test -p e2e --features anvil -- --test-threads=1
//! ```
//!
//! It starts a coordinator and five participants on loopback TCP, runs a
//! Pedersen DKG, deploys `SchnorrVault` on a fresh anvil instance (random
//! port), threshold-signs and settles a withdrawal, rotates the group key to a
//! second DKG group, and checks that the retired key can no longer withdraw.
