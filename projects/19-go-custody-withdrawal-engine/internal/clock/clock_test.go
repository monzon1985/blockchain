// SPDX-License-Identifier: MIT

package clock_test

import (
	"testing"
	"time"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/clock"
)

func TestClocks(t *testing.T) {
	if now := (clock.Real{}).Now(); now.Location() != time.UTC || time.Since(now) > time.Minute {
		t.Fatalf("real clock: %s", now)
	}
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.FixedZone("x", 3600))
	f := clock.NewFake(start)
	f.Advance(time.Hour)
	if !f.Now().Equal(start.Add(time.Hour)) || f.Now().Location() != time.UTC {
		t.Fatalf("fake clock: %s", f.Now())
	}
	f.Set(start)
	if !f.Now().Equal(start) {
		t.Fatal("Set")
	}
}
