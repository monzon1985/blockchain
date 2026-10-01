// SPDX-License-Identifier: MIT
//! # rollup-stf
//!
//! The L2 state-transition function (deposits, signed transfers and withdrawals over a sparse Merkle tree of
//! accounts), expressed three ways that must agree:
//!
//! 1. [`program::stf_program`], a program for the rollup VM: the canonical definition, and what fraud proofs execute;
//! 2. [`native::apply_tape`], a plain-Rust restatement (differential oracle, fast queries);
//! 3. the on-chain `OneStepVM`, which executes one instruction of (1) during a dispute.
//!
//! [`exec::EpochTrace`] records the padded per-step state hashes the bisection game is played over.

pub mod exec;
pub mod keys;
pub mod native;
pub mod program;
pub mod record;
pub mod tape;

pub use exec::{DEFAULT_MAX_DEPTH, EpochTrace, Execution, Fault, Stf, StfError};
pub use native::{Effect, Report, StateExt, WithdrawalEntry, apply_tape};
pub use record::{
    Kind, L2Tx, RECORD_BYTES, RECORD_WORDS, Record, accumulate, address_word, domain_separator, key_address,
};
pub use tape::{MAX_QUEUE_PER_BATCH, MAX_SEQUENCED_TXS, build_tape, decode_tx_data, encode_tx_data};

#[cfg(test)]
mod tests;
