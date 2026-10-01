// SPDX-License-Identifier: MIT
//! Instruction set of the rollup VM.
//!
//! Every value here is mirrored by `contracts/src/lib/VmSpec.sol`; the differential suite in `crates/diff` fails if
//! the two drift apart.

use alloy_primitives::U256;

/// Maximum number of words on the stack. Exceeding it errors the machine.
pub const MAX_STACK: usize = 1024;

/// Deepest stack slot reachable by `DUP`/`SWAP` (inclusive).
pub const MAX_STACK_REACH: u64 = 15;

/// The 24 opcodes of the VM. Binary operators pop `a` (top) then `b` and push `a OP b`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Opcode {
    /// Stop successfully; the machine becomes a fixed point.
    Halt = 0x00,
    /// Push the immediate.
    Push = 0x01,
    /// Drop the top word.
    Pop = 0x02,
    /// Push a copy of stack item `imm` (0 = top), `imm <= 15`.
    Dup = 0x03,
    /// Swap the top with stack item `imm`, `1 <= imm <= 15`.
    Swap = 0x04,
    /// `a + b` modulo 2^256.
    Add = 0x05,
    /// `a - b` modulo 2^256.
    Sub = 0x06,
    /// `a * b` modulo 2^256.
    Mul = 0x07,
    /// `a / b`, or 0 when `b == 0`.
    Div = 0x08,
    /// `a < b` as 0/1.
    Lt = 0x09,
    /// `a > b` as 0/1.
    Gt = 0x0a,
    /// `a == b` as 0/1.
    Eq = 0x0b,
    /// `a == 0` as 0/1.
    IsZero = 0x0c,
    /// Bitwise and.
    And = 0x0d,
    /// Bitwise or.
    Or = 0x0e,
    /// `keccak256(abi.encode(a, b))`.
    Hash = 0x0f,
    /// Jump to the immediate (errors if it is outside the program).
    Jump = 0x10,
    /// Pop a condition; jump to the immediate if it is non-zero.
    JumpI = 0x11,
    /// Pop an index; push that tape word (0 when out of range).
    Input = 0x12,
    /// Push the tape length in words.
    InputSize = 0x13,
    /// Pop a key; push its value from the state tree.
    SLoad = 0x14,
    /// Pop a key then a value; write the value into the state tree.
    SStore = 0x15,
    /// Pop hash, v, r, s; push the recovered address (0 on failure), exactly like the ecrecover precompile.
    EcRecover = 0x16,
    /// Error the machine (explicit assertion failure).
    Fail = 0x17,
}

impl Opcode {
    /// Every defined opcode, in numeric order.
    pub const ALL: [Self; 24] = [
        Self::Halt,
        Self::Push,
        Self::Pop,
        Self::Dup,
        Self::Swap,
        Self::Add,
        Self::Sub,
        Self::Mul,
        Self::Div,
        Self::Lt,
        Self::Gt,
        Self::Eq,
        Self::IsZero,
        Self::And,
        Self::Or,
        Self::Hash,
        Self::Jump,
        Self::JumpI,
        Self::Input,
        Self::InputSize,
        Self::SLoad,
        Self::SStore,
        Self::EcRecover,
        Self::Fail,
    ];

    /// Decodes a raw opcode byte; `None` for undefined bytes.
    pub fn from_u8(byte: u8) -> Option<Self> {
        Self::ALL.get(usize::from(byte)).copied()
    }

