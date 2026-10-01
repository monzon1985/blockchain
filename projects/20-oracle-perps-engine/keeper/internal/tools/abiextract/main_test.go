// SPDX-License-Identifier: MIT

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeArtifact(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, name+".sol"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name+".sol", name+".json"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestRun(t *testing.T) {
	art := t.TempDir()
	writeArtifact(t, art, "Good", `{"abi":[{"type":"function","name":"f","inputs":[],"outputs":[]}],"bytecode":{"object":"0x6000"}}`)
	writeArtifact(t, art, "NoBin", `{"abi":[],"bytecode":{"object":"0x"}}`)
	writeArtifact(t, art, "Linked", `{"abi":[],"bytecode":{"object":"0x60__$abc$__"}}`)
	writeArtifact(t, art, "NoAbi", `{"bytecode":{"object":"0x6000"}}`)
	writeArtifact(t, art, "Broken", `{`)

	tests := []struct {
		name      string
		dir       string
		contracts []string
		wantErr   string
	}{
		{"abi and bin", art, []string{"Good:bin", "NoBin"}, ""},
		{"no arguments", art, nil, "usage"},
		{"missing artifacts dir", filepath.Join(art, "nope"), []string{"Good"}, "forge build"},
		{"missing contract", art, []string{"Missing"}, "read"},
		{"missing bytecode", art, []string{"NoBin:bin"}, "missing or unlinked"},
		{"unlinked library", art, []string{"Linked:bin"}, "missing or unlinked"},
		{"missing abi", art, []string{"NoAbi"}, "no abi"},
		{"malformed json", art, []string{"Broken"}, "decode"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			out := filepath.Join(t.TempDir(), "combined.json")
			err := run(tc.dir, out, tc.contracts)
			if tc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("got %v, want error containing %q", err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			var doc combined
			raw, _ := os.ReadFile(out)
			if err := json.Unmarshal(raw, &doc); err != nil {
				t.Fatal(err)
			}
			if doc.Contracts["Good.sol:Good"].Bin != "6000" || doc.Contracts["NoBin.sol:NoBin"].Bin != "" {
				t.Fatalf("unexpected output: %s", raw)
			}
		})
	}
}
