// SPDX-License-Identifier: MIT
//! The state-transition function, written as a program for the rollup VM.
//!
//! This program *is* the rollup's specification: its Merkle root is deployed in `DisputeGame.CODE_ROOT`, and every
//! fraud proof executes one of its instructions. [`crate::native`] is a plain-Rust restatement used as a
//! differential oracle.
//!
//! Pseudocode (stack comments in the source are top-first):
//! ```text
//! N = (INPUTSIZE - 1) / 8                 // whole records after the header word (0 if the tape is empty)
//! Q = min(tape[0], N)                     // leading records that came from the L1 queue
//! for i in 0..N:
//!     base = 1 + 8 * i
//!     if i < Q:  deposit / forced transfer / forced withdrawal, authenticated by L1; other kinds skipped
//!     else:      signed transfer / withdrawal: signer == from != 0 and nonce == nonce[from], then nonce += 1;
//!                the value movement is skipped (nonce still bumps) if the balance is insufficient
//! HALT
//! ```

use alloy_primitives::{B256, U256};
use rollup_vm::{Opcode::*, Program, asm::Assembler};

use crate::{
    keys::{BALANCE_TAG, NONCE_TAG, WITHDRAWAL_TAG, withdrawal_counter_key},
    record::{Kind, RECORD_WORDS},
};

fn num(b: B256) -> U256 {
    U256::from_be_bytes(b.0)
}

/// Pushes `tape[base + offset]`, where `base` sits `depth` slots below the top.
fn field(a: &mut Assembler, offset: u64, depth: u8) {
    a.dup(depth).push_u64(offset).op(Add).op(Input);
}

/// `[to, amount] -> []`: `balance[to] += amount`.
fn credit(a: &mut Assembler) {
    a.push_u64(BALANCE_TAG).op(Hash); // [bk, amount]
    a.dup(0).op(SLoad); // [bal, bk, amount]
    a.dup(2).op(Add); // [bal+amount, bk, amount]
    a.swap(1).op(SStore); // [amount]
    a.op(Pop); // []
}

/// `[from, x, amount] -> [x, amount]` with `balance[from] -= amount`, or jumps to `insufficient` with
/// `[balance, fromKey, x, amount]` when the balance is too small.
fn debit(a: &mut Assembler, insufficient: rollup_vm::asm::Label) {
    a.push_u64(BALANCE_TAG).op(Hash); // [fk, x, amount]
    a.dup(0).op(SLoad); // [fb, fk, x, amount]
    a.dup(3).dup(1).op(Lt); // [fb < amount, fb, fk, x, amount]
    a.jumpi(insufficient); // [fb, fk, x, amount]
    a.dup(3).swap(1).op(Sub); // [fb - amount, fk, x, amount]
    a.swap(1).op(SStore); // [x, amount]
}

/// `[from, to, amount] -> []`.
fn transfer(a: &mut Assembler) {
    let insufficient = a.label();
    let end = a.label();
    debit(a, insufficient); // [to, amount]
    credit(a); // []
    a.jump(end);
    a.bind(insufficient).op(Pop).op(Pop).op(Pop).op(Pop);
    a.bind(end);
}

/// `[from, recipient, amount] -> []`: debits and records withdrawal `id = counter++`.
fn withdraw(a: &mut Assembler) {
    let insufficient = a.label();
    let end = a.label();
    let counter = num(withdrawal_counter_key());
    debit(a, insufficient); // [recipient, amount]
    a.op(Hash); // [value = keccak(recipient ++ amount)]
    a.push(counter).op(SLoad); // [id, value]
    a.dup(0).push_u64(WITHDRAWAL_TAG).op(Hash); // [key = keccak(3 ++ id), id, value]
    a.swap(1).push_u64(1).op(Add); // [id + 1, key, value]
    a.push(counter).op(SStore); // [key, value]
    a.op(SStore); // []
    a.jump(end);
    a.bind(insufficient).op(Pop).op(Pop).op(Pop).op(Pop);
    a.bind(end);
}

