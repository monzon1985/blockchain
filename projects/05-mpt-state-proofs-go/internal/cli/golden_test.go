// SPDX-License-Identifier: MIT

package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/internal/rpcreplay"
)

// The golden tests replay JSON-RPC sessions recorded from anvil by
// internal/tools/recordfixtures (a deterministic chain: re-recording reproduces the cassettes
// byte for byte) and compare the CLI's output with testdata/golden/*.golden.
// Regenerate the golden files with: go test ./internal/cli -run Golden -update

var update = flag.Bool("update", false, "rewrite the golden files")

type goldenCase struct {
	Name string   `json:"name"`
	Args []string `json:"args"`
	Exit int      `json:"exit"`
}

func loadCases(t *testing.T) map[string]goldenCase {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "cases.json"))
	require.NoError(t, err)
	var list []goldenCase
	require.NoError(t, json.Unmarshal(raw, &list))
	require.NotEmpty(t, list)
	out := map[string]goldenCase{}
	for _, c := range list {
		out[c.Name] = c
	}
	return out
}

// replay serves a recorded cassette, optionally rewritten, and returns the CLI's output.
func replay(t *testing.T, c goldenCase, rewrite rpcreplay.Rewrite) (string, int) {
	t.Helper()
	cas, err := rpcreplay.Load(filepath.Join("testdata", c.Name+".cassette.json"))
	require.NoError(t, err)
	r := rpcreplay.NewReplayer(cas)
	r.Rewrite = rewrite
	srv := httptest.NewServer(r)
	defer srv.Close()
	args := make([]string, len(c.Args))
	for i, a := range c.Args {
		args[i] = strings.ReplaceAll(a, "{rpc}", srv.URL)
	}
	var stdout, stderr bytes.Buffer
	code := Run(context.Background(), args, &stdout, &stderr)
	require.Empty(t, stderr.String(), "no diagnostics on stderr")
	return stdout.String(), code
}

func checkGolden(t *testing.T, name, got string) {
	t.Helper()
	path := filepath.Join("testdata", "golden", name+".golden")
	if *update {
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
		require.NoError(t, os.WriteFile(path, []byte(got), 0o644))
	}
	want, err := os.ReadFile(path)
	require.NoError(t, err, "missing golden file (run with -update)")
	require.Equal(t, strings.ReplaceAll(string(want), "\r\n", "\n"), got)
}

func TestGolden(t *testing.T) {
	for name, c := range loadCases(t) {
		t.Run(name, func(t *testing.T) {
			out, code := replay(t, c, nil)
			require.Equal(t, c.Exit, code, "exit code recorded against the live node")
			require.Equal(t, ExitVerified, code)
			checkGolden(t, name, out)
		})
	}
}

// edit rewrites a JSON result with f.
func edit(result json.RawMessage, f func(v any)) json.RawMessage {
	var v any
	if err := json.Unmarshal(result, &v); err != nil {
		panic(err)
	}
	f(v)
	out, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return out
}

func flipLastHex(s string) string {
	if strings.HasSuffix(s, "0") {
		return s[:len(s)-1] + "1"
	}
	return s[:len(s)-1] + "0"
}

func TestGoldenTampered(t *testing.T) {
	cases := loadCases(t)
	tampered := []struct {
		name    string
		base    string
		method  string
		mutate  func(v any) bool // reports whether it changed something
		failing string
	}{
		{"tampered-log-dropped", "verify-block-2", "eth_getBlockReceipts", func(v any) bool {
			r := v.([]any)[0].(map[string]any)
			logs := r["logs"].([]any)
			r["logs"] = logs[:len(logs)-1]
			return true
		}, "receiptsRoot"},
		{"tampered-status", "verify-block-3", "eth_getBlockReceipts", func(v any) bool {
			for _, r := range v.([]any) {
				r.(map[string]any)["status"] = "0x1"
			}
			return true
		}, "receiptsRoot"},
		{"tampered-slot-value", "verify-proof-contract", "eth_getProof", func(v any) bool {
			sp := v.(map[string]any)["storageProof"].([]any)[0].(map[string]any)
			sp["value"] = "0x1234"
			return true
		}, "claims"},
		{"tampered-proof-node", "verify-proof-eoa", "eth_getProof", func(v any) bool {
			nodes := v.(map[string]any)["accountProof"].([]any)
			nodes[0] = flipLastHex(nodes[0].(string))
			return true
		}, "proofs"},
	}
	for _, tc := range tampered {
		t.Run(tc.name, func(t *testing.T) {
			base, ok := cases[tc.base]
			require.True(t, ok, tc.base)
			changed := false
			out, code := replay(t, base, func(method string, _, result json.RawMessage) json.RawMessage {
				if method != tc.method {
					return result
				}
				return edit(result, func(v any) { changed = tc.mutate(v) || changed })
			})
			require.True(t, changed, "the rewrite applied")
			require.Equal(t, ExitFailed, code)
			require.Contains(t, out, "verdict: FAILED")
			require.Regexp(t, fmt.Sprintf(`\[fail\]\s+%s`, tc.failing), out)
			checkGolden(t, tc.name, out)
		})
	}
}

func TestGoldenTamperedRawTransaction(t *testing.T) {
	base := loadCases(t)["verify-block-1"]
	changed := 0
	out, code := replay(t, base, func(method string, _, result json.RawMessage) json.RawMessage {
		if method != "eth_getRawTransactionByHash" || changed > 0 {
			return result
		}
		changed++
		var s string
		require.NoError(t, json.Unmarshal(result, &s))
		b, _ := json.Marshal(flipLastHex(s))
		return b
	})
	require.Equal(t, 1, changed)
	require.Equal(t, ExitFailed, code)
	require.Regexp(t, `\[fail\]\s+transaction hashes`, out)
	require.Regexp(t, `\[fail\]\s+transactionsRoot`, out)
	checkGolden(t, "tampered-raw-tx", out)
}

func TestGoldenTamperedStorageValue(t *testing.T) {
	base := loadCases(t)["storage-root"]
	changed := 0
	out, code := replay(t, base, func(method string, _, result json.RawMessage) json.RawMessage {
		if method != "eth_getStorageAt" || changed > 0 {
			return result
		}
		var s string
		require.NoError(t, json.Unmarshal(result, &s))
		if strings.Trim(s[2:], "0") == "" {
			return result // a cleared slot; alter a live one
		}
		changed++
		b, _ := json.Marshal(flipLastHex(s))
		return b
	})
	require.Equal(t, 1, changed)
	require.Equal(t, ExitFailed, code)
	require.Regexp(t, `\[fail\]\s+storage root`, out)
	checkGolden(t, "tampered-storage-value", out)
}

func TestStrictTurnsWarningsIntoFailures(t *testing.T) {
	base := loadCases(t)["verify-block-2"]
	withExtraField := func(method string, _, result json.RawMessage) json.RawMessage {
		if method != "eth_getBlockByNumber" {
			return result
		}
		return edit(result, func(v any) { v.(map[string]any)["futureField"] = "0x1" })
	}
	out, code := replay(t, base, withExtraField)
	require.Equal(t, ExitVerified, code, "an unknown field alone is a warning")
	require.Contains(t, out, "VERIFIED WITH WARNINGS")
	require.Regexp(t, `\[warn\]\s+unknown fields\s+.*futureField`, out)

	strict := base
	strict.Args = append(append([]string{}, base.Args...), "--strict")
	_, code = replay(t, strict, withExtraField)
	require.Equal(t, ExitFailed, code)
}
