// SPDX-License-Identifier: MIT

package cli

import (
	"context"
	"os"
	"syscall"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestSignalContextHandlesSIGTERM pins the regression where only os.Interrupt cancelled the
// command, so SIGTERM (what CI runners, containers and process managers send) killed it
// without a clean shutdown. signal_unix_test.go delivers a real SIGTERM.
func TestSignalContextHandlesSIGTERM(t *testing.T) {
	require.Contains(t, shutdownSignals, os.Signal(syscall.SIGTERM))
	require.Contains(t, shutdownSignals, os.Interrupt)

	ctx, stop := SignalContext(context.Background())
	require.NoError(t, ctx.Err())
	stop()
	require.ErrorIs(t, ctx.Err(), context.Canceled)
}