    /// Mnemonic used by the disassembler.
    pub const fn mnemonic(self) -> &'static str {
        match self {
            Self::Halt => "HALT",
            Self::Push => "PUSH",
            Self::Pop => "POP",
            Self::Dup => "DUP",
            Self::Swap => "SWAP",
            Self::Add => "ADD",
            Self::Sub => "SUB",
            Self::Mul => "MUL",
            Self::Div => "DIV",
            Self::Lt => "LT",
            Self::Gt => "GT",
            Self::Eq => "EQ",
            Self::IsZero => "ISZERO",
            Self::And => "AND",
            Self::Or => "OR",
            Self::Hash => "HASH",
            Self::Jump => "JUMP",
            Self::JumpI => "JUMPI",
            Self::Input => "INPUT",
            Self::InputSize => "INPUTSIZE",
            Self::SLoad => "SLOAD",
            Self::SStore => "SSTORE",
            Self::EcRecover => "ECRECOVER",
            Self::Fail => "FAIL",
        }
    }

    /// Stack words read and written back, or `None` when the instruction errors the machine
    /// (FAIL, out-of-range `DUP`/`SWAP` operand). `HALT` is handled before shapes are consulted.
    pub fn shape(self, imm: U256) -> Option<(usize, usize)> {
        let reach =
            || -> Option<usize> { if imm > U256::from(MAX_STACK_REACH) { None } else { Some(imm.to::<usize>()) } };
        match self {
            Self::Push | Self::InputSize => Some((0, 1)),
            Self::Pop | Self::JumpI => Some((1, 0)),
            Self::Jump | Self::Halt => Some((0, 0)),
            Self::Dup => reach().map(|n| (n + 1, n + 2)),
            Self::Swap => reach().filter(|n| *n != 0).map(|n| (n + 1, n + 1)),
            Self::Add
            | Self::Sub
            | Self::Mul
            | Self::Div
            | Self::Lt
            | Self::Gt
            | Self::Eq
            | Self::And
            | Self::Or
            | Self::Hash => Some((2, 1)),
            Self::IsZero | Self::Input | Self::SLoad => Some((1, 1)),
            Self::SStore => Some((2, 0)),
            Self::EcRecover => Some((4, 1)),
            Self::Fail => None,
        }
    }
}

/// One program instruction. The opcode is kept raw so programs may contain undefined bytes (they error the machine
/// when executed, exactly as on-chain).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Instruction {
    /// Raw opcode byte.
    pub opcode: u8,
    /// Immediate operand (push value, jump target, stack reach).
    pub imm: U256,
}

impl Instruction {
    /// Instruction without an immediate.
    pub const fn op(opcode: Opcode) -> Self {
        Self { opcode: opcode as u8, imm: U256::ZERO }
    }

    /// Instruction with an immediate.
    pub const fn with_imm(opcode: Opcode, imm: U256) -> Self {
        Self { opcode: opcode as u8, imm }
    }

    /// Decoded opcode, if defined.
    pub fn decoded(&self) -> Option<Opcode> {
        Opcode::from_u8(self.opcode)
    }
}

impl core::fmt::Display for Instruction {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self.decoded() {
            Some(op @ (Opcode::Push | Opcode::Dup | Opcode::Swap | Opcode::Jump | Opcode::JumpI)) => {
                write!(f, "{} {:#x}", op.mnemonic(), self.imm)
            }
            Some(op) => f.write_str(op.mnemonic()),
            None => write!(f, "INVALID({:#04x})", self.opcode),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opcode_bytes_round_trip() {
        for (i, op) in Opcode::ALL.iter().enumerate() {
            assert_eq!(*op as usize, i);
            assert_eq!(Opcode::from_u8(i as u8), Some(*op));
        }
        assert_eq!(Opcode::from_u8(0x18), None);
        assert_eq!(Opcode::from_u8(0xff), None);
    }

    #[test]
    fn dup_and_swap_reach_is_bounded() {
        assert_eq!(Opcode::Dup.shape(U256::from(15)), Some((16, 17)));
        assert_eq!(Opcode::Dup.shape(U256::from(16)), None);
        assert_eq!(Opcode::Swap.shape(U256::ZERO), None);
        assert_eq!(Opcode::Swap.shape(U256::from(15)), Some((16, 16)));
        assert_eq!(Opcode::Swap.shape(U256::MAX), None);
        assert_eq!(Opcode::Fail.shape(U256::ZERO), None);
    }

    #[test]
    fn display_is_readable() {
        assert_eq!(Instruction::with_imm(Opcode::Push, U256::from(7)).to_string(), "PUSH 0x7");
        assert_eq!(Instruction::op(Opcode::SStore).to_string(), "SSTORE");
        assert_eq!(Instruction { opcode: 0x42, imm: U256::ZERO }.to_string(), "INVALID(0x42)");
    }
}
