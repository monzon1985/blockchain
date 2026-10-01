// SPDX-License-Identifier: MIT

// Package inspect verifies what an Ethereum node reports, end to end: it fetches a block,
// transactions, receipts and state proofs through a Source, recomputes every commitment with
// this module's own RLP, trie and hashing code, and produces a report of named checks.
package inspect

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/ethrpc"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/stateproof"
)

// Source is what the verifiers need from a node. *ethrpc.Client implements it.
type Source interface {
	BlockByRef(ctx context.Context, ref ethrpc.BlockRef) (*ethrpc.Block, error)
	RawTransactions(ctx context.Context, hashes []keccak.Hash) ([][]byte, error)
	BlockReceipts(ctx context.Context, ref ethrpc.BlockRef) ([]ethrpc.Receipt, error)
	GetProof(ctx context.Context, addr keccak.Address, slots []keccak.Hash, ref ethrpc.BlockRef) (*stateproof.GetProofResult, error)
	StorageAt(ctx context.Context, addr keccak.Address, slot keccak.Hash, ref ethrpc.BlockRef) (keccak.Hash, error)
}

var _ Source = (*ethrpc.Client)(nil)

// Status is the outcome of one check.
type Status uint8

const (
	// Pass means the recomputed value equals the reported one.
	Pass Status = iota
	// Warn means the data verifies but deviates from the canonical form, or could not be
	// checked completely; the detail says how.
	Warn
	// Fail means the node's data contradicts itself or its commitments.
	Fail
)

// String implements fmt.Stringer.
func (s Status) String() string {
	switch s {
	case Pass:
		return "ok"
	case Warn:
		return "warn"
	default:
		return "fail"
	}
}

// MarshalText implements encoding.TextMarshaler.
func (s Status) MarshalText() ([]byte, error) { return []byte(s.String()), nil }

// Check is one verified claim.
type Check struct {
	Name   string `json:"name"`
	Status Status `json:"status"`
	// Detail explains the result in one line.
	Detail string `json:"detail"`
	// Reported and Computed hold the two sides of a comparison, when there is one.
	Reported string `json:"reported,omitempty"`
	Computed string `json:"computed,omitempty"`
}

// Checks is an ordered list of checks.
type Checks []Check

func (c *Checks) add(name string, s Status, detail string) {
	*c = append(*c, Check{Name: name, Status: s, Detail: detail})
}

// compare records a check of a reported hash against a recomputed one.
func (c *Checks) compare(name string, reported, computed keccak.Hash, detail string) bool {
	s := Pass
	if reported != computed {
		s = Fail
		detail = fmt.Sprintf("MISMATCH: %s", detail)
	}
	*c = append(*c, Check{Name: name, Status: s, Detail: detail, Reported: reported.Hex(), Computed: computed.Hex()})
	return s == Pass
}

// Count returns the number of checks with status s.
func (c Checks) Count(s Status) int {
	n := 0
	for _, ch := range c {
		if ch.Status == s {
			n++
		}
	}
	return n
}

// Verdict summarizes checks: VERIFIED, VERIFIED WITH WARNINGS or FAILED.
func (c Checks) Verdict() string {
	switch {
	case c.Count(Fail) > 0:
		return fmt.Sprintf("FAILED (%d of %d checks failed)", c.Count(Fail), len(c))
	case c.Count(Warn) > 0:
		return fmt.Sprintf("VERIFIED WITH WARNINGS (%d checks, %d warnings)", len(c), c.Count(Warn))
	default:
		return fmt.Sprintf("VERIFIED (%d checks)", len(c))
	}
}

// OK reports whether no check failed and, if strict, none warned.
func (c Checks) OK(strict bool) bool {
	return c.Count(Fail) == 0 && (!strict || c.Count(Warn) == 0)
}

func writeChecks(w io.Writer, checks Checks) {
	width := 0
	for _, c := range checks {
		width = max(width, len(c.Name))
	}
	for _, c := range checks {
		fmt.Fprintf(w, "  %-6s %-*s  %s\n", "["+c.Status.String()+"]", width, c.Name, c.Detail)
		if c.Status == Fail && c.Reported != "" {
			fmt.Fprintf(w, "  %-6s %-*s    reported %s\n", "", width, "", c.Reported)
			fmt.Fprintf(w, "  %-6s %-*s    computed %s\n", "", width, "", c.Computed)
		}
	}
	fmt.Fprintf(w, "verdict: %s\n", checks.Verdict())
}

// WriteJSON writes v as indented JSON.
func WriteJSON(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func short(h keccak.Hash) string {
	s := h.Hex()
	return s[:10] + ".." + s[len(s)-4:]
}

func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	if strings.HasSuffix(word, "y") {
		return fmt.Sprintf("%d %sies", n, word[:len(word)-1])
	}
	return fmt.Sprintf("%d %ss", n, word)
}
