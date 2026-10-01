// SPDX-License-Identifier: MIT

package block

import (
	"bytes"
	"math/big"
	"math/rand/v2"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	gethtrie "github.com/ethereum/go-ethereum/trie"
	"github.com/holiman/uint256"
	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/rlp"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/trie"
)

func randBytes(rng *rand.Rand, n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(rng.Uint32())
	}
	return b
}

func randomLogs(rng *rand.Rand) ([]Log, []*types.Log) {
	n := rng.IntN(5)
	ours := make([]Log, n)
	geth := make([]*types.Log, n)
	for i := range n {
		var l Log
		copy(l.Address[:], randBytes(rng, 20))
		for range rng.IntN(5) {
			var topic keccak.Hash
			copy(topic[:], randBytes(rng, 32))
			l.Topics = append(l.Topics, topic)
		}
		l.Data = randBytes(rng, rng.IntN(100))
		ours[i] = l
		g := &types.Log{Address: common.Address(l.Address), Data: l.Data, Topics: []common.Hash{}}
		for _, tp := range l.Topics {
			g.Topics = append(g.Topics, common.Hash(tp))
		}
		geth[i] = g
	}
	return ours, geth
}

func TestDifferentialBloom(t *testing.T) {
	rng := rand.New(rand.NewPCG(31, 2026))
	for range 300 {
		logs, gethLogs := randomLogs(rng)
		want := types.CreateBloom(&types.Receipt{Logs: gethLogs})
		require.Equal(t, [256]byte(want), [256]byte(LogsBloom(logs)))
	}
	var b, c Bloom
	b.Add([]byte("x"))
	c.Or(b)
	require.Equal(t, b, c)
	require.Equal(t, Bloom{}, LogsBloom(nil))
}

func TestDifferentialReceipts(t *testing.T) {
	rng := rand.New(rand.NewPCG(32, 2026))
	for round := range 100 {
		n := rng.IntN(40)
		ours := make([]Receipt, n)
		geth := make(types.Receipts, n)
		var cumulative uint64
		for i := range n {
			logs, gethLogs := randomLogs(rng)
			cumulative += uint64(21000 + rng.IntN(1_000_000))
			r := Receipt{
				Type:              uint8(rng.IntN(5)),
				Status:            uint64(rng.IntN(2)),
				CumulativeGasUsed: cumulative,
				Bloom:             LogsBloom(logs),
				Logs:              logs,
			}
			g := &types.Receipt{Type: r.Type, Status: r.Status, CumulativeGasUsed: cumulative, Bloom: types.Bloom(r.Bloom), Logs: gethLogs}
			if r.Type == LegacyTxType && rng.IntN(4) == 0 { // pre-Byzantium receipt
				r.PostState = randBytes(rng, 32)
				g.PostState = r.PostState
			}
			ours[i], geth[i] = r, g

			enc, err := r.Encode()
			require.NoError(t, err)
			var buf bytes.Buffer
			geth.EncodeIndex(i, &buf)
			require.Equal(t, buf.Bytes(), enc, "round %d receipt %d type %d", round, i, r.Type)
		}
		got, err := ReceiptsRoot(ours)
		require.NoError(t, err)
		want := types.DeriveSha(geth, gethtrie.NewStackTrie(nil))
		require.Equal(t, want, common.Hash(got), "round %d", round)
	}
}

func TestReceiptStatusEncoding(t *testing.T) {
	ok := Receipt{Status: 1}
	enc, err := ok.Encode()
	require.NoError(t, err)
	require.Equal(t, byte(0x01), enc[1+0], "status 1 is the byte 0x01")

	failed := Receipt{Type: DynamicFeeTxType}
	enc, err = failed.Encode()
	require.NoError(t, err)
	require.Equal(t, byte(DynamicFeeTxType), enc[0])
	v, err := rlp.Decode(enc[1:])
	require.NoError(t, err)
	require.Empty(t, v.Items[0].Bytes, "status 0 is the empty string")

	_, err = (&Receipt{Status: 2}).Encode()
	require.ErrorIs(t, err, ErrInvalidStatus)
	_, err = ReceiptsRoot([]Receipt{{Status: 2}})
	require.ErrorIs(t, err, ErrInvalidStatus)
}

