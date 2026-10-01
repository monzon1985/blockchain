// SPDX-License-Identifier: MIT
//! Layout of the L2 state inside the sparse Merkle tree.
//!
//! | Item | Key | Value |
//! |---|---|---|
//! | balance of `a` | `keccak256(1 ++ a)` | wei |
//! | nonce of `a` | `keccak256(2 ++ a)` | next nonce |
//! | withdrawal `id` | `keccak256(3 ++ id)` | `keccak256(recipient ++ amount)` |
//! | withdrawal counter | `keccak256(4 ++ 0)` | next withdrawal id |
//!
//! `++` is 32-byte word concatenation, i.e. `keccak256(abi.encode(x, y))` in Solidity. The withdrawal layout is what
//! `Bridge.finalizeWithdrawal` verifies against a finalized state root.

use alloy_primitives::{Address, B256, U256};
use rollup_vm::smt::hash_pair;

use crate::record::address_word;

/// Tag of balance keys.
pub const BALANCE_TAG: u64 = 1;
/// Tag of nonce keys.
pub const NONCE_TAG: u64 = 2;
/// Tag of withdrawal keys (mirrors `RollupSpec.WITHDRAWAL_TAG`).
pub const WITHDRAWAL_TAG: u64 = 3;
/// Tag of the withdrawal counter key.
pub const COUNTER_TAG: u64 = 4;

/// Word from a number.
pub fn word(x: U256) -> B256 {
    B256::from(x.to_be_bytes::<32>())
}

/// Word from a small number.
pub fn word_u64(x: u64) -> B256 {
    word(U256::from(x))
}

/// Balance key of an account word.
pub fn balance_key(account: U256) -> B256 {
    hash_pair(word_u64(BALANCE_TAG), word(account))
}

/// Nonce key of an account word.
pub fn nonce_key(account: U256) -> B256 {
    hash_pair(word_u64(NONCE_TAG), word(account))
}

/// Balance key of an address.
pub fn balance_key_of(a: Address) -> B256 {
    balance_key(address_word(a))
}

/// Nonce key of an address.
pub fn nonce_key_of(a: Address) -> B256 {
    nonce_key(address_word(a))
}

/// Key of withdrawal `id`.
pub fn withdrawal_key(id: U256) -> B256 {
    hash_pair(word_u64(WITHDRAWAL_TAG), word(id))
}

/// Value committed for a withdrawal.
pub fn withdrawal_value(recipient: U256, amount: U256) -> B256 {
    hash_pair(word(recipient), word(amount))
}

/// Key of the withdrawal counter.
pub fn withdrawal_counter_key() -> B256 {
    hash_pair(word_u64(COUNTER_TAG), B256::ZERO)
}
