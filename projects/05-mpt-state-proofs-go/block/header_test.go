// SPDX-License-Identifier: MIT

package block

import (
	"encoding/hex"
	"math/big"
	"math/rand/v2"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	gethrlp "github.com/ethereum/go-ethereum/rlp"
	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
)

func mustHex(t testing.TB, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	require.NoError(t, err)
	return b
}

func TestMainnetGenesisHash(t *testing.T) {
	h := Header{
		OmmersHash:  keccak.EmptyList,
		StateRoot:   keccak.MustParse("0xd7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544"),
		TxRoot:      keccak.EmptyRoot,
		ReceiptRoot: keccak.EmptyRoot,
		Difficulty:  big.NewInt(0x400000000),
		GasLimit:    5000,
		Extra:       mustHex(t, "11bbe8db4e347b4e8c937c1c8370e4b5ed33adb3db69cbdb7a38e1e50b1b82fa"),
		Nonce:       [8]byte{7: 0x42},
	}
	require.Equal(t, Frontier, h.Era())
	require.NoError(t, h.Validate())
	got, err := h.Hash()
	require.NoError(t, err)
	require.Equal(t, "0xd4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3", got.Hex())
}

// TestAnvilGenesisHeaders pins the genesis headers anvil 1.8.3 reported for five hardforks
// (field values and hashes copied from eth_getBlockByNumber("0x0") during development). Before
// Cancun anvil fills in blobGasUsed and excessBlobGas, which produces headers that mix eras;
// for Berlin and London only the present-only layout reproduces anvil's hash.
func TestAnvilGenesisHeaders(t *testing.T) {
	zero := uint64(0)
	emptyRoot := keccak.EmptyRoot
	var zeroHash keccak.Hash
	noRequests := keccak.MustParse("0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") // sha256("")
	genesis := func(ts uint64) Header {
		return Header{
			OmmersHash: keccak.EmptyList, StateRoot: keccak.EmptyRoot, TxRoot: keccak.EmptyRoot,
			ReceiptRoot: keccak.EmptyRoot, Difficulty: big.NewInt(0), GasLimit: 0x1c9c380, Time: ts,
			BlobGasUsed: &zero, ExcessBlobGas: &zero,
		}
	}
	cases := []struct {
		name      string
		header    func() Header
		want      string
		era       Era
		valid     bool
		canonical bool // the canonical layout reproduces the hash
	}{
		{"berlin", func() Header { return genesis(0x6abe108b) }, "0x337e9e4db18de7753aa84ae6cafb4dca5e16b111694b46dd1304d752fc81e0cb", Cancun, false, false},
		{"london", func() Header {
			h := genesis(0x6abe1091)
			h.BaseFee = big.NewInt(1_000_000_000)
			return h
		}, "0x5b5fb075ed0fef1ab5f7ba34cac036deeef5ab82ebe43f09e4f45d9378862d75", Cancun, false, false},
		{"shanghai", func() Header {
			h := genesis(0x6abe1098)
			h.BaseFee, h.WithdrawalsRoot = big.NewInt(1_000_000_000), &emptyRoot
			return h
		}, "0x7fe98c02886d31d3335f922ecd61afdf352a6635b9570e2d27291dfc809a7a9d", Cancun, false, true},
		{"cancun", func() Header {
			h := genesis(0x6abe109e)
			h.BaseFee, h.WithdrawalsRoot, h.ParentBeaconRoot = big.NewInt(1_000_000_000), &emptyRoot, &zeroHash
			return h
		}, "0xf6991772fbf926d49cdbba10bbdc91b3491cc432d057a3d1ce6ccc45703f2756", Cancun, true, true},
		{"prague", func() Header {
			h := genesis(0x6abe10a5)
			h.BaseFee, h.WithdrawalsRoot, h.ParentBeaconRoot = big.NewInt(1_000_000_000), &emptyRoot, &zeroHash
			h.RequestsHash = &noRequests
			return h
		}, "0xbdd6c6accda5dbe279b95617f66ca0c6ee214332162870a97ad4ec57fb8b6594", Prague, true, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := tc.header()
			require.Equal(t, tc.era, h.Era())
			if tc.valid {
				require.NoError(t, h.Validate())
			} else {
				require.ErrorIs(t, h.Validate(), ErrMixedEras)
			}
			present, err := h.HashLayout(PresentOnly)
			require.NoError(t, err)
			require.Equal(t, tc.want, present.Hex(), "present-only layout")
			canonical, err := h.Hash()
			require.NoError(t, err)
			require.Equal(t, tc.canonical, canonical.Hex() == tc.want, "canonical layout")
		})
	}
}

func TestEraAndValidate(t *testing.T) {
	one := uint64(1)
	h := Header{}
	require.Equal(t, Frontier, h.Era())
	h.BaseFee = big.NewInt(7)
	require.Equal(t, London, h.Era())
	require.NoError(t, h.Validate())
	h.ExcessBlobGas = &one
	require.Equal(t, Cancun, h.Era())
	err := h.Validate()
	require.ErrorIs(t, err, ErrMixedEras)
	require.Contains(t, err.Error(), "withdrawalsRoot")
	h.SlotNumber = &one
	require.Equal(t, Amsterdam, h.Era())
	require.Equal(t, "amsterdam", Amsterdam.String())
	require.Equal(t, "Era(9)", Era(9).String())
	require.Equal(t, "canonical", Canonical.String())
	require.Equal(t, "present-only", PresentOnly.String())
}

