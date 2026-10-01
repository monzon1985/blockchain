// SPDX-License-Identifier: MIT

// Package archtest enforces the module's layering.
package archtest

import (
	"os/exec"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

const module = "github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go"

// TestCoreIsFromScratch checks that the verification core (RLP, trie, hashing, headers,
// receipts, state proofs, reports) does not depend on go-ethereum, even transitively.
// go-ethereum is used by tests (as a differential oracle) and by the transport layer
// (ethrpc) only.
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
