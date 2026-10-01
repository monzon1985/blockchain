// SPDX-License-Identifier: MIT
//! Interpreter unit and property tests.

use std::sync::Arc;

use alloy_primitives::{B256, U256, keccak256};
use proptest::prelude::*;

use crate::{
    abi::StepProof,
    asm::Assembler,
    code::{Program, instruction_leaf, process_proof},
    interp::{Witness, run, step, trace},
    machine::{MachineState, Status, Tape},
    opcode::{Instruction, MAX_STACK, Opcode},
    smt::{SmtProof, SparseMerkleTree, hash_pair},
    stack::Stack,
};

fn w(x: u64) -> B256 {
    B256::from(U256::from(x))
}

fn machine(program: Program, tape: Vec<B256>, stack: Vec<B256>) -> MachineState {
    let mut m = MachineState::new(Arc::new(program), Arc::new(Tape::new(tape).unwrap()), SparseMerkleTree::new());
    m.stack = Stack::from_items(stack);
    m
}

fn single(op: Opcode, imm: u64, stack: Vec<B256>) -> MachineState {
    let program =
        Program::new(vec![Instruction::with_imm(op, U256::from(imm)), Instruction::op(Opcode::Halt)]).unwrap();
    machine(program, vec![], stack)
}

/// Stack after one step, top first.
fn after(op: Opcode, imm: u64, stack_bottom_first: Vec<B256>) -> (Status, Vec<B256>) {
    let mut m = single(op, imm, stack_bottom_first);
    step(&mut m, Witness::Skip);
    (m.status, m.stack.items().iter().rev().copied().collect())
}

#[test]
fn arithmetic_pops_a_then_b() {
    // Stack bottom-first [b, a]: a is on top.
    assert_eq!(after(Opcode::Sub, 0, vec![w(3), w(10)]).1, vec![w(7)]);
    assert_eq!(after(Opcode::Sub, 0, vec![w(10), w(3)]).1, vec![B256::from(U256::MAX - U256::from(6))]);
    assert_eq!(after(Opcode::Add, 0, vec![B256::from(U256::MAX), w(2)]).1, vec![w(1)]);
    assert_eq!(after(Opcode::Mul, 0, vec![w(6), w(7)]).1, vec![w(42)]);
    assert_eq!(after(Opcode::Div, 0, vec![w(3), w(10)]).1, vec![w(3)]);
    assert_eq!(after(Opcode::Div, 0, vec![w(0), w(10)]).1, vec![w(0)]);
    assert_eq!(after(Opcode::Lt, 0, vec![w(5), w(4)]).1, vec![w(1)]);
    assert_eq!(after(Opcode::Gt, 0, vec![w(5), w(4)]).1, vec![w(0)]);
    assert_eq!(after(Opcode::Eq, 0, vec![w(5), w(5)]).1, vec![w(1)]);
    assert_eq!(after(Opcode::IsZero, 0, vec![w(0)]).1, vec![w(1)]);
    assert_eq!(after(Opcode::And, 0, vec![w(0b1100), w(0b1010)]).1, vec![w(0b1000)]);
    assert_eq!(after(Opcode::Or, 0, vec![w(0b1100), w(0b1010)]).1, vec![w(0b1110)]);
}

#[test]
fn hash_is_keccak_of_top_then_second() {
    let (_, s) = after(Opcode::Hash, 0, vec![w(2), w(1)]);
    assert_eq!(s, vec![keccak256([w(1).as_slice(), w(2).as_slice()].concat())]);
}

#[test]
fn dup_and_swap_address_items_from_the_top() {
    let stack = vec![w(1), w(2), w(3)]; // top is 3
    assert_eq!(after(Opcode::Dup, 0, stack.clone()).1, vec![w(3), w(3), w(2), w(1)]);
    assert_eq!(after(Opcode::Dup, 2, stack.clone()).1, vec![w(1), w(3), w(2), w(1)]);
    assert_eq!(after(Opcode::Swap, 2, stack.clone()).1, vec![w(1), w(2), w(3)]);
    assert_eq!(after(Opcode::Dup, 3, stack.clone()).0, Status::Errored);
    assert_eq!(after(Opcode::Swap, 0, stack.clone()).0, Status::Errored);
    assert_eq!(after(Opcode::Dup, 16, stack).0, Status::Errored);
}

#[test]
fn errors_leave_everything_but_status_untouched() {
    for (op, imm, stack) in [
        (Opcode::Add, 0, vec![w(1)]),       // underflow
        (Opcode::Fail, 0, vec![w(1)]),      // explicit failure
        (Opcode::Jump, 99, vec![w(1)]),     // target outside the program
        (Opcode::JumpI, 99, vec![w(1)]),    // taken jump outside the program
        (Opcode::Swap, 16, vec![w(1); 17]), // reach out of range
    ] {
        let mut m = single(op, imm, stack);
        let before = m.commitment();
        step(&mut m, Witness::Skip);
        let mut expected = before;
        expected.status = Status::Errored as u8;
        assert_eq!(m.commitment(), expected, "{op:?}");
    }
    // A JUMPI that is not taken never looks at its target.
    let mut m = single(Opcode::JumpI, 99, vec![w(0)]);
    step(&mut m, Witness::Skip);
    assert_eq!((m.status, m.pc), (Status::Running, 1));
}

#[test]
fn undefined_opcode_and_running_off_the_end_error() {
    let mut m = machine(Program::new(vec![Instruction { opcode: 0x42, imm: U256::ZERO }]).unwrap(), vec![], vec![]);
    step(&mut m, Witness::Skip);
    assert_eq!(m.status, Status::Errored);

    let mut m =
        machine(Program::new(vec![Instruction::with_imm(Opcode::Push, U256::from(1))]).unwrap(), vec![], vec![]);
    let summary = run(&mut m, 10);
    assert_eq!((summary.steps, summary.status), (2, Status::Errored));
}

