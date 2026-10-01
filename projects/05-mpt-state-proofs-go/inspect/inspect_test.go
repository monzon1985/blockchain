// SPDX-License-Identifier: MIT

package inspect

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/block"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/ethrpc"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/rlp"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/stateproof"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/trie"
)

// fake is a Source backed by data recorded from anvil (internal/cli/testdata), which the
// tests then corrupt in specific ways.
type fake struct {
	block    *ethrpc.Block
	raws     map[keccak.Hash][]byte
	receipts []ethrpc.Receipt
	proof    *stateproof.GetProofResult
	storage  map[keccak.Hash]keccak.Hash
	fail     string // method that returns an error
}

var errFake = errors.New("fake transport error")

func (f *fake) BlockByRef(_ context.Context, _ ethrpc.BlockRef) (*ethrpc.Block, error) {
	if f.fail == "block" {
		return nil, errFake
	}
	return f.block, nil
}

func (f *fake) RawTransactions(_ context.Context, hashes []keccak.Hash) ([][]byte, error) {
	if f.fail == "raw" {
		return nil, errFake
	}
	out := make([][]byte, len(hashes))
	for i, h := range hashes {
		out[i] = f.raws[h]
	}
	return out, nil
}

func (f *fake) BlockReceipts(_ context.Context, _ ethrpc.BlockRef) ([]ethrpc.Receipt, error) {
	if f.fail == "receipts" {
		return nil, errFake
	}
	return f.receipts, nil
}

func (f *fake) GetProof(_ context.Context, _ keccak.Address, _ []keccak.Hash, _ ethrpc.BlockRef) (*stateproof.GetProofResult, error) {
	if f.fail == "proof" {
		return nil, errFake
	}
	return f.proof, nil
}

func (f *fake) StorageAt(_ context.Context, _ keccak.Address, slot keccak.Hash, _ ethrpc.BlockRef) (keccak.Hash, error) {
	if f.fail == "storage" {
		return keccak.Hash{}, errFake
	}
	return f.storage[slot], nil
}

// load builds a fake from a recorded cassette.
func load(t *testing.T, cassette string) *fake {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "internal", "cli", "testdata", cassette+".cassette.json"))
	require.NoError(t, err)
	var c struct {
		Calls []struct {
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
			Result json.RawMessage `json:"result"`
		} `json:"calls"`
	}
	require.NoError(t, json.Unmarshal(raw, &c))
	f := &fake{raws: map[keccak.Hash][]byte{}, storage: map[keccak.Hash]keccak.Hash{}}
	for _, call := range c.Calls {
		var params []string
		_ = json.Unmarshal(call.Params, &params)
		switch call.Method {
		case "eth_getBlockByNumber":
			f.block, err = ethrpc.DecodeBlock(call.Result)
			require.NoError(t, err)
		case "eth_getBlockReceipts":
			f.receipts, err = ethrpc.DecodeReceipts(call.Result)
			require.NoError(t, err)
		case "eth_getProof":
			f.proof, err = ethrpc.DecodeProof(call.Result)
			require.NoError(t, err)
		case "eth_getRawTransactionByHash":
			var s string
			require.NoError(t, json.Unmarshal(call.Result, &s))
			h, err := keccak.Parse(params[0])
			require.NoError(t, err)
			f.raws[h], err = hex.DecodeString(strings.TrimPrefix(s, "0x"))
			require.NoError(t, err)
		case "eth_getStorageAt":
			var s string
			require.NoError(t, json.Unmarshal(call.Result, &s))
			slot, err := keccak.Parse(params[1])
			require.NoError(t, err)
			v, err := ethrpc.ParseSlot(s)
			require.NoError(t, err)
			f.storage[slot] = v
		}
	}
	require.NotNil(t, f.block)
	return f
}

func statusOf(checks Checks, name string) Status {
	s := Status(255)
	for _, c := range checks {
		if c.Name == name {
			s = c.Status
		}
	}
	return s
}

