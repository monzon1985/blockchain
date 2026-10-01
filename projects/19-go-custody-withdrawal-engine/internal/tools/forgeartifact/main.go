// SPDX-License-Identifier: MIT

// Command forgeartifact extracts the ABI and creation bytecode of a contract from a Foundry
// build artifact (out/<File>.sol/<Contract>.json) into the .abi/.bin pair abigen consumes.
//
// The output is normalised (compact JSON, lower-case hex, trailing newline) so that
// `go generate ./... && git diff --exit-code -- internal/bindings` is a reliable check that
// the committed bindings match the contracts.
//
//	go run ./internal/tools/forgeartifact -artifact <path.json> -out <dir> [-name <Name>]
//	go run ./internal/tools/forgeartifact -spdx a.go,b.go
//
// The second form prepends the repository's SPDX license header to files abigen just wrote
// (abigen cannot emit one), so generated sources carry it like every other file.
package main

import (
	"bytes"
	"encoding/json"
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

func main() {
	path := flag.String("artifact", "", "path to the Foundry artifact JSON")
	out := flag.String("out", ".", "output directory")
	name := flag.String("name", "", "base name of the output files (default: artifact file name)")
	spdx := flag.String("spdx", "", "comma-separated generated Go files to prepend the SPDX header to")
	flag.Parse()
	var err error
	if *spdx != "" {
		err = prependSPDX(strings.Split(*spdx, ","))
	} else {
		err = run(*path, *out, *name)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "forgeartifact:", err)
		os.Exit(1)
	}
}

const spdxHeader = "// SPDX-License-Identifier: MIT\n\n"

// prependSPDX adds the license header to each file that does not start with it.
func prependSPDX(files []string) error {
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			return err
		}
		if bytes.HasPrefix(b, []byte(spdxHeader)) {
			continue
		}
		if err := os.WriteFile(f, append([]byte(spdxHeader), b...), 0o644); err != nil {
			return err
		}
	}
	return nil
}

func run(path, out, name string) error {
	if path == "" {
		return fmt.Errorf("-artifact is required")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read artifact (run `forge build` in contracts/ first): %w", err)
	}
	var a artifact
	if err := json.Unmarshal(raw, &a); err != nil {
		return fmt.Errorf("decode %s: %w", path, err)
	}
	if len(a.ABI) == 0 {
		return fmt.Errorf("%s has no abi", path)
	}
	var abi bytes.Buffer
	if err := json.Compact(&abi, a.ABI); err != nil {
		return fmt.Errorf("compact abi: %w", err)
	}
	abi.WriteByte('\n')
	bin := strings.ToLower(strings.TrimPrefix(a.Bytecode.Object, "0x"))
	if name == "" {
		name = strings.TrimSuffix(filepath.Base(path), ".json")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(out, name+".abi"), abi.Bytes(), 0o644); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(out, name+".bin"), []byte(bin+"\n"), 0o644)
}
