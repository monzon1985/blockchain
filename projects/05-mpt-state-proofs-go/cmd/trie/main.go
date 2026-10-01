// SPDX-License-Identifier: MIT

// Command trie verifies what an Ethereum node reports: block hashes, transactionsRoot,
// receiptsRoot and the logs bloom recomputed from raw data, and eth_getProof account and
// storage proofs checked against a verified block. Run `trie help` for usage.
package main

import (
	"context"
	"os"
	"os/signal"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/internal/cli"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	code := cli.Run(ctx, os.Args[1:], os.Stdout, os.Stderr)
	stop()
	os.Exit(code)
}