func verifyBlock(t *testing.T, f *fake, ref ethrpc.BlockRef) *BlockReport {
	t.Helper()
	rep, err := VerifyBlock(context.Background(), f, ref)
	require.NoError(t, err)
	return rep
}

func TestVerifyBlockRecorded(t *testing.T) {
	for _, name := range []string{"verify-block-0", "verify-block-1", "verify-block-2", "verify-block-3"} {
		f := load(t, name)
		rep := verifyBlock(t, f, ethrpc.Number(f.block.Header.Number))
		require.True(t, rep.Checks.OK(true), "%s: %s", name, rep.Checks.Verdict())
		require.Equal(t, "prague", rep.Era)
	}
	rep := verifyBlock(t, load(t, "verify-block-1"), ethrpc.Latest())
	require.Equal(t, 3, rep.Transactions)
	require.Equal(t, map[string]int{"legacy": 1, "access-list": 1, "dynamic-fee": 1}, rep.TxTypes)
	require.Equal(t, "VERIFIED (13 checks)", rep.Checks.Verdict())
}

func TestVerifyBlockTransportErrors(t *testing.T) {
	for _, m := range []string{"block", "raw", "receipts"} {
		f := load(t, "verify-block-1")
		f.fail = m
		_, err := VerifyBlock(context.Background(), f, ethrpc.Number(1))
		require.ErrorIs(t, err, errFake, m)
	}
}

func TestVerifyBlockDetectsInconsistencies(t *testing.T) {
	cases := []struct {
		name    string
		base    string
		ref     ethrpc.BlockRef
		mutate  func(f *fake)
		check   string
		want    Status
		verdict string
	}{
		{"node returns another block", "verify-block-1", ethrpc.Number(5), func(*fake) {}, "block number", Fail, "FAILED"},
		{"unknown header field", "verify-block-1", ethrpc.Number(1), func(f *fake) { f.block.UnknownFields = []string{"l1BlockNumber"} }, "unknown fields", Warn, "WITH WARNINGS"},
		{"unencodable header", "verify-block-1", ethrpc.Number(1), func(f *fake) { f.block.Header.Difficulty = big.NewInt(-1) }, "block hash", Fail, "FAILED"},
		{"invalid raw envelope", "verify-block-1", ethrpc.Number(1), func(f *fake) {
			f.raws[f.block.TxHashes[0]] = []byte{0x80}
		}, "transaction hashes", Fail, "FAILED"},
		{"missing receipt", "verify-block-1", ethrpc.Number(1), func(f *fake) { f.receipts = f.receipts[:2] }, "receipt identity", Fail, "FAILED"},
		{"receipt from another block", "verify-block-1", ethrpc.Number(1), func(f *fake) { f.receipts[1].BlockHash[0] ^= 1 }, "receipt identity", Fail, "FAILED"},
		{"receipt index shifted", "verify-block-1", ethrpc.Number(1), func(f *fake) { f.receipts[1].TxIndex = 7 }, "receipt identity", Fail, "FAILED"},
		{"receipt for another tx", "verify-block-1", ethrpc.Number(1), func(f *fake) { f.receipts[1].TxHash[0] ^= 1 }, "receipt identity", Fail, "FAILED"},
		{"receipt type differs", "verify-block-1", ethrpc.Number(1), func(f *fake) { f.receipts[1].Type = 3 }, "receipt identity", Fail, "FAILED"},
		{"cumulative gas decreases", "verify-block-1", ethrpc.Number(1), func(f *fake) { f.receipts[2].CumulativeGasUsed = 1 }, "gasUsed", Fail, "FAILED"},
		{"gas used differs", "verify-block-1", ethrpc.Number(1), func(f *fake) { f.block.Header.GasUsed++ }, "gasUsed", Fail, "FAILED"},
		{"unencodable receipt", "verify-block-1", ethrpc.Number(1), func(f *fake) { f.receipts[0].Status = 2 }, "receiptsRoot", Fail, "FAILED"},
		{"header bloom differs", "verify-block-3", ethrpc.Number(3), func(f *fake) { f.block.Header.Bloom = block.Bloom{} }, "logsBloom", Fail, "FAILED"},
		{"receipt bloom differs", "verify-block-3", ethrpc.Number(3), func(f *fake) {
			for i := range f.receipts {
				f.receipts[i].Bloom = block.Bloom{}
			}
		}, "receipt blooms", Fail, "FAILED"},
		{"withdrawals without a root", "verify-block-1", ethrpc.Number(1), func(f *fake) {
			f.block.Header.WithdrawalsRoot = nil
			f.block.Withdrawals = []block.Withdrawal{{Index: 1}}
		}, "withdrawalsRoot", Fail, "FAILED"},
		{"root without withdrawals", "verify-block-1", ethrpc.Number(1), func(f *fake) { f.block.Withdrawals = nil }, "withdrawalsRoot", Fail, "FAILED"},
		{"withdrawal not committed", "verify-block-1", ethrpc.Number(1), func(f *fake) { f.block.Withdrawals = []block.Withdrawal{{Index: 1, Amount: 32}} }, "withdrawalsRoot", Fail, "FAILED"},
		{"ommers not fetched", "verify-block-1", ethrpc.Number(1), func(f *fake) { f.block.Uncles = []keccak.Hash{{1}} }, "ommersHash", Warn, "WITH WARNINGS"},
		{"requests present", "verify-block-1", ethrpc.Number(1), func(f *fake) { f.block.Header.RequestsHash = &keccak.Hash{1} }, "requestsHash", Warn, "FAILED"},
		{"blob gas without blobs", "verify-block-1", ethrpc.Number(1), func(f *fake) { v := uint64(block.GasPerBlob); f.block.Header.BlobGasUsed = &v }, "blobGasUsed", Fail, "FAILED"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := load(t, tc.base)
			tc.mutate(f)
			rep := verifyBlock(t, f, tc.ref)
			require.Equal(t, tc.want, statusOf(rep.Checks, tc.check), rep.Checks.Verdict())
			require.Contains(t, rep.Checks.Verdict(), tc.verdict)
		})
	}
}

