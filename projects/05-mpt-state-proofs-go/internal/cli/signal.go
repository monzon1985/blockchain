// SPDX-License-Identifier: MIT

package cli

import (
	"context"
	"os"
	"os/signal"
	"syscall"
)

// shutdownSignals cancel a running command: os.Interrupt (Ctrl-C) and SIGTERM, which process
// managers, containers and CI runners send to stop a process. On Windows, Go delivers the
// console close, logoff and shutdown events as SIGTERM.
var shutdownSignals = []os.Signal{os.Interrupt, syscall.SIGTERM}

// SignalContext returns a copy of parent that is cancelled by the first shutdown signal, so a
// command stops its RPC calls and returns instead of being killed mid-report. The returned
// stop function cancels the context and restores the default signal behaviour.
func SignalContext(parent context.Context) (context.Context, context.CancelFunc) {
	return signal.NotifyContext(parent, shutdownSignals...)
}