/// Assembles the STF for the given signing domain (see [`crate::record::domain_separator`]).
///
/// # Panics
/// Never for the fixed program below (all labels are bound); the `expect` guards against editing mistakes and is
/// covered by every test in this crate.
#[allow(clippy::expect_used)]
pub fn stf_program(domain: B256) -> Program {
    let mut a = Assembler::new();
    let record_words = RECORD_WORDS as u64;
    let (clamp, q_ok, top, done, next) = (a.label(), a.label(), a.label(), a.label(), a.label());
    let (l1, l1_deposit, l1_transfer, l1_withdraw) = (a.label(), a.label(), a.label(), a.label());
    let (signed, do_transfer, skip_nonce, skip_kind) = (a.label(), a.label(), a.label(), a.label());

    // ---- header: N and Q -------------------------------------------------------------------------------------
    a.op(InputSize); // [size]
    a.dup(0).op(IsZero).jumpi(done); // [size]
    a.push_u64(1).swap(1).op(Sub); // [size - 1]
    a.push_u64(record_words).swap(1).op(Div); // [N]
    a.push_u64(0).op(Input); // [q, N]
    a.dup(1).dup(1).op(Gt).jumpi(clamp); // [q, N]
    a.jump(q_ok);
    a.bind(clamp).op(Pop).dup(0); // [N, N]
    a.bind(q_ok); // [Q, N]
    a.push_u64(0); // [i, Q, N]

    // ---- loop over records ----------------------------------------------------------------------------------
    a.bind(top);
    a.dup(2).dup(1).op(Lt).op(IsZero).jumpi(done); // [i, Q, N]
    a.dup(0).push_u64(record_words).op(Mul).push_u64(1).op(Add); // [base, i, Q, N]
    a.dup(2).dup(2).op(Lt).jumpi(l1); // [base, i, Q, N]

    // ---- sequenced record: only signed transfers / withdrawals ------------------------------------------------
    a.dup(0).op(Input); // [kind, base]
    a.dup(0).push_u64(Kind::Transfer as u64).op(Eq).jumpi(signed);
    a.dup(0).push_u64(Kind::Withdrawal as u64).op(Eq).jumpi(signed);
    a.op(Pop).jump(next);

    a.bind(signed); // [kind, base]
    a.dup(0).push(num(domain)).op(Hash); // [h = H(domain, kind), kind, base]
    for offset in 1..=4 {
        field(&mut a, offset, 2); // [x, h, kind, base]
        a.swap(1).op(Hash); // [H(h, x), kind, base]
    }
    field(&mut a, 7, 2); // [s, d, kind, base]
    field(&mut a, 6, 3); // [r, s, d, kind, base]
    field(&mut a, 5, 4); // [v, r, s, d, kind, base]
    a.dup(3).op(EcRecover); // [signer, d, kind, base]
    a.swap(1).op(Pop); // [signer, kind, base]
    field(&mut a, 1, 2); // [from, signer, kind, base]
    a.dup(1).op(IsZero); // [signer == 0, from, signer, kind, base]
    a.swap(2).op(Eq).op(IsZero).op(Or); // [bad, kind, base]
    a.jumpi(skip_kind); // [kind, base]

    field(&mut a, 1, 1); // [from, kind, base]
    a.push_u64(NONCE_TAG).op(Hash); // [nk, kind, base]
    a.dup(0).op(SLoad); // [current, nk, kind, base]
    field(&mut a, 4, 3); // [nonce, current, nk, kind, base]
    a.op(Eq).op(IsZero).jumpi(skip_nonce); // [nk, kind, base]
    field(&mut a, 4, 2); // [nonce, nk, kind, base]
    a.push_u64(1).op(Add).swap(1).op(SStore); // [kind, base]

    field(&mut a, 3, 1); // [amount, kind, base]
    field(&mut a, 2, 2); // [to, amount, kind, base]
    field(&mut a, 1, 3); // [from, to, amount, kind, base]
    a.dup(3).push_u64(Kind::Transfer as u64).op(Eq).jumpi(do_transfer);
    withdraw(&mut a); // [kind, base]
    a.op(Pop).jump(next);
    a.bind(do_transfer);
    transfer(&mut a); // [kind, base]
    a.op(Pop).jump(next);
    a.bind(skip_nonce).op(Pop); // [kind, base]
    a.bind(skip_kind).op(Pop).jump(next); // [base]

    // ---- L1 queue record: authenticated by the L1 contracts ---------------------------------------------------
    a.bind(l1); // [base, i, Q, N]
    a.dup(0).op(Input); // [kind, base]
    a.dup(0).push_u64(Kind::Deposit as u64).op(Eq).jumpi(l1_deposit);
    a.dup(0).push_u64(Kind::ForcedTransfer as u64).op(Eq).jumpi(l1_transfer);
    a.dup(0).push_u64(Kind::ForcedWithdrawal as u64).op(Eq).jumpi(l1_withdraw);
    a.op(Pop).jump(next);

    a.bind(l1_deposit).op(Pop); // [base]
    field(&mut a, 3, 0); // [amount, base]
    field(&mut a, 2, 1); // [to, amount, base]
    credit(&mut a); // [base]
    a.jump(next);

    a.bind(l1_transfer).op(Pop); // [base]
    field(&mut a, 3, 0);
    field(&mut a, 2, 1);
    field(&mut a, 1, 2); // [from, to, amount, base]
    transfer(&mut a); // [base]
    a.jump(next);

    a.bind(l1_withdraw).op(Pop); // [base]
    field(&mut a, 3, 0);
    field(&mut a, 2, 1);
    field(&mut a, 1, 2); // [from, recipient, amount, base]
    withdraw(&mut a); // [base]

    // ---- advance ----------------------------------------------------------------------------------------------
    a.bind(next); // [base, i, Q, N]
    a.op(Pop).push_u64(1).op(Add).jump(top); // [i + 1, Q, N]

    a.bind(done);
    a.op(Halt);

    a.finish().expect("the STF program binds every label it uses")
}