func TestHeaderEncodeErrors(t *testing.T) {
	h := Header{Difficulty: big.NewInt(-1)}
	_, err := h.Hash()
	require.Error(t, err)
	h = Header{BaseFee: big.NewInt(-1)}
	_, err = h.Encode()
	require.Error(t, err)
}

// randomHeader fills every field; for each optional field, present decides whether it exists.
func randomHeader(rng *rand.Rand, present [8]bool) (Header, *types.Header) {
	hash := func() keccak.Hash {
		var h keccak.Hash
		for i := range h {
			h[i] = byte(rng.Uint32())
		}
		return h
	}
	u64 := func() uint64 { return rng.Uint64() >> rng.IntN(64) }
	ours := Header{
		ParentHash: hash(), OmmersHash: hash(), StateRoot: hash(), TxRoot: hash(), ReceiptRoot: hash(),
		Difficulty: new(big.Int).SetUint64(u64()), Number: u64(), GasLimit: u64(), GasUsed: u64(), Time: u64(),
		Extra: make([]byte, rng.IntN(40)), MixDigest: hash(),
	}
	for i := range ours.Coinbase {
		ours.Coinbase[i] = byte(rng.Uint32())
	}
	for i := range ours.Bloom {
		if rng.IntN(8) == 0 {
			ours.Bloom[i] = byte(rng.Uint32())
		}
	}
	for i := range ours.Extra {
		ours.Extra[i] = byte(rng.Uint32())
	}
	for i := range ours.Nonce {
		ours.Nonce[i] = byte(rng.Uint32())
	}
	if present[0] {
		ours.BaseFee = new(big.Int).Lsh(new(big.Int).SetUint64(u64()), uint(rng.IntN(100)))
	}
	ptrHash := func(ok bool) *keccak.Hash {
		if !ok {
			return nil
		}
		h := hash()
		return &h
	}
	ptrU64 := func(ok bool) *uint64 {
		if !ok {
			return nil
		}
		v := u64()
		return &v
	}
	ours.WithdrawalsRoot = ptrHash(present[1])
	ours.BlobGasUsed = ptrU64(present[2])
	ours.ExcessBlobGas = ptrU64(present[3])
	ours.ParentBeaconRoot = ptrHash(present[4])
	ours.RequestsHash = ptrHash(present[5])
	ours.BlockAccessListHash = ptrHash(present[6])
	ours.SlotNumber = ptrU64(present[7])

	geth := &types.Header{
		ParentHash: common.Hash(ours.ParentHash), UncleHash: common.Hash(ours.OmmersHash),
		Coinbase: common.Address(ours.Coinbase), Root: common.Hash(ours.StateRoot),
		TxHash: common.Hash(ours.TxRoot), ReceiptHash: common.Hash(ours.ReceiptRoot),
		Bloom: types.Bloom(ours.Bloom), Difficulty: ours.Difficulty, Number: new(big.Int).SetUint64(ours.Number),
		GasLimit: ours.GasLimit, GasUsed: ours.GasUsed, Time: ours.Time, Extra: ours.Extra,
		MixDigest: common.Hash(ours.MixDigest), Nonce: types.BlockNonce(ours.Nonce), BaseFee: ours.BaseFee,
		BlobGasUsed: ours.BlobGasUsed, ExcessBlobGas: ours.ExcessBlobGas, SlotNumber: ours.SlotNumber,
	}
	geth.WithdrawalsHash = (*common.Hash)(ours.WithdrawalsRoot)
	geth.ParentBeaconRoot = (*common.Hash)(ours.ParentBeaconRoot)
	geth.RequestsHash = (*common.Hash)(ours.RequestsHash)
	geth.BlockAccessListHash = (*common.Hash)(ours.BlockAccessListHash)
	return ours, geth
}

func TestDifferentialHeaderEveryEra(t *testing.T) {
	rng := rand.New(rand.NewPCG(21, 2026))
	// Contiguous field sets, one per era: 0 (Frontier), 1 (London), 2 (Shanghai),
	// 5 (Cancun), 6 (Prague), 8 (Amsterdam) optional fields.
	for _, n := range []int{0, 1, 2, 5, 6, 8} {
		for range 200 {
			var present [8]bool
			for i := range n {
				present[i] = true
			}
			ours, geth := randomHeader(rng, present)
			require.NoError(t, ours.Validate())
			enc, err := ours.Encode()
			require.NoError(t, err)
			want, err := gethrlp.EncodeToBytes(geth)
			require.NoError(t, err)
			require.Equal(t, want, enc, "era %s", ours.Era())
			got, err := ours.Hash()
			require.NoError(t, err)
			require.Equal(t, geth.Hash(), common.Hash(got))
			present2, err := ours.EncodeLayout(PresentOnly)
			require.NoError(t, err)
			require.Equal(t, enc, present2, "layouts agree on valid headers")
		}
	}
}

func TestDifferentialHeaderGaps(t *testing.T) {
	// Arbitrary presence patterns: the Canonical layout matches go-ethereum's encoder, which
	// writes the empty string for every absent field before the last present one.
	rng := rand.New(rand.NewPCG(22, 2026))
	for range 500 {
		var present [8]bool
		for i := range present {
			present[i] = rng.IntN(2) == 0
		}
		ours, geth := randomHeader(rng, present)
		enc, err := ours.Encode()
		require.NoError(t, err)
		want, err := gethrlp.EncodeToBytes(geth)
		require.NoError(t, err)
		require.Equal(t, want, enc, "presence %v", present)
	}
}
