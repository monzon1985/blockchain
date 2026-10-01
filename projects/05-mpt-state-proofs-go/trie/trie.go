// SPDX-License-Identifier: MIT

package trie

import (
	"bytes"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
)

// Trie is an in-memory Merkle-Patricia trie. The zero value is an empty trie.
type Trie struct {
	root node
	size int
}

// New returns an empty trie.
func New() *Trie { return &Trie{} }

// Len returns the number of keys in the trie.
func (t *Trie) Len() int { return t.size }

// Hash returns the root hash: Keccak-256 of the root node's encoding, or keccak.EmptyRoot.
func (t *Trie) Hash() keccak.Hash {
	if t.root == nil {
		return keccak.EmptyRoot
	}
	return hashOf(t.root)
}

// Get returns the value stored under key, or (nil, false) if there is none.
func (t *Trie) Get(key []byte) ([]byte, bool) {
	path := KeyToNibbles(key)
	n := t.root
	for {
		switch x := n.(type) {
		case nil:
			return nil, false
		case *leafNode:
			if bytes.Equal(path, x.path) {
				return bytes.Clone(x.value), true
			}
			return nil, false
		case *extensionNode:
			if !hasPrefix(path, x.path) {
				return nil, false
			}
			path, n = path[len(x.path):], x.child
		case *branchNode:
			if len(path) == 0 {
				return bytes.Clone(x.value), x.value != nil
			}
			path, n = path[1:], x.children[path[0]]
		default:
			// A trie built by Put never holds hashRefs; they only appear in decoded proofs.
			panic("trie: unresolved node in an in-memory trie")
		}
	}
}

// Put stores value under key. An empty value deletes the key, as in Ethereum, where trie
// values are RLP encodings and therefore never empty.
func (t *Trie) Put(key, value []byte) {
	if len(value) == 0 {
		t.Delete(key)
		return
	}
	var added bool
	t.root, added = insert(t.root, KeyToNibbles(key), bytes.Clone(value))
	if added {
		t.size++
	}
}

// Delete removes key and reports whether it was present.
func (t *Trie) Delete(key []byte) bool {
	root, removed := remove(t.root, KeyToNibbles(key))
	if removed {
		t.root = root
		t.size--
	}
	return removed
}

// insert returns n with path set to value, and whether the key is new. It builds new nodes
// along the path and shares every untouched subtree with n.
func insert(n node, path, value []byte) (node, bool) {
	switch x := n.(type) {
	case nil:
		return &leafNode{path: bytes.Clone(path), value: value}, true

	case *leafNode:
		cp := commonPrefixLen(x.path, path)
		if cp == len(x.path) && cp == len(path) {
			return &leafNode{path: x.path, value: value}, false
		}
		// The paths diverge after cp nibbles: a branch at the divergence holds both keys,
		// behind an extension for the shared part.
		b := &branchNode{}
		b.place(x.path[cp:], x.value)
		b.place(path[cp:], value)
		return withExtension(path[:cp], b), true

	case *extensionNode:
		cp := commonPrefixLen(x.path, path)
		if cp == len(x.path) {
			child, added := insert(x.child, path[cp:], value)
			return &extensionNode{path: x.path, child: child}, added
		}
		// Split the extension at the divergence. Its remainder after the branch nibble keeps
		// pointing at the old child, through a shorter extension if anything is left.
		b := &branchNode{}
		if rest := x.path[cp+1:]; len(rest) == 0 {
			b.children[x.path[cp]] = x.child
		} else {
			b.children[x.path[cp]] = &extensionNode{path: rest, child: x.child}
		}
		b.place(path[cp:], value)
		return withExtension(path[:cp], b), true

	case *branchNode:
		b := x.clone()
		if len(path) == 0 {
			b.value = value
			return b, x.value == nil
		}
		child, added := insert(x.children[path[0]], path[1:], value)
		b.children[path[0]] = child
		return b, added

	default:
		panic("trie: unresolved node in an in-memory trie")
	}
}

