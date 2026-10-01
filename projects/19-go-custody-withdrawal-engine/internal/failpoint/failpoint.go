// SPDX-License-Identifier: MIT

// Package failpoint implements the named crash points used by the chaos tests.
//
// Production code calls Set.Hit at every step of the withdrawal state machine where a crash
// would leave a different durable state behind. When the process is started with
// CUSTODY_FAILPOINT=<name>[,<name>...], the first time execution reaches an armed point it
// panics with a Crash value. Nothing else changes: a disarmed Set costs one map lookup.
package failpoint

import (
	"fmt"
	"os"
	"slices"
	"strings"
	"sync"
)

// EnvVar is the environment variable read by FromEnv.
const EnvVar = "CUSTODY_FAILPOINT"

// The seven crash points of the withdrawal state machine, in lifecycle order.
const (
	// AfterRequestCommit fires after the withdrawal and its idempotency record are committed,
	// before the HTTP response is written. The client sees a dropped connection and retries.
	AfterRequestCommit = "after_request_commit"
	// AfterApprove fires after requested -> approved and the signing intent are committed.
	AfterApprove = "after_approve"
	// BeforeSign fires after a nonce has been reserved and committed, before signing.
	BeforeSign = "before_sign"
	// AfterSign fires after the signed transaction is persisted (write-ahead), before broadcast.
	AfterSign = "after_sign"
	// AfterBroadcast fires after the node accepted the transaction, before that is recorded.
	AfterBroadcast = "after_broadcast"
	// AfterBumpBroadcast fires after a fee-bumped replacement was accepted, before it is recorded.
	AfterBumpBroadcast = "after_bump_broadcast"
	// BeforeConfirm fires once a receipt reached the confirmation depth, before the confirmed
	// state and the final ledger entry are committed.
	BeforeConfirm = "before_confirm"
)

// All lists every failpoint name in lifecycle order.
var All = []string{
	AfterRequestCommit, AfterApprove, BeforeSign, AfterSign,
	AfterBroadcast, AfterBumpBroadcast, BeforeConfirm,
}

// Crash is the panic value raised by an armed failpoint.
type Crash struct {
	// Name is the failpoint that fired.
	Name string
}

// Error implements error so a recovered Crash prints well.
func (c Crash) Error() string { return "failpoint: " + c.Name }

// Set holds the armed failpoints of one process. The zero value and a nil *Set are disarmed.
type Set struct {
	mu    sync.Mutex
	armed map[string]bool
	hits  map[string]int
}

// New returns a Set with the given names armed. Unknown names are rejected so a typo in a
// chaos test cannot silently disable the crash it was meant to cause.
func New(names ...string) (*Set, error) {
	s := &Set{armed: map[string]bool{}, hits: map[string]int{}}
	for _, n := range names {
		n = strings.TrimSpace(n)
		if n == "" {
			continue
		}
		if !slices.Contains(All, n) {
			return nil, fmt.Errorf("failpoint: unknown name %q (known: %s)", n, strings.Join(All, ", "))
		}
		s.armed[n] = true
	}
	return s, nil
}

// FromEnv builds a Set from CUSTODY_FAILPOINT.
func FromEnv() (*Set, error) {
	return New(strings.Split(os.Getenv(EnvVar), ",")...)
}

// Hit records that execution reached name and panics with Crash if name is armed. Each armed
// point fires once: a process that recovers the panic (the in-process simulator does) keeps
// running with that point disarmed, exactly like a restarted process started without it.
func (s *Set) Hit(name string) {
	if s == nil {
		return
	}
	s.mu.Lock()
	if s.hits == nil {
		s.hits = map[string]int{}
	}
	s.hits[name]++
	fire := s.armed[name]
	delete(s.armed, name)
	s.mu.Unlock()
	if fire {
		panic(Crash{Name: name})
	}
}

// Arm arms name (used by the in-process simulator between steps).
func (s *Set) Arm(name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.armed == nil {
		s.armed = map[string]bool{}
	}
	s.armed[name] = true
}

// Disarm clears every armed point.
func (s *Set) Disarm() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.armed = map[string]bool{}
}

// Hits reports how many times name was reached, armed or not.
func (s *Set) Hits(name string) int {
	if s == nil {
		return 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.hits[name]
}

// Armed reports whether any point is still armed.
func (s *Set) Armed() bool {
	if s == nil {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.armed) > 0
}

// AsCrash reports whether a recovered panic value is a failpoint crash.
func AsCrash(v any) (Crash, bool) {
	c, ok := v.(Crash)
	return c, ok
}

// ExitCode is the status a process exits with after a failpoint crash. It matches the status
// of an unrecovered Go panic so the chaos harness can treat both the same way.
const ExitCode = 2

// Die prints the crash like the Go runtime prints an unrecovered panic and exits the process.
// It exists because net/http recovers panics raised on connection goroutines: without it, the
// after_request_commit failpoint would only kill one request instead of the process.
func Die(c Crash) {
	fmt.Fprintf(os.Stderr, "panic: %s [recovered from an HTTP handler and re-raised as a crash]\n", c.Error())
	os.Exit(ExitCode)
}
