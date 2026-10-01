// SPDX-License-Identifier: MIT

package policy_test

import (
	"context"
	"fmt"
	"math/big"
	"math/rand/v2"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/policy"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

var (
	t0   = time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)
	dest = common.HexToAddress("0x00000000000000000000000000000000000000d1")
	hot  = common.HexToAddress("0x00000000000000000000000000000000000000f0")
)

func rules() policy.Rules {
	return policy.Rules{
		Assets: map[string]policy.AssetRules{"USD": {
			MaxPerTx: big.NewInt(1_000), Velocity24h: big.NewInt(2_500), ApprovalThreshold: big.NewInt(500),
		}},
		AllowlistCooldown: 24 * time.Hour,
		ApprovalsRequired: 2,
		Approvers: []policy.Approver{
			{ID: "a", TokenSHA256: policy.HashToken("ta")}, {ID: "b", TokenSHA256: policy.HashToken("tb")}, {ID: "c", TokenSHA256: policy.HashToken("tc")},
		},
	}
}

func activeEntry() *policy.AllowlistEntry {
	return &policy.AllowlistEntry{Address: dest, AddedAt: t0.Add(-48 * time.Hour), ActiveAt: t0.Add(-24 * time.Hour)}
}

func TestEvaluate(t *testing.T) {
	r := rules()
	base := func() (policy.Request, policy.State) {
		return policy.Request{AccountID: "u", Asset: "USD", Amount: big.NewInt(100), Destination: dest},
			policy.State{Now: t0, Available: big.NewInt(10_000), UsedIn24h: big.NewInt(0), Allowlist: activeEntry(), Forbidden: []common.Address{hot}}
	}
	cases := []struct {
		name      string
		mut       func(*policy.Request, *policy.State)
		reason    string
		allowed   bool
		approvals int
	}{
		{"ok below threshold", func(*policy.Request, *policy.State) {}, policy.ReasonApproved, true, 0},
		{"at threshold needs M approvals", func(q *policy.Request, _ *policy.State) { q.Amount = big.NewInt(500) }, policy.ReasonApprovalsRequired, true, 2},
		{"unknown asset", func(q *policy.Request, _ *policy.State) { q.Asset = "EUR" }, policy.ReasonAssetUnsupported, false, 0},
		{"zero amount", func(q *policy.Request, _ *policy.State) { q.Amount = big.NewInt(0) }, policy.ReasonAmountInvalid, false, 0},
		{"nil amount", func(q *policy.Request, _ *policy.State) { q.Amount = nil }, policy.ReasonAmountInvalid, false, 0},
		{"above max per tx", func(q *policy.Request, _ *policy.State) { q.Amount = big.NewInt(1_001) }, policy.ReasonAboveMaxPerTx, false, 0},
		{"zero destination", func(q *policy.Request, _ *policy.State) { q.Destination = common.Address{} }, policy.ReasonBadDestination, false, 0},
		{"forbidden destination", func(q *policy.Request, _ *policy.State) { q.Destination = hot }, policy.ReasonBadDestination, false, 0},
		{"not allowlisted", func(_ *policy.Request, s *policy.State) { s.Allowlist = nil }, policy.ReasonNotAllowlisted, false, 0},
		{"in cool-down", func(_ *policy.Request, s *policy.State) { s.Allowlist.ActiveAt = t0.Add(time.Second) }, policy.ReasonInCooldown, false, 0},
		{"cool-down ends exactly now", func(_ *policy.Request, s *policy.State) { s.Allowlist.ActiveAt = t0 }, policy.ReasonApproved, true, 0},
		{"velocity exceeded", func(_ *policy.Request, s *policy.State) { s.UsedIn24h = big.NewInt(2_401) }, policy.ReasonVelocityExceeded, false, 0},
		{"velocity exactly reached", func(_ *policy.Request, s *policy.State) { s.UsedIn24h = big.NewInt(2_400) }, policy.ReasonApproved, true, 0},
		{"insufficient balance", func(_ *policy.Request, s *policy.State) { s.Available = big.NewInt(99) }, policy.ReasonInsufficientFunds, false, 0},
		{"nil balance", func(_ *policy.Request, s *policy.State) { s.Available = nil }, policy.ReasonInsufficientFunds, false, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			q, s := base()
			tc.mut(&q, &s)
			d := r.Evaluate(q, s)
			if d.Reason != tc.reason || d.Allowed != tc.allowed || d.ApprovalsRequired != tc.approvals {
				t.Fatalf("got %+v, want reason=%s allowed=%v approvals=%d", d, tc.reason, tc.allowed, tc.approvals)
			}
		})
	}
}

