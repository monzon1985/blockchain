// SPDX-License-Identifier: MIT

package withdrawal

import (
	"testing"
	"time"
)

func TestBackoffDoublesAndCaps(t *testing.T) {
	want := []time.Duration{200 * time.Millisecond, 400 * time.Millisecond, 800 * time.Millisecond, 1600 * time.Millisecond}
	for i, w := range want {
		if got := backoff(i); got != w {
			t.Fatalf("backoff(%d) = %s, want %s", i, got, w)
		}
	}
	for _, n := range []int{8, 20, 1000} {
		if got := backoff(n); got != maxBackoff {
			t.Fatalf("backoff(%d) = %s, want the %s cap", n, got, maxBackoff)
		}
	}
}
