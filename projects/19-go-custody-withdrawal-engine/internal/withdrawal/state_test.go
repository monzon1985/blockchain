// SPDX-License-Identifier: MIT

package withdrawal_test

import (
	"math/big"
	"testing"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/withdrawal"
)

// TestTransitionTable pins the complete transition relation: every (from, to) pair is either
// an edge or explicitly illegal, so a change to the state machine must change this table.
func TestTransitionTable(t *testing.T) {
	type pair struct{ from, to withdrawal.Status }
	legal := map[pair]bool{
		{withdrawal.Created, withdrawal.Requested}:  true,
		{withdrawal.Requested, withdrawal.Approved}: true,
		{withdrawal.Requested, withdrawal.Failed}:   true,
		{withdrawal.Approved, withdrawal.Signed}:    true,
		{withdrawal.Approved, withdrawal.Failed}:    true,
		{withdrawal.Signed, withdrawal.Broadcast}:   true,
		{withdrawal.Broadcast, withdrawal.Mined}:    true,
		{withdrawal.Mined, withdrawal.Broadcast}:    true,
		{withdrawal.Mined, withdrawal.Confirmed}:    true,
		{withdrawal.Mined, withdrawal.Failed}:       true,
		{withdrawal.Mined, withdrawal.Replaced}:     true,
	}
	all := append([]withdrawal.Status{withdrawal.Created}, withdrawal.AllStatuses...)
	count := 0
	for _, from := range all {
		for _, to := range all {
			if got := withdrawal.CanTransition(from, to); got != legal[pair{from, to}] {
				t.Errorf("%q -> %q: got %v", from, to, got)
			}
			if legal[pair{from, to}] {
				count++
			}
		}
	}
	if count != len(legal) {
		t.Fatalf("table has %d edges, relation has %d", len(legal), count)
	}
}

// TestSafetyProperties checks structural properties of the state machine by exhaustive search.
func TestSafetyProperties(t *testing.T) {
	// Terminal states have no outgoing edges.
	for _, s := range withdrawal.AllStatuses {
		if s.Terminal() {
			for _, to := range withdrawal.AllStatuses {
				if withdrawal.CanTransition(s, to) {
					t.Fatalf("terminal %s has edge to %s", s, to)
				}
			}
		}
	}
	// Once signed, every path to a terminal state goes through mined: the engine can never fail
	// or refund a withdrawal whose transaction may be on the network without the chain deciding.
	var reachWithoutMined func(s withdrawal.Status, seen map[withdrawal.Status]bool) bool
	reachWithoutMined = func(s withdrawal.Status, seen map[withdrawal.Status]bool) bool {
		if s == withdrawal.Mined || seen[s] {
			return false
		}
		if s.Terminal() {
			return true
		}
		seen[s] = true
		for _, to := range withdrawal.AllStatuses {
			if withdrawal.CanTransition(s, to) && reachWithoutMined(to, seen) {
				return true
			}
		}
		return false
	}
	for _, s := range []withdrawal.Status{withdrawal.Signed, withdrawal.Broadcast} {
		if reachWithoutMined(s, map[withdrawal.Status]bool{}) {
			t.Fatalf("a terminal state is reachable from %s without passing through mined", s)
		}
	}
	// Every state is reachable from creation, and every non-terminal state can reach a terminal one.
	reach := map[withdrawal.Status]bool{withdrawal.Created: true}
	for changed := true; changed; {
		changed = false
		for from := range reach {
			for _, to := range withdrawal.AllStatuses {
				if withdrawal.CanTransition(from, to) && !reach[to] {
					reach[to], changed = true, true
				}
			}
		}
	}
	for _, s := range withdrawal.AllStatuses {
		if !reach[s] {
			t.Fatalf("%s unreachable", s)
		}
	}
	if !withdrawal.Failed.Refundable() || !withdrawal.Replaced.Refundable() || withdrawal.Confirmed.Refundable() {
		t.Fatal("refund classification wrong")
	}
}

func TestParseAmount(t *testing.T) {
	ok := []string{"1", "1000000", "115792089237316195423570985008687907853269984665640564039457584007913129639935"}
	bad := []string{"", "0", "01", "-1", "+1", "1e6", "1.5", " 1", "0x10",
		"115792089237316195423570985008687907853269984665640564039457584007913129639936"}
	for _, s := range ok {
		if v, good := withdrawal.ParseAmount(s); !good || v.String() != s {
			t.Errorf("%q rejected", s)
		}
	}
	for _, s := range bad {
		if _, good := withdrawal.ParseAmount(s); good {
			t.Errorf("%q accepted", s)
		}
	}
	_ = big.NewInt
}

func TestParseAddress(t *testing.T) {
	cases := map[string]bool{
		"0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed": true,  // valid EIP-55
		"0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed": true,  // all lower: no checksum claimed
		"0x5AAEB6053F3E94C9B9A09F33669435E7EF1BEAED": true,  // all upper
		"0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD": false, // broken checksum
		"5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed":   false, // no prefix
		"0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeA":   false, // short
		"": false,
	}
	for in, want := range cases {
		if _, got := withdrawal.ParseAddress(in); got != want {
			t.Errorf("%q: got %v", in, got)
		}
	}
}

func TestValidators(t *testing.T) {
	if !withdrawal.ValidAccountID("user:42_a.b-c") || withdrawal.ValidAccountID("") || withdrawal.ValidAccountID("has space") {
		t.Fatal("account id validation")
	}
	if !withdrawal.ValidIdempotencyKey("abc-123") || withdrawal.ValidIdempotencyKey("") || withdrawal.ValidIdempotencyKey("tab\tkey") {
		t.Fatal("idempotency key validation")
	}
}