// randomTxs builds one transaction of each type with random fields. Signatures are random
// numbers: transactionsRoot commits to the bytes, not to their validity.
func randomTxs(rng *rand.Rand) types.Transactions {
	u := func() *uint256.Int { return uint256.NewInt(rng.Uint64() >> rng.IntN(64)) }
	addr := common.Address(randBytes(rng, 20))
	al := types.AccessList{{Address: addr, StorageKeys: []common.Hash{common.Hash(randBytes(rng, 32))}}}
	data := randBytes(rng, rng.IntN(200))
	var txs types.Transactions
	switch rng.IntN(5) {
	case 0:
		txs = append(txs, types.NewTx(&types.LegacyTx{Nonce: rng.Uint64(), GasPrice: big.NewInt(int64(rng.Uint32())), Gas: 21000, To: &addr, Value: big.NewInt(1), Data: data, V: big.NewInt(27), R: big.NewInt(int64(rng.Uint32())), S: big.NewInt(int64(rng.Uint32()))}))
	case 1:
		txs = append(txs, types.NewTx(&types.AccessListTx{ChainID: big.NewInt(31337), Nonce: rng.Uint64(), GasPrice: big.NewInt(7), Gas: 50000, To: &addr, Value: big.NewInt(0), Data: data, AccessList: al, V: big.NewInt(1), R: big.NewInt(2), S: big.NewInt(3)}))
	case 2:
		txs = append(txs, types.NewTx(&types.DynamicFeeTx{ChainID: big.NewInt(1), Nonce: rng.Uint64(), GasTipCap: big.NewInt(1), GasFeeCap: big.NewInt(9), Gas: 60000, Data: data, AccessList: al, V: big.NewInt(0), R: big.NewInt(5), S: big.NewInt(6)}))
	case 3:
		txs = append(txs, types.NewTx(&types.BlobTx{ChainID: uint256.NewInt(1), Nonce: rng.Uint64(), GasTipCap: u(), GasFeeCap: u(), Gas: 100000, To: addr, Value: u(), Data: data, AccessList: al, BlobFeeCap: u(), BlobHashes: []common.Hash{common.Hash(randBytes(rng, 32))}, V: uint256.NewInt(1), R: u(), S: u()}))
	case 4:
		auth := types.SetCodeAuthorization{ChainID: *uint256.NewInt(1), Address: addr, Nonce: rng.Uint64(), V: 1, R: *u(), S: *u()}
		txs = append(txs, types.NewTx(&types.SetCodeTx{ChainID: uint256.NewInt(1), Nonce: rng.Uint64(), GasTipCap: u(), GasFeeCap: u(), Gas: 100000, To: addr, Value: u(), Data: data, AccessList: al, AuthList: []types.SetCodeAuthorization{auth}, V: uint256.NewInt(0), R: u(), S: u()}))
	}
	return txs
}

func TestDifferentialTransactionsRoot(t *testing.T) {
	rng := rand.New(rand.NewPCG(33, 2026))
	for round := range 100 {
		var txs types.Transactions
		for range rng.IntN(300) { // past 127 items, where RLP(index) changes width
			txs = append(txs, randomTxs(rng)...)
		}
		raw := make([][]byte, len(txs))
		for i, tx := range txs {
			b, err := tx.MarshalBinary()
			require.NoError(t, err)
			raw[i] = b
			typ, err := TxType(b)
			require.NoError(t, err)
			require.Equal(t, tx.Type(), typ)
			require.Equal(t, tx.Hash(), common.Hash(TxHash(b)))
		}
		want := types.DeriveSha(txs, gethtrie.NewStackTrie(nil))
		require.Equal(t, want, common.Hash(TransactionsRoot(raw)), "round %d (%d txs)", round, len(txs))
	}
	require.Equal(t, keccak.EmptyRoot, TransactionsRoot(nil))
}

func TestTxTypeRejects(t *testing.T) {
	cases := map[string][]byte{
		"empty":                     nil,
		"string where a list goes":  {0x83, 1, 2, 3},
		"typed with string payload": {0x02, 0x80},
		"typed with no payload":     {0x02},
		"legacy with trailing data": {0xc0, 0x00},
		"truncated legacy":          {0xc3, 0x80},
	}
	for name, raw := range cases {
		_, err := TxType(raw)
		require.ErrorIs(t, err, ErrInvalidTx, name)
	}
	for typ, name := range map[uint8]string{0: "legacy", 1: "access-list", 2: "dynamic-fee", 3: "blob", 4: "set-code", 0x7e: "type-0x7e"} {
		require.Equal(t, name, TxTypeName(typ))
	}
}

func TestDifferentialWithdrawalsRoot(t *testing.T) {
	rng := rand.New(rand.NewPCG(34, 2026))
	for range 50 {
		n := rng.IntN(20)
		ours := make([]Withdrawal, n)
		geth := make(types.Withdrawals, n)
		for i := range n {
			w := Withdrawal{Index: rng.Uint64(), Validator: rng.Uint64() >> 20, Amount: rng.Uint64() >> 30}
			copy(w.Address[:], randBytes(rng, 20))
			ours[i] = w
			geth[i] = &types.Withdrawal{Index: w.Index, Validator: w.Validator, Address: common.Address(w.Address), Amount: w.Amount}
		}
		require.Equal(t, types.DeriveSha(geth, gethtrie.NewStackTrie(nil)), common.Hash(WithdrawalsRoot(ours)))
	}
}

func TestDifferentialOmmersHash(t *testing.T) {
	got, err := OmmersHash(nil)
	require.NoError(t, err)
	require.Equal(t, keccak.EmptyList, got)

	rng := rand.New(rand.NewPCG(35, 2026))
	var ours []Header
	var geth []*types.Header
	for range 2 {
		h, g := randomHeader(rng, [8]bool{true})
		ours, geth = append(ours, h), append(geth, g)
	}
	got, err = OmmersHash(ours)
	require.NoError(t, err)
	require.Equal(t, types.CalcUncleHash(geth), common.Hash(got))

	_, err = OmmersHash([]Header{{Difficulty: big.NewInt(-1)}})
	require.Error(t, err)
}

func TestListRootKeys(t *testing.T) {
	// ListRoot keys item i by RLP(i): 0x80 for 0, the byte itself for 1..127, 0x81 0x80 for
	// 128. Building the same trie with those literal keys must give the same root.
	items := make([][]byte, 130)
	manual := trie.New()
	for i := range items {
		items[i] = []byte{byte(i), 0xff}
		var key []byte
		switch {
		case i == 0:
			key = []byte{0x80}
		case i < 128:
			key = []byte{byte(i)}
		default:
			key = []byte{0x81, byte(i)}
		}
		manual.Put(key, items[i])
	}
	require.Equal(t, manual.Hash(), ListRoot(items))
	require.Equal(t, keccak.EmptyRoot, ListRoot(nil))
}