// blobTx builds a raw type-3 envelope with n blob hashes (unsigned: only the shape matters).
func blobTx(n int) []byte {
	hashes := make([][]byte, n)
	for i := range hashes {
		h := keccak.Sum256([]byte{byte(i)})
		hashes[i] = rlp.EncodeString(h[:])
	}
	zero := rlp.EncodeUint64(0)
	fields := [][]byte{zero, zero, zero, zero, zero, rlp.EncodeString(make([]byte, 20)), zero, rlp.EncodeString(nil), rlp.EncodeList(), zero, rlp.EncodeList(hashes...), zero, zero, zero}
	return append([]byte{block.BlobTxType}, rlp.EncodeList(fields...)...)
}

func TestBlobGas(t *testing.T) {
	f := load(t, "verify-block-1")
	tx := blobTx(3)
	h := block.TxHash(tx)
	f.raws[h] = tx
	f.block.TxHashes = []keccak.Hash{h}
	f.receipts = nil
	used := uint64(3 * block.GasPerBlob)
	f.block.Header.BlobGasUsed = &used
	rep := verifyBlock(t, f, ethrpc.Number(1))
	require.Equal(t, Pass, statusOf(rep.Checks, "blobGasUsed"))
	require.Equal(t, 1, rep.TxTypes["blob"])

	used = 2 * block.GasPerBlob
	rep = verifyBlock(t, f, ethrpc.Number(1))
	require.Equal(t, Fail, statusOf(rep.Checks, "blobGasUsed"))

	bad := append([]byte{block.BlobTxType}, rlp.EncodeList(rlp.EncodeUint64(1))...) // 1 field, not 14
	f.raws[h] = bad
	rep = verifyBlock(t, f, ethrpc.Number(1))
	require.Equal(t, Fail, statusOf(rep.Checks, "blobGasUsed"))

	_, err := block.BlobCount([]byte{0x02, 0xc0})
	require.ErrorIs(t, err, block.ErrInvalidTx)
	_, err = block.BlobCount([]byte{0x03, 0x81})
	require.ErrorIs(t, err, block.ErrInvalidTx)
	tooFew := blobTx(1)
	fields, _ := rlp.Decode(tooFew[1:])
	fields.Items[10] = rlp.Str(nil)
	_, err = block.BlobCount(append([]byte{3}, fields.Encode()...))
	require.ErrorIs(t, err, block.ErrInvalidTx, "blobVersionedHashes must be a list")
}

