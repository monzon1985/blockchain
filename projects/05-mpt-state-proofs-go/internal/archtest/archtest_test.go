// SPDX-License-Identifier: MIT

// Package archtest checks repository rules that no single package can check: the module's
// layering, and the provenance of the vendored test vectors.
package archtest

import (
	"bytes"
	"crypto/sha1" // git object ids are SHA-1; used to identify files, not for security
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

const module = "github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go"

// TestCoreIsFromScratch checks that the verification core (RLP, trie, hashing, headers,
// receipts, state proofs) does not depend on go-ethereum, even transitively. go-ethereum is
// used by tests (as a differential oracle) and by the transport layer only: ethrpc wraps its
// JSON-RPC client, so inspect and the CLI, which fetch through ethrpc, are not part of the
// core and are not checked here.
func TestCoreIsFromScratch(t *testing.T) {
	for _, pkg := range []string{"keccak", "rlp", "trie", "block", "stateproof"} {
		cmd := exec.Command("go", "list", "-deps", "-f", "{{.ImportPath}}", module+"/"+pkg)
		cmd.Env = append(cmd.Environ(), "CGO_ENABLED=0")
		out, err := cmd.CombinedOutput()
		require.NoError(t, err, string(out))
		deps := strings.Fields(string(out))
		require.NotEmpty(t, deps)
		for _, d := range deps {
			require.False(t, strings.HasPrefix(d, "github.com/ethereum/go-ethereum"), "%s depends on %s", pkg, d)
			if strings.Contains(d, ".") && !strings.HasPrefix(d, module) {
				require.True(t, strings.HasPrefix(d, "golang.org/x/crypto/sha3") || strings.HasPrefix(d, "golang.org/x/sys/cpu"),
					"%s depends on third-party package %s", pkg, d)
			}
		}
	}
}

// sourceRow is a row of a SOURCE.md table: vendored file, upstream path, git blob SHA-1.
var sourceRow = regexp.MustCompile("(?m)^[|] `([^`]+)` [|] `([^`]+)` [|] `([0-9a-f]{40})` [|]$")

// gitBlobHash is the object id git gives a file: SHA-1 of "blob <size>\x00<content>".
// Line endings are normalized to LF first, as the repository's .gitattributes stores them.
func gitBlobHash(content []byte) string {
	content = bytes.ReplaceAll(content, []byte("\r\n"), []byte("\n"))
	h := sha1.New()
	fmt.Fprintf(h, "blob %d\x00", len(content))
	h.Write(content)
	return hex.EncodeToString(h.Sum(nil))
}

// TestVendoredVectorsMatchUpstream checks that every vendored ethereum/tests file is listed
// in its directory's SOURCE.md and still has the git blob hash recorded there, which is the
// hash of the file at the upstream tag. A modified, unlisted or missing file fails.
func TestVendoredVectorsMatchUpstream(t *testing.T) {
	// The id `git hash-object` gives "hello" plus a newline, with CRLF normalized like git does.
	require.Equal(t, "ce013625030ba8dba906f756967f9e9ca394464a", gitBlobHash([]byte("hello\r\n")))
	for _, dir := range []string{"../../rlp/testdata/ethereum-tests", "../../trie/testdata/ethereum-tests"} {
		t.Run(filepath.Base(filepath.Dir(filepath.Dir(dir))), func(t *testing.T) {
			manifest, err := os.ReadFile(filepath.Join(dir, "SOURCE.md"))
			require.NoError(t, err)
			require.Contains(t, string(manifest), "c67e485ff8b5be9abc8ad15345ec21aa22e290d9", "the upstream commit is recorded")
			rows := sourceRow.FindAllStringSubmatch(strings.ReplaceAll(string(manifest), "\r\n", "\n"), -1)
			require.NotEmpty(t, rows)

			listed := map[string]bool{}
			for _, r := range rows {
				name, upstream, want := r[1], r[2], r[3]
				require.Equal(t, name, filepath.Base(upstream), "%s keeps its upstream file name", name)
				content, err := os.ReadFile(filepath.Join(dir, name))
				require.NoError(t, err, "%s is listed but missing", name)
				require.Equal(t, want, gitBlobHash(content), "%s differs from upstream %s", name, upstream)
				listed[name] = true
			}
			entries, err := os.ReadDir(dir)
			require.NoError(t, err)
			for _, e := range entries {
				if e.Name() != "SOURCE.md" {
					require.True(t, listed[e.Name()], "%s is vendored but not listed in SOURCE.md", e.Name())
				}
			}
		})
	}
}
