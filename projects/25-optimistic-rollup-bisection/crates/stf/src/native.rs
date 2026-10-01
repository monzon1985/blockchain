// SPDX-License-Identifier: MIT
//! Native Rust restatement of the STF, used as a differential oracle for the VM program and by services that need
//! fast answers (balances, nonces) without stepping the VM.

use alloy_primitives::{B256, U256};
use rollup_vm::{SparseMerkleTree, crypto::ecrecover};

use crate::{
    keys::{balance_key, nonce_key, withdrawal_counter_key, withdrawal_key, withdrawal_value, word},
    record::{Kind, L2Tx, RECORD_WORDS, Record},
};

/// What happened to one record.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Effect {
    /// Value moved (deposit, transfer or withdrawal).
    Applied,
    /// Authenticated (and nonce bumped, for signed records) but the balance was insufficient.
    InsufficientBalance,
    /// Bad signature or nonce.
    Rejected,
    /// Unknown kind, or a kind not allowed from its source.
    Skipped,
}

/// A withdrawal written to the state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WithdrawalEntry {
    /// Sequential id.
    pub id: U256,
    /// L1 recipient word.
    pub recipient: U256,
    /// Amount in wei.
    pub amount: U256,
}

/// Per-epoch execution report.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Report {
    /// One effect per record, in tape order.
    pub effects: Vec<Effect>,
    /// Withdrawals created in this epoch.
    pub withdrawals: Vec<WithdrawalEntry>,
}

fn num(b: B256) -> U256 {
    U256::from_be_bytes(b.0)
}

/// Typed accessors over the state tree.
pub trait StateExt {
    /// Balance of an account word.
    fn balance(&self, account: U256) -> U256;
    /// Next nonce of an account word.
    fn nonce(&self, account: U256) -> U256;
    /// Number of withdrawals ever created.
    fn withdrawal_count(&self) -> U256;
}

impl StateExt for SparseMerkleTree {
    fn balance(&self, account: U256) -> U256 {
        num(self.get(balance_key(account)))
    }
    fn nonce(&self, account: U256) -> U256 {
        num(self.get(nonce_key(account)))
    }
    fn withdrawal_count(&self) -> U256 {
        num(self.get(withdrawal_counter_key()))
    }
}

fn debit(state: &mut SparseMerkleTree, from: U256, amount: U256) -> bool {
    let balance = state.balance(from);
    if balance < amount {
        return false;
    }
    state.insert(balance_key(from), word(balance - amount));
    true
}

fn credit(state: &mut SparseMerkleTree, to: U256, amount: U256) {
    let balance = state.balance(to);
    state.insert(balance_key(to), word(balance.wrapping_add(amount)));
}

fn transfer(state: &mut SparseMerkleTree, from: U256, to: U256, amount: U256) -> Effect {
    if !debit(state, from, amount) {
        return Effect::InsufficientBalance;
    }
    credit(state, to, amount);
    Effect::Applied
}

fn withdraw(state: &mut SparseMerkleTree, from: U256, recipient: U256, amount: U256, report: &mut Report) -> Effect {
    if !debit(state, from, amount) {
        return Effect::InsufficientBalance;
    }
    let id = state.withdrawal_count();
    state.insert(withdrawal_counter_key(), word(id.wrapping_add(U256::from(1u8))));
    state.insert(withdrawal_key(id), withdrawal_value(recipient, amount));
    report.withdrawals.push(WithdrawalEntry { id, recipient, amount });
    Effect::Applied
}

fn apply_signed(state: &mut SparseMerkleTree, r: &Record, kind: Kind, domain: B256, report: &mut Report) -> Effect {
    let digest = L2Tx::digest_of(kind, r.from, r.to, r.amount, r.nonce, domain);
    let signer = num(ecrecover(digest, r.v, word(r.r), word(r.s)));
    if signer.is_zero() || signer != r.from || r.nonce != state.nonce(r.from) {
        return Effect::Rejected;
    }
    state.insert(nonce_key(r.from), word(r.nonce.wrapping_add(U256::from(1u8))));
    match kind {
        Kind::Transfer => transfer(state, r.from, r.to, r.amount),
        _ => withdraw(state, r.from, r.to, r.amount, report),
    }
}

/// Applies an epoch's tape to `state`.
pub fn apply_tape(state: &mut SparseMerkleTree, tape: &[B256], domain: B256) -> Report {
    let mut report = Report::default();
    if tape.is_empty() {
        return report;
    }
    let n = (tape.len() - 1) / RECORD_WORDS;
    let q = num(tape[0]).min(U256::from(n)).to::<usize>();
    for i in 0..n {
        let base = 1 + i * RECORD_WORDS;
        let Some(r) = Record::from_words(&tape[base..base + RECORD_WORDS]) else {
            report.effects.push(Effect::Skipped);
            continue;
        };
        let kind = Kind::from_word(r.kind);
        let effect = match (i < q, kind) {
            (true, Some(Kind::Deposit)) => {
                credit(state, r.to, r.amount);
                Effect::Applied
            }
            (true, Some(Kind::ForcedTransfer)) => transfer(state, r.from, r.to, r.amount),
            (true, Some(Kind::ForcedWithdrawal)) => withdraw(state, r.from, r.to, r.amount, &mut report),
            (false, Some(k @ (Kind::Transfer | Kind::Withdrawal))) => apply_signed(state, &r, k, domain, &mut report),
            _ => Effect::Skipped,
        };
        report.effects.push(effect);
    }
    report
}

impl L2Tx {
    /// Signing digest from raw record words (the words may not be valid addresses).
    pub fn digest_of(kind: Kind, from: U256, to: U256, amount: U256, nonce: U256, domain: B256) -> B256 {
        let mut h = rollup_vm::smt::hash_pair(domain, word(U256::from(kind as u8)));
        for x in [from, to, amount, nonce] {
            h = rollup_vm::smt::hash_pair(h, word(x));
        }
        h
    }
}
