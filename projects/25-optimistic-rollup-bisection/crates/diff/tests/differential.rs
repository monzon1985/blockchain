// SPDX-License-Identifier: MIT
//! Differential tests: the Rust VM (`rollup-vm`) versus the compiled Solidity `OneStepVM` executed in revm.
//!
//! Requires `forge build` in `contracts/` first (the documented gate order does this).
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, missing_docs)]

use std::sync::{Arc, OnceLock};

use alloy_primitives::{Address, B256, Bytes, U256, keccak256};
use k256::ecdsa::SigningKey;
use proptest::prelude::*;
use rollup_diff::{EvmStep, OneStepVmEvm};
use rollup_stf::{Kind, L2Tx, Record, Stf, build_tape, encode_tx_data, key_address};
use rollup_vm::{
    Instruction, MachineState, Opcode, Program, SparseMerkleTree, StepProof, Tape, Witness, stack::Stack, step,
};

fn evm() -> &'static OneStepVmEvm {
    static EVM: OnceLock<OneStepVmEvm> = OnceLock::new();
    EVM.get_or_init(|| OneStepVmEvm::load().expect("run `forge build` in contracts/ before the differential tests"))
}

fn w(x: u64) -> B256 {
    B256::from(U256::from(x))
}

/// Executes one step in Rust and in Solidity; asserts the full post-state commitments are equal. Returns the gas.
fn assert_step_agrees(m: &mut MachineState) -> u64 {
    let pre = m.commitment();
    let proof = step(m, Witness::Build);
    match evm().step(&pre, &proof).unwrap() {
        EvmStep::Ok { post, gas } => {
            assert_eq!(post, m.commitment(), "post-state mismatch at pc {} (opcode {:#x})", pre.pc, proof.opcode);
            gas
        }
        EvmStep::Reverted { data } => panic!("Solidity rejected an honest witness at pc {}: {data}", pre.pc),
    }
}

fn machine(program: Vec<Instruction>, tape: Vec<B256>, stack: Vec<B256>, state: SparseMerkleTree) -> MachineState {
    let mut m = MachineState::new(Arc::new(Program::new(program).unwrap()), Arc::new(Tape::new(tape).unwrap()), state);
    m.stack = Stack::from_items(stack);
    m
}

// ---- strategies --------------------------------------------------------------------------------------------------

fn arb_word() -> impl Strategy<Value = B256> {
    prop_oneof![
        4 => (0u64..10).prop_map(w),
        1 => any::<[u8; 32]>().prop_map(B256::from),
        1 => Just(B256::from(U256::MAX)),
    ]
}

fn arb_instruction(len: u64) -> impl Strategy<Value = Instruction> {
    let small = (0u64..20).prop_map(U256::from);
    prop_oneof![
        10 => (0u8..24, small.clone()).prop_map(|(op, imm)| Instruction { opcode: op, imm }),
        3 => small.clone().prop_map(|v| Instruction::with_imm(Opcode::Push, v)),
        2 => (0..len + 3).prop_map(|t| Instruction::with_imm(Opcode::JumpI, U256::from(t))),
        1 => (0..len + 3).prop_map(|t| Instruction::with_imm(Opcode::Jump, U256::from(t))),
        2 => prop_oneof![Just(Opcode::SLoad), Just(Opcode::SStore), Just(Opcode::Input)].prop_map(Instruction::op),
        1 => (24u8..=255, any::<[u8; 32]>()).prop_map(|(op, imm)| Instruction { opcode: op, imm: U256::from_be_bytes(imm) }),
        1 => (prop_oneof![Just(Opcode::Dup), Just(Opcode::Swap)], 14u64..20).prop_map(|(op, n)| Instruction::with_imm(op, U256::from(n))),
    ]
}

fn arb_state() -> impl Strategy<Value = SparseMerkleTree> {
    prop::collection::vec((0u64..10, 1u64..1000), 0..8).prop_map(|kvs| {
        let mut t = SparseMerkleTree::new();
        for (k, v) in kvs {
            t.insert(w(k), w(v));
        }
        t
    })
}

