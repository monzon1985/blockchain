// SPDX-License-Identifier: MIT
//! Full machine state and its commitment.

use std::sync::Arc;

use alloy_primitives::{B256, Bytes, keccak256};

use crate::{abi, code::Program, error::VmError, smt::SparseMerkleTree, stack::Stack};

/// Execution status. A machine that is not running is a fixed point of `step`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Status {
    /// Executing.
    Running = 0,
    /// Executed `HALT`.
    Halted = 1,
    /// Hit an invalid instruction or operand.
    Errored = 2,
}

/// The read-only input tape: 32-byte words committed by `keccak256(concat(words))`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tape {
    words: Vec<B256>,
    bytes: Bytes,
    root: B256,
}

impl Tape {
    /// Tape from words.
    ///
    /// # Errors
    /// [`VmError::TapeTooLarge`] beyond `u32::MAX` words.
    pub fn new(words: Vec<B256>) -> Result<Self, VmError> {
        if u32::try_from(words.len()).is_err() {
            return Err(VmError::TapeTooLarge(words.len()));
        }
        let bytes: Bytes = words.iter().flat_map(|w| w.0).collect::<Vec<u8>>().into();
        let root = keccak256(&bytes);
        Ok(Self { words, bytes, root })
    }

    /// Tape from raw bytes (must be a whole number of words).
    ///
    /// # Errors
    /// [`VmError::TapeNotWordAligned`] or [`VmError::TapeTooLarge`].
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, VmError> {
        if !bytes.len().is_multiple_of(32) {
            return Err(VmError::TapeNotWordAligned(bytes.len()));
        }
        Self::new(bytes.as_chunks::<32>().0.iter().map(|c| B256::from(*c)).collect())
    }

    /// Commitment (`keccak256` of the bytes).
    pub fn root(&self) -> B256 {
        self.root
    }

    /// Length in words.
    pub fn size(&self) -> u32 {
        // Bounded by the check in `new`.
        self.words.len() as u32
    }

    /// Word at `index`, or zero when out of range.
    pub fn word(&self, index: usize) -> B256 {
        self.words.get(index).copied().unwrap_or_default()
    }

    /// All words.
    pub fn words(&self) -> &[B256] {
        &self.words
    }

    /// Raw bytes (what the INPUT witness carries).
    pub fn bytes(&self) -> &Bytes {
        &self.bytes
    }
}

/// Full machine state. All commitment fields are derived from real data (the stack hash from the stack, the state
/// root from the tree, the code root and size from the program, the input root and size from the tape), so a
/// `MachineState` can never be internally inconsistent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MachineState {
    /// Execution status.
    pub status: Status,
    /// Program counter.
    pub pc: u32,
    /// Operand stack.
    pub stack: Stack,
    /// L2 state tree.
    pub state: SparseMerkleTree,
    program: Arc<Program>,
    tape: Arc<Tape>,
}

impl MachineState {
    /// A running machine at `pc = 0` with an empty stack.
    pub fn new(program: Arc<Program>, tape: Arc<Tape>, state: SparseMerkleTree) -> Self {
        Self { status: Status::Running, pc: 0, stack: Stack::new(), state, program, tape }
    }

    /// The program.
    pub fn program(&self) -> &Program {
        &self.program
    }

    /// Shared handle to the program.
    pub fn program_arc(&self) -> Arc<Program> {
        Arc::clone(&self.program)
    }

    /// The input tape.
    pub fn tape(&self) -> &Tape {
        &self.tape
    }

    /// Whether the machine still executes.
    pub fn is_running(&self) -> bool {
        self.status == Status::Running
    }

    /// Commitment-level view.
    pub fn commitment(&self) -> abi::Machine {
        abi::Machine {
            status: self.status as u8,
            pc: self.pc,
            // Bounded by MAX_STACK (1024).
            stackDepth: self.stack.len() as u32,
            stackHash: self.stack.hash(),
            stateRoot: self.state.root(),
            codeRoot: self.program.code_root(),
            codeSize: self.program.code_size(),
            inputRoot: self.tape.root(),
            inputSize: self.tape.size(),
        }
    }

    /// State hash, `keccak256(abi.encode(commitment))`.
    pub fn hash(&self) -> B256 {
        self.commitment().hash()
    }
}
