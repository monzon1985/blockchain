// SPDX-License-Identifier: MIT
//! # keysmith-core
//!
//! The `no_std` + `alloc` core of Keysmith, an air-gapped HD wallet and typed-transaction signer.
//!
//! | Module | What it implements |
//! |---|---|
//! | [`rlp`] | Hand-written, strictly canonical RLP encoder / decoder |
//! | [`u256`] | Checked 256-bit integer for values and fee math |
//! | [`bip39`], [`bip32`] | Mnemonics, seeds, HD derivation (BIP-39 / 32 / 44) |
//! | [`keys`] | secp256k1 keys, low-s recoverable signatures |
//! | [`tx`] | Legacy / EIP-155, EIP-2930, EIP-1559, EIP-7702 envelopes |
//! | [`authorization`] | EIP-7702 authorization tuples and the self-execution nonce rule |
//! | [`eip712`], [`eip191`], [`permit`] | Typed data, `personal_sign`, ERC-2612 permits |
//! | [`keystore`] | Web3 Secret Storage v3 (scrypt / pbkdf2 + AES-128-CTR) |
//! | [`gas`], [`policy`], [`envelope`], [`report`] | Intrinsic gas, signing policy, air-gap envelopes, decode reports |
//! | [`calldata`] | ERC-20 call recognition for the operator review |
//!
//! The crate has no I/O, no randomness source and no networking: callers supply entropy, and
//! the only way data enters or leaves is through function arguments and return values.
#![no_std]
#![forbid(unsafe_code)]

extern crate alloc;
#[cfg(feature = "std")]
extern crate std;

pub mod address;
pub mod authorization;
pub mod base58;
pub mod bip32;
pub mod bip39;
pub mod calldata;
pub mod eip191;
pub mod eip712;
pub mod envelope;
pub mod gas;
pub mod hash;
pub mod hex;
pub mod keys;
pub mod keystore;
pub mod permit;
pub mod policy;
pub mod quantity;
pub mod report;
pub mod rlp;
pub mod tx;
pub mod u256;
pub mod units;

pub use address::Address;
pub use keys::{PrivateKey, Signature};
pub use u256::U256;