// ---- random programs ---------------------------------------------------------------------------------------------

proptest! {
    #![proptest_config(ProptestConfig { cases: 256, ..ProptestConfig::default() })]

    /// Every step of a random program produces the same post-state in Rust and in Solidity.
    #[test]
    fn random_programs_agree_step_by_step(
        program in prop::collection::vec(arb_instruction(40), 1..40),
        tape in prop::collection::vec(arb_word(), 0..12),
        stack in prop::collection::vec(arb_word(), 0..18),
        state in arb_state(),
    ) {
        let mut m = machine(program, tape, stack, state);
        for _ in 0..48 {
            assert_step_agrees(&mut m);
            if !m.is_running() {
                // Fixed point on both sides too.
                assert_step_agrees(&mut m);
                break;
            }
        }
    }

    /// ECRECOVER matches the precompile on valid signatures and on every class of malformed input.
    #[test]
    fn ecrecover_matches_the_precompile(
        // [0xff; 32] is not a valid secp256k1 scalar (it exceeds the group order), so 255 is excluded.
        seed in 1u8..=254,
        msg in any::<[u8; 32]>(),
        v_mode in 0u8..6,
        rs_mode in 0u8..6,
        noise in any::<[u8; 32]>(),
    ) {
        let key = SigningKey::from_slice(&[seed; 32]).unwrap();
        let digest = B256::from(msg);
        let (sig, recid) = key.sign_prehash_recoverable(digest.as_slice()).unwrap();
        let bytes = sig.to_bytes();
        let n = U256::from_str_radix("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141", 16).unwrap();
        let (mut r, mut s) = (U256::from_be_slice(&bytes[..32]), U256::from_be_slice(&bytes[32..]));
        let mut v = U256::from(27 + recid.to_byte());
        match v_mode {
            1 => v = U256::from(55 - v.to::<u64>()),         // wrong recovery id
            2 => v += U256::from(256u64),                   // 27/28 in the low byte only
            3 => v = U256::from(0u64),
            4 => v = U256::from_be_bytes(noise),
            _ => {}
        }
        match rs_mode {
            1 => { s = n - s; v = U256::from(55u64) - v.min(U256::from(28u64)).max(U256::from(27u64)); } // malleable twin
            2 => r = U256::ZERO,
            3 => s = n,
            4 => r = U256::from_be_bytes(noise),
            5 => s = U256::MAX,
            _ => {}
        }
        let program = vec![Instruction::op(Opcode::EcRecover), Instruction::op(Opcode::Halt)];
        let stack = vec![B256::from(s), B256::from(r), B256::from(v), digest]; // bottom first: top is the digest
        let mut m = machine(program, vec![], stack, SparseMerkleTree::new());
        assert_step_agrees(&mut m);
    }
}

