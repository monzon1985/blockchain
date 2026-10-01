// SPDX-License-Identifier: MIT

// Command demo runs the trie command against a fresh local chain: it starts anvil on a free
// port, deploys the SlotWriter fixture, writes 200 storage slots and clears 50, then verifies
// blocks, proofs and the whole storage root, and stops anvil.
//
// Usage (from the module root, after `forge build` in fixtures/):
//
//	go run ./internal/tools/demo
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"time"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/internal/cli"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/internal/devnet"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	if err := run(ctx); err != nil {
		fmt.Fprintln(os.Stderr, "demo:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context) error {
	code, err := devnet.LoadSlotWriter("fixtures")
	if err != nil {
		return err
	}
	node, err := devnet.Start(ctx, devnet.Options{Hardfork: "osaka"})
	if err != nil {
		return err
	}
	defer node.Close()
	sc, err := devnet.RunScenario(ctx, node, code, true)
	if err != nil {
		return err
	}
	fmt.Printf("anvil on %s; SlotWriter at %s; head block %d\n\n", node.URL, sc.SlotWriter, sc.Head)

	dir, err := os.MkdirTemp("", "trie-demo-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	var lines []string
	for i := range uint64(devnet.ScenarioWrites) {
		lines = append(lines, devnet.Slot(devnet.ScenarioSeed, i).Hex())
	}
	slots := filepath.Join(dir, "slots.txt")
	if err := os.WriteFile(slots, []byte(strings.Join(lines, "\n")), 0o644); err != nil {
		return err
	}

	failed := 0
	for _, args := range [][]string{
		{"verify-block", "2"},
		{"verify-proof", "--address", sc.SlotWriter.Hex(), "--slot", devnet.Slot(devnet.ScenarioSeed, 60).Hex(), "--slot", devnet.Slot(devnet.ScenarioSeed, 0).Hex()},
		{"storage-root", "--address", sc.SlotWriter.Hex(), "--slots-file", slots},
	} {
		fmt.Printf("$ trie %s\n", strings.Join(args, " "))
		if cli.Run(ctx, append(args, "--rpc", node.URL), os.Stdout, os.Stderr) != cli.ExitVerified {
			failed++
		}
		fmt.Println()
	}
	if failed > 0 {
		return fmt.Errorf("%d command(s) did not verify", failed)
	}
	return nil
}
