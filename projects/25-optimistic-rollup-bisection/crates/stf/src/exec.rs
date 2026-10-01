// SPDX-License-Identifier: MIT
//! Running the STF program on the VM: epoch execution and the padded traces the bisection game plays over.

use std::sync::Arc;

use alloy_primitives::{B256, U256};
use rollup_vm::{MachineCommitment, MachineState, Program, SparseMerkleTree, Status, StepProof, Tape, Witness, step};
use thiserror::Error;

use crate::{keys::word, program::stf_program, record::domain_separator};

/// Default bisection depth: traces are padded to `2^16 = 65,536` steps, comfortably above the worst case the inbox
/// allows (checked by `worst_case_batch_fits_the_trace` in the tests).
pub const DEFAULT_MAX_DEPTH: u8 = 16;

/// Errors of epoch execution.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum StfError {
    /// The program did not halt within `2^max_depth` steps.
    #[error("program did not halt within {0} steps")]
    TraceTooLong(u64),
    /// The program errored (never happens for the canonical program; see the property tests).
    #[error("program errored at pc {pc} after {steps} steps")]
    ProgramErrored {
        /// Program counter of the failing instruction.
        pc: u32,
        /// Steps executed.
        steps: u64,
    },
    /// Step index outside the padded trace.
    #[error("step {0} is outside the trace")]
    StepOutOfRange(u64),
}

/// The STF for one L2 chain: the program plus its signing domain.
#[derive(Debug, Clone)]
pub struct Stf {
    program: Arc<Program>,
    domain: B256,
    chain_id: u64,
    max_depth: u8,
}

/// Result of executing an epoch.
#[derive(Debug, Clone)]
pub struct Execution {
    /// State after the epoch.
    pub post_state: SparseMerkleTree,
    /// Steps until HALT (inclusive).
    pub steps: u64,
    /// Final (halted) machine commitment, what the defender reveals in `commitEnd`.
    pub final_commitment: MachineCommitment,
}

impl Stf {
    /// STF for `chain_id` with the default bisection depth.
    pub fn new(chain_id: u64) -> Self {
        Self::with_depth(chain_id, DEFAULT_MAX_DEPTH)
    }

    /// STF for `chain_id` with a custom bisection depth.
    pub fn with_depth(chain_id: u64, max_depth: u8) -> Self {
        let domain = domain_separator(chain_id);
        Self { program: Arc::new(stf_program(domain)), domain, chain_id, max_depth }
    }

    /// The program.
    pub fn program(&self) -> &Arc<Program> {
        &self.program
    }

    /// Signing domain.
    pub fn domain(&self) -> B256 {
        self.domain
    }

    /// L2 chain id.
    pub fn chain_id(&self) -> u64 {
        self.chain_id
    }

    /// Bisection depth.
    pub fn max_depth(&self) -> u8 {
        self.max_depth
    }

    /// Padded trace length, `2^max_depth`.
    pub fn max_steps(&self) -> u64 {
        1u64 << self.max_depth
    }

    /// Machine at step 0 of an epoch: exactly what `DisputeGame.initialMachine` computes on L1.
    pub fn initial_machine(&self, pre_state: SparseMerkleTree, tape: Arc<Tape>) -> MachineState {
        MachineState::new(Arc::clone(&self.program), tape, pre_state)
    }

    /// Executes an epoch to completion.
    ///
    /// # Errors
    /// [`StfError::TraceTooLong`] or [`StfError::ProgramErrored`]; neither happens for inbox-accepted batches.
    pub fn execute(&self, pre_state: &SparseMerkleTree, tape: Arc<Tape>) -> Result<Execution, StfError> {
        self.execute_owned(pre_state.clone(), tape)
    }

    /// [`Stf::execute`] on a pre-state the caller no longer needs (saves one copy of the state tree).
    ///
    /// # Errors
    /// See [`Stf::execute`].
    pub fn execute_owned(&self, pre_state: SparseMerkleTree, tape: Arc<Tape>) -> Result<Execution, StfError> {
        let mut m = self.initial_machine(pre_state, tape);
        let mut steps = 0u64;
        while m.is_running() {
            if steps >= self.max_steps() {
                return Err(StfError::TraceTooLong(self.max_steps()));
            }
            step(&mut m, Witness::Skip);
            steps += 1;
        }
        if m.status == Status::Errored {
            return Err(StfError::ProgramErrored { pc: m.pc, steps });
        }
        Ok(Execution { final_commitment: m.commitment(), post_state: m.state, steps })
    }
}

