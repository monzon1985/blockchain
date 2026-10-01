// SPDX-License-Identifier: MIT
//! 256-level keccak sparse Merkle tree (SMT) with compressed proofs.
//!
//! Conventions (mirrored by `contracts/src/lib/SparseMerkle.sol`):
//! - the key is the path: bit `h` of the key (as a big-endian `uint256`) picks the side at height `h`, where height 0
//!   is the leaf level and height 256 is the root;
//! - `leaf(k, v) = v == 0 ? 0 : keccak256(k ++ v)`;
//! - `node(l, r) = l == 0 && r == 0 ? 0 : keccak256(l ++ r)`.
//!
//! Empty subtrees hash to zero at every height, so a proof ships only the non-zero siblings plus a 256-bit bitmap
//! saying where they go.

use std::collections::{BTreeMap, HashMap};

use alloy_primitives::{B256, U256, keccak256};

use crate::error::VmError;

/// Tree height: one level per key bit.
pub const DEPTH: usize = 256;

/// Hash of the leaf holding `value` at `key` (zero for an empty leaf).
pub fn leaf_hash(key: B256, value: B256) -> B256 {
    if value.is_zero() { B256::ZERO } else { hash_pair(key, value) }
}

/// Hash of an internal node; two empty children give an empty node.
pub fn node_hash(left: B256, right: B256) -> B256 {
    if left.is_zero() && right.is_zero() { B256::ZERO } else { hash_pair(left, right) }
}

/// `keccak256(abi.encode(a, b))` for two words.
pub fn hash_pair(a: B256, b: B256) -> B256 {
    let mut buf = [0u8; 64];
    buf[..32].copy_from_slice(a.as_slice());
    buf[32..].copy_from_slice(b.as_slice());
    keccak256(buf)
}

/// Compressed proof for one key.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SmtProof {
    /// Bit `h` set means the sibling at height `h` is non-zero and taken from `siblings`.
    pub bitmap: U256,
    /// The non-zero siblings, leaf level first.
    pub siblings: Vec<B256>,
}

impl SmtProof {
    /// Root implied by `value` at `key` under this proof (the same algorithm as the Solidity verifier).
    ///
    /// # Errors
    /// [`VmError::SmtProofLength`] when the bitmap and the sibling list disagree.
    pub fn compute_root(&self, key: B256, value: B256) -> Result<B256, VmError> {
        let path = U256::from_be_bytes(key.0);
        let mut node = leaf_hash(key, value);
        let mut used = 0usize;
        for height in 0..DEPTH {
            let mut sibling = B256::ZERO;
            if self.bitmap.bit(height) {
                if let Some(s) = self.siblings.get(used) {
                    sibling = *s;
                }
                used += 1;
            }
            node = if path.bit(height) { node_hash(sibling, node) } else { node_hash(node, sibling) };
        }
        if used != self.siblings.len() {
            return Err(VmError::SmtProofLength { supplied: self.siblings.len(), consumed: used });
        }
        Ok(node)
    }
}

/// In-memory SMT. Only non-zero leaves and nodes are stored.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SparseMerkleTree {
    leaves: BTreeMap<B256, B256>,
    /// `(height, prefix) -> hash` where `prefix` is the key with its low `height` bits cleared.
    nodes: HashMap<(u16, U256), B256>,
}

/// Key with its low `height` bits cleared (identifies the subtree at `height` containing `key`).
fn prefix(key: U256, height: usize) -> U256 {
    if height >= DEPTH { U256::ZERO } else { key & (U256::MAX << height) }
}

impl SparseMerkleTree {
    /// Empty tree (root zero).
    pub fn new() -> Self {
        Self::default()
    }

    /// Current root.
    pub fn root(&self) -> B256 {
        self.node(DEPTH, U256::ZERO)
    }

    /// Value stored at `key` (zero when absent).
    pub fn get(&self, key: B256) -> B256 {
        self.leaves.get(&key).copied().unwrap_or_default()
    }

    /// Number of non-empty leaves.
    pub fn len(&self) -> usize {
        self.leaves.len()
    }

    /// Whether the tree has no leaves.
    pub fn is_empty(&self) -> bool {
        self.leaves.is_empty()
    }

    /// Non-empty leaves in key order.
    pub fn iter(&self) -> impl Iterator<Item = (&B256, &B256)> {
        self.leaves.iter()
    }

    fn node(&self, height: usize, prefix: U256) -> B256 {
        // Heights are at most 256, so the narrowing is exact.
        let h = height as u16;
        self.nodes.get(&(h, prefix)).copied().unwrap_or_default()
    }

    fn set_node(&mut self, height: usize, prefix: U256, hash: B256) {
        let key = (height as u16, prefix);
        if hash.is_zero() {
            self.nodes.remove(&key);
        } else {
            self.nodes.insert(key, hash);
        }
    }

    /// Writes `value` at `key` (zero deletes) and updates the 256 nodes on its path.
    pub fn insert(&mut self, key: B256, value: B256) {
        if value.is_zero() {
            self.leaves.remove(&key);
        } else {
            self.leaves.insert(key, value);
        }
        let path = U256::from_be_bytes(key.0);
        let mut node = leaf_hash(key, value);
        self.set_node(0, path, node);
        for height in 0..DEPTH {
            let sibling = self.node(height, prefix(path, height) ^ (U256::from(1u8) << height));
            node = if path.bit(height) { node_hash(sibling, node) } else { node_hash(node, sibling) };
            self.set_node(height + 1, prefix(path, height + 1), node);
        }
    }

