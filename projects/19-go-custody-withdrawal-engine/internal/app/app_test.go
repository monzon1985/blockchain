// SPDX-License-Identifier: MIT

package app_test

import (
	"math/big"
	"net/http"
	"testing"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/ledger"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/testenv"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/withdrawal"
)

func TestSimHappyPath(t *testing.T) {
	e := testenv.New(t, 1)
	e.FundUser("alice", 900_000_000)
	avail, err := ledger.Available(e.Ctx, e.App.DB, "alice", testenv.Asset)
	if err != nil || avail.Cmp(big.NewInt(900_000_000)) != 0 {
		t.Fatalf("available = %v, %v", avail, err)
	}
	dest := testenv.Addr(1)
	e.Allowlist("alice", dest)
	id := testenv.CreatedID(t, e.Create("k1", "alice", 100_000_000, dest))
	e.RunUntil(40, func() bool { return e.Status(id) == withdrawal.Confirmed })

	if got := e.Chain.TokenBalance(testenv.TokenAddr, dest); got.Cmp(big.NewInt(100_000_000)) != 0 {
		t.Fatalf("destination balance %s", got)
	}
	avail, _ = ledger.Available(e.Ctx, e.App.DB, "alice", testenv.Asset)
	if avail.Cmp(big.NewInt(800_000_000)) != 0 {
		t.Fatalf("available after withdrawal = %s", avail)
	}
	e.CheckInvariants()
}

func TestSimIdempotentReplay(t *testing.T) {
	e := testenv.New(t, 2)
	e.FundUser("bob", 500_000_000)
	dest := testenv.Addr(2)
	e.Allowlist("bob", dest)
	first := e.Create("same-key", "bob", 10, dest)
	second := e.Create("same-key", "bob", 10, dest)
	if !second.Replayed || second.Code != first.Code || string(second.Body) != string(first.Body) {
		t.Fatalf("replay mismatch: %+v vs %+v", first, second)
	}
	conflict := e.Create("same-key", "bob", 11, dest)
	if conflict.Code != http.StatusUnprocessableEntity {
		t.Fatalf("reused key with a different body must be 422, got %d", conflict.Code)
	}
	all, _ := withdrawal.All(e.Ctx, e.App.DB)
	if len(all) != 1 {
		t.Fatalf("expected one withdrawal, got %d", len(all))
	}
}
