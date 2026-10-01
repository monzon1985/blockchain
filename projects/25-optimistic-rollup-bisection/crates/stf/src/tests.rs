// SPDX-License-Identifier: MIT
//! STF tests: semantics, VM-vs-native differential properties, and trace/bisection properties.

use std::sync::Arc;

use alloy_primitives::{Address, B256, U256};
use k256::ecdsa::SigningKey;
use proptest::prelude::*;
use rollup_vm::{SparseMerkleTree, Status, Tape};

use crate::{
    exec::{EpochTrace, Fault, Stf},
    keys::{withdrawal_key, withdrawal_value},
    native::{Effect, StateExt, apply_tape},
    record::{Kind, L2Tx, Record, address_word, key_address},
    tape::{MAX_QUEUE_PER_BATCH, MAX_SEQUENCED_TXS, build_tape, encode_tx_data},
};

const CHAIN_ID: u64 = 901;

fn key(i: u8) -> SigningKey {
    SigningKey::from_slice(&[i.max(1); 32]).unwrap()
}

fn eth(x: u64) -> U256 {
    U256::from(x) * U256::from(10u64.pow(18))
}

fn deposit(to: Address, amount: U256) -> Record {
    Record::queue(Kind::Deposit, Address::repeat_byte(0xd0), to, amount)
}

fn signed(stf: &Stf, k: &SigningKey, kind: Kind, to: Address, amount: U256, nonce: u64) -> Record {
    L2Tx { kind, from: key_address(k), to, amount, nonce: U256::from(nonce) }.sign(k, stf.domain()).unwrap()
}

/// Runs both implementations and asserts they agree; returns the post-state and the native effects.
fn run_both(
    stf: &Stf,
    pre: &SparseMerkleTree,
    queue: &[Record],
    seq: &[Record],
) -> (SparseMerkleTree, Vec<Effect>, u64) {
    let tape = build_tape(queue, &encode_tx_data(seq)).unwrap();
    let vm = stf.execute(pre, Arc::new(tape.clone())).unwrap();
    let mut native = pre.clone();
    let report = apply_tape(&mut native, tape.words(), stf.domain());
    assert_eq!(vm.post_state.root(), native.root(), "VM program and native STF disagree");
    (native, report.effects, vm.steps)
}

#[test]
fn deposits_transfers_and_withdrawals() {
    let stf = Stf::new(CHAIN_ID);
    let (alice, bob) = (key(1), key(2));
    let (a, b) = (key_address(&alice), key_address(&bob));
    let queue = [deposit(a, eth(10))];
    let seq = [
        signed(&stf, &alice, Kind::Transfer, b, eth(3), 0),
        signed(&stf, &bob, Kind::Withdrawal, Address::repeat_byte(0xee), eth(1), 0),
    ];
    let (state, effects, _) = run_both(&stf, &SparseMerkleTree::new(), &queue, &seq);
    assert_eq!(effects, vec![Effect::Applied; 3]);
    assert_eq!(state.balance(address_word(a)), eth(7));
    assert_eq!(state.balance(address_word(b)), eth(2));
    assert_eq!(state.nonce(address_word(a)), U256::from(1));
    assert_eq!(state.withdrawal_count(), U256::from(1));
    assert_eq!(
        state.get(withdrawal_key(U256::ZERO)),
        withdrawal_value(address_word(Address::repeat_byte(0xee)), eth(1))
    );
}

#[test]
fn replayed_forged_and_misnonced_transactions_are_rejected() {
    let stf = Stf::new(CHAIN_ID);
    let (alice, mallory) = (key(1), key(9));
    let a = key_address(&alice);
    let tx = signed(&stf, &alice, Kind::Transfer, key_address(&mallory), eth(1), 0);
    let mut forged = tx;
    forged.amount = eth(5); // signature no longer matches
    let wrong_chain = {
        let other = Stf::new(CHAIN_ID + 1);
        signed(&other, &alice, Kind::Transfer, key_address(&mallory), eth(1), 1)
    };
    let mut impersonation = signed(&stf, &mallory, Kind::Transfer, key_address(&mallory), eth(1), 0);
    impersonation.from = address_word(a); // claims to be alice
    let seq = [tx, tx, forged, wrong_chain, impersonation, signed(&stf, &alice, Kind::Transfer, a, eth(1), 7)];
    let (state, effects, _) = run_both(&stf, &SparseMerkleTree::new(), &[deposit(a, eth(2))], &seq);
    assert_eq!(
        effects,
        vec![
            Effect::Applied,
            Effect::Applied,
            Effect::Rejected,
            Effect::Rejected,
            Effect::Rejected,
            Effect::Rejected,
            Effect::Rejected
        ]
    );
    assert_eq!(state.balance(address_word(a)), eth(1));
}

