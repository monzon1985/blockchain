// SPDX-License-Identifier: MIT

//go:build unix

package cli

import (
	"context"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// TestSIGTERMCancelsTheCommand sends SIGTERM to the test process itself. With the signal
// registered, it cancels the context; without it, the default action would kill the test
// binary and fail the package. (Unix only: Windows cannot send SIGTERM to a process.)
func TestSIGTERMCancelsTheCommand(t *testing.T) {
	ctx, stop := SignalContext(context.Background())
	defer stop()
	require.NoError(t, syscall.Kill(syscall.Getpid(), syscall.SIGTERM))
	select {
	case <-ctx.Done():
	case <-time.After(10 * time.Second):
		t.Fatal("SIGTERM did not cancel the context")
	}
}
