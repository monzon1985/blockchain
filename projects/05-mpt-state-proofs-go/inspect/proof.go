// SPDX-License-Identifier: MIT

package inspect

import (
	"context"
	"fmt"
	"io"
	"math/big"
	"strings"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/ethrpc"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/stateproof"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/trie"
)

// AccountView is a proven account, for reports.
type AccountView struct {
	Exists      bool        `json:"exists"`
	Nonce       uint64      `json:"nonce"`
	Balance     string      `json:"balance"`
	StorageRoot keccak.Hash `json:"storageRoot"`
	CodeHash    keccak.Hash `json:"codeHash"`
	// Path is the walk through the state trie, e.g. "branch > branch > leaf".
	Path string `json:"path"`
}

// SlotView is a proven storage slot, for reports.
type SlotView struct {
	Slot   keccak.Hash `json:"slot"`
	Value  keccak.Hash `json:"value"`
	Exists bool        `json:"exists"`
	Path   string      `json:"path"`
}

// ProofReport is the result of VerifyProof.
type ProofReport struct {
	Block     uint64       `json:"block"`
	BlockHash keccak.Hash  `json:"blockHash"`
	StateRoot keccak.Hash  `json:"stateRoot"`
	Address   string       `json:"address"`
	Account   *AccountView `json:"account,omitempty"`
	Slots     []SlotView   `json:"slots"`
	Checks    Checks       `json:"checks"`
}

// describePath renders a proof walk such as "branch > extension > branch > leaf (inline)".
func describePath(steps []trie.Step) string {
	parts := make([]string, len(steps))
	for i, s := range steps {
		parts[i] = s.Kind.String()
		if s.Inline {
			parts[i] += "(inline)"
		}
	}
	return strings.Join(parts, " > ")
}

// VerifyProof anchors a state proof to a verified block: it checks that the node returned the
// requested block and its hash, that the response is for the requested address and slots, then
// verifies eth_getProof's account proof against the header's stateRoot and every storage proof
// against the proven account's storage root, and compares the node's claims with the proofs.
func VerifyProof(ctx context.Context, src Source, addr keccak.Address, slots []keccak.Hash, ref ethrpc.BlockRef) (*ProofReport, error) {
	b, err := src.BlockByRef(ctx, ref)
	if err != nil {
		return nil, err
	}
	rep := &ProofReport{Block: b.Header.Number, BlockHash: b.Hash, StateRoot: b.Header.StateRoot, Address: addr.Hex(), Slots: []SlotView{}}
	c := &rep.Checks
	checkBlockNumber(c, ref, b.Header.Number)
	checkHeader(c, b)

	res, err := src.GetProof(ctx, addr, slots, ethrpc.Number(b.Header.Number))
	if err != nil {
		return nil, err
	}
	checkAddress(c, addr, res.Address)
	if len(res.StorageProof) != len(slots) {
		c.add("storage proofs", Fail, fmt.Sprintf("asked for %s, got %s", plural(len(slots), "slot"), plural(len(res.StorageProof), "proof")))
	} else {
		for i, s := range res.StorageProof {
			if s.Key != slots[i] {
				c.add("storage proofs", Fail, fmt.Sprintf("proof %d is for slot %s, asked for %s", i, s.Key, slots[i]))
			}
		}
	}

	out, err := stateproof.CheckGetProof(b.Header.StateRoot, res)
	if err != nil {
		c.add("proofs", Fail, "INVALID: "+err.Error())
		return rep, nil
	}
	view := &AccountView{Exists: out.Account != nil, Path: describePath(out.AccountSteps), Balance: "0"}
	if a := out.Account; a != nil {
		view.Nonce, view.Balance, view.StorageRoot, view.CodeHash = a.Nonce, a.Balance.String(), a.StorageRoot, a.CodeHash
		c.add("account proof", Pass, fmt.Sprintf("account exists under stateRoot %s (%s)", short(b.Header.StateRoot), view.Path))
	} else {
		c.add("account proof", Pass, fmt.Sprintf("no account at this address: exclusion proof under stateRoot %s (%s)", short(b.Header.StateRoot), view.Path))
	}
	rep.Account = view

	for _, s := range out.Slots {
		sv := SlotView{Slot: s.Key, Value: s.Value, Exists: s.Exists, Path: describePath(s.Steps)}
		rep.Slots = append(rep.Slots, sv)
		what := "absent (zero): exclusion proof"
		if s.Exists {
			what = fmt.Sprintf("= %#x", new(big.Int).SetBytes(s.Value[:]))
		}
		c.add("storage "+short(s.Key), Pass, fmt.Sprintf("%s (%s)", what, emptyPath(sv.Path)))
	}
	if out.OK() {
		c.add("claims", Pass, "nonce, balance, codeHash, storageHash and slot values match the proofs")
	} else {
		for _, m := range out.Mismatches {
			c.add("claims", Fail, "MISMATCH: "+m)
		}
	}
	return rep, nil
}

func emptyPath(p string) string {
	if p == "" {
		return "empty storage trie"
	}
	return p
}

// WriteText renders the report for a terminal.
func (r *ProofReport) WriteText(w io.Writer) {
	fmt.Fprintf(w, "account %s at block %d %s\n", r.Address, r.Block, r.BlockHash)
	if a := r.Account; a != nil {
		if a.Exists {
			fmt.Fprintf(w, "  nonce %d, balance %s wei\n  storageRoot %s\n  codeHash    %s\n", a.Nonce, a.Balance, a.StorageRoot, a.CodeHash)
		} else {
			fmt.Fprintln(w, "  no account")
		}
	}
	writeChecks(w, r.Checks)
}