func TestRulesValidate(t *testing.T) {
	if err := rules().Validate(); err != nil {
		t.Fatal(err)
	}
	bad := map[string]func(*policy.Rules){
		"M > N":         func(r *policy.Rules) { r.ApprovalsRequired = 4 },
		"M = 0":         func(r *policy.Rules) { r.ApprovalsRequired = 0 },
		"duplicate id":  func(r *policy.Rules) { r.Approvers[1].ID = "a" },
		"bad hash":      func(r *policy.Rules) { r.Approvers[0].TokenSHA256 = strings.Repeat("z", 64) },
		"short hash":    func(r *policy.Rules) { r.Approvers[0].TokenSHA256 = "abcd" },
		"no assets":     func(r *policy.Rules) { r.Assets = nil },
		"missing limit": func(r *policy.Rules) { r.Assets["USD"] = policy.AssetRules{MaxPerTx: big.NewInt(1)} },
		"zero limit": func(r *policy.Rules) {
			r.Assets["USD"] = policy.AssetRules{MaxPerTx: big.NewInt(0), Velocity24h: big.NewInt(1), ApprovalThreshold: big.NewInt(1)}
		},
		"negative cooldown": func(r *policy.Rules) { r.AllowlistCooldown = -time.Second },
	}
	for name, mut := range bad {
		r := rules()
		r.Assets = map[string]policy.AssetRules{"USD": r.Assets["USD"]}
		r.Approvers = append([]policy.Approver{}, r.Approvers...)
		mut(&r)
		if err := r.Validate(); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

// TestPropertyVelocityWindow replays random request streams through Evaluate with the state a
// correct engine would maintain, and checks the rolling-window property: the sum of allowed
// amounts inside any 24 h window never exceeds the limit.
func TestPropertyVelocityWindow(t *testing.T) {
	r := rules()
	limit := r.Assets["USD"].Velocity24h
	for seed := uint64(1); seed <= 50; seed++ {
		rng := rand.New(rand.NewPCG(seed, 3))
		type accepted struct {
			at     time.Time
			amount *big.Int
		}
		var hist []accepted
		now := t0
		for range 300 {
			now = now.Add(time.Duration(rng.IntN(6*3600)) * time.Second)
			amt := big.NewInt(int64(1 + rng.IntN(999)))
			used := new(big.Int)
			for _, h := range hist {
				if h.at.After(now.Add(-policy.Window)) {
					used.Add(used, h.amount)
				}
			}
			d := r.Evaluate(policy.Request{Asset: "USD", Amount: amt, Destination: dest},
				policy.State{Now: now, Available: big.NewInt(1 << 40), UsedIn24h: used, Allowlist: activeEntry()})
			if d.Allowed {
				hist = append(hist, accepted{now, amt})
			}
		}
		for i := range hist {
			sum := new(big.Int)
			for j := range hist {
				if !hist[j].at.Before(hist[i].at) && hist[j].at.Before(hist[i].at.Add(policy.Window)) {
					sum.Add(sum, hist[j].amount)
				}
			}
			if sum.Cmp(limit) > 0 {
				t.Fatalf("seed %d: window starting %s holds %s > %s", seed, hist[i].at, sum, limit)
			}
		}
	}
}

func TestAuthenticate(t *testing.T) {
	ps := rules().ApproverPrincipals()
	if id, ok := policy.Authenticate("tb", ps); !ok || id != "b" {
		t.Fatalf("got %q %v", id, ok)
	}
	for _, bad := range []string{"", "tx", "TB", "tb "} {
		if _, ok := policy.Authenticate(bad, ps); ok {
			t.Fatalf("token %q accepted", bad)
		}
	}
	if len(policy.HashToken("x")) != 64 {
		t.Fatal("hash length")
	}
	// Hashes are compared as bytes: an upper-case hex digest matches; a malformed one never does.
	mixed := []policy.Principal{{ID: "upper", TokenSHA256: strings.ToUpper(policy.HashToken("tu"))}, {ID: "junk", TokenSHA256: strings.Repeat("z", 64)}}
	if id, ok := policy.Authenticate("tu", mixed); !ok || id != "upper" {
		t.Fatalf("upper-case digest: %q %v", id, ok)
	}
	if _, ok := policy.Authenticate("zz", mixed); ok {
		t.Fatal("a malformed digest matched")
	}
}

func TestAllowlistStore(t *testing.T) {
	ctx := context.Background()
	db, err := store.OpenWith(ctx, filepath.Join(t.TempDir(), "a.db"), store.Options{Synchronous: "OFF"})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	r := rules()
	e, err := policy.Add(ctx, db, "u", dest, "cold", t0, r.ActiveAt(t0))
	if err != nil {
		t.Fatal(err)
	}
	if !e.ActiveAt.Equal(t0.Add(24 * time.Hour)) {
		t.Fatalf("active at %s", e.ActiveAt)
	}
	// Re-adding does not reset the cool-down.
	e2, _ := policy.Add(ctx, db, "u", dest, "again", t0.Add(time.Hour), r.ActiveAt(t0.Add(time.Hour)))
	if !e2.ActiveAt.Equal(e.ActiveAt) {
		t.Fatalf("cool-down reset by re-add: %s", e2.ActiveAt)
	}
	al := policy.NewAllowlist(db)
	for _, tc := range []struct {
		at   time.Time
		acct string
		want bool
	}{
		{t0.Add(23 * time.Hour), "u", false},
		{t0.Add(24 * time.Hour), "u", true},
		{t0.Add(48 * time.Hour), "other", false},
	} {
		got, err := al.IsActive(ctx, tc.acct, dest, tc.at)
		if err != nil || got != tc.want {
			t.Fatalf("IsActive(%s, %s) = %v %v", tc.acct, tc.at, got, err)
		}
	}
	list, _ := policy.List(ctx, db, "u")
	if len(list) != 1 || list[0].Label != "cold" {
		t.Fatalf("list = %+v", list)
	}
	if removed, _ := policy.Remove(ctx, db, "u", dest); !removed {
		t.Fatal("remove failed")
	}
	if removed, _ := policy.Remove(ctx, db, "u", dest); removed {
		t.Fatal("double remove reported success")
	}
	if got, _ := al.IsActive(ctx, "u", dest, t0.Add(100*time.Hour)); got {
		t.Fatal("removed entry still active")
	}
	_ = fmt.Sprint()
}
