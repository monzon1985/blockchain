// SPDX-License-Identifier: MIT
//! # rfq-core
//!
//! The protocol logic of the RFQ settlement program, written once and shared by
//! every consumer:
//!
//! * the idiomatic **Anchor** program (`programs/rfq`),
//! * the zero-copy **Pinocchio** program (`programs/rfq-pinocchio`),
//! * the off-chain **client** (`crates/rfq-client`) and the test harnesses.
//!
//! The crate is `no_std`, performs no heap allocation and contains no `unsafe`
//! code, so the exact same bytes-in / bytes-out functions run on the host (where
//! they are property- and differential-tested against the canonical Solana and
//! SPL implementations) and inside SBF programs.
//!
//! Public keys are plain `[u8; 32]` arrays ([`Pubkey`]) so the crate is agnostic
//! of which Solana SDK generation a consumer links against.

#![no_std]
#![forbid(unsafe_code)]
#![warn(missing_docs)]

#[cfg(test)]
extern crate std;

pub mod anchor_codes;
pub mod ed25519;
pub mod error;
pub mod hook;
pub mod ids;
pub mod ix_sysvar;
pub mod layout;
pub mod math;
pub mod nonce;
pub mod quote;
pub mod seeds;
pub mod token;
pub mod transfer_fee;

pub use error::RfqError;
pub use quote::Quote;

/// A 32-byte Solana address, independent of any SDK crate.
pub type Pubkey = [u8; 32];

/// Reads a little-endian `u64` at `offset`, returning `None` when out of bounds.
#[inline(always)]
pub(crate) fn read_u64(data: &[u8], offset: usize) -> Option<u64> {
    let end = offset.checked_add(8)?;
    let bytes: [u8; 8] = data.get(offset..end)?.try_into().ok()?;
    Some(u64::from_le_bytes(bytes))
}

/// Reads a little-endian `u16` at `offset`, returning `None` when out of bounds.
#[inline(always)]
pub(crate) fn read_u16(data: &[u8], offset: usize) -> Option<u16> {
    let end = offset.checked_add(2)?;
    let bytes: [u8; 2] = data.get(offset..end)?.try_into().ok()?;
    Some(u16::from_le_bytes(bytes))
}

/// Reads a 32-byte key at `offset`, returning `None` when out of bounds.
#[inline(always)]
pub(crate) fn read_key(data: &[u8], offset: usize) -> Option<&Pubkey> {
    let end = offset.checked_add(32)?;
    data.get(offset..end)?.try_into().ok()
}
