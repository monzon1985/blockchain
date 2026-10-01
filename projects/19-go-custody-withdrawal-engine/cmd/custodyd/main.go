// SPDX-License-Identifier: MIT

// Command custodyd runs the custodial withdrawal and deposit engine. See internal/cli for the
// subcommands; SIGINT and SIGTERM trigger a graceful shutdown.
package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/cli"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	code := cli.Run(ctx, os.Args[1:], cli.IO{In: os.Stdin, Out: os.Stdout, Err: os.Stderr})
	stop()
	os.Exit(code)
}