// place puts a key whose remaining path is rest into a fresh branch: in the value slot if
// the path ends here, or as a leaf under its first nibble.
func (b *branchNode) place(rest, value []byte) {
	if len(rest) == 0 {
		b.value = value
		return
	}
	b.children[rest[0]] = &leafNode{path: bytes.Clone(rest[1:]), value: value}
}

// clone copies a branch's slots without its memoized encoding.
func (b *branchNode) clone() *branchNode {
	return &branchNode{children: b.children, value: b.value}
}

// withExtension puts an extension for a non-empty shared prefix above b.
func withExtension(prefix []byte, b *branchNode) node {
	if len(prefix) == 0 {
		return b
	}
	return &extensionNode{path: bytes.Clone(prefix), child: b}
}

// remove returns n without path, and whether path was present. The result is canonical: a
// branch left with one entry collapses, and an extension absorbs a child that stopped being
// a branch.
func remove(n node, path []byte) (node, bool) {
	switch x := n.(type) {
	case nil:
		return nil, false

	case *leafNode:
		if bytes.Equal(x.path, path) {
			return nil, true
		}
		return x, false

	case *extensionNode:
		if !hasPrefix(path, x.path) {
			return x, false
		}
		child, removed := remove(x.child, path[len(x.path):])
		if !removed {
			return x, false
		}
		switch c := child.(type) {
		case *leafNode:
			return &leafNode{path: concat(x.path, c.path), value: c.value}, true
		case *extensionNode:
			return &extensionNode{path: concat(x.path, c.path), child: c.child}, true
		default:
			// The child is still a branch. (It cannot be nil: a branch has at least two
			// entries and one delete removes one.)
			return &extensionNode{path: x.path, child: child}, true
		}

	case *branchNode:
		b := x.clone()
		if len(path) == 0 {
			if x.value == nil {
				return x, false
			}
			b.value = nil
		} else {
			child, removed := remove(x.children[path[0]], path[1:])
			if !removed {
				return x, false
			}
			b.children[path[0]] = child
		}
		return b.collapse(), true

	default:
		panic("trie: unresolved node in an in-memory trie")
	}
}

// collapse returns the canonical form of a branch that may have lost an entry. With two or
// more entries it stays a branch; with only its value it becomes a leaf with an empty path;
// with a single child it merges that child's nibble into the child's path.
func (b *branchNode) collapse() node {
	entries, last := 0, -1
	for i, c := range b.children {
		if c != nil {
			entries++
			last = i
		}
	}
	if b.value != nil {
		entries++
	}
	switch {
	case entries >= 2:
		return b
	case entries == 0:
		return nil
	case b.value != nil:
		return &leafNode{path: []byte{}, value: b.value}
	}
	nibble := []byte{byte(last)}
	switch c := b.children[last].(type) {
	case *leafNode:
		return &leafNode{path: concat(nibble, c.path), value: c.value}
	case *extensionNode:
		return &extensionNode{path: concat(nibble, c.path), child: c.child}
	default:
		return &extensionNode{path: nibble, child: c}
	}
}

// Prove returns the encoded nodes on the path of key, root first. For a key in the trie the
// last node holds its value; for a missing key the nodes show where the path ends. Inline
// nodes are not listed separately: they are part of their parent's encoding. The proof of
// any key in an empty trie is empty.
func (t *Trie) Prove(key []byte) [][]byte {
	path := KeyToNibbles(key)
	var proof [][]byte
	for n, first := t.root, true; n != nil; first = false {
		if enc := n.encoding(); first || len(enc) >= 32 {
			proof = append(proof, bytes.Clone(enc))
		}
		switch x := n.(type) {
		case *extensionNode:
			if !hasPrefix(path, x.path) {
				return proof
			}
			path, n = path[len(x.path):], x.child
		case *branchNode:
			if len(path) == 0 {
				return proof
			}
			path, n = path[1:], x.children[path[0]]
		default: // a leaf ends every path
			return proof
		}
	}
	return proof
}
