// SPDX-License-Identifier: MIT
//! Hash-chained stack: `hash(empty) = 0`, `hash(push(s, x)) = keccak256(x ++ hash(s))`.
//!
//! Revealing the top `k` words together with the hash of everything below them is enough for the on-chain verifier
//! to check them, whatever the depth of the stack.

use alloy_primitives::B256;

use crate::smt::hash_pair;

/// Stack with O(1) access to the hash of any suffix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stack {
    items: Vec<B256>,
    /// `hashes[i]` is the hash of the stack made of the bottom `i` items; `hashes[0] == 0`.
    hashes: Vec<B256>,
}

impl Default for Stack {
    fn default() -> Self {
        Self::new()
    }
}

impl Stack {
    /// Empty stack.
    pub fn new() -> Self {
        Self { items: Vec::new(), hashes: vec![B256::ZERO] }
    }

    /// Stack holding `items` (bottom first).
    pub fn from_items(items: impl IntoIterator<Item = B256>) -> Self {
        let mut s = Self::new();
        for item in items {
            s.push(item);
        }
        s
    }

    /// Number of words.
    pub fn len(&self) -> usize {
        self.items.len()
    }

    /// Whether the stack is empty.
    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    /// Hash of the whole stack.
    pub fn hash(&self) -> B256 {
        self.hashes.last().copied().unwrap_or_default()
    }

    /// Hash of the stack without its top `k` words. `k` must not exceed `len()`.
    pub fn hash_below(&self, k: usize) -> B256 {
        self.hashes[self.items.len() - k]
    }

    /// Top `k` words, top first. `k` must not exceed `len()`.
    pub fn top(&self, k: usize) -> Vec<B256> {
        self.items[self.items.len() - k..].iter().rev().copied().collect()
    }

    /// Pushes a word.
    pub fn push(&mut self, x: B256) {
        let h = hash_pair(x, self.hash());
        self.items.push(x);
        self.hashes.push(h);
    }

    /// Drops the top `k` words. `k` must not exceed `len()`.
    pub fn drop_top(&mut self, k: usize) {
        let n = self.items.len() - k;
        self.items.truncate(n);
        self.hashes.truncate(n + 1);
    }

    /// Items, bottom first.
    pub fn items(&self) -> &[B256] {
        &self.items
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::keccak256;

    #[test]
    fn hash_chain_matches_definition() {
        let a = B256::repeat_byte(0xaa);
        let b = B256::repeat_byte(0xbb);
        let s = Stack::from_items([a, b]);
        let h_a = keccak256([a.as_slice(), B256::ZERO.as_slice()].concat());
        let h_ab = keccak256([b.as_slice(), h_a.as_slice()].concat());
        assert_eq!(s.hash(), h_ab);
        assert_eq!(s.hash_below(1), h_a);
        assert_eq!(s.hash_below(2), B256::ZERO);
        assert_eq!(s.top(2), vec![b, a]);
    }

    #[test]
    fn drop_restores_previous_hash() {
        let mut s = Stack::from_items([B256::repeat_byte(1)]);
        let before = s.hash();
        s.push(B256::repeat_byte(2));
        s.push(B256::repeat_byte(3));
        s.drop_top(2);
        assert_eq!(s.hash(), before);
        assert_eq!(s.len(), 1);
        assert!(!s.is_empty());
        assert_eq!(s.items(), &[B256::repeat_byte(1)]);
    }
}
