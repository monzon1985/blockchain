// SPDX-License-Identifier: MIT

package cli

import (
	"bytes"
	"context"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/internal/rpcreplay"
)

func run(args ...string) (stdout, stderr string, code int) {
	var o, e bytes.Buffer
	code = Run(context.Background(), args, &o, &e)
	return o.String(), e.String(), code
}

// deadURL returns the URL of a server that has already stopped: nothing listens there.
func deadURL(t *testing.T) string {
	srv := httptest.NewServer(&rpcreplay.Replayer{})
	url := srv.URL
	srv.Close()
	return url
}

func TestUsageErrors(t *testing.T) {
	slots := filepath.Join(t.TempDir(), "slots.txt")
	require.NoError(t, os.WriteFile(slots, []byte("# comment only\n\n"), 0o644))
	twice := filepath.Join(t.TempDir(), "twice.txt")
	require.NoError(t, os.WriteFile(twice, []byte("1\n0x01\n"), 0o644))
	addr := "0x00000000000000000000000000000000000000aa"

	cases := []struct {
		name string
		args []string
		want string
	}{
		{"no command", nil, "Usage:"},
		{"unknown command", []string{"frobnicate"}, `unknown command "frobnicate"`},
		{"unknown flag", []string{"verify-block", "--nope", "1"}, "flag provided but not defined"},
		{"block missing", []string{"verify-block"}, "exactly one block"},
		{"two blocks", []string{"verify-block", "1", "2"}, "exactly one block"},
		{"bad block", []string{"verify-block", "twelve"}, "not a number or a tag"},
		{"address missing", []string{"verify-proof"}, "--address is required"},
		{"bad address", []string{"verify-proof", "--address", "0x1234"}, "40 hex digits"},
		{"bad slot", []string{"verify-proof", "--address", addr, "--slot", "slot-one"}, "neither a decimal"},
		{"slot over 32 bytes", []string{"verify-proof", "--address", addr, "--slot", "0x" + strings.Repeat("f", 65)}, "invalid hex"},
		{"duplicate slot", []string{"storage-root", "--address", addr, "--slots-file", twice}, "listed twice"},
		{"stray argument", []string{"verify-proof", "--address", addr, "extra"}, `unexpected argument "extra"`},
		{"bad --block", []string{"verify-proof", "--address", addr, "--block", "-1"}, "not a number or a tag"},
		{"storage-root without file", []string{"storage-root", "--address", addr}, "takes --slots-file"},
		{"storage-root with --slot", []string{"storage-root", "--address", addr, "--slots-file", slots, "--slot", "1"}, "takes --slots-file"},
		{"slots file elsewhere", []string{"verify-proof", "--address", addr, "--slots-file", slots}, "storage-root only"},
		{"empty slots file", []string{"storage-root", "--address", addr, "--slots-file", slots}, "lists no slots"},
		{"missing slots file", []string{"storage-root", "--address", addr, "--slots-file", filepath.Join(t.TempDir(), "nope")}, "nope"},
		{"rlp without input", []string{"rlp"}, "one hex argument"},
		{"rlp bad hex", []string{"rlp", "0xzz"}, "invalid byte"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, stderr, code := run(tc.args...)
			require.Equal(t, ExitUsage, code)
			require.Contains(t, stderr, tc.want)
		})
	}
}

func TestUnreachableNode(t *testing.T) {
	url := deadURL(t)
	for _, args := range [][]string{
		{"verify-block", "--rpc", url, "--timeout", "5s", "1"},
		{"verify-proof", "--rpc", url, "--timeout", "5s", "--address", "0x00000000000000000000000000000000000000aa"},
		{"storage-root", "--rpc", url, "--timeout", "5s", "--address", "0x00000000000000000000000000000000000000aa", "--slots-file", filepath.Join("testdata", "slots.txt")},
	} {
		_, stderr, code := run(args...)
		require.Equal(t, ExitUsage, code, "%v", args)
		require.NotEmpty(t, stderr)
	}
	_, stderr, code := run("verify-block", "--rpc", "ftp://nowhere", "1")
	require.Equal(t, ExitUsage, code)
	require.Contains(t, stderr, "dial")
}

func TestCallsOutsideTheCassetteFail(t *testing.T) {
	// The replayer answers unknown calls with an error; the CLI reports it and exits 2.
	cas, err := rpcreplay.Load(filepath.Join("testdata", "verify-block-0.cassette.json"))
	require.NoError(t, err)
	srv := httptest.NewServer(rpcreplay.NewReplayer(cas))
	defer srv.Close()
	_, stderr, code := run("verify-block", "--rpc", srv.URL, "7")
	require.Equal(t, ExitUsage, code)
	require.Contains(t, stderr, "not recorded")
}

func TestHelpAndVerbose(t *testing.T) {
	out, _, code := run("help")
	require.Equal(t, ExitVerified, code)
	require.Contains(t, out, "trie verify-block")

	c := loadCases(t)["verify-block-0"]
	c.Args = append(append([]string{}, c.Args...), "--verbose")
	cas, err := rpcreplay.Load(filepath.Join("testdata", "verify-block-0.cassette.json"))
	require.NoError(t, err)
	srv := httptest.NewServer(rpcreplay.NewReplayer(cas))
	defer srv.Close()
	args := make([]string, len(c.Args))
	for i, a := range c.Args {
		args[i] = strings.ReplaceAll(a, "{rpc}", srv.URL)
	}
	_, stderr, code := run(args...)
	require.Equal(t, ExitVerified, code)
	require.Contains(t, stderr, "client=anvil/v1.8.3")
	require.Contains(t, stderr, "verifying block")
}

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, os.ErrClosed }

func TestOutputAndInputErrors(t *testing.T) {
	c := loadCases(t)["verify-block-latest-json"]
	cas, err := rpcreplay.Load(filepath.Join("testdata", c.Name+".cassette.json"))
	require.NoError(t, err)
	srv := httptest.NewServer(rpcreplay.NewReplayer(cas))
	defer srv.Close()
	args := make([]string, len(c.Args))
	for i, a := range c.Args {
		args[i] = strings.ReplaceAll(a, "{rpc}", srv.URL)
	}
	var stderr bytes.Buffer
	require.Equal(t, ExitUsage, Run(context.Background(), args, failingWriter{}, &stderr))
	require.Contains(t, stderr.String(), "file already closed")

	long := filepath.Join(t.TempDir(), "long.txt")
	require.NoError(t, os.WriteFile(long, []byte(strings.Repeat("1", 70_000)), 0o644))
	_, errOut, code := run("storage-root", "--address", "0x00000000000000000000000000000000000000aa", "--slots-file", long)
	require.Equal(t, ExitUsage, code)
	require.Contains(t, errOut, "too long")
}

func TestRLPCommand(t *testing.T) {
	// ["cat", ["dog", ""], 1024, 0x00ff]
	out, _, code := run("rlp", "0xd083636174c583646f67808204008200ff")
	require.Equal(t, ExitVerified, code)
	checkGolden(t, "rlp", out)

	_, stderr, code := run("rlp", "0x8105")
	require.Equal(t, ExitFailed, code, "non-canonical input is a verification failure")
	require.Contains(t, stderr, "non-canonical")
}
