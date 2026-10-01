// SPDX-License-Identifier: MIT

package retry

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestDelaySchedule(t *testing.T) {
	p := Policy{Initial: 100 * time.Millisecond, Max: time.Second, Multiplier: 2}
	tests := []struct {
		attempt int
		want    time.Duration
	}{
		{0, 0},
		{1, 0},
		{2, 100 * time.Millisecond},
		{3, 200 * time.Millisecond},
		{4, 400 * time.Millisecond},
		{5, 800 * time.Millisecond},
		{6, time.Second},
		{20, time.Second},
	}
	for _, tc := range tests {
		if got := p.Delay(tc.attempt); got != tc.want {
			t.Fatalf("Delay(%d) = %s want %s", tc.attempt, got, tc.want)
		}
	}
}

func TestDelayJitterBounds(t *testing.T) {
	for _, r := range []float64{0, 0.5, 0.999} {
		p := Policy{Initial: time.Second, Max: 10 * time.Second, Multiplier: 2, Jitter: 0.25, Rand: func() float64 { return r }}
		d := p.Delay(2)
		if d < 750*time.Millisecond || d > 1250*time.Millisecond {
			t.Fatalf("jittered delay %s out of bounds for r=%v", d, r)
		}
	}
	p := Policy{Initial: time.Second, Max: time.Second, Multiplier: 1, Jitter: 0.5, Rand: func() float64 { return 0.99 }}
	if p.Delay(2) != time.Second {
		t.Fatal("jitter must not exceed Max")
	}
}

func TestDoRetriesTransientErrors(t *testing.T) {
	calls := 0
	n, err := Do(context.Background(), Policy{Attempts: 5, Initial: time.Millisecond}, func(context.Context) error {
		calls++
		if calls < 3 {
			return errors.New("transient")
		}
		return nil
	})
	if err != nil || n != 3 || calls != 3 {
		t.Fatalf("n=%d calls=%d err=%v", n, calls, err)
	}
}

func TestDoStopsOnPermanentAndExhaustion(t *testing.T) {
	sentinel := errors.New("reverted")
	calls := 0
	n, err := Do(context.Background(), Policy{Attempts: 5, Initial: time.Millisecond}, func(context.Context) error {
		calls++
		return Permanent(sentinel)
	})
	if !errors.Is(err, sentinel) || IsPermanent(err) || n != 1 || calls != 1 {
		t.Fatalf("permanent: n=%d err=%v", n, err)
	}

	calls = 0
	n, err = Do(context.Background(), Policy{Attempts: 3, Initial: time.Millisecond}, func(context.Context) error {
		calls++
		return errors.New("down")
	})
	if err == nil || n != 3 || calls != 3 {
		t.Fatalf("exhaustion: n=%d calls=%d err=%v", n, calls, err)
	}
	if Permanent(nil) != nil {
		t.Fatal("Permanent(nil) must be nil")
	}
}

func TestDoHonoursContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	calls := 0
	done := make(chan struct{})
	var err error
	go func() {
		_, err = Do(ctx, Policy{Attempts: 10, Initial: time.Hour}, func(context.Context) error {
			calls++
			return errors.New("down")
		})
		close(done)
	}()
	time.Sleep(20 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Do ignored cancellation")
	}
	if !errors.Is(err, context.Canceled) || calls != 1 {
		t.Fatalf("calls=%d err=%v", calls, err)
	}
}
