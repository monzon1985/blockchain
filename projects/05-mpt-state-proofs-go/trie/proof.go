// SPDX-License-Identifier: MIT

package trie

import (
	"bytes"
	"errors"
	"fmt"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
)

// Proof verification errors.
var (
	// ErrMissingProofNode means the path needs a node the proof does not contain, so the
	// proof decides nothing: neither inclusion nor exclusion.
	ErrMissingProofNode = errors.New("trie: proof is missing a node on the key's path")
	// ErrUnusedProofNode means the proof carries a node that is not on the key's path.
	ErrUnusedProofNode = errors.New("trie: proof contains a node that is not on the key's path")
	// ErrDuplicateProofNode means the same node appears twice in the proof.
	ErrDuplicateProofNode = errors.New("trie: proof contains a node twice")
)

// Step describes one node visited while verifying a proof.
type Step struct {
	Kind     NodeKind
	Hash     keccak.Hash // zero for an inline node
	Inline   bool        // embedded in its parent rather than referenced by hash
	Size     int         // encoded size in bytes
	Consumed []byte      // key nibbles matched at this node
}

// Result is the outcome of a successful proof verification.
type Result struct {
	// Value is the value stored under the key, or nil if the proof shows the key is absent.
	Value []byte
	// Steps is the walk from the root to the node that decided the result.
	Steps []Step
}

// Exists reports whether the proof shows the key is present.
func (r Result) Exists() bool { return r.Value != nil }

// VerifyProof checks that proof, a list of node encodings, proves the value of key in the
// trie with root hash root. It returns the value, or nil if the proof shows the key is absent.
// An error means the proof is invalid: it must not be read as absence.
func VerifyProof(root keccak.Hash, key []byte, proof [][]byte) ([]byte, error) {
	r, err := VerifyProofTrace(root, key, proof)
	return r.Value, err
}

// VerifyProofTrace is VerifyProof that also returns the walk through the trie.
//
// Beyond following the path, it enforces that the proof is canonical and minimal: every
// node decodes strictly; a node referenced by hash below the root is at least 32 bytes long
// and an inline node is shorter; an extension's child is a branch; and every proof node is
// used exactly once.
func VerifyProofTrace(root keccak.Hash, key []byte, proof [][]byte) (Result, error) {
	byHash := make(map[keccak.Hash][]byte, len(proof))
	for i, enc := range proof {
		h := keccak.Sum256(enc)
		if _, dup := byHash[h]; dup {
			return Result{}, fmt.Errorf("%w: node %d (%s)", ErrDuplicateProofNode, i, h)
		}
		byHash[h] = enc
	}
	if root == keccak.EmptyRoot {
		// The empty trie's root "node" is RLP("") = 0x80, whose hash is the root. Clients
		// differ on whether a proof includes it: go-ethereum sends no nodes, anvil sends
		// [0x80]. Both prove absence; anything else is not a proof of the empty trie.
		if len(proof) == 0 || (len(proof) == 1 && bytes.Equal(proof[0], emptyString)) {
			return Result{}, nil
		}
		return Result{}, fmt.Errorf("%w: the empty trie has only the empty node, got %d node(s)", ErrUnusedProofNode, len(proof))
	}

	var (
		res        Result
		path       = KeyToNibbles(key)
		want       = root
		wantBranch bool // the hash we follow was an extension's child
	)
	for depth := 0; ; depth++ {
		enc, ok := byHash[want]
		if !ok {
			return Result{}, fmt.Errorf("%w: node %d on the path, hash %s", ErrMissingProofNode, depth, want)
		}
		delete(byHash, want)
		if depth > 0 && len(enc) < 32 {
			return Result{}, invalid("node %s of %d bytes is referenced by hash (it must be inlined)", want, len(enc))
		}
		n, err := decodeNode(enc)
		if err != nil {
			return Result{}, fmt.Errorf("proof node %s: %w", want, err)
		}
		if wantBranch && kindOf(n) != Branch {
			return Result{}, invalid("extension child %s is a %s, not a branch", want, kindOf(n))
		}
		hash, inline := want, false

		// Walk this node and any inline nodes below it until the path leaves the node by
		// hash (continue with the next proof node) or the result is decided.
		for {
			step := Step{Kind: kindOf(n), Inline: inline, Size: len(n.encoding())}
			if !inline {
				step.Hash = hash
			}
			var next node
			switch x := n.(type) {
			case *leafNode:
				if bytes.Equal(path, x.path) {
					step.Consumed = path
					res.Value = bytes.Clone(x.value)
				}
				// A leaf whose path differs proves absence: this is where the key would be.
				res.Steps = append(res.Steps, step)
				return finish(res, byHash)
			case *extensionNode:
				if !hasPrefix(path, x.path) {
					res.Steps = append(res.Steps, step) // the key diverges inside the extension
					return finish(res, byHash)
				}
				step.Consumed, path, next = x.path, path[len(x.path):], x.child
				wantBranch = true
			case *branchNode:
				if len(path) == 0 {
					res.Value = bytes.Clone(x.value) // nil if no key ends here
					res.Steps = append(res.Steps, step)
					return finish(res, byHash)
				}
				step.Consumed, path, next = path[:1], path[1:], x.children[path[0]]
				wantBranch = false
				if next == nil {
					res.Steps = append(res.Steps, step) // empty slot: the key is absent
					return finish(res, byHash)
				}
			}
			res.Steps = append(res.Steps, step)
			if ref, ok := next.(hashRef); ok {
				want = keccak.Hash(ref)
				break
			}
			n, inline = next, true // inline child: decoded already, keep walking
		}
	}
}

// finish rejects proofs that carry nodes the walk did not use.
func finish(res Result, unused map[keccak.Hash][]byte) (Result, error) {
	for h := range unused {
		return Result{}, fmt.Errorf("%w: %d node(s), including %s", ErrUnusedProofNode, len(unused), h)
	}
	return res, nil
}