#[test]
fn insufficient_balance_still_consumes_the_nonce() {
    let stf = Stf::new(CHAIN_ID);
    let alice = key(1);
    let a = key_address(&alice);
    let seq = [signed(&stf, &alice, Kind::Transfer, Address::repeat_byte(1), eth(1), 0)];
    let (state, effects, _) = run_both(&stf, &SparseMerkleTree::new(), &[], &seq);
    assert_eq!(effects, vec![Effect::InsufficientBalance]);
    assert_eq!(state.nonce(address_word(a)), U256::from(1));
}

#[test]
fn sequencer_cannot_inject_l1_kinds() {
    // A deposit record placed in the sequenced section (after the queue records) must be ignored.
    let stf = Stf::new(CHAIN_ID);
    let thief = Address::repeat_byte(0x66);
    let seq = [deposit(thief, eth(1000)), Record::queue(Kind::ForcedTransfer, thief, thief, eth(1))];
    let (state, effects, _) = run_both(&stf, &SparseMerkleTree::new(), &[], &seq);
    assert_eq!(effects, vec![Effect::Skipped, Effect::Skipped]);
    assert_eq!(state.root(), B256::ZERO);
}

#[test]
fn queue_cannot_carry_signed_kinds() {
    let stf = Stf::new(CHAIN_ID);
    let alice = key(1);
    let rec = signed(&stf, &alice, Kind::Transfer, Address::repeat_byte(1), U256::ZERO, 0);
    let (_, effects, _) = run_both(&stf, &SparseMerkleTree::new(), &[rec], &[]);
    assert_eq!(effects, vec![Effect::Skipped]);
}

#[test]
fn forced_transfer_and_withdrawal_bypass_signatures() {
    let stf = Stf::new(CHAIN_ID);
    let user = Address::repeat_byte(0x42);
    let queue = [
        deposit(user, eth(5)),
        Record::queue(Kind::ForcedTransfer, user, Address::repeat_byte(0x43), eth(2)),
        Record::queue(Kind::ForcedWithdrawal, user, Address::repeat_byte(0x44), eth(2)),
        Record::queue(Kind::ForcedWithdrawal, user, Address::repeat_byte(0x44), eth(2)), // insufficient
    ];
    let (state, effects, _) = run_both(&stf, &SparseMerkleTree::new(), &queue, &[]);
    assert_eq!(effects, vec![Effect::Applied, Effect::Applied, Effect::Applied, Effect::InsufficientBalance]);
    assert_eq!(state.balance(address_word(user)), eth(1));
}

#[test]
fn degenerate_tapes_halt() {
    let stf = Stf::new(CHAIN_ID);
    for words in [vec![], vec![B256::repeat_byte(0xff)], vec![B256::repeat_byte(0xff); 20]] {
        let tape = Arc::new(Tape::new(words.clone()).unwrap());
        let out = stf.execute(&SparseMerkleTree::new(), tape).unwrap();
        let mut native = SparseMerkleTree::new();
        apply_tape(&mut native, &words, stf.domain());
        assert_eq!(out.post_state.root(), native.root());
        assert_eq!(out.final_commitment.status, Status::Halted as u8);
    }
}

