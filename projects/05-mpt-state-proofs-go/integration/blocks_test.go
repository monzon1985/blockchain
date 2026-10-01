// SPDX-License-Identifier: MIT

//go:build integration

package integration

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/block"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/ethrpc"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/inspect"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/internal/devnet"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/stateproof"
)

// hardforks is the matrix, with what the inspector must conclude about anvil 1.8.3's blocks.
// Mined blocks carry exactly the header fields of their fork. The genesis block of a
// pre-Cancun chain does not: anvil adds blobGasUsed and excessBlobGas to it, so it mixes eras.
// On Shanghai the canonical encoding still matches (the extra fields happen to be contiguous);
// on Berlin and London only the present-only layout reproduces anvil's genesis hash.
var hardforks = []struct {
	name        string
	era         block.Era // mined blocks
	genesisEra  block.Era
	genesisHash inspect.Status // the "block hash" check of block 0
}{
	{"berlin", block.Frontier, block.Cancun, inspect.Warn},
	{"london", block.London, block.Cancun, inspect.Warn},
	{"shanghai", block.Shanghai, block.Cancun, inspect.Pass},
	{"cancun", block.Cancun, block.Cancun, inspect.Pass},
	{"prague", block.Prague, block.Prague, inspect.Pass},
	{"osaka", block.Prague, block.Prague, inspect.Pass},
}

func TestHardforkMatrix(t *testing.T) {
	for _, hf := range hardforks {
		t.Run(hf.name, func(t *testing.T) {
			t.Parallel()
			n, sc := scenario(t, hf.name)
			c := dial(t, n.URL)
			ctx := testContext(t)

			for num := uint64(0); num <= sc.Head; num++ {
				rep, err := inspect.VerifyBlock(ctx, c, ethrpc.Number(num))
				require.NoError(t, err)
				st := statuses(rep.Checks)
				if num == 0 && hf.genesisEra != hf.era {
					require.Equal(t, hf.genesisEra.String(), rep.Era)
					require.Equal(t, hf.genesisHash, st["block hash"])
					require.Equal(t, inspect.Warn, st["header fields"], "the genesis header mixes eras")
					requireAllPass(t, rep.Checks, "block hash", "header fields")
					require.True(t, rep.Checks.OK(false), rep.Checks.Verdict())
					require.False(t, rep.Checks.OK(true), "--strict rejects the mixed-era genesis")
				} else {
					require.Equal(t, hf.era.String(), rep.Era, "block %d", num)
					requireAllPass(t, rep.Checks)
				}

				wantTypes := map[string]int{}
				for _, typ := range sc.TxTypes[num] {
					wantTypes[block.TxTypeName(typ)]++
				}
				require.Equal(t, wantTypes, rep.TxTypes, "block %d", num)
			}

			// Block 2 holds the 200-slot write: one receipt with 200 logs.
			rep, err := inspect.VerifyBlock(ctx, c, ethrpc.Number(2))
			require.NoError(t, err)
			require.Equal(t, devnet.ScenarioWrites, rep.Logs)

			// The whole storage trie of the fixture, rebuilt from the seeds, at every block.
			for num := uint64(1); num <= sc.Head; num++ {
				b, err := c.BlockByRef(ctx, ethrpc.Number(num))
				require.NoError(t, err)
				res, err := c.GetProof(ctx, sc.SlotWriter, nil, ethrpc.Number(num))
				require.NoError(t, err)
				out, err := stateproof.CheckGetProof(b.Header.StateRoot, res)
				require.NoError(t, err)
				require.True(t, out.OK(), out.Mismatches)
				require.Equal(t, stateproof.StorageRoot(sc.Storage[num]), out.Account.StorageRoot, "block %d", num)
			}
		})
	}
}

func TestLatestBlock(t *testing.T) {
	n, sc := scenario(t, "")
	rep, err := inspect.VerifyBlock(testContext(t), dial(t, n.URL), ethrpc.Latest())
	require.NoError(t, err)
	require.Equal(t, sc.Head, rep.Number)
	requireAllPass(t, rep.Checks)
}

func TestEmptyBlocksAndGenesis(t *testing.T) {
	n := startNode(t, "prague")
	ctx := testContext(t)
	for range 3 {
		_, err := n.Mine(ctx, 0)
		require.NoError(t, err)
	}
	c := dial(t, n.URL)
	for num := range uint64(4) {
		rep, err := inspect.VerifyBlock(ctx, c, ethrpc.Number(num))
		require.NoError(t, err)
		requireAllPass(t, rep.Checks)
		require.Zero(t, rep.Transactions)
		b, err := c.BlockByRef(ctx, ethrpc.Number(num))
		require.NoError(t, err)
		require.Equal(t, keccak.EmptyRoot, b.Header.TxRoot, "an empty block commits to the empty trie")
	}
}
