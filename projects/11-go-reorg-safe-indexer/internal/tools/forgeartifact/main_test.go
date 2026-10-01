// SPDX-License-Identifier: MIT

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestExtractNormalises(t *testing.T) {
	dir := t.TempDir()
	art := filepath.Join(dir, "Thing.json")
	raw := "{\r\n  \"abi\": [ { \"type\": \"function\", \"name\": \"f\" } ],\r\n  \"bytecode\": { \"object\": \"0xABCDef\" }\r\n}"
	if err := os.WriteFile(art, []byte(raw), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "out")
	if err := extract(art, out); err != nil {
		t.Fatal(err)
	}
	abi, _ := os.ReadFile(filepath.Join(out, "Thing.abi"))
	bin, _ := os.ReadFile(filepath.Join(out, "Thing.bin"))
	if string(abi) != `[{"type":"function","name":"f"}]`+"\n" {
		t.Fatalf("abi %q", abi)
	}
	if string(bin) != "abcdef\n" {
		t.Fatalf("bin %q", bin)
	}
}

func TestExtractErrors(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	cases := map[string]string{
		"missing flag":   "",
		"missing file":   filepath.Join(dir, "nope.json"),
		"not json":       write("bad.json", "{"),
		"no abi":         write("noabi.json", `{"bytecode":{"object":"0x00"}}`),
		"interface":      write("iface.json", `{"abi":[],"bytecode":{"object":"0x"}}`),
		"malformed abi":  write("badabi.json", `{"abi":{"x":,},"bytecode":{"object":"0x00"}}`),
		"unwritable out": write("ok.json", `{"abi":[],"bytecode":{"object":"0x00"}}`),
	}
	for name, artifact := range cases {
		out := filepath.Join(dir, "out-"+name)
		if name == "unwritable out" {
			out = write("a-file", "x") // a file where a directory must go
		}
		if err := extract(artifact, out); err == nil {
			t.Errorf("%s: no error", name)
		}
	}
}

func TestAddSPDX(t *testing.T) {
	dir := t.TempDir()
	gen := filepath.Join(dir, "gen.go")
	src := "// Code generated via abigen V2 - DO NOT EDIT.\n// This file is a generated binding.\n\npackage bindings\n"
	if err := os.WriteFile(gen, []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	want := "// Code generated via abigen V2 - DO NOT EDIT.\n// This file is a generated binding.\n// SPDX-License-Identifier: MIT\n\npackage bindings\n"
	for range 2 { // idempotent: a second run changes nothing
		if err := addSPDX("MIT", []string{gen}); err != nil {
			t.Fatal(err)
		}
		if got, _ := os.ReadFile(gen); string(got) != want {
			t.Fatalf("got %q, want %q", got, want)
		}
	}
	// Only generated files are touched, and only existing ones.
	hand := filepath.Join(dir, "hand.go")
	if err := os.WriteFile(hand, []byte("package bindings\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for name, files := range map[string][]string{
		"no files":     nil,
		"missing file": {filepath.Join(dir, "nope.go")},
		"hand-written": {hand},
	} {
		if err := addSPDX("MIT", files); err == nil {
			t.Errorf("%s: no error", name)
		}
	}
}