/// A deliberate deviation from the honest execution, used by the `--malicious` proposer: right after executing step
/// `at_step`, credit `amount` to `beneficiary` out of thin air. Every later state inherits the forged balance, so the
/// resulting trace is self-consistent everywhere except at `at_step`, which is exactly where bisection converges.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Fault {
    /// Index of the step whose post-state is forged.
    pub at_step: u64,
    /// Account word credited.
    pub beneficiary: U256,
    /// Amount minted.
    pub amount: U256,
}

/// Full trace of one epoch, padded to `2^max_depth` steps, with random access to state hashes and witnesses.
#[derive(Debug, Clone)]
pub struct EpochTrace {
    initial: MachineState,
    /// `hashes[i]` = state hash after `i` steps, up to and including the first stopped state.
    hashes: Vec<B256>,
    final_machine: MachineState,
    fault: Option<Fault>,
    max_steps: u64,
}

fn apply_fault(m: &mut MachineState, fault: &Fault) {
    let key = crate::keys::balance_key(fault.beneficiary);
    let balance = U256::from_be_bytes(m.state.get(key).0);
    m.state.insert(key, word(balance.wrapping_add(fault.amount)));
}

impl EpochTrace {
    /// Executes and records the trace (optionally with a fault).
    ///
    /// # Errors
    /// [`StfError::TraceTooLong`] when the program does not stop within `2^max_depth` steps.
    pub fn new(stf: &Stf, initial: MachineState, fault: Option<Fault>) -> Result<Self, StfError> {
        let max_steps = stf.max_steps();
        let mut m = initial.clone();
        let mut hashes = vec![m.hash()];
        let mut i = 0u64;
        while m.is_running() {
            if i >= max_steps {
                return Err(StfError::TraceTooLong(max_steps));
            }
            step(&mut m, Witness::Skip);
            if let Some(f) = fault.as_ref().filter(|f| f.at_step == i) {
                apply_fault(&mut m, f);
            }
            hashes.push(m.hash());
            i += 1;
        }
        Ok(Self { initial, hashes, final_machine: m, fault, max_steps })
    }

    /// Number of steps until the machine stopped.
    pub fn steps(&self) -> u64 {
        self.hashes.len() as u64 - 1
    }

    /// Padded trace length.
    pub fn max_steps(&self) -> u64 {
        self.max_steps
    }

    /// State hash after `i` steps (a stopped machine is a fixed point, so the padding repeats the final hash).
    pub fn hash_at(&self, i: u64) -> B256 {
        let idx = usize::try_from(i).unwrap_or(usize::MAX).min(self.hashes.len() - 1);
        self.hashes[idx]
    }

    /// Final machine.
    pub fn final_machine(&self) -> &MachineState {
        &self.final_machine
    }

    /// Final machine commitment (what `commitEnd` reveals).
    pub fn final_commitment(&self) -> MachineCommitment {
        self.final_machine.commitment()
    }

    /// Machine after `i` steps, re-executed from the initial state (with the same fault, if any).
    ///
    /// # Errors
    /// [`StfError::StepOutOfRange`] beyond the padded length.
    pub fn machine_at(&self, i: u64) -> Result<MachineState, StfError> {
        if i > self.max_steps {
            return Err(StfError::StepOutOfRange(i));
        }
        let mut m = self.initial.clone();
        for k in 0..i {
            if !m.is_running() {
                break;
            }
            step(&mut m, Witness::Skip);
            if let Some(f) = self.fault.as_ref().filter(|f| f.at_step == k) {
                apply_fault(&mut m, f);
            }
        }
        Ok(m)
    }

    /// Pre-state commitment and witness for executing step `i` (from state `i` to `i + 1`) on-chain.
    ///
    /// # Errors
    /// [`StfError::StepOutOfRange`] beyond the padded length.
    pub fn proof_at(&self, i: u64) -> Result<(MachineCommitment, StepProof), StfError> {
        let mut m = self.machine_at(i)?;
        let pre = m.commitment();
        let proof = step(&mut m, Witness::Build);
        Ok((pre, proof))
    }

    /// First step index whose post-state differs from `other` (the step bisection must converge to).
    pub fn first_divergence(&self, other: &Self) -> Option<u64> {
        let end = self.hashes.len().max(other.hashes.len()) as u64;
        (1..=end).find(|i| self.hash_at(*i) != other.hash_at(*i)).map(|i| i - 1)
    }
}
