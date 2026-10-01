// SPDX-License-Identifier: MIT

//go:build integration

package integration

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/internal/devnet"
)

var (
	buildOnce sync.Once
	trieBin   string
	buildErr  error
)

func TestMain(m *testing.M) {
	code := m.Run()
	if trieBin != "" {
		_ = os.RemoveAll(filepath.Dir(trieBin))
	}
	os.Exit(code)
}

// binary builds the trie command once (CGO_ENABLED=0, as shipped).
func binary(t *testing.T) string {
	t.Helper()
	buildOnce.Do(func() {
		dir, err := os.MkdirTemp("", "trie-it-")
		if err != nil {
			buildErr = err
			return
		}
		name := "trie"
		if runtime.GOOS == "windows" {
			name += ".exe"
		}
		trieBin = filepath.Join(dir, name)
		cmd := exec.Command("go", "build", "-o", trieBin, "../cmd/trie")
		cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
		if out, err := cmd.CombinedOutput(); err != nil {
			buildErr = errors.New(string(out))
		}
	})
	require.NoError(t, buildErr)
	return trieBin
}

func runTrie(t *testing.T, args ...string) (string, string, int) {
	t.Helper()
	cmd := exec.Command(binary(t), args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	code := 0
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		code = exit.ExitCode()
	} else {
		require.NoError(t, err)
	}
	return stdout.String(), stderr.String(), code
}

func TestCLIEndToEnd(t *testing.T) {
	n, sc := scenario(t, "osaka")
	sw := sc.SlotWriter.Hex()

	out, stderr, code := runTrie(t, "verify-block", "2", "--rpc", n.URL)
	require.Equal(t, 0, code, stderr)
	require.Contains(t, out, "verdict: VERIFIED (13 checks)")

	out, _, code = runTrie(t, "verify-block", "--rpc", n.URL, "--json", "latest")
	require.Equal(t, 0, code)
	var rep struct {
		Number uint64 `json:"number"`
		Checks []struct {
			Status string `json:"status"`
		} `json:"checks"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &rep))
	require.Equal(t, sc.Head, rep.Number)
	for _, c := range rep.Checks {
		require.Equal(t, "ok", c.Status)
	}

	slot := devnet.Slot(devnet.ScenarioSeed, 99).Hex()
	out, stderr, code = runTrie(t, "verify-proof", "--rpc", n.URL, "--address", sw, "--slot", slot, "--slot", "0")
	require.Equal(t, 0, code, stderr)
	require.Contains(t, out, "verdict: VERIFIED")

	// The full slot list rebuilds the storage root; dropping one live slot breaks it.
	var lines []string
	for i := range uint64(devnet.ScenarioWrites) {
		lines = append(lines, devnet.Slot(devnet.ScenarioSeed, i).Hex())
	}
	full := filepath.Join(t.TempDir(), "slots.txt")
	require.NoError(t, os.WriteFile(full, []byte(strings.Join(lines, "\n")), 0o644))
	out, stderr, code = runTrie(t, "storage-root", "--rpc", n.URL, "--address", sw, "--slots-file", full)
	require.Equal(t, 0, code, stderr)
	require.Contains(t, out, "150 non-zero")
	partial := filepath.Join(t.TempDir(), "partial.txt")
	require.NoError(t, os.WriteFile(partial, []byte(strings.Join(lines[:len(lines)-1], "\n")), 0o644))
	out, _, code = runTrie(t, "storage-root", "--rpc", n.URL, "--address", sw, "--slots-file", partial)
	require.Equal(t, 1, code, out)
	require.Contains(t, out, "verdict: FAILED")

	// A node that lies about a slot value: exit status 1.
	liar := lyingNode(t, n, only("eth_getProof", func(_ string, _, r json.RawMessage) json.RawMessage {
		return edit(t, r, func(v any) any {
			obj(obj(v)["storageProof"].([]any)[0])["value"] = "0x2a"
			return v
		})
	}))
	out, _, code = runTrie(t, "verify-proof", "--rpc", liar, "--address", sw, "--slot", slot)
	require.Equal(t, 1, code, out)
	require.Contains(t, out, "MISMATCH")
}

func TestCLIStrictOnAnvilGenesisQuirk(t *testing.T) {
	n := startNode(t, "london")
	out, _, code := runTrie(t, "verify-block", "0", "--rpc", n.URL)
	require.Equal(t, 0, code, out)
	require.Contains(t, out, "present-only layout")
	_, _, code = runTrie(t, "verify-block", "0", "--rpc", n.URL, "--strict")
	require.Equal(t, 1, code, "--strict refuses the mixed-era genesis header")
}

func TestCLIUnreachableNode(t *testing.T) {
	n := startNode(t, "")
	url := n.URL
	require.NoError(t, n.Close()) // stopped by PID: nothing listens there any more
	_, stderr, code := runTrie(t, "verify-block", "1", "--rpc", url, "--timeout", "10s")
	require.Equal(t, 2, code)
	require.NotEmpty(t, stderr)
}

// TestRecordedFixturesAreReproducible re-records the CLI golden cassettes on a fresh anvil
// chain and requires them to match the committed ones byte for byte: the offline golden
// tests replay exactly what anvil 1.8.3 answers today.
func TestRecordedFixturesAreReproducible(t *testing.T) {
	out := t.TempDir()
	cmd := exec.Command("go", "run", "./internal/tools/recordfixtures", "-out", out)
	cmd.Dir = ".."
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
	logs, err := cmd.CombinedOutput()
	require.NoError(t, err, string(logs))

	committed := filepath.Join("..", "internal", "cli", "testdata")
	entries, err := os.ReadDir(out)
	require.NoError(t, err)
	require.NotEmpty(t, entries)
	for _, e := range entries {
		got, err := os.ReadFile(filepath.Join(out, e.Name()))
		require.NoError(t, err)
		want, err := os.ReadFile(filepath.Join(committed, e.Name()))
		require.NoError(t, err, "committed fixture %s", e.Name())
		require.Equal(t, strings.ReplaceAll(string(want), "\r\n", "\n"), string(got), "fixture %s differs from a fresh recording", e.Name())
	}
}
