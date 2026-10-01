// SPDX-License-Identifier: MIT
//! Programs and their OpenZeppelin-compatible Merkle commitment.
//!
//! Leaf of instruction `pc`: `keccak256(keccak256(abi.encode(pc, opcode, imm)))` (double hashing, the OpenZeppelin
//! convention against second-preimage tricks). Internal nodes use sorted-pair hashing
//! (`Hashes.commutativeKeccak256`); an unpaired node at the end of a layer is promoted unchanged. Proofs verify with
//! `MerkleProof.verifyCalldata` from OpenZeppelin Contracts 5.x.

use alloy_primitives::{B256, U256, keccak256};

use crate::{error::VmError, opcode::Instruction, smt::hash_pair};

/// Leaf hash of the instruction at `pc`.
pub fn instruction_leaf(pc: u32, ins: &Instruction) -> B256 {
    let mut buf = [0u8; 96];
    buf[..32].copy_from_slice(&U256::from(pc).to_be_bytes::<32>());
    buf[32..64].copy_from_slice(&U256::from(ins.opcode).to_be_bytes::<32>());
    buf[64..].copy_from_slice(&ins.imm.to_be_bytes::<32>());
    keccak256(keccak256(buf))
}

/// `Hashes.commutativeKeccak256`.
pub fn commutative_hash(a: B256, b: B256) -> B256 {
    if a < b { hash_pair(a, b) } else { hash_pair(b, a) }
}

/// Folds an OpenZeppelin proof (`MerkleProof.processProof`).
pub fn process_proof(leaf: B256, proof: &[B256]) -> B256 {
    proof.iter().fold(leaf, |acc, sibling| commutative_hash(acc, *sibling))
}

/// An immutable program with its Merkle tree precomputed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Program {
    instructions: Vec<Instruction>,
    /// `layers[0]` are the leaves, the last layer holds the root.
    layers: Vec<Vec<B256>>,
}

impl Program {
    /// Commits to `instructions`.
    ///
    /// # Errors
    /// [`VmError::ProgramTooLarge`] beyond `u32::MAX` instructions.
    pub fn new(instructions: Vec<Instruction>) -> Result<Self, VmError> {
        let n = instructions.len();
        let len = u32::try_from(n).map_err(|_| VmError::ProgramTooLarge(n))?;
        let leaves: Vec<B256> = (0..len).zip(&instructions).map(|(pc, ins)| instruction_leaf(pc, ins)).collect();
        let mut layers = vec![leaves];
        loop {
            let prev = &layers[layers.len() - 1];
            if prev.len() <= 1 {
                break;
            }
            let next: Vec<B256> = prev
                .chunks(2)
                .map(|pair| match pair {
                    [a, b] => commutative_hash(*a, *b),
                    [a] => *a,
                    _ => B256::ZERO,
                })
                .collect();
            layers.push(next);
        }
        Ok(Self { instructions, layers })
    }

    /// Merkle root (zero for an empty program).
    pub fn code_root(&self) -> B256 {
        self.layers.last().and_then(|l| l.first()).copied().unwrap_or_default()
    }

    /// Number of instructions.
    pub fn code_size(&self) -> u32 {
        // Bounded by the check in `new`, so the narrowing is exact.
        self.instructions.len() as u32
    }

    /// Instruction at `pc`.
    pub fn get(&self, pc: u32) -> Option<&Instruction> {
        self.instructions.get(pc as usize)
    }

    /// All instructions.
    pub fn instructions(&self) -> &[Instruction] {
        &self.instructions
    }

    /// Sibling path of instruction `pc` (empty when out of range).
    pub fn proof(&self, pc: u32) -> Vec<B256> {
        let mut idx = pc as usize;
        if idx >= self.instructions.len() {
            return Vec::new();
        }
        let mut proof = Vec::new();
        for layer in &self.layers[..self.layers.len() - 1] {
            if let Some(sibling) = layer.get(idx ^ 1) {
                proof.push(*sibling);
            }
            idx /= 2;
        }
        proof
    }

    /// Human-readable listing, one instruction per line.
    pub fn disassemble(&self) -> String {
        use std::fmt::Write as _;
        let mut out = String::new();
        for (pc, ins) in self.instructions.iter().enumerate() {
            let _ = writeln!(out, "{pc:5}: {ins}");
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::opcode::Opcode;
    use proptest::prelude::*;

    fn program(n: usize) -> Program {
        let ins = (0..n).map(|i| Instruction::with_imm(Opcode::Push, U256::from(i * 7 + 1))).collect();
        Program::new(ins).unwrap()
    }

    #[test]
    fn single_instruction_root_is_its_leaf() {
        let p = program(1);
        assert_eq!(p.code_root(), instruction_leaf(0, &p.instructions()[0]));
        assert!(p.proof(0).is_empty());
    }

    #[test]
    fn empty_program_has_zero_root() {
        let p = Program::new(vec![]).unwrap();
        assert_eq!(p.code_root(), B256::ZERO);
        assert_eq!(p.code_size(), 0);
        assert!(p.proof(0).is_empty());
        assert!(p.get(0).is_none());
    }

    #[test]
    fn leaf_binds_the_program_counter() {
        let ins = Instruction::op(Opcode::Add);
        assert_ne!(instruction_leaf(0, &ins), instruction_leaf(1, &ins));
    }

    #[test]
    fn disassembly_lists_every_instruction() {
        let text = program(3).disassemble();
        assert_eq!(text.lines().count(), 3);
        assert!(text.contains("PUSH 0x8"));
    }

    proptest! {
        #[test]
        fn every_instruction_proves_against_the_root(n in 1usize..200) {
            let p = program(n);
            for pc in 0..n as u32 {
                let leaf = instruction_leaf(pc, &p.instructions()[pc as usize]);
                prop_assert_eq!(process_proof(leaf, &p.proof(pc)), p.code_root());
            }
        }

        #[test]
        fn a_different_instruction_does_not_prove(n in 2usize..100, pc_seed in any::<u32>(), imm in any::<u64>()) {
            let p = program(n);
            let pc = pc_seed % n as u32;
            let forged = Instruction::with_imm(Opcode::Push, U256::from(imm));
            prop_assume!(forged != p.instructions()[pc as usize]);
            prop_assert_ne!(process_proof(instruction_leaf(pc, &forged), &p.proof(pc)), p.code_root());
        }
    }
}