/// Overwrites a random element of `v` (or appends one to an empty list); `idx` picks the element.
fn overwrite(v: &mut Vec<B256>, idx: prop::sample::Index, g: B256) {
    if v.is_empty() {
        v.push(g);
    } else {
        let i = idx.index(v.len());
        v[i] = g;
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 512, ..ProptestConfig::default() })]

    /// Soundness of the verifier: tampering with any component of an honest witness either makes Solidity revert or
    /// leaves the post-state unchanged (the tampered part was irrelevant). No witness can produce a different
    /// post-state. Every scalar field is mutated, a random element of each array (stack reveal, sibling list, code
    /// proof) is overwritten, a random bit of the sibling bitmap is flipped, trailing elements are dropped, and the
    /// tape gets a random word overwritten or an extra word appended.
    #[test]
    fn tampered_witnesses_never_change_the_post_state(
        program in prop::collection::vec(arb_instruction(24), 1..24),
        tape in prop::collection::vec(arb_word(), 1..8),
        stack in prop::collection::vec(arb_word(), 4..12),
        state in arb_state(),
        steps in 0usize..12,
        field in 0u8..13,
        idx in any::<prop::sample::Index>(),
        bit in 0usize..256,
        garbage in any::<[u8; 32]>(),
    ) {
        let mut m = machine(program, tape, stack, state);
        for _ in 0..steps { step(&mut m, Witness::Skip); }
        let pre = m.commitment();
        let honest_proof = step(&mut m, Witness::Build);
        let honest_post = m.commitment();
        let g = B256::from(garbage);
        let mut p: StepProof = honest_proof.clone();
        match field {
            0 => p.imm ^= U256::from(1u8) << (bit % 256),
            1 => p.opcode = p.opcode.wrapping_add(1 + (bit % 255) as u8),
            2 => overwrite(&mut p.stack, idx, g),
            3 => p.stackRest = g,
            4 => p.leafValue = g,
            5 => {
                if p.siblings.is_empty() {
                    p.siblingBitmap |= U256::from(1u8) << (bit % 256);
                }
                overwrite(&mut p.siblings, idx, g);
            }
            6 => p.siblingBitmap ^= U256::from(1u8) << bit,
            7 => overwrite(&mut p.codeProof, idx, g),
            8 => p.tape = Bytes::from([p.tape.as_ref(), &garbage[..]].concat()),
            9 => {
                let mut bytes = p.tape.to_vec();
                if bytes.len() >= 32 {
                    let w = idx.index(bytes.len() / 32);
                    bytes[w * 32..w * 32 + 32].copy_from_slice(&garbage);
                } else {
                    bytes.extend_from_slice(&garbage);
                }
                p.tape = Bytes::from(bytes);
            }
            10 => { p.stack.pop(); }
            11 => { p.siblings.pop(); }
            _ => { p.codeProof.pop(); }
        }
        prop_assume!(p != honest_proof);
        match evm().step(&pre, &p).unwrap() {
            EvmStep::Reverted { .. } => {}
            EvmStep::Ok { post, .. } => prop_assert_eq!(post, honest_post),
        }
    }
}

// ---- the real state-transition program ---------------------------------------------------------------------------

fn signing_key(i: u8) -> SigningKey {
    SigningKey::from_slice(&[i; 32]).unwrap()
}

#[derive(Debug, Clone)]
struct BatchSpec {
    deposits: Vec<(u8, u64)>,
    txs: Vec<(u8, bool, u8, u64, u64)>,
}

fn arb_batch() -> impl Strategy<Value = BatchSpec> {
    (
        prop::collection::vec((1u8..5, 1u64..100), 0..4),
        prop::collection::vec((1u8..5, any::<bool>(), 1u8..5, 0u64..80, 0u64..2), 0..5),
    )
        .prop_map(|(deposits, txs)| BatchSpec { deposits, txs })
}

fn tape_for(stf: &Stf, spec: &BatchSpec) -> Tape {
    let queue: Vec<Record> = spec
        .deposits
        .iter()
        .map(|(to, amt)| Record::queue(Kind::Deposit, Address::ZERO, key_address(&signing_key(*to)), U256::from(*amt)))
        .collect();
    let seq: Vec<Record> = spec
        .txs
        .iter()
        .map(|(from, transfer, to, amount, nonce)| {
            let k = signing_key(*from);
            let kind = if *transfer { Kind::Transfer } else { Kind::Withdrawal };
            L2Tx {
                kind,
                from: key_address(&k),
                to: key_address(&signing_key(*to)),
                amount: U256::from(*amount),
                nonce: U256::from(*nonce),
            }
            .sign(&k, stf.domain())
            .unwrap()
        })
        .collect();
    build_tape(&queue, &encode_tx_data(&seq)).unwrap()
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 12, ..ProptestConfig::default() })]

    /// Every single step of the canonical STF program on random batches agrees, including SLOAD/SSTORE against a
    /// populated 256-level tree, INPUT against the full tape and ECRECOVER on real signatures.
    #[test]
    fn stf_program_traces_agree_on_every_step(spec in arb_batch()) {
        let stf = Stf::new(901);
        let mut pre = SparseMerkleTree::new();
        pre.insert(rollup_stf::keys::balance_key_of(key_address(&signing_key(1))), w(50));
        let mut m = stf.initial_machine(pre, Arc::new(tape_for(&stf, &spec)));
        let mut steps = 0;
        while m.is_running() {
            assert_step_agrees(&mut m);
            steps += 1;
        }
        prop_assert!(steps > 0);
    }
}

