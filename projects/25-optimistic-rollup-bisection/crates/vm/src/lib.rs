// SPDX-License-Identifier: MIT
//! # rollup-vm
//!
//! A deterministic 24-opcode stack VM whose full state is Merkleized after every instruction, so that two parties
//! who disagree about a long execution can bisect down to one instruction and let an on-chain verifier
//! (`contracts/src/OneStepVM.sol`) execute just that one.
//!
//! - [`machine::MachineState`] holds the program, the input tape, a hash-chained [`stack::Stack`] and the L2 state as
//!   a 256-level [`smt::SparseMerkleTree`].
//! - [`interp::step`] is the transition function; with [`interp::Witness::Build`] it also returns the
//!   [`abi::StepProof`] the Solidity verifier needs.
//! - [`asm::Assembler`] writes programs; [`code::Program`] commits to them with an OpenZeppelin-compatible Merkle
//!   tree.

pub mod abi;
pub mod asm;
pub mod code;
pub mod crypto;
pub mod error;
pub mod interp;
pub mod machine;
pub mod opcode;
pub mod smt;
pub mod stack;

pub use abi::{Machine as MachineCommitment, StepProof};
pub use code::Program;
pub use error::VmError;
pub use interp::{Witness, run, step, trace};
pub use machine::{MachineState, Status, Tape};
pub use opcode::{Instruction, MAX_STACK, Opcode};
pub use smt::{SmtProof, SparseMerkleTree};

#[cfg(test)]
mod tests;
