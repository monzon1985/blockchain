// SPDX-License-Identifier: MIT

// Command abiextract assembles Foundry build artifacts into a solc-style `--combined-json` document that abigen
// binds in a single pass (so struct types shared by several contracts are generated once). It is run by
// `go generate ./...` in internal/bindings after `forge build`.
//
// Usage:
//
//	abiextract -artifacts ../../../contracts/out -out combined.json PerpsMarket:bin OrderBook LPVault ...
//
// A contract name suffixed with ":bin" also carries its creation bytecode (abigen then emits a Deploy helper).
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type artifact struct {
	ABI      json.RawMessage `json:"abi"`
	Bytecode struct {
		Object string `json:"object"`
	} `json:"bytecode"`
}

type combinedContract struct {
	ABI json.RawMessage `json:"abi"`
	Bin string          `json:"bin"`
}

type combined struct {
	Contracts map[string]combinedContract `json:"contracts"`
	Version   string                      `json:"version"`
}

func main() {
	artifacts := flag.String("artifacts", "", "Foundry out/ directory")
	out := flag.String("out", "combined.json", "output file")
	flag.Parse()
	if err := run(*artifacts, *out, flag.Args()); err != nil {
		fmt.Fprintln(os.Stderr, "abiextract:", err)
		os.Exit(1)
	}
}

func run(artifactsDir, outFile string, contracts []string) error {
	if artifactsDir == "" || len(contracts) == 0 {
		return errors.New("usage: abiextract -artifacts DIR -out FILE Contract[:bin]...")
	}
	if _, err := os.Stat(artifactsDir); err != nil {
		return fmt.Errorf("artifacts not found at %s: run `forge build` in contracts/ first: %w", artifactsDir, err)
	}
	doc := combined{Contracts: make(map[string]combinedContract, len(contracts)), Version: "0.8.37"}
	for _, spec := range contracts {
		name, withBin := strings.CutSuffix(spec, ":bin")
		path := filepath.Join(artifactsDir, name+".sol", name+".json")
		raw, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("read %s: %w", path, err)
		}
		var a artifact
		if err := json.Unmarshal(raw, &a); err != nil {
			return fmt.Errorf("decode %s: %w", path, err)
		}
		if len(a.ABI) == 0 {
			return fmt.Errorf("%s has no abi", path)
		}
		entry := combinedContract{ABI: a.ABI}
		if withBin {
			entry.Bin = strings.TrimPrefix(a.Bytecode.Object, "0x")
			if entry.Bin == "" || strings.Contains(entry.Bin, "__$") {
				return fmt.Errorf("%s: missing or unlinked bytecode", name)
			}
		}
		doc.Contracts[name+".sol:"+name] = entry
	}
	encoded, err := json.MarshalIndent(doc, "", " ")
	if err != nil {
		return err
	}
	return os.WriteFile(outFile, append(encoded, '\n'), 0o644)
}
