// SPDX-License-Identifier: MIT

//go:build integration

package integration

import (
	"math/big"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/ethrpc"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/inspect"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/internal/devnet"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/stateproof"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/trie"
)

// TestStorageRootReconstruction is the headline test: the fixture writes 200 pseudo-random
// slots, the test rebuilds the storage trie from values computed off-chain from the seed
// alone, and the root must equal eth_getProof's storageHash. Then 50 slots are cleared and
// the same holds; historical blocks keep their own roots.
func TestStorageRootReconstruction(t *testing.T) {
	n, sc := scenario(t, "prague")
	c := dial(t, n.URL)
	ctx := testContext(t)

	written := devnet.Batch(devnet.ScenarioSeed, devnet.ScenarioWrites)
	require.Len(t, written, devnet.ScenarioWrites)
	// The values span every leaf length: entry i keeps 32 - i%32 bytes.
	lengths := map[int]bool{}
	for i := range uint64(devnet.ScenarioWrites) {
		v := written[devnet.Slot(devnet.ScenarioSeed, i)]
		lengths[len(stateproof.EncodeStorageValue(v))] = true
	}
	require.GreaterOrEqual(t, len(lengths), 32, "storage leaves of many different lengths")

	for _, tc := range []struct {
		block uint64
		slots map[keccak.Hash]keccak.Hash
	}{
		{1, nil},           // freshly deployed: empty storage
		{2, written},       // 200 slots
		{3, sc.Storage[3]}, // 150 slots after clearing 50
		{2, sc.Storage[2]}, // block 2 again, read after block 3 was mined (historical state)
	} {
		ref := ethrpc.Number(tc.block)
		b, err := c.BlockByRef(ctx, ref)
		require.NoError(t, err)

		all := make([]keccak.Hash, 0, devnet.ScenarioWrites+20)
		for i := range uint64(devnet.ScenarioWrites + 20) { // 20 slots that were never written
			all = append(all, devnet.Slot(devnet.ScenarioSeed, i))
		}
		res, err := c.GetProof(ctx, sc.SlotWriter, all, ref)
		require.NoError(t, err)
		out, err := stateproof.CheckGetProof(b.Header.StateRoot, res)
		require.NoError(t, err)
		require.True(t, out.OK(), out.Mismatches)

		rebuilt := stateproof.StorageRoot(tc.slots)
		require.Equal(t, rebuilt, res.StorageHash, "block %d: rebuilt root vs eth_getProof storageHash", tc.block)
		require.Equal(t, rebuilt, out.Account.StorageRoot)
		if len(tc.slots) == 0 {
			require.Equal(t, keccak.EmptyRoot, rebuilt)
		}

		present := 0
		for i, s := range out.Slots {
			want, ok := tc.slots[all[i]]
			require.Equal(t, ok, s.Exists, "block %d slot %d", tc.block, i)
			if ok {
				present++
				require.Equal(t, want, s.Value, "block %d slot %d", tc.block, i)
			} else {
				require.True(t, s.Value.IsZero())
			}
		}
		require.Equal(t, len(tc.slots), present)
	}

	// The same through the CLI-facing report.
	slots := make([]keccak.Hash, 0, len(sc.Storage[3]))
	for i := range uint64(devnet.ScenarioWrites) {
		slots = append(slots, devnet.Slot(devnet.ScenarioSeed, i)) // includes the 50 cleared ones
	}
	rep, err := inspect.RebuildStorage(ctx, c, sc.SlotWriter, slots, ethrpc.Number(3))
	require.NoError(t, err)
	requireAllPass(t, rep.Checks)
	require.Equal(t, devnet.ScenarioWrites-devnet.ScenarioCleared, rep.NonZero)

	// One live slot missing from the list: the rebuilt root no longer matches.
	rep, err = inspect.RebuildStorage(ctx, c, sc.SlotWriter, slots[:len(slots)-1], ethrpc.Number(3))
	require.NoError(t, err)
	require.Equal(t, inspect.Fail, statuses(rep.Checks)["storage root"])
}

