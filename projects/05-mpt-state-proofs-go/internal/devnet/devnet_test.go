// SPDX-License-Identifier: MIT

package devnet

import (
	"encoding/hex"
	"encoding/json"
	"math/big"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
)

func TestSelectorsMatchTheCompiledFixture(t *testing.T) {
	// forge build records the selectors of the compiled contract; the calldata this package
	// builds must use the same ones.
	raw, err := os.ReadFile(filepath.Join("..", "..", "fixtures", "out", "SlotWriter.sol", "SlotWriter.json"))
	if os.IsNotExist(err) {
		t.Fatal("run `forge build` in fixtures/ first")
	}
	require.NoError(t, err)
	var art struct {
		MethodIdentifiers map[string]string `json:"methodIdentifiers"`
	}
	require.NoError(t, json.Unmarshal(raw, &art))
	require.Equal(t, art.MethodIdentifiers["write(uint256,uint256)"], hex.EncodeToString(WriteCall(1, 2)[:4]))
	require.Equal(t, art.MethodIdentifiers["clear(uint256,uint256,uint256)"], hex.EncodeToString(ClearCall(1, 2, 3)[:4]))
	require.Len(t, WriteCall(1, 2), 4+64)
	require.Len(t, ClearCall(1, 2, 3), 4+96)

	code, err := LoadSlotWriter(filepath.Join("..", "..", "fixtures"))
	require.NoError(t, err)
	require.NotEmpty(t, code)
}

func TestLoadSlotWriterErrors(t *testing.T) {
	dir := t.TempDir()
	_, err := LoadSlotWriter(dir)
	require.ErrorContains(t, err, "forge build")

	art := filepath.Join(dir, "out", "SlotWriter.sol")
	require.NoError(t, os.MkdirAll(art, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(art, "SlotWriter.json"), []byte("{"), 0o644))
	_, err = LoadSlotWriter(dir)
	require.Error(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(art, "SlotWriter.json"), []byte(`{"bytecode":{"object":"0x"}}`), 0o644))
	_, err = LoadSlotWriter(dir)
	require.ErrorContains(t, err, "no creation bytecode")
}

func TestSlotAndValueFormulas(t *testing.T) {
	// slotOf(seed, i) = keccak256(abi.encode(seed, i)).
	var enc [64]byte
	enc[31], enc[63] = 7, 3
	require.Equal(t, keccak.Sum256(enc[:]), Slot(7, 3))

	slot := Slot(1, 0)
	full := keccak.Sum256(slot[:])
	require.Equal(t, full, Value(slot, 0), "i = 0 keeps the whole hash")
	require.Equal(t, full, Value(slot, 32), "i = 32 wraps around")
	v := Value(slot, 31)
	require.Equal(t, full[0], v[31], "i = 31 keeps the top byte only")
	require.True(t, new(big.Int).SetBytes(v[:]).IsUint64())

	// valueOf never returns zero: a hash whose top byte is zero becomes 1 at i = 31.
	for i := uint64(0); i < 5000; i++ {
		s := Slot(9, i)
		h := keccak.Sum256(s[:])
		if h[0] == 0 {
			require.Equal(t, keccak.Hash{31: 1}, Value(s, 31))
			break
		}
	}
	b := Batch(1, 10)
	require.Len(t, b, 10)
	for i := range uint64(10) {
		require.Equal(t, Value(Slot(1, i), i), b[Slot(1, i)])
	}
}

func TestTxJSON(t *testing.T) {
	to := keccak.Address{1}
	for _, tc := range []struct {
		tx   Tx
		want map[string]any
	}{
		{Tx{From: keccak.Address{2}, To: &to, Data: []byte{0xab}, Value: big.NewInt(255), Gas: 21000, Type: 0},
			map[string]any{"from": keccak.Address{2}.Hex(), "to": to.Hex(), "data": "0xab", "value": "0xff", "gas": "0x5208", "type": "0x0", "gasPrice": "0x77359400"}},
		{Tx{Type: 1}, map[string]any{"from": keccak.Address{}.Hex(), "data": "0x", "type": "0x1", "gasPrice": "0x77359400", "accessList": []any{}}},
		{Tx{Type: 2, AccessList: []AccessTuple{{Address: to, StorageKeys: []keccak.Hash{{}}}}}, map[string]any{
			"from": keccak.Address{}.Hex(), "data": "0x", "type": "0x2", "maxFeePerGas": "0x77359400", "maxPriorityFeePerGas": "0x3b9aca00",
			"accessList": []any{map[string]any{"address": to.Hex(), "storageKeys": []any{keccak.Hash{}.Hex()}}},
		}},
	} {
		raw, err := json.Marshal(tc.tx)
		require.NoError(t, err)
		var got map[string]any
		require.NoError(t, json.Unmarshal(raw, &got))
		require.Equal(t, tc.want, got)
	}
	_, err := json.Marshal(Tx{Type: 3})
	require.Error(t, err)
}

func TestStartFailsWithoutAnvil(t *testing.T) {
	_, err := Start(t.Context(), Options{Binary: filepath.Join(t.TempDir(), "no-such-anvil")})
	require.ErrorContains(t, err, "is Foundry installed")
}
