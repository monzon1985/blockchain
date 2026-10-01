// SPDX-License-Identifier: MIT

package failpoint_test

import (
	"testing"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/failpoint"
)

func mustPanic(t *testing.T, f func()) (v any) {
	t.Helper()
	defer func() { v = recover() }()
	f()
	t.Fatal("expected a panic")
	return nil
}

func TestHitFiresOnceAndOnlyWhenArmed(t *testing.T) {
	s, err := failpoint.New(failpoint.AfterSign)
	if err != nil {
		t.Fatal(err)
	}
	s.Hit(failpoint.BeforeSign) // not armed
	v := mustPanic(t, func() { s.Hit(failpoint.AfterSign) })
	c, ok := failpoint.AsCrash(v)
	if !ok || c.Name != failpoint.AfterSign || c.Error() != "failpoint: after_sign" {
		t.Fatalf("panic value %v", v)
	}
	s.Hit(failpoint.AfterSign) // fired once already: now disarmed
	if s.Hits(failpoint.AfterSign) != 2 || s.Hits(failpoint.BeforeSign) != 1 || s.Armed() {
		t.Fatalf("hits/armed bookkeeping wrong")
	}
	s.Arm(failpoint.BeforeConfirm)
	if !s.Armed() {
		t.Fatal("Arm did not arm")
	}
	s.Disarm()
	s.Hit(failpoint.BeforeConfirm)
}

func TestUnknownNamesAreRejected(t *testing.T) {
	if _, err := failpoint.New("before_sgin"); err == nil {
		t.Fatal("typo accepted")
	}
	if _, err := failpoint.New(" ", ""); err != nil {
		t.Fatalf("blank entries should be ignored: %v", err)
	}
}

func TestFromEnv(t *testing.T) {
	t.Setenv(failpoint.EnvVar, "after_broadcast, before_confirm")
	s, err := failpoint.FromEnv()
	if err != nil || !s.Armed() {
		t.Fatalf("%v", err)
	}
	mustPanic(t, func() { s.Hit(failpoint.BeforeConfirm) })
	mustPanic(t, func() { s.Hit(failpoint.AfterBroadcast) })
	t.Setenv(failpoint.EnvVar, "nope")
	if _, err := failpoint.FromEnv(); err == nil {
		t.Fatal("unknown env failpoint accepted")
	}
}

func TestNilSetIsDisarmed(t *testing.T) {
	var s *failpoint.Set
	s.Hit(failpoint.AfterSign)
	if s.Armed() || s.Hits(failpoint.AfterSign) != 0 {
		t.Fatal("nil set misbehaves")
	}
	if len(failpoint.All) != 7 {
		t.Fatalf("the chaos suite expects 7 failpoints, have %d", len(failpoint.All))
	}
	if _, ok := failpoint.AsCrash("x"); ok {
		t.Fatal("non-crash value recognised as a crash")
	}
}