func TestAccountProofs(t *testing.T) {
	n, sc := scenario(t, "osaka")
	c := dial(t, n.URL)
	ctx := testContext(t)
	absent := keccak.Address{0xde, 0xad}

	for _, tc := range []struct {
		name   string
		addr   keccak.Address
		exists bool
		code   bool
	}{
		{"sender EOA", sc.Sender, true, false},
		{"recipient EOA", sc.Recipient, true, false},
		{"SlotWriter contract", sc.SlotWriter, true, true},
		{"address without an account", absent, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			slots := []keccak.Hash{devnet.Slot(devnet.ScenarioSeed, 60), {}}
			rep, err := inspect.VerifyProof(ctx, c, tc.addr, slots, ethrpc.Latest())
			require.NoError(t, err)
			requireAllPass(t, rep.Checks)
			require.Equal(t, tc.exists, rep.Account.Exists)
			require.Equal(t, tc.code, rep.Account.CodeHash != keccak.EmptyCode && rep.Account.Exists)
			require.NotEmpty(t, rep.Account.Path)

			var balance string
			require.NoError(t, n.Call(ctx, &balance, "eth_getBalance", tc.addr, "latest"))
			want, _ := new(big.Int).SetString(balance[2:], 16)
			require.Equal(t, want.String(), rep.Account.Balance, "proven balance = eth_getBalance")
		})
	}

	// Every account the scenario touched is provable against the state root of every mined
	// block. (Genesis is the exception: see TestAnvilGenesisStateRoot.)
	for num := uint64(1); num <= sc.Head; num++ {
		b, err := c.BlockByRef(ctx, ethrpc.Number(num))
		require.NoError(t, err)
		for _, a := range []keccak.Address{sc.Sender, sc.Recipient, sc.SlotWriter} {
			res, err := c.GetProof(ctx, a, nil, ethrpc.Number(num))
			require.NoError(t, err)
			acct, steps, err := stateproof.VerifyAccount(b.Header.StateRoot, a, res.AccountProof)
			require.NoError(t, err)
			require.NotEmpty(t, steps)
			require.NotNil(t, acct)
		}
	}
}

// TestAnvilGenesisStateRoot pins an anvil 1.8.3 inconsistency the inspector detects: the
// genesis header reports the empty state root although the dev accounts are funded at
// genesis, so no account proof at block 0 verifies against it. Mined blocks are consistent.
func TestAnvilGenesisStateRoot(t *testing.T) {
	n := startNode(t, "prague")
	c := dial(t, n.URL)
	ctx := testContext(t)
	b, err := c.BlockByRef(ctx, ethrpc.Number(0))
	require.NoError(t, err)
	require.Equal(t, keccak.EmptyRoot, b.Header.StateRoot, "anvil's genesis claims an empty state")

	var balance string
	require.NoError(t, n.Call(ctx, &balance, "eth_getBalance", n.Accounts[0], "0x0"))
	require.NotEqual(t, "0x0", balance, "yet the first dev account is funded at genesis")

	rep, err := inspect.VerifyProof(ctx, c, n.Accounts[0], nil, ethrpc.Number(0))
	require.NoError(t, err)
	st := statuses(rep.Checks)
	require.Equal(t, inspect.Pass, st["block hash"], "the header itself hashes correctly")
	require.Equal(t, inspect.Fail, st["proofs"], "but its stateRoot does not commit to the funded accounts")

	_, err = n.Mine(ctx, 0)
	require.NoError(t, err)
	rep, err = inspect.VerifyProof(ctx, c, n.Accounts[0], nil, ethrpc.Number(1))
	require.NoError(t, err)
	requireAllPass(t, rep.Checks)
}

// TestProofsAreMinimal checks that anvil's proofs satisfy the strict verifier's minimality
// rule (no node off the key's path) and match a proof built locally from the same data:
// the storage trie rebuilt from the seeds proves each slot with exactly the nodes anvil sends.
func TestProofsAreMinimal(t *testing.T) {
	n, sc := scenario(t, "cancun")
	c := dial(t, n.URL)
	ctx := testContext(t)
	local := stateproof.StorageTrie(sc.Storage[3])
	for i := range uint64(devnet.ScenarioWrites + 5) {
		slot := devnet.Slot(devnet.ScenarioSeed, i)
		res, err := c.GetProof(ctx, sc.SlotWriter, []keccak.Hash{slot}, ethrpc.Number(3))
		require.NoError(t, err)
		require.Equal(t, local.Prove(slot[:]), res.StorageProof[0].Proof, "slot %d", i)
		_, err = trie.VerifySecureProof(local.Hash(), slot[:], res.StorageProof[0].Proof)
		require.NoError(t, err)
	}
}