#[test]
fn worst_case_batch_fits_the_trace() {
    // Every record is the most expensive kind: a valid signed withdrawal (sequenced) or a forced withdrawal (queue).
    let stf = Stf::new(CHAIN_ID);
    let users: Vec<SigningKey> = (1..=MAX_SEQUENCED_TXS as u8).map(key).collect();
    let queue: Vec<Record> = users
        .iter()
        .take(MAX_QUEUE_PER_BATCH)
        .map(|k| Record::queue(Kind::ForcedWithdrawal, key_address(k), Address::repeat_byte(9), U256::from(1)))
        .collect();
    let seq: Vec<Record> =
        users.iter().map(|k| signed(&stf, k, Kind::Withdrawal, Address::repeat_byte(7), U256::from(1), 0)).collect();
    let mut pre = SparseMerkleTree::new();
    for k in &users {
        pre.insert(crate::keys::balance_key_of(key_address(k)), crate::keys::word(eth(1)));
    }
    let (_, effects, steps) = run_both(&stf, &pre, &queue, &seq);
    assert!(effects.iter().all(|e| *e == Effect::Applied));
    // Recorded in the README; the padded trace is 2^16 steps.
    assert!(steps < stf.max_steps() / 4, "worst case uses {steps} steps");
    println!("worst-case batch: {} records, {steps} VM steps", queue.len() + seq.len());

    // The deployment script refuses depths that cannot hold this trace; its constants must match the measurement.
    let script = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../contracts/script/Deploy.s.sol"))
        .expect("contracts/script/Deploy.s.sol");
    let constant = |name: &str| -> u64 {
        let after = script.split(&format!("{name} = ")).nth(1).unwrap_or_else(|| panic!("{name} not in Deploy.s.sol"));
        after.split(';').next().unwrap().replace('_', "").trim().parse().unwrap()
    };
    assert_eq!(constant("WORST_CASE_TRACE_STEPS"), steps, "update WORST_CASE_TRACE_STEPS in Deploy.s.sol");
    let min_depth = constant("MIN_MAX_DEPTH");
    assert!(1u64 << min_depth >= steps && 1u64 << (min_depth - 1) < steps, "MIN_MAX_DEPTH must be the tightest depth");
}

#[test]
fn fault_diverges_exactly_where_injected_and_bisection_finds_it() {
    let stf = Stf::new(CHAIN_ID);
    let alice = key(1);
    let a = key_address(&alice);
    let tape = Arc::new(
        build_tape(
            &[deposit(a, eth(3))],
            &encode_tx_data(&[signed(&stf, &alice, Kind::Transfer, Address::repeat_byte(5), eth(1), 0)]),
        )
        .unwrap(),
    );
    let honest = EpochTrace::new(&stf, stf.initial_machine(SparseMerkleTree::new(), Arc::clone(&tape)), None).unwrap();
    let fault = Fault { at_step: honest.steps() / 2, beneficiary: U256::from(0xbad), amount: eth(100) };
    let evil = EpochTrace::new(&stf, stf.initial_machine(SparseMerkleTree::new(), tape), Some(fault)).unwrap();
    assert_eq!(honest.first_divergence(&evil), Some(fault.at_step));
    assert_ne!(honest.final_commitment().stateRoot, evil.final_commitment().stateRoot);

    // Play the bisection exactly as the contracts do: the defender (evil) posts midpoints, the honest challenger
    // agrees iff the midpoint matches its own trace.
    let (mut lo, mut hi) = (0u64, stf.max_steps());
    while hi - lo > 1 {
        let mid = lo + (hi - lo) / 2;
        if evil.hash_at(mid) == honest.hash_at(mid) { lo = mid } else { hi = mid }
    }
    assert_eq!(lo, fault.at_step);
    // The honest one-step execution from the agreed state contradicts the defender's claim at `hi`.
    let mut m = honest.machine_at(lo).unwrap();
    assert_eq!(m.hash(), evil.hash_at(lo));
    rollup_vm::step(&mut m, rollup_vm::Witness::Skip);
    assert_eq!(m.hash(), honest.hash_at(hi));
    assert_ne!(m.hash(), evil.hash_at(hi));
}

#[test]
fn trace_hashes_match_re_execution() {
    let stf = Stf::new(CHAIN_ID);
    let tape = Arc::new(build_tape(&[deposit(Address::repeat_byte(1), eth(1))], &[]).unwrap());
    let t = EpochTrace::new(&stf, stf.initial_machine(SparseMerkleTree::new(), tape), None).unwrap();
    for i in [0, 1, t.steps() / 2, t.steps(), t.steps() + 1, t.max_steps()] {
        assert_eq!(t.machine_at(i).unwrap().hash(), t.hash_at(i), "step {i}");
    }
    assert!(t.machine_at(t.max_steps() + 1).is_err());
    let (pre, proof) = t.proof_at(3).unwrap();
    assert_eq!(pre.hash(), t.hash_at(3));
    assert!(!proof.codeProof.is_empty());
}

// ---- properties --------------------------------------------------------------------------------------------------

