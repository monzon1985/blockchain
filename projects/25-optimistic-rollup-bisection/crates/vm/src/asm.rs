// SPDX-License-Identifier: MIT
//! A tiny assembler with forward-referencable labels, used to write the state-transition program.

use alloy_primitives::U256;

use crate::{
    code::Program,
    error::VmError,
    opcode::{Instruction, Opcode},
};

/// A jump target created by [`Assembler::label`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Label(usize);

/// Builds a [`Program`] instruction by instruction.
#[derive(Debug, Default)]
pub struct Assembler {
    code: Vec<Instruction>,
    labels: Vec<Option<u32>>,
    fixups: Vec<(usize, Label)>,
    errors: Vec<VmError>,
}

impl Assembler {
    /// Empty assembler.
    pub fn new() -> Self {
        Self::default()
    }

    /// Creates an unbound label.
    pub fn label(&mut self) -> Label {
        self.labels.push(None);
        Label(self.labels.len() - 1)
    }

    /// Binds `label` to the next instruction.
    pub fn bind(&mut self, label: Label) -> &mut Self {
        let here = self.here();
        match self.labels.get_mut(label.0) {
            Some(slot @ None) => *slot = Some(here),
            _ => self.errors.push(VmError::LabelBoundTwice(label.0)),
        }
        self
    }

    /// Index of the next instruction.
    pub fn here(&self) -> u32 {
        u32::try_from(self.code.len()).unwrap_or(u32::MAX)
    }

    /// Appends a raw instruction.
    pub fn emit(&mut self, ins: Instruction) -> &mut Self {
        self.code.push(ins);
        self
    }

    /// Appends an instruction without immediate.
    pub fn op(&mut self, op: Opcode) -> &mut Self {
        self.emit(Instruction::op(op))
    }

    /// `PUSH value`.
    pub fn push(&mut self, value: U256) -> &mut Self {
        self.emit(Instruction::with_imm(Opcode::Push, value))
    }

    /// `PUSH value` for a small constant.
    pub fn push_u64(&mut self, value: u64) -> &mut Self {
        self.push(U256::from(value))
    }

    /// `DUP n` (0 = top).
    pub fn dup(&mut self, n: u8) -> &mut Self {
        self.emit(Instruction::with_imm(Opcode::Dup, U256::from(n)))
    }

    /// `SWAP n`.
    pub fn swap(&mut self, n: u8) -> &mut Self {
        self.emit(Instruction::with_imm(Opcode::Swap, U256::from(n)))
    }

    /// `JUMP label`.
    pub fn jump(&mut self, label: Label) -> &mut Self {
        self.fixups.push((self.code.len(), label));
        self.emit(Instruction::op(Opcode::Jump))
    }

    /// `JUMPI label`.
    pub fn jumpi(&mut self, label: Label) -> &mut Self {
        self.fixups.push((self.code.len(), label));
        self.emit(Instruction::op(Opcode::JumpI))
    }

    /// Resolves labels and commits to the program.
    ///
    /// # Errors
    /// Unbound or doubly bound labels, or a program too large for a `u32` program counter.
    pub fn finish(mut self) -> Result<Program, VmError> {
        if let Some(e) = self.errors.into_iter().next() {
            return Err(e);
        }
        for (at, label) in self.fixups {
            let target = self.labels.get(label.0).copied().flatten().ok_or(VmError::UnboundLabel(label.0))?;
            self.code[at].imm = U256::from(target);
        }
        Program::new(self.code)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forward_and_backward_labels_resolve() {
        let mut a = Assembler::new();
        let top = a.label();
        let end = a.label();
        a.bind(top).push_u64(1).jumpi(end).jump(top).bind(end).op(Opcode::Halt);
        let p = a.finish().unwrap();
        assert_eq!(p.instructions()[1].imm, U256::from(3));
        assert_eq!(p.instructions()[2].imm, U256::ZERO);
    }

    #[test]
    fn unbound_label_is_an_error() {
        let mut a = Assembler::new();
        let l = a.label();
        a.jump(l);
        assert_eq!(a.finish().unwrap_err(), VmError::UnboundLabel(0));
    }

    #[test]
    fn double_bind_is_an_error() {
        let mut a = Assembler::new();
        let l = a.label();
        a.bind(l).op(Opcode::Halt).bind(l);
        assert_eq!(a.finish().unwrap_err(), VmError::LabelBoundTwice(0));
    }
}