#[test]
fn gas_per_opcode_is_bounded() {
    // Measures the most expensive steps of a realistic epoch and keeps them far below the block gas limit.
    let stf = Stf::new(901);
    let spec = BatchSpec {
        deposits: vec![(1, 90), (2, 40)],
        txs: vec![(1, true, 2, 10, 0), (2, false, 3, 5, 0), (1, false, 3, 7, 1)],
    };
    let mut m = stf.initial_machine(SparseMerkleTree::new(), Arc::new(tape_for(&stf, &spec)));
    let mut max_by_op = std::collections::BTreeMap::<&'static str, u64>::new();
    while m.is_running() {
        let op = m.program().get(m.pc).and_then(|i| i.decoded()).map_or("?", Opcode::mnemonic);
        let gas = assert_step_agrees(&mut m);
        let e = max_by_op.entry(op).or_default();
        *e = (*e).max(gas);
    }
    for (op, gas) in &max_by_op {
        println!("{op:>10}: {gas} gas (whole transaction)");
    }
    assert!(max_by_op.values().all(|g| *g < 1_000_000));
    assert!(max_by_op.contains_key("SSTORE") && max_by_op.contains_key("ECRECOVER") && max_by_op.contains_key("INPUT"));
}

#[test]
fn keccak_of_tape_is_the_input_root() {
    // Guard for the INPUT witness: the tape bytes the Rust side ships hash to the committed root.
    let stf = Stf::new(901);
    let tape = tape_for(&stf, &BatchSpec { deposits: vec![(1, 1)], txs: vec![] });
    assert_eq!(keccak256(tape.bytes()), tape.root());
}

/// Largest batch the inbox accepts (32 queue + 64 sequenced records, every one a valid withdrawal): executes every
/// step on both sides and reports the most expensive one-step proofs. INPUT carries the whole 24.6 KB tape.
#[test]
fn worst_case_batch_step_gas() {
    let stf = Stf::new(901);
    let keys: Vec<SigningKey> = (1..=64u8).map(signing_key).collect();
    let queue: Vec<Record> = keys
        .iter()
        .take(rollup_stf::MAX_QUEUE_PER_BATCH)
        .map(|k| Record::queue(Kind::ForcedWithdrawal, key_address(k), Address::repeat_byte(9), U256::from(1)))
        .collect();
    let seq: Vec<Record> = keys
        .iter()
        .map(|k| {
            L2Tx {
                kind: Kind::Withdrawal,
                from: key_address(k),
                to: Address::repeat_byte(7),
                amount: U256::from(1),
                nonce: U256::ZERO,
            }
            .sign(k, stf.domain())
            .unwrap()
        })
        .collect();
    let mut pre = SparseMerkleTree::new();
    for k in &keys {
        pre.insert(rollup_stf::keys::balance_key_of(key_address(k)), w(10));
    }
    let tape = build_tape(&queue, &encode_tx_data(&seq)).unwrap();
    assert_eq!(tape.bytes().len(), 32 + 96 * 256);
    let mut m = stf.initial_machine(pre, Arc::new(tape));
    let mut max_by_op = std::collections::BTreeMap::<&'static str, u64>::new();
    let mut steps = 0u64;
    while m.is_running() {
        let op = m.program().get(m.pc).and_then(|i| i.decoded()).map_or("?", Opcode::mnemonic);
        let gas = assert_step_agrees(&mut m);
        let e = max_by_op.entry(op).or_default();
        *e = (*e).max(gas);
        steps += 1;
    }
    println!("worst-case batch: {steps} steps, all agreed");
    for (op, gas) in &max_by_op {
        println!("{op:>10}: {gas} gas (whole transaction)");
    }
    let worst = max_by_op.values().copied().max().unwrap();
    assert!(worst < 2_000_000, "worst one-step proof costs {worst} gas");
}