func TestVerifyBlockPresentOnlyLayout(t *testing.T) {
	// Reproduce anvil's pre-Cancun genesis: blob fields without the fields before them, hashed
	// with the present-only layout.
	f := load(t, "verify-block-0")
	h := &f.block.Header
	h.WithdrawalsRoot, h.ParentBeaconRoot, h.RequestsHash, f.block.Withdrawals = nil, nil, nil, nil
	present, err := h.HashLayout(block.PresentOnly)
	require.NoError(t, err)
	f.block.Hash = present
	rep := verifyBlock(t, f, ethrpc.Number(0))
	require.Equal(t, Warn, statusOf(rep.Checks, "block hash"))
	require.Equal(t, Warn, statusOf(rep.Checks, "header fields"))
	require.True(t, rep.Checks.OK(false))
	require.False(t, rep.Checks.OK(true))
}

func TestVerifyProof(t *testing.T) {
	ctx := context.Background()
	f := load(t, "verify-proof-contract")
	slots := make([]keccak.Hash, len(f.proof.StorageProof))
	for i, s := range f.proof.StorageProof {
		slots[i] = s.Key
	}
	rep, err := VerifyProof(ctx, f, f.proof.Address, slots, ethrpc.Number(3))
	require.NoError(t, err)
	require.True(t, rep.Checks.OK(true), rep.Checks.Verdict())
	require.True(t, rep.Account.Exists)
	require.Len(t, rep.Slots, 3)

	// Wrong address, wrong slot list, wrong slot order.
	rep, err = VerifyProof(ctx, f, keccak.Address{1}, slots, ethrpc.Number(3))
	require.NoError(t, err)
	require.Equal(t, Fail, statusOf(rep.Checks, "address"))
	rep, err = VerifyProof(ctx, f, f.proof.Address, slots[:1], ethrpc.Number(3))
	require.NoError(t, err)
	require.Equal(t, Fail, statusOf(rep.Checks, "storage proofs"))
	rep, err = VerifyProof(ctx, f, f.proof.Address, []keccak.Hash{slots[1], slots[0], slots[2]}, ethrpc.Number(3))
	require.NoError(t, err)
	require.Equal(t, Fail, statusOf(rep.Checks, "storage proofs"))

	// An invalid proof and a lying claim.
	f.proof.AccountProof[0] = append([]byte{}, f.proof.AccountProof[0][:len(f.proof.AccountProof[0])-1]...)
	rep, err = VerifyProof(ctx, f, f.proof.Address, slots, ethrpc.Number(3))
	require.NoError(t, err)
	require.Equal(t, Fail, statusOf(rep.Checks, "proofs"))

	f = load(t, "verify-proof-contract")
	f.proof.Nonce = 99
	rep, err = VerifyProof(ctx, f, f.proof.Address, slots, ethrpc.Number(3))
	require.NoError(t, err)
	require.Equal(t, Fail, statusOf(rep.Checks, "claims"))

	// Transport errors.
	for _, m := range []string{"block", "proof"} {
		f := load(t, "verify-proof-contract")
		f.fail = m
		_, err := VerifyProof(ctx, f, f.proof.Address, slots, ethrpc.Number(3))
		require.ErrorIs(t, err, errFake)
	}

	// An absent account, reported with an exclusion proof.
	f = load(t, "verify-proof-absent")
	rep, err = VerifyProof(ctx, f, f.proof.Address, []keccak.Hash{f.proof.StorageProof[0].Key}, ethrpc.Number(3))
	require.NoError(t, err)
	require.True(t, rep.Checks.OK(true), rep.Checks.Verdict())
	require.False(t, rep.Account.Exists)
	var buf bytes.Buffer
	rep.WriteText(&buf)
	require.Contains(t, buf.String(), "no account")
	require.Contains(t, buf.String(), "empty storage trie")
}

