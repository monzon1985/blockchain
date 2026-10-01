// SPDX-License-Identifier: MIT

package trie

import (
	"bytes"
	"errors"
	"fmt"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/rlp"
)

// ErrInvalidNode is returned for a node encoding that is malformed or that a canonical trie
// could not contain.
var ErrInvalidNode = errors.New("trie: invalid node")

// node is one of *leafNode, *extensionNode, *branchNode, or hashRef (a child known only by
// its hash, which appears when decoding proof nodes). Nodes are immutable once built: every
// modification creates new nodes along the path, so the memoized encodings stay valid.
type node interface {
	encoding() []byte
}

// memo caches a node's RLP encoding and hash.
type memo struct {
	enc    []byte
	hash   keccak.Hash
	hashed bool
}

type leafNode struct {
	path  []byte // remaining key nibbles, possibly empty
	value []byte // never empty
	memo
}

type extensionNode struct {
	path  []byte // shared nibbles, never empty
	child node   // always a branch (or a hashRef to one)
	memo
}

type branchNode struct {
	children [16]node
	value    []byte // nil when no key ends here
	memo
}

// hashRef is a child referenced by hash whose node is not in memory.
type hashRef keccak.Hash

// emptyString is RLP("").
var emptyString = []byte{0x80}

func (n *leafNode) encoding() []byte {
	if n.enc == nil {
		n.enc = rlp.EncodeList(rlp.EncodeString(HexPrefixEncode(n.path, true)), rlp.EncodeString(n.value))
	}
	return n.enc
}

func (n *extensionNode) encoding() []byte {
	if n.enc == nil {
		n.enc = rlp.EncodeList(rlp.EncodeString(HexPrefixEncode(n.path, false)), reference(n.child))
	}
	return n.enc
}

func (n *branchNode) encoding() []byte {
	if n.enc == nil {
		var items [17][]byte
		for i, c := range n.children {
			items[i] = reference(c)
		}
		items[16] = rlp.EncodeString(n.value)
		n.enc = rlp.EncodeList(items[:]...)
	}
	return n.enc
}

// encoding of a hashRef is its reference form; it is never used as a node encoding.
func (h hashRef) encoding() []byte { return rlp.EncodeString(h[:]) }

// hashOf returns Keccak-256 of a node's encoding, memoized.
func hashOf(n node) keccak.Hash {
	var m *memo
	switch x := n.(type) {
	case hashRef:
		return keccak.Hash(x)
	case *leafNode:
		m = &x.memo
	case *extensionNode:
		m = &x.memo
	case *branchNode:
		m = &x.memo
	}
	if !m.hashed {
		m.hash = keccak.Sum256(n.encoding())
		m.hashed = true
	}
	return m.hash
}

// reference returns how a parent refers to child n: RLP("") for no child, the child's own
// encoding when it is shorter than 32 bytes, and RLP(keccak(encoding)) otherwise.
func reference(n node) []byte {
	switch x := n.(type) {
	case nil:
		return emptyString
	case hashRef:
		return x.encoding()
	}
	if enc := n.encoding(); len(enc) < 32 {
		return enc
	}
	h := hashOf(n)
	return rlp.EncodeString(h[:])
}

// NodeKind names the three node types.
type NodeKind uint8

const (
	// Branch is a 17-item node: sixteen children and a value.
	Branch NodeKind = iota + 1
	// Extension is a 2-item node with a shared path and a branch child.
	Extension
	// Leaf is a 2-item node with the rest of a key and its value.
	Leaf
)

// String implements fmt.Stringer.
func (k NodeKind) String() string {
	switch k {
	case Branch:
		return "branch"
	case Extension:
		return "extension"
	case Leaf:
		return "leaf"
	default:
		return fmt.Sprintf("NodeKind(%d)", uint8(k))
	}
}