    /// Compressed proof for `key` (valid for both inclusion and absence).
    pub fn proof(&self, key: B256) -> SmtProof {
        let path = U256::from_be_bytes(key.0);
        let mut proof = SmtProof::default();
        for height in 0..DEPTH {
            let sibling = self.node(height, prefix(path, height) ^ (U256::from(1u8) << height));
            if !sibling.is_zero() {
                proof.bitmap.set_bit(height, true);
                proof.siblings.push(sibling);
            }
        }
        proof
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    /// Root recomputed from scratch, without the node cache: the reference the incremental tree is checked against.
    fn naive_root(leaves: &BTreeMap<B256, B256>) -> B256 {
        fn subtree(entries: &[(U256, B256, B256)], height: usize) -> B256 {
            if entries.is_empty() {
                return B256::ZERO;
            }
            if height == 0 {
                let (_, k, v) = entries[0];
                return leaf_hash(k, v);
            }
            let bit = height - 1;
            let split = entries.partition_point(|(p, _, _)| !p.bit(bit));
            node_hash(subtree(&entries[..split], bit), subtree(&entries[split..], bit))
        }
        // The root splits on bit 255 and the leaf level on bit 0, so numeric order puts every 0-branch before its
        // sibling 1-branch at every height.
        let mut entries: Vec<(U256, B256, B256)> =
            leaves.iter().filter(|(_, v)| !v.is_zero()).map(|(k, v)| (U256::from_be_bytes(k.0), *k, *v)).collect();
        entries.sort_by_key(|e| e.0);
        subtree(&entries, DEPTH)
    }

    fn arb_b256() -> impl Strategy<Value = B256> {
        prop_oneof![
            any::<[u8; 32]>().prop_map(B256::from),
            // Small keys share long prefixes and exercise deep, dense subtrees.
            (0u64..64).prop_map(|x| B256::from(U256::from(x))),
        ]
    }

    #[test]
    fn empty_tree_has_zero_root_and_absence_proofs() {
        let t = SparseMerkleTree::new();
        assert_eq!(t.root(), B256::ZERO);
        let p = t.proof(B256::repeat_byte(7));
        assert!(p.siblings.is_empty());
        assert_eq!(p.compute_root(B256::repeat_byte(7), B256::ZERO).unwrap(), B256::ZERO);
    }

    #[test]
    fn deleting_the_last_leaf_restores_the_empty_root() {
        let mut t = SparseMerkleTree::new();
        let k = B256::repeat_byte(1);
        t.insert(k, B256::repeat_byte(2));
        assert_ne!(t.root(), B256::ZERO);
        t.insert(k, B256::ZERO);
        assert_eq!(t.root(), B256::ZERO);
        assert!(t.is_empty());
    }

    #[test]
    fn proof_length_mismatch_is_rejected() {
        let mut t = SparseMerkleTree::new();
        t.insert(B256::with_last_byte(1), B256::with_last_byte(9));
        t.insert(B256::with_last_byte(2), B256::with_last_byte(9));
        let mut p = t.proof(B256::with_last_byte(1));
        assert!(!p.siblings.is_empty());
        p.siblings.push(B256::repeat_byte(3));
        assert!(matches!(
            p.compute_root(B256::with_last_byte(1), B256::with_last_byte(9)),
            Err(VmError::SmtProofLength { .. })
        ));
        p.siblings.clear();
        assert!(p.compute_root(B256::with_last_byte(1), B256::with_last_byte(9)).is_err());
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(64))]

        #[test]
        fn incremental_root_matches_naive_recomputation(ops in prop::collection::vec((arb_b256(), prop_oneof![Just(B256::ZERO), arb_b256()]), 1..24)) {
            let mut t = SparseMerkleTree::new();
            let mut reference = BTreeMap::new();
            for (k, v) in ops {
                t.insert(k, v);
                if v.is_zero() { reference.remove(&k); } else { reference.insert(k, v); }
            }
            prop_assert_eq!(t.root(), naive_root(&reference));
        }

        #[test]
        fn proofs_verify_for_members_and_non_members(entries in prop::collection::btree_map(arb_b256(), arb_b256(), 0..16), probe in arb_b256()) {
            let mut t = SparseMerkleTree::new();
            for (k, v) in &entries { t.insert(*k, *v); }
            for k in entries.keys().chain(std::iter::once(&probe)) {
                let p = t.proof(*k);
                prop_assert_eq!(p.compute_root(*k, t.get(*k)).unwrap(), t.root());
            }
        }

        #[test]
        fn proof_binds_the_value(entries in prop::collection::btree_map(arb_b256(), arb_b256(), 1..12), forged in arb_b256()) {
            let mut t = SparseMerkleTree::new();
            for (k, v) in &entries { t.insert(*k, *v); }
            let (k, v) = entries.iter().next().map(|(k, v)| (*k, *v)).unwrap();
            prop_assume!(forged != v);
            prop_assert_ne!(t.proof(k).compute_root(k, forged).unwrap(), t.root());
        }

        #[test]
        fn root_is_independent_of_insertion_order(entries in prop::collection::btree_map(arb_b256(), arb_b256(), 0..12)) {
            let mut forward = SparseMerkleTree::new();
            let mut backward = SparseMerkleTree::new();
            for (k, v) in &entries { forward.insert(*k, *v); }
            for (k, v) in entries.iter().rev() { backward.insert(*k, *v); }
            prop_assert_eq!(forward.root(), backward.root());
        }

        #[test]
        fn update_through_proof_matches_tree_update(entries in prop::collection::btree_map(arb_b256(), arb_b256(), 1..12), key in arb_b256(), value in arb_b256()) {
            let mut t = SparseMerkleTree::new();
            for (k, v) in &entries { t.insert(*k, *v); }
            let p = t.proof(key);
            let predicted = p.compute_root(key, value).unwrap();
            t.insert(key, value);
            prop_assert_eq!(predicted, t.root());
        }
    }
}
