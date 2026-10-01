// SPDX-License-Identifier: MIT

// Package retry runs an operation with capped exponential backoff and jitter, honouring context cancellation.
package retry

import (
	"context"
	"errors"
	"math/rand/v2"
	"time"
)

// Policy configures Do.
type Policy struct {
	// Attempts is the total number of tries (values < 1 mean 1).
	Attempts int
	// Initial is the delay before the second attempt.
	Initial time.Duration
	// Max caps every delay.
	Max time.Duration
	// Multiplier grows the delay after each failure (values < 1 mean 1).
	Multiplier float64
	// Jitter randomises each delay by up to +-Jitter (a fraction in [0, 1)).
	Jitter float64
	// Rand returns a uniform value in [0, 1); defaults to math/rand/v2.
	Rand func() float64
}

// DefaultPolicy suits JSON-RPC calls against a local or remote node.
var DefaultPolicy = Policy{Attempts: 4, Initial: 200 * time.Millisecond, Max: 3 * time.Second, Multiplier: 2, Jitter: 0.2}

type permanentError struct{ err error }

func (p permanentError) Error() string { return p.err.Error() }
func (p permanentError) Unwrap() error { return p.err }

// Permanent marks err as not worth retrying (e.g. a transaction that reverts in simulation).
func Permanent(err error) error {
	if err == nil {
		return nil
	}
	return permanentError{err}
}

// IsPermanent reports whether err was marked with Permanent.
func IsPermanent(err error) bool {
	var p permanentError
	return errors.As(err, &p)
}

// Delay is the wait before attempt number `attempt` (1-based; attempt 1 has no delay).
func (p Policy) Delay(attempt int) time.Duration {
	if attempt <= 1 {
		return 0
	}
	mult := p.Multiplier
	if mult < 1 {
		mult = 1
	}
	d := float64(p.Initial)
	for i := 2; i < attempt; i++ {
		d *= mult
		if p.Max > 0 && d >= float64(p.Max) {
			d = float64(p.Max)
			break
		}
	}
	if p.Jitter > 0 {
		r := rand.Float64
		if p.Rand != nil {
			r = p.Rand
		}
		d *= 1 + p.Jitter*(2*r()-1)
	}
	if p.Max > 0 && time.Duration(d) > p.Max {
		return p.Max
	}
	return time.Duration(d)
}

// Do calls fn until it succeeds, returns a Permanent error, the attempts are exhausted or ctx is done. It returns
// the number of attempts made and the last error (unwrapped from Permanent).
func Do(ctx context.Context, p Policy, fn func(context.Context) error) (int, error) {
	attempts := max(p.Attempts, 1)
	var err error
	for i := 1; i <= attempts; i++ {
		if d := p.Delay(i); d > 0 {
			t := time.NewTimer(d)
			select {
			case <-ctx.Done():
				t.Stop()
				return i - 1, errors.Join(err, ctx.Err())
			case <-t.C:
			}
		}
		if err = fn(ctx); err == nil {
			return i, nil
		}
		if IsPermanent(err) {
			return i, errors.Unwrap(err)
		}
		if ctx.Err() != nil {
			return i, errors.Join(err, ctx.Err())
		}
	}
	return attempts, err
}