#[derive(Debug, Clone)]
enum Action {
    Queue(Record),
    Signed { signer: u8, kind: Kind, to: u8, amount: u64, nonce: u64, corrupt: bool },
    Garbage(Record),
}

fn arb_word() -> impl Strategy<Value = U256> {
    prop_oneof![(0u64..8).prop_map(U256::from), any::<[u8; 32]>().prop_map(U256::from_be_bytes)]
}

fn arb_action() -> impl Strategy<Value = Action> {
    let addr = (1u8..5).prop_map(|i| key_address(&key(i)));
    prop_oneof![
        3 => (addr.clone(), 0u64..50).prop_map(|(to, amt)| Action::Queue(deposit(to, U256::from(amt)))),
        2 => (addr.clone(), addr.clone(), 0u64..50, 2u8..4).prop_map(|(from, to, amt, k)| {
            let kind = if k == 2 { Kind::ForcedTransfer } else { Kind::ForcedWithdrawal };
            Action::Queue(Record::queue(kind, from, to, U256::from(amt)))
        }),
        5 => (1u8..5, 4u8..6, 1u8..5, 0u64..60, 0u64..3, prop::bool::weighted(0.15)).prop_map(|(signer, k, to, amount, nonce, corrupt)| {
            let kind = if k == 4 { Kind::Transfer } else { Kind::Withdrawal };
            Action::Signed { signer, kind, to, amount, nonce, corrupt }
        }),
        1 => (arb_word(), arb_word(), arb_word(), arb_word()).prop_map(|(kind, from, to, amount)| {
            Action::Garbage(Record { kind, from, to, amount, ..Record::default() })
        }),
    ]
}

fn materialize(stf: &Stf, actions: &[Action]) -> (Vec<Record>, Vec<Record>) {
    let mut queue = Vec::new();
    let mut seq = Vec::new();
    for a in actions {
        match a {
            Action::Queue(r) => queue.push(*r),
            Action::Signed { signer, kind, to, amount, nonce, corrupt } => {
                let k = key(*signer);
                let mut r = signed(stf, &k, *kind, key_address(&key(*to)), U256::from(*amount), *nonce);
                if *corrupt {
                    r.s = r.s.wrapping_add(U256::from(1));
                }
                seq.push(r);
            }
            Action::Garbage(r) => seq.push(*r),
        }
    }
    (queue, seq)
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(48))]

    /// Differential: the VM program and the native STF produce the same state root on random batches.
    #[test]
    fn vm_program_matches_native_stf(actions in prop::collection::vec(arb_action(), 0..24)) {
        let stf = Stf::new(CHAIN_ID);
        let (queue, seq) = materialize(&stf, &actions);
        run_both(&stf, &SparseMerkleTree::new(), &queue, &seq);
    }

    /// Totality: arbitrary tapes (including garbage headers) always halt, never error, and agree with native.
    #[test]
    fn arbitrary_tapes_halt_and_agree(words in prop::collection::vec(arb_word().prop_map(|w| B256::from(w.to_be_bytes::<32>())), 0..60)) {
        let stf = Stf::new(CHAIN_ID);
        let out = stf.execute(&SparseMerkleTree::new(), Arc::new(Tape::new(words.clone()).unwrap())).unwrap();
        let mut native = SparseMerkleTree::new();
        apply_tape(&mut native, &words, stf.domain());
        prop_assert_eq!(out.post_state.root(), native.root());
    }

    /// Conservation: deposits = sum of balances + sum of withdrawals.
    #[test]
    fn value_is_conserved(actions in prop::collection::vec(arb_action(), 0..24)) {
        let stf = Stf::new(CHAIN_ID);
        let (queue, seq) = materialize(&stf, &actions);
        let tape = build_tape(&queue, &encode_tx_data(&seq)).unwrap();
        let mut state = SparseMerkleTree::new();
        let report = apply_tape(&mut state, tape.words(), stf.domain());
        let deposited: U256 = queue.iter().filter(|r| r.kind == U256::from(Kind::Deposit as u8)).map(|r| r.amount).sum();
        let withdrawn: U256 = report.withdrawals.iter().map(|w| w.amount).sum();
        let held: U256 = (1u8..5).map(|i| state.balance(address_word(key_address(&key(i))))).sum();
        prop_assert_eq!(deposited, held + withdrawn);
    }
}
