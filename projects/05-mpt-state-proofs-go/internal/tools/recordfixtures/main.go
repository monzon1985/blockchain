// SPDX-License-Identifier: MIT

// Command recordfixtures records the JSON-RPC sessions behind the CLI golden tests. It builds
// the standard scenario on a fresh anvil chain with fixed timestamps, runs each CLI case
// through a recording proxy, and writes one cassette per case plus a manifest to
// internal/cli/testdata. The golden tests replay those cassettes offline.
//
// Usage (from the module root, after `forge build` in fixtures/):
//
//	go run ./internal/tools/recordfixtures
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http/httptest"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"time"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/internal/cli"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/internal/devnet"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/internal/rpcreplay"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
)

// Case is one CLI invocation of the golden suite. Args use {rpc} for the endpoint.
type Case struct {
	Name string   `json:"name"`
	Args []string `json:"args"`
	Exit int      `json:"exit"`
}

// Hardfork of the recorded chain.
const Hardfork = "osaka"

func main() {
	out := flag.String("out", filepath.Join("internal", "cli", "testdata"), "output directory")
	fixtures := flag.String("fixtures", "fixtures", "Foundry project with the built SlotWriter")
	flag.Parse()
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	if err := record(ctx, log, *out, *fixtures); err != nil {
		log.Error("recording failed", "err", err)
		os.Exit(1)
	}
}

func record(ctx context.Context, log *slog.Logger, out, fixtures string) error {
	code, err := devnet.LoadSlotWriter(fixtures)
	if err != nil {
		return err
	}
	node, err := devnet.Start(ctx, devnet.Options{Hardfork: Hardfork, GenesisTimestamp: devnet.GenesisTimestamp})
	if err != nil {
		return err
	}
	defer node.Close()
	log.Info("anvil started", "url", node.URL, "hardfork", Hardfork)
	sc, err := devnet.RunScenario(ctx, node, code, true)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}

	// The slot list for storage-root: every slot the scenario wrote, including the 50 it
	// cleared (they read as zero and are skipped by the rebuild).
	var slots strings.Builder
	fmt.Fprintf(&slots, "# The %d slots SlotWriter.write(%d, %d) touched; %d were cleared later.\n",
		devnet.ScenarioWrites, devnet.ScenarioSeed, devnet.ScenarioWrites, devnet.ScenarioCleared)
	for i := range uint64(devnet.ScenarioWrites) {
		fmt.Fprintln(&slots, devnet.Slot(devnet.ScenarioSeed, i).Hex())
	}
	slotsFile := filepath.Join(out, "slots.txt")
	if err := os.WriteFile(slotsFile, []byte(slots.String()), 0o644); err != nil {
		return err
	}

	sw := sc.SlotWriter.Hex()
	cleared := devnet.Slot(devnet.ScenarioSeed, 0).Hex()
	live := devnet.Slot(devnet.ScenarioSeed, 60).Hex()
	absent := keccak.Address{0xde, 0xad}.Hex()
	cases := []Case{
		{Name: "verify-block-0", Args: []string{"verify-block", "--rpc", "{rpc}", "0"}},
		{Name: "verify-block-1", Args: []string{"verify-block", "--rpc", "{rpc}", "1"}},
		{Name: "verify-block-2", Args: []string{"verify-block", "--rpc", "{rpc}", "2"}},
		{Name: "verify-block-3", Args: []string{"verify-block", "3", "--rpc", "{rpc}"}},
		{Name: "verify-block-latest-json", Args: []string{"verify-block", "--rpc", "{rpc}", "--json", "latest"}},
		{Name: "verify-proof-contract", Args: []string{"verify-proof", "--rpc", "{rpc}", "--address", sw, "--slot", live, "--slot", cleared, "--slot", "0", "--block", "3"}},
		{Name: "verify-proof-eoa", Args: []string{"verify-proof", "--rpc", "{rpc}", "--address", sc.Sender.Hex(), "--block", "3"}},
		{Name: "verify-proof-absent", Args: []string{"verify-proof", "--rpc", "{rpc}", "--address", absent, "--slot", "1", "--block", "3"}},
		{Name: "verify-proof-json", Args: []string{"verify-proof", "--rpc", "{rpc}", "--json", "--address", sw, "--slot", live, "--block", "2"}},
		{Name: "storage-root", Args: []string{"storage-root", "--rpc", "{rpc}", "--address", sw, "--slots-file", "testdata/slots.txt", "--block", "3"}},
	}
	for i, c := range cases {
		proxy := &rpcreplay.Proxy{Upstream: node.URL, Record: true}
		srv := httptest.NewServer(proxy)
		args := make([]string, len(c.Args))
		for j, a := range c.Args {
			args[j] = strings.ReplaceAll(a, "{rpc}", srv.URL)
			if a == "testdata/slots.txt" {
				args[j] = slotsFile
			}
		}
		var stdout, stderr bytes.Buffer
		cases[i].Exit = cli.Run(ctx, args, &stdout, &stderr)
		srv.Close()
		if cases[i].Exit == cli.ExitUsage {
			return fmt.Errorf("case %s: %s", c.Name, stderr.String())
		}
		if err := proxy.Cassette().Save(filepath.Join(out, c.Name+".cassette.json")); err != nil {
			return err
		}
		log.Info("recorded", "case", c.Name, "exit", cases[i].Exit, "calls", len(proxy.Cassette().Calls))
		_, _ = io.Copy(io.Discard, &stdout)
	}
	manifest, err := json.MarshalIndent(cases, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(out, "cases.json"), append(manifest, '\n'), 0o644)
}
