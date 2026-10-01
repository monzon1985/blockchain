// SPDX-License-Identifier: MIT
//! Error type of the VM crate.

use thiserror::Error;

/// Errors raised while building programs, tapes or proofs. Program misbehaviour is never an error: it moves the
/// machine to the errored status, exactly like the on-chain verifier.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum VmError {
    /// A compressed SMT proof supplied a different number of siblings than its bitmap asks for.
    #[error("SMT proof supplies {supplied} siblings but its bitmap consumes {consumed}")]
    SmtProofLength {
        /// Siblings supplied.
        supplied: usize,
        /// Siblings the bitmap consumed.
        consumed: usize,
    },
    /// A program longer than `u32::MAX` instructions.
    #[error("program has {0} instructions, more than a u32 program counter can address")]
    ProgramTooLarge(usize),
    /// A tape longer than `u32::MAX` words.
    #[error("tape has {0} words, more than a u32 input size can describe")]
    TapeTooLarge(usize),
    /// Tape bytes that are not a whole number of words.
    #[error("tape byte length {0} is not a multiple of 32")]
    TapeNotWordAligned(usize),
    /// An assembler label was used but never bound.
    #[error("label {0} is used but never bound")]
    UnboundLabel(usize),
    /// An assembler label was bound twice.
    #[error("label {0} is bound twice")]
    LabelBoundTwice(usize),
}
