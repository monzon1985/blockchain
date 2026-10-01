// SPDX-License-Identifier: MIT
//! The transition function and its one-step witness.
//!
//! Evaluation order is part of the specification and matches `OneStepVM.sol` line by line:
//! 1. a halted or errored machine is a fixed point;
//! 2. `pc >= codeSize` errors;
//! 3. (witness: instruction + Merkle path)
//! 4. undefined opcode, `FAIL`, or an out-of-range `DUP`/`SWAP` operand errors; `HALT` halts;
//! 5. stack underflow or overflow errors;
//! 6. (witness: revealed stack words + hash below them)
//! 7. the opcode executes; an invalid jump target errors.
//!
//! Erroring changes nothing but the status.

use alloy_primitives::{B256, U256};

use crate::{
    abi::StepProof,
    crypto::ecrecover,
    machine::{MachineState, Status},
    opcode::{MAX_STACK, Opcode},
    smt::hash_pair,
};

/// Whether `step` should also build the witness the on-chain verifier needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Witness {
    /// Only execute.
    Skip,
    /// Execute and return the witness for the executed step.
    Build,
}

fn word(x: U256) -> B256 {
    B256::from(x.to_be_bytes::<32>())
}

fn num(x: B256) -> U256 {
    U256::from_be_bytes(x.0)
}

fn flag(b: bool) -> B256 {
    word(U256::from(u8::from(b)))
}

/// Executes one instruction in place. Returns the witness when asked; the witness of a step on a machine that is not
/// running is empty (the verifier ignores it).
pub fn step(m: &mut MachineState, witness: Witness) -> StepProof {
    let build = witness == Witness::Build;
    let mut proof = StepProof::default();
    if m.status != Status::Running {
        return proof;
    }
    let pc = m.pc;
    let Some(ins) = m.program().get(pc).copied() else {
        m.status = Status::Errored;
        return proof;
    };
    if build {
        proof.opcode = ins.opcode;
        proof.imm = ins.imm;
        proof.codeProof = m.program().proof(pc);
    }
    let Some(op) = ins.decoded() else {
        m.status = Status::Errored;
        return proof;
    };
    if op == Opcode::Halt {
        m.status = Status::Halted;
        return proof;
    }
    let Some((reads, writes)) = op.shape(ins.imm) else {
        m.status = Status::Errored;
        return proof;
    };
    let depth = m.stack.len();
    if depth < reads || depth - reads + writes > MAX_STACK {
        m.status = Status::Errored;
        return proof;
    }
    let s = m.stack.top(reads);
    if build {
        proof.stack = s.clone();
        proof.stackRest = m.stack.hash_below(reads);
    }

    let code_size = U256::from(m.program().code_size());
    let mut next_pc = pc + 1;
    let out: Vec<B256> = match op {
        Opcode::Push => vec![word(ins.imm)],
        Opcode::Pop => vec![],
        Opcode::Dup => {
            let n = ins.imm.to::<usize>();
            std::iter::once(s[n]).chain(s.iter().copied()).collect()
        }
        Opcode::Swap => {
            let n = ins.imm.to::<usize>();
            let mut v = s.clone();
            v.swap(0, n);
            v
        }
        Opcode::Add => vec![word(num(s[0]).wrapping_add(num(s[1])))],
        Opcode::Sub => vec![word(num(s[0]).wrapping_sub(num(s[1])))],
        Opcode::Mul => vec![word(num(s[0]).wrapping_mul(num(s[1])))],
        Opcode::Div => vec![word(num(s[0]).checked_div(num(s[1])).unwrap_or_default())],
        Opcode::Lt => vec![flag(num(s[0]) < num(s[1]))],
        Opcode::Gt => vec![flag(num(s[0]) > num(s[1]))],
        Opcode::Eq => vec![flag(s[0] == s[1])],
        Opcode::IsZero => vec![flag(s[0].is_zero())],
        Opcode::And => vec![s[0] & s[1]],
        Opcode::Or => vec![s[0] | s[1]],
        Opcode::Hash => vec![hash_pair(s[0], s[1])],
        Opcode::Jump | Opcode::JumpI => {
            let taken = op == Opcode::Jump || !s[0].is_zero();
            if taken {
                if ins.imm >= code_size {
                    m.status = Status::Errored;
                    return proof;
                }
                next_pc = ins.imm.to::<u32>();
            }
            vec![]
        }
        Opcode::Input => {
            if build {
                proof.tape = m.tape().bytes().clone();
            }
            let index = num(s[0]);
            let value =
                if index < U256::from(m.tape().size()) { m.tape().word(index.to::<usize>()) } else { B256::ZERO };
            vec![value]
        }
        Opcode::InputSize => vec![word(U256::from(m.tape().size()))],
        Opcode::SLoad => {
            if build {
                attach_state_witness(&mut proof, m, s[0]);
            }
            vec![m.state.get(s[0])]
        }
        Opcode::SStore => {
            if build {
                attach_state_witness(&mut proof, m, s[0]);
            }
            m.state.insert(s[0], s[1]);
            vec![]
        }
        Opcode::EcRecover => vec![ecrecover(s[0], num(s[1]), s[2], s[3])],
        // Handled above (HALT) or rejected by `shape` (FAIL).
        Opcode::Halt | Opcode::Fail => {
            m.status = Status::Errored;
            return proof;
        }
    };

    m.stack.drop_top(reads);
    for x in out.into_iter().rev() {
        m.stack.push(x);
    }
    m.pc = next_pc;
    proof
}

fn attach_state_witness(proof: &mut StepProof, m: &MachineState, key: B256) {
    let smt = m.state.proof(key);
    proof.leafValue = m.state.get(key);
    proof.siblingBitmap = smt.bitmap;
    proof.siblings = smt.siblings;
}

/// Outcome of running a machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunSummary {
    /// Steps executed (a step on a stopped machine is not counted).
    pub steps: u64,
    /// Final status.
    pub status: Status,
}

/// Runs until the machine stops or `max_steps` steps were executed.
pub fn run(m: &mut MachineState, max_steps: u64) -> RunSummary {
    let mut steps = 0;
    while m.is_running() && steps < max_steps {
        step(m, Witness::Skip);
        steps += 1;
    }
    RunSummary { steps, status: m.status }
}

/// Runs until the machine stops or `max_steps` steps were executed, recording the state hash before the first step
/// and after every step: `hashes[i]` is the hash after `i` steps. Hashes past the end of the vector equal the last
/// one, because a stopped machine is a fixed point.
pub fn trace(m: &mut MachineState, max_steps: u64) -> Vec<B256> {
    let mut hashes = vec![m.hash()];
    let mut steps = 0;
    while m.is_running() && steps < max_steps {
        step(m, Witness::Skip);
        hashes.push(m.hash());
        steps += 1;
    }
    hashes
}
