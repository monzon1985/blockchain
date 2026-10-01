// SPDX-License-Identifier: MIT

//go:build integration

package integration

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/ethrpc"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/inspect"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/internal/devnet"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/internal/rpcreplay"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/stateproof"
)

// edit decodes a JSON result, lets f change it, and re-encodes it.
func edit(t *testing.T, result json.RawMessage, f func(v any) any) json.RawMessage {
	var v any
	require.NoError(t, json.Unmarshal(result, &v))
	out, err := json.Marshal(f(v))
	require.NoError(t, err)
	return out
}

func obj(v any) map[string]any { return v.(map[string]any) }

// flipHex changes the last hex digit of a 0x string.
func flipHex(s string) string {
	last := s[len(s)-1]
	repl := byte('0')
	if last == '0' {
		repl = '1'
	}
	return s[:len(s)-1] + string(repl)
}

func only(method string, f rpcreplay.Rewrite) rpcreplay.Rewrite {
	return func(m string, params, result json.RawMessage) json.RawMessage {
		if m != method || string(result) == "null" {
			return result
		}
		return f(m, params, result)
	}
}

// TestLyingNodeIsCaught runs the verifiers through a proxy that tells one lie at a time (16
// in all). Every lie must turn into a failed check (never a pass, never a crash).
func TestLyingNodeIsCaught(t *testing.T) {
	n, sc := scenario(t, "prague")
	ctx := testContext(t)
	honest := dial(t, n.URL)
	slot60 := devnet.Slot(devnet.ScenarioSeed, 60)

	// A forged storage trie in which slot 60 holds 0xbad, for the storage-hash lie below.
	forged := stateproof.StorageTrie(map[keccak.Hash]keccak.Hash{slot60: {31: 0x0b}})

	blockCases := []struct {
		name    string
		block   uint64
		rewrite rpcreplay.Rewrite
		failing []string // checks that must fail
	}{
		{"raw transaction altered", 1, only("eth_getRawTransactionByHash", func(_ string, _, r json.RawMessage) json.RawMessage {
			return edit(t, r, func(v any) any { return flipHex(v.(string)) })
		}), []string{"transaction hashes", "transactionsRoot"}},
		{"cumulative gas inflated", 1, only("eth_getBlockReceipts", func(_ string, _, r json.RawMessage) json.RawMessage {
			return edit(t, r, func(v any) any {
				rc := obj(v.([]any)[0])
				rc["cumulativeGasUsed"] = flipHex(rc["cumulativeGasUsed"].(string))
				return v
			})
		}), []string{"receiptsRoot"}},
		{"a log dropped", 2, only("eth_getBlockReceipts", func(_ string, _, r json.RawMessage) json.RawMessage {
			return edit(t, r, func(v any) any {
				rc := obj(v.([]any)[0])
				logs := rc["logs"].([]any)
				rc["logs"] = logs[:len(logs)-1]
				return v
			})
		}), []string{"receipt blooms", "receiptsRoot"}},
		{"a reverted transaction reported as successful", 3, only("eth_getBlockReceipts", func(_ string, _, r json.RawMessage) json.RawMessage {
			return edit(t, r, func(v any) any {
				for _, x := range v.([]any) {
					obj(x)["status"] = "0x1"
				}
				return v
			})
		}), []string{"receiptsRoot"}},
		{"receipts of another block", 2, only("eth_getBlockReceipts", func(_ string, _, r json.RawMessage) json.RawMessage {
			return edit(t, r, func(v any) any {
				obj(v.([]any)[0])["blockHash"] = flipHex(obj(v.([]any)[0])["blockHash"].(string))
				return v
			})
		}), []string{"receipt identity"}},
		{"state root altered in the header", 2, only("eth_getBlockByNumber", func(_ string, _, r json.RawMessage) json.RawMessage {
			return edit(t, r, func(v any) any {
				obj(v)["stateRoot"] = flipHex(obj(v)["stateRoot"].(string))
				return v
			})
		}), []string{"block hash"}},
		{"block hash altered", 2, only("eth_getBlockByNumber", func(_ string, _, r json.RawMessage) json.RawMessage {
			return edit(t, r, func(v any) any {
				obj(v)["hash"] = flipHex(obj(v)["hash"].(string))
				return v
			})
		}), []string{"block hash"}},
		{"header bloom cleared", 2, only("eth_getBlockByNumber", func(_ string, _, r json.RawMessage) json.RawMessage {
			return edit(t, r, func(v any) any {
				obj(v)["logsBloom"] = "0x" + strings.Repeat("00", 256)
				return v
			})
		}), []string{"block hash", "logsBloom"}},
	}
	for _, tc := range blockCases {
		t.Run(tc.name, func(t *testing.T) {
			c := dial(t, lyingNode(t, n, tc.rewrite))
			rep, err := inspect.VerifyBlock(ctx, c, ethrpc.Number(tc.block))
			require.NoError(t, err)
			st := statuses(rep.Checks)
			for _, name := range tc.failing {
				require.Equal(t, inspect.Fail, st[name], "check %q; verdict %s", name, rep.Checks.Verdict())
			}
			require.False(t, rep.Checks.OK(false))
		})
	}

	proofCases := []struct {
		name    string
		rewrite rpcreplay.Rewrite
		failing string
	}{
		{"slot value claimed wrong", only("eth_getProof", func(_ string, _, r json.RawMessage) json.RawMessage {
			return edit(t, r, func(v any) any {
				sp := obj(obj(v)["storageProof"].([]any)[0])
				sp["value"] = "0xbad"
				return v
			})
		}), "claims"},
		{"balance claimed wrong", only("eth_getProof", func(_ string, _, r json.RawMessage) json.RawMessage {
			return edit(t, r, func(v any) any {
				obj(v)["balance"] = "0x1"
				return v
			})
		}), "claims"},
		{"storage proof node corrupted", only("eth_getProof", func(_ string, _, r json.RawMessage) json.RawMessage {
			return edit(t, r, func(v any) any {
				sp := obj(obj(v)["storageProof"].([]any)[0])
				nodes := sp["proof"].([]any)
				nodes[len(nodes)-1] = flipHex(nodes[len(nodes)-1].(string))
				return v
			})
		}), "proofs"},
		{"account proof truncated", only("eth_getProof", func(_ string, _, r json.RawMessage) json.RawMessage {
			return edit(t, r, func(v any) any {
				nodes := obj(v)["accountProof"].([]any)
				obj(v)["accountProof"] = nodes[:len(nodes)-1]
				return v
			})
		}), "proofs"},
		{"storage hash and proof forged together", only("eth_getProof", func(_ string, _, r json.RawMessage) json.RawMessage {
			return edit(t, r, func(v any) any {
				obj(v)["storageHash"] = forged.Hash().Hex()
				sp := obj(obj(v)["storageProof"].([]any)[0])
				sp["value"] = "0xb"
				var nodes []any
				for _, nd := range forged.Prove(slot60[:]) {
					nodes = append(nodes, fmt.Sprintf("0x%x", nd))
				}
				sp["proof"] = nodes
				return v
			})
		}), "proofs"},
	}
	for _, tc := range proofCases {
		t.Run(tc.name, func(t *testing.T) {
			c := dial(t, lyingNode(t, n, tc.rewrite))
			rep, err := inspect.VerifyProof(ctx, c, sc.SlotWriter, []keccak.Hash{slot60}, ethrpc.Number(3))
			require.NoError(t, err)
			require.Equal(t, inspect.Fail, statuses(rep.Checks)[tc.failing], rep.Checks.Verdict())
			require.False(t, rep.Checks.OK(false))
		})
	}

	allSlots := make([]keccak.Hash, 0, devnet.ScenarioWrites)
	for i := range uint64(devnet.ScenarioWrites) {
		allSlots = append(allSlots, devnet.Slot(devnet.ScenarioSeed, i))
	}

	t.Run("one storage value altered", func(t *testing.T) {
		target := fmt.Sprintf("%q", slot60.Hex())
		c := dial(t, lyingNode(t, n, only("eth_getStorageAt", func(_ string, params, r json.RawMessage) json.RawMessage {
			if !strings.Contains(string(params), target) {
				return r
			}
			return edit(t, r, func(v any) any { return flipHex(v.(string)) })
		})))
		rep, err := inspect.RebuildStorage(ctx, c, sc.SlotWriter, allSlots, ethrpc.Number(3))
		require.NoError(t, err)
		require.Equal(t, inspect.Fail, statuses(rep.Checks)["storage root"])
	})

	// The node answers about another account: anvil's own, valid proof of the recipient EOA
	// (empty storage) and zero for every slot. Every proof and the rebuilt storage root check
	// out; only the address in the response gives the lie away.
	recipientProof := func(slots ...string) json.RawMessage {
		var out json.RawMessage
		require.NoError(t, n.Call(ctx, &out, "eth_getProof", sc.Recipient.Hex(), append([]string{}, slots...), "0x3"))
		return out
	}
	proofNoSlots, proofSlot60 := recipientProof(), recipientProof(slot60.Hex())
	anotherAccount := func(m string, params, r json.RawMessage) json.RawMessage {
		switch {
		case m == "eth_getProof" && strings.Contains(string(params), slot60.Hex()):
			return proofSlot60
		case m == "eth_getProof":
			return proofNoSlots
		case m == "eth_getStorageAt":
			return json.RawMessage(`"0x` + strings.Repeat("00", 32) + `"`)
		}
		return r
	}
	t.Run("proof and storage of another account", func(t *testing.T) {
		c := dial(t, lyingNode(t, n, anotherAccount))
		rep, err := inspect.RebuildStorage(ctx, c, sc.SlotWriter, allSlots, ethrpc.Number(3))
		require.NoError(t, err)
		require.Equal(t, inspect.Fail, statuses(rep.Checks)["address"], rep.Checks.Verdict())
		// Everything else passes, the storage root included (empty storage, zero values).
		requireAllPass(t, rep.Checks, "address")
		require.False(t, rep.Checks.OK(false))

		prep, err := inspect.VerifyProof(ctx, c, sc.SlotWriter, []keccak.Hash{slot60}, ethrpc.Number(3))
		require.NoError(t, err)
		require.Equal(t, inspect.Fail, statuses(prep.Checks)["address"], prep.Checks.Verdict())
		requireAllPass(t, prep.Checks, "address")
		require.False(t, prep.Checks.OK(false))
	})

	// The node answers `--block 3` with block 2: a genuine block, so its hash, proofs and
	// storage all verify. Only the block number gives the lie away.
	var block2 json.RawMessage
	require.NoError(t, n.Call(ctx, &block2, "eth_getBlockByNumber", "0x2", false))
	olderBlock := only("eth_getBlockByNumber", func(_ string, params, r json.RawMessage) json.RawMessage {
		if strings.Contains(string(params), `"0x3"`) {
			return block2
		}
		return r
	})
	t.Run("an older block served for the requested one", func(t *testing.T) {
		c := dial(t, lyingNode(t, n, olderBlock))
		// Block 2 is genuine and its state consistent: every other check passes.
		prep, err := inspect.VerifyProof(ctx, c, sc.SlotWriter, []keccak.Hash{slot60}, ethrpc.Number(3))
		require.NoError(t, err)
		require.Equal(t, inspect.Fail, statuses(prep.Checks)["block number"], prep.Checks.Verdict())
		requireAllPass(t, prep.Checks, "block number")
		require.Equal(t, uint64(2), prep.Block)

		rep, err := inspect.RebuildStorage(ctx, c, sc.SlotWriter, allSlots, ethrpc.Number(3))
		require.NoError(t, err)
		require.Equal(t, inspect.Fail, statuses(rep.Checks)["block number"], rep.Checks.Verdict())
		requireAllPass(t, rep.Checks, "block number")

		brep, err := inspect.VerifyBlock(ctx, c, ethrpc.Number(3))
		require.NoError(t, err)
		require.Equal(t, inspect.Fail, statuses(brep.Checks)["block number"], brep.Checks.Verdict())
		requireAllPass(t, brep.Checks, "block number")
	})

	// Sanity: the honest node passes the same checks.
	rep, err := inspect.VerifyProof(ctx, honest, sc.SlotWriter, []keccak.Hash{slot60}, ethrpc.Number(3))
	require.NoError(t, err)
	requireAllPass(t, rep.Checks)
}
