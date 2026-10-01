// SPDX-License-Identifier: MIT

// Command indexer is a reorg-safe EVM event indexer with a REST and SSE query API.
//
//	indexer index  --rpc-url URL --token 0x... [--vault 0x...] [--db indexer.db]
//	indexer serve  --rpc-url URL --token 0x... [--listen 127.0.0.1:8080]
//	indexer verify --rpc-url URL [--db indexer.db]
//
// SIGINT and SIGTERM trigger a graceful shutdown: the running commit finishes, the checkpoint
// is durable, HTTP connections drain, and the next start resumes from the checkpoint.
package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/app"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	code := app.Main(ctx, os.Args[1:], os.Stdout, os.Stderr)
	stop()
	os.Exit(code)
}