func kindOf(n node) NodeKind {
	switch n.(type) {
	case *branchNode:
		return Branch
	case *extensionNode:
		return Extension
	case *leafNode:
		return Leaf
	}
	return 0
}

// decodeNode parses a node encoding strictly. Children longer than 31 bytes come back as
// hashRefs; shorter ones are decoded in place (inline nodes).
func decodeNode(enc []byte) (node, error) {
	v, err := rlp.Decode(enc)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrInvalidNode, err)
	}
	n, err := nodeFromValue(v, 0)
	if err != nil {
		return nil, err
	}
	// Defense in depth: the checks above admit only canonical encodings, so re-encoding must
	// reproduce the input exactly.
	if !bytes.Equal(n.encoding(), enc) {
		return nil, invalid("encoding is not canonical")
	}
	return n, nil
}

func invalid(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalidNode, fmt.Sprintf(format, args...))
}

// maxInlineDepth bounds the nesting of inline nodes. An inline node is shorter than 32 bytes,
// and each level of nesting costs at least two bytes, so legitimate nesting is shallow.
const maxInlineDepth = 16

func nodeFromValue(v rlp.Value, depth int) (node, error) {
	if v.Kind != rlp.List {
		return nil, invalid("node is a string, not a list")
	}
	switch len(v.Items) {
	case 2:
		return shortFromValue(v, depth)
	case 17:
		return branchFromValue(v, depth)
	default:
		return nil, invalid("list of %d items (want 2 or 17)", len(v.Items))
	}
}

func shortFromValue(v rlp.Value, depth int) (node, error) {
	if v.Items[0].Kind != rlp.String {
		return nil, invalid("path is a list")
	}
	path, leaf, err := HexPrefixDecode(v.Items[0].Bytes)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrInvalidNode, err)
	}
	if leaf {
		val := v.Items[1]
		if val.Kind != rlp.String || len(val.Bytes) == 0 {
			return nil, invalid("leaf value must be a non-empty string")
		}
		return &leafNode{path: path, value: val.Bytes}, nil
	}
	if len(path) == 0 {
		return nil, invalid("extension with an empty path")
	}
	child, err := childFromValue(v.Items[1], depth)
	if err != nil {
		return nil, err
	}
	switch child.(type) {
	case nil:
		return nil, invalid("extension without a child")
	case *leafNode, *extensionNode:
		return nil, invalid("extension child is a %s, not a branch", kindOf(child))
	}
	return &extensionNode{path: path, child: child}, nil
}

func branchFromValue(v rlp.Value, depth int) (node, error) {
	b := &branchNode{}
	used := 0
	for i := range 16 {
		c, err := childFromValue(v.Items[i], depth)
		if err != nil {
			return nil, err
		}
		if c != nil {
			b.children[i] = c
			used++
		}
	}
	val := v.Items[16]
	if val.Kind != rlp.String {
		return nil, invalid("branch value is a list")
	}
	if len(val.Bytes) > 0 {
		b.value = val.Bytes
		used++
	}
	if used < 2 {
		return nil, invalid("branch with %d entries (a canonical branch has at least 2)", used)
	}
	return b, nil
}

// childFromValue decodes a child reference: RLP("") is no child, a 32-byte string is a hash,
// and a list is an inline node, which must be shorter than 32 bytes.
func childFromValue(v rlp.Value, depth int) (node, error) {
	if v.Kind == rlp.String {
		switch len(v.Bytes) {
		case 0:
			return nil, nil
		case 32:
			return hashRef(v.Bytes), nil
		default:
			return nil, invalid("child reference of %d bytes (want 0 or 32)", len(v.Bytes))
		}
	}
	if size := len(v.Encode()); size >= 32 {
		return nil, invalid("inline node of %d bytes (nodes of 32 bytes or more are hashed)", size)
	}
	if depth >= maxInlineDepth {
		return nil, invalid("inline nodes nested deeper than %d", maxInlineDepth)
	}
	return nodeFromValue(v, depth+1)
}
