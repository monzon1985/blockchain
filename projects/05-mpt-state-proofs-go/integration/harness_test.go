// SPDX-License-Identifier: MIT

//go:build integration

// Package integration runs the inspector against live anvil nodes. Every node listens on an
// OS-assigned port and is stopped by PID when its test ends. Run `forge build` in fixtures/
// first: the tests deploy the SlotWriter fixture.
package integration

import (
	"context"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/ethrpc"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/inspect"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/internal/devnet"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/internal/rpcreplay"
)

const fixturesDir = "../fixtures"

func testContext(t *testing.T) context.Context {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	t.Cleanup(cancel)
	return ctx
}

// startNode launches anvil and stops it when the test ends.
func startNode(t *testing.T, hardfork string) *devnet.Node {
	t.Helper()
	n, err := devnet.Start(testContext(t), devnet.Options{Hardfork: hardfork})
	require.NoError(t, err)
	t.Cleanup(func() { _ = n.Close() })
	return n
}

// dial returns a client for url, closed when the test ends.
func dial(t *testing.T, url string) *ethrpc.Client {
	t.Helper()
	c, err := ethrpc.Dial(testContext(t), url)
	require.NoError(t, err)
	t.Cleanup(c.Close)
	return c
}

// scenario starts a node and builds the standard chain on it.
func scenario(t *testing.T, hardfork string) (*devnet.Node, *devnet.ScenarioResult) {
	t.Helper()
	n := startNode(t, hardfork)
	code, err := devnet.LoadSlotWriter(fixturesDir)
	require.NoError(t, err)
	res, err := devnet.RunScenario(testContext(t), n, code, hardfork != "berlin")
	require.NoError(t, err, "anvil log:\n%s", n.Log())
	return n, res
}

// lyingNode puts a rewriting proxy in front of a node and returns its URL.
func lyingNode(t *testing.T, n *devnet.Node, rewrite rpcreplay.Rewrite) string {
	t.Helper()
	srv := httptest.NewServer(&rpcreplay.Proxy{Upstream: n.URL, Rewrite: rewrite})
	t.Cleanup(srv.Close)
	return srv.URL
}

// statuses maps check names to their statuses (later duplicates win).
func statuses(checks inspect.Checks) map[string]inspect.Status {
	m := map[string]inspect.Status{}
	for _, c := range checks {
		m[c.Name] = c.Status
	}
	return m
}

func requireAllPass(t *testing.T, checks inspect.Checks, except ...string) {
	t.Helper()
	skip := map[string]bool{}
	for _, e := range except {
		skip[e] = true
	}
	for _, c := range checks {
		if !skip[c.Name] {
			require.Equal(t, inspect.Pass, c.Status, "%s: %s", c.Name, c.Detail)
		}
	}
}
