// SPDX-License-Identifier: MIT

// Command forgeartifact turns a Foundry build artifact (contracts/out/<File>.sol/<Name>.json)
// into the <Name>.abi / <Name>.bin pair that abigen consumes, and adds the SPDX license header
// to the Go files abigen generates.
//
// The output is normalised (compact JSON ABI, lower-case hex bytecode without 0x, one trailing
// newline) so the files are byte-identical on every OS. CI regenerates the bindings and runs
// `git diff --exit-code -- internal/bindings`; normalisation keeps that check meaningful, and
// since the header is added by `go generate` itself, regenerated files stay byte-identical.
//
//	go run ./internal/tools/forgeartifact -artifact <path.json> -out <dir>
//	go run ./internal/tools/forgeartifact -spdx MIT <generated.go>...
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

func main() {
	artifact := flag.String("artifact", "", "Foundry artifact JSON (required unless -spdx is given)")
	out := flag.String("out", ".", "directory receiving <Name>.abi and <Name>.bin")
	spdx := flag.String("spdx", "", "add `// SPDX-License-Identifier: <id>` to the generated Go files given as arguments")
	flag.Parse()
	var err error
	if *spdx != "" {
		err = addSPDX(*spdx, flag.Args())
	} else {
		err = extract(*artifact, *out)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "forgeartifact:", err)
		os.Exit(1)
	}
}

// generatedRe is the Go convention for generated files (https://go.dev/s/generatedcode).
var generatedRe = regexp.MustCompile(`^// Code generated .* DO NOT EDIT\.$`)

// addSPDX adds an SPDX license line at the end of the leading comment block of each generated
// Go file. The "// Code generated ... DO NOT EDIT." line stays first, so gofmt, linters and
// code review tools still recognise the file as generated. A file that already has an SPDX line
// is left unchanged, which makes the step idempotent.
func addSPDX(id string, files []string) error {
	if len(files) == 0 {
		return errors.New("-spdx needs the generated files as arguments")
	}
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			return err
		}
		if bytes.Contains(raw, []byte("SPDX-License-Identifier:")) {
			continue
		}
		lines := strings.SplitAfter(string(raw), "\n")
		if !generatedRe.MatchString(strings.TrimRight(lines[0], "\r\n")) {
			return fmt.Errorf("%s: the first line is not a \"// Code generated ... DO NOT EDIT.\" comment", f)
		}
		end := 1
		for end < len(lines) && strings.HasPrefix(lines[end], "//") {
			end++
		}
		header := "// SPDX-License-Identifier: " + id + "\n"
		out := strings.Join(lines[:end], "") + header + strings.Join(lines[end:], "")
		if err := os.WriteFile(f, []byte(out), 0o644); err != nil {
			return err
		}
	}
	return nil
}

// extract writes the normalised ABI and creation bytecode of artifact into dir.
func extract(artifact, dir string) error {
	if artifact == "" {
		return errors.New("-artifact is required")
	}
	raw, err := os.ReadFile(artifact)
	if err != nil {
		return fmt.Errorf("read artifact (run `forge build` in contracts/ first): %w", err)
	}
	var parsed struct {
		ABI      json.RawMessage `json:"abi"`
		Bytecode struct {
			Object string `json:"object"`
		} `json:"bytecode"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return fmt.Errorf("decode %s: %w", artifact, err)
	}
	if len(parsed.ABI) == 0 {
		return fmt.Errorf("%s has no abi", artifact)
	}
	bin := strings.ToLower(strings.TrimPrefix(parsed.Bytecode.Object, "0x"))
	if bin == "" {
		return fmt.Errorf("%s has no creation bytecode (abstract contract or interface?)", artifact)
	}
	var abi bytes.Buffer
	if err := json.Compact(&abi, parsed.ABI); err != nil {
		return fmt.Errorf("compact abi: %w", err)
	}
	abi.WriteByte('\n')

	name := strings.TrimSuffix(filepath.Base(artifact), ".json")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, name+".abi"), abi.Bytes(), 0o644); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, name+".bin"), []byte(bin+"\n"), 0o644)
}