#[test]
fn stack_overflow_errors() {
    let mut m = single(Opcode::Push, 1, vec![w(0); MAX_STACK]);
    step(&mut m, Witness::Skip);
    assert_eq!(m.status, Status::Errored);
}

#[test]
fn input_reads_words_and_zero_out_of_range() {
    let mut a = Assembler::new();
    a.push_u64(1).op(Opcode::Input).push_u64(7).op(Opcode::Input).op(Opcode::InputSize).op(Opcode::Halt);
    let mut m = machine(a.finish().unwrap(), vec![w(10), w(11)], vec![]);
    run(&mut m, 100);
    assert_eq!(m.status, Status::Halted);
    assert_eq!(m.stack.items(), &[w(11), w(0), w(2)]);
}

#[test]
fn sstore_then_sload_round_trips_and_moves_the_root() {
    let mut a = Assembler::new();
    a.push_u64(99).push_u64(5).op(Opcode::SStore).push_u64(5).op(Opcode::SLoad).op(Opcode::Halt);
    let mut m = machine(a.finish().unwrap(), vec![], vec![]);
    let empty_root = m.state.root();
    run(&mut m, 100);
    assert_eq!(m.stack.items(), &[w(99)]);
    assert_ne!(m.state.root(), empty_root);
    assert_eq!(m.state.get(w(5)), w(99));
}

#[test]
fn halted_machine_is_a_fixed_point() {
    let mut m = single(Opcode::Halt, 0, vec![w(1)]);
    step(&mut m, Witness::Skip);
    assert_eq!(m.status, Status::Halted);
    let h = m.hash();
    let proof = step(&mut m, Witness::Build);
    assert_eq!(m.hash(), h);
    assert_eq!(proof, StepProof::default());
}

#[test]
fn trace_records_every_intermediate_hash() {
    let mut a = Assembler::new();
    a.push_u64(1).push_u64(2).op(Opcode::Add).op(Opcode::Halt);
    let mut m = machine(a.finish().unwrap(), vec![], vec![]);
    let hashes = trace(&mut m, 100);
    assert_eq!(hashes.len(), 5);
    assert_eq!(*hashes.last().unwrap(), m.hash());
    assert_eq!(m.stack.items(), &[w(3)]);
}

/// Checks a witness against the pre-state the way `OneStepVM.sol` does (code proof, stack reveal, state proof, tape).
fn witness_is_consistent(pre: &MachineState, proof: &StepProof) -> bool {
    let c = pre.commitment();
    if pre.status != Status::Running || pre.pc >= pre.program().code_size() {
        return true;
    }
    let leaf = instruction_leaf(pre.pc, &Instruction { opcode: proof.opcode, imm: proof.imm });
    if process_proof(leaf, &proof.codeProof) != c.codeRoot {
        return false;
    }
    let folded = proof.stack.iter().rev().fold(proof.stackRest, |h, x| hash_pair(*x, h));
    if !proof.stack.is_empty() && folded != c.stackHash {
        return false;
    }
    match Opcode::from_u8(proof.opcode) {
        Some(Opcode::SLoad | Opcode::SStore) if !proof.stack.is_empty() => {
            let smt = SmtProof { bitmap: proof.siblingBitmap, siblings: proof.siblings.clone() };
            smt.compute_root(proof.stack[0], proof.leafValue).ok() == Some(c.stateRoot)
        }
        Some(Opcode::Input) if !proof.stack.is_empty() => keccak256(&proof.tape) == c.inputRoot,
        _ => true,
    }
}

fn arb_instruction(len: u64) -> impl Strategy<Value = Instruction> {
    let small = (0u64..24).prop_map(U256::from);
    prop_oneof![
        8 => (0u8..24, small.clone()).prop_map(|(op, imm)| Instruction { opcode: op, imm }),
        2 => (0u8..=255, any::<[u8; 32]>()).prop_map(|(op, imm)| Instruction { opcode: op, imm: U256::from_be_bytes(imm) }),
        2 => (0..len + 2).prop_map(|t| Instruction::with_imm(Opcode::JumpI, U256::from(t))),
        3 => small.prop_map(|v| Instruction::with_imm(Opcode::Push, v)),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(128))]

    #[test]
    fn every_witness_verifies_against_its_pre_state(
        program in prop::collection::vec(arb_instruction(32), 1..32),
        tape in prop::collection::vec((0u64..8).prop_map(w), 0..8),
        stack in prop::collection::vec((0u64..8).prop_map(w), 0..8),
        keys in prop::collection::vec((0u64..8, 1u64..5), 0..6),
    ) {
        let mut m = machine(Program::new(program).unwrap(), tape, stack);
        for (k, v) in keys { m.state.insert(w(k), w(v)); }
        for _ in 0..64 {
            let pre = m.clone();
            let proof = step(&mut m, Witness::Build);
            prop_assert!(witness_is_consistent(&pre, &proof));
            // Building the witness never changes the transition.
            let mut replay = pre.clone();
            step(&mut replay, Witness::Skip);
            prop_assert_eq!(replay.hash(), m.hash());
        }
    }

    #[test]
    fn stopped_machines_stay_stopped(program in prop::collection::vec(arb_instruction(16), 1..16)) {
        let mut m = machine(Program::new(program).unwrap(), vec![], vec![]);
        run(&mut m, 1_000);
        if !m.is_running() {
            let h = m.hash();
            step(&mut m, Witness::Skip);
            prop_assert_eq!(m.hash(), h);
        }
    }
}