func TestRebuildStorage(t *testing.T) {
	ctx := context.Background()
	f := load(t, "storage-root")
	slots := make([]keccak.Hash, 0, len(f.storage))
	for s := range f.storage {
		slots = append(slots, s)
	}
	rep, err := RebuildStorage(ctx, f, f.proof.Address, slots, ethrpc.Number(3))
	require.NoError(t, err)
	require.True(t, rep.Checks.OK(true), rep.Checks.Verdict())
	require.Equal(t, 150, rep.NonZero)
	require.Equal(t, rep.StorageRoot, rep.Rebuilt)

	// A claim mismatch is reported but the rebuild still runs.
	f.proof.Balance = big.NewInt(1)
	rep, err = RebuildStorage(ctx, f, f.proof.Address, slots, ethrpc.Number(3))
	require.NoError(t, err)
	require.Equal(t, Fail, statusOf(rep.Checks, "claims"))
	require.Equal(t, Pass, statusOf(rep.Checks, "storage root"))

	// No account / invalid proof.
	absent := load(t, "verify-proof-absent")
	f = load(t, "storage-root")
	f.proof = absent.proof
	f.block = absent.block
	rep, err = RebuildStorage(ctx, f, f.proof.Address, slots, ethrpc.Number(3))
	require.NoError(t, err)
	require.Equal(t, Fail, statusOf(rep.Checks, "account proof"))
	f = load(t, "storage-root")
	f.proof.AccountProof = f.proof.AccountProof[1:]
	rep, err = RebuildStorage(ctx, f, f.proof.Address, slots, ethrpc.Number(3))
	require.NoError(t, err)
	require.Equal(t, Fail, statusOf(rep.Checks, "account proof"))

	for _, m := range []string{"block", "proof", "storage"} {
		f := load(t, "storage-root")
		f.fail = m
		_, err := RebuildStorage(ctx, f, f.proof.Address, slots, ethrpc.Number(3))
		require.ErrorIs(t, err, errFake, m)
	}
}

func TestDescribePath(t *testing.T) {
	require.Equal(t, "branch > extension > branch(inline) > leaf(inline)", describePath([]trie.Step{
		{Kind: trie.Branch}, {Kind: trie.Extension}, {Kind: trie.Branch, Inline: true}, {Kind: trie.Leaf, Inline: true},
	}))
	require.Equal(t, "", describePath(nil))
	require.Equal(t, "empty storage trie", emptyPath(""))
}

func TestReportRendering(t *testing.T) {
	require.Equal(t, "ok", Pass.String())
	require.Equal(t, "warn", Warn.String())
	require.Equal(t, "fail", Fail.String())
	text, err := Warn.MarshalText()
	require.NoError(t, err)
	require.Equal(t, "warn", string(text))
	require.Equal(t, "1 entry", plural(1, "entry"))
	require.Equal(t, "2 entries", plural(2, "entry"))
	require.Equal(t, "0 logs", plural(0, "log"))

	var c Checks
	c.add("a", Pass, "fine")
	require.Equal(t, "VERIFIED (1 checks)", c.Verdict())
	c.compare("b", keccak.Hash{1}, keccak.Hash{2}, "roots")
	require.Equal(t, "FAILED (1 of 2 checks failed)", c.Verdict())
	var buf bytes.Buffer
	writeChecks(&buf, c)
	require.Contains(t, buf.String(), "reported 0x01")
	require.Contains(t, buf.String(), "computed 0x02")

	f := load(t, "verify-block-1")
	rep := verifyBlock(t, f, ethrpc.Number(1))
	buf.Reset()
	require.NoError(t, WriteJSON(&buf, rep))
	var decoded map[string]any
	require.NoError(t, json.Unmarshal(buf.Bytes(), &decoded))
	require.Equal(t, "ok", decoded["checks"].([]any)[0].(map[string]any)["status"])
}
