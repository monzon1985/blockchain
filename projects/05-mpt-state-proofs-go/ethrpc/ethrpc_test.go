// SPDX-License-Identifier: MIT

package ethrpc

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/block"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
)

// recorded returns the result of the first call to method in a cassette recorded from anvil
// (see internal/tools/recordfixtures).
func recorded(t *testing.T, cassette, method string) json.RawMessage {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "internal", "cli", "testdata", cassette+".cassette.json"))
	require.NoError(t, err)
	var c struct {
		Calls []struct {
			Method string          `json:"method"`
			Result json.RawMessage `json:"result"`
		} `json:"calls"`
	}
	require.NoError(t, json.Unmarshal(raw, &c))
	for _, call := range c.Calls {
		if call.Method == method {
			return call.Result
		}
	}
	t.Fatalf("no %s in %s", method, cassette)
	return nil
}

// patch decodes a JSON object, applies f, and re-encodes it.
func patch(t *testing.T, raw json.RawMessage, f func(m map[string]any)) json.RawMessage {
	t.Helper()
	var m map[string]any
	require.NoError(t, json.Unmarshal(raw, &m))
	f(m)
	out, err := json.Marshal(m)
	require.NoError(t, err)
	return out
}

func TestQuantityAndData(t *testing.T) {
	for _, tc := range []struct {
		in   string
		want string
		ok   bool
	}{
		{"0x0", "0", true},
		{"0x1a", "26", true},
		{"0x" + strings.Repeat("f", 64), "115792089237316195423570985008687907853269984665640564039457584007913129639935", true},
		{"0x", "", false},
		{"1a", "", false},
		{"0x01", "", false}, // leading zero
		{"0x" + strings.Repeat("f", 65), "", false},
		{"0xg", "", false},
		// Signs: big.Int.SetString accepts them, the JSON-RPC quantity grammar does not.
		{"0x+1", "", false},
		{"0x-1", "", false},
		{"0x-0", "", false},
		{"0x+ff", "", false},
		{"0x+01", "", false}, // a sign must not hide a leading zero
		{"0x+0ff", "", false},
		{"0x 1", "", false},
		{"0x1_0", "", false},
	} {
		v, err := parseQuantity(tc.in)
		if !tc.ok {
			require.ErrorIs(t, err, ErrBadHex, tc.in)
			continue
		}
		require.NoError(t, err, tc.in)
		require.Equal(t, tc.want, v.String())
	}
	_, err := parseUint64("0x10000000000000000")
	require.ErrorIs(t, err, ErrBadHex)
	_, err = parseUint64("nope")
	require.ErrorIs(t, err, ErrBadHex)

	b, err := parseData("0x")
	require.NoError(t, err)
	require.Empty(t, b)
	_, err = parseData("abcd")
	require.ErrorIs(t, err, ErrBadHex)
	_, err = parseData("0xabc")
	require.ErrorIs(t, err, ErrBadHex)
	_, err = parseHash("0x1234")
	require.ErrorIs(t, err, ErrBadHex)
	_, err = parseAddress("0x1234")
	require.ErrorIs(t, err, ErrBadHex)
	_, err = jsonString(json.RawMessage(`12`))
	require.ErrorIs(t, err, ErrBadHex)
	require.Equal(t, `"`+strings.Repeat("a", 39)+"...", truncate([]byte(`"`+strings.Repeat("a", 60))))
}

func TestSlots(t *testing.T) {
	one := keccak.Hash{31: 1}
	for _, in := range []string{"1", "0x1", "0X01", "0x" + strings.Repeat("0", 63) + "1"} {
		got, err := ParseSlot(in)
		require.NoError(t, err, in)
		require.Equal(t, one, got, in)
	}
	got, err := parseSlot("0x0")
	require.NoError(t, err)
	require.Equal(t, keccak.Hash{}, got)
	for _, bad := range []string{"-1", "+5", "-0", "+0", " 1", "1_000", "", "x", "0x", "0xzz", "0x+1", "0x-1", "0x" + strings.Repeat("1", 65), "115792089237316195423570985008687907853269984665640564039457584007913129639936"} {
		_, err := ParseSlot(bad)
		require.Error(t, err, bad)
	}
	_, err = parseSlot("12")
	require.ErrorIs(t, err, ErrBadHex)
}

func TestBlockRef(t *testing.T) {
	for in, arg := range map[string]string{"latest": "latest", "safe": "safe", "finalized": "finalized", "pending": "pending", "earliest": "earliest", "26": "0x1a", "0x1a": "0x1a", "0": "0x0"} {
		r, err := ParseBlockRef(in)
		require.NoError(t, err, in)
		require.Equal(t, arg, r.Arg())
	}
	require.Equal(t, "latest", Latest().String())
	require.Equal(t, "26", Number(26).String())
	for _, bad := range []string{"", "head", "-1", "0x", "1.5", "0xzz"} {
		_, err := ParseBlockRef(bad)
		require.Error(t, err, bad)
	}
}

func TestDecodeBlockFromAnvil(t *testing.T) {
	raw := recorded(t, "verify-block-1", "eth_getBlockByNumber")
	b, err := DecodeBlock(raw)
	require.NoError(t, err)
	require.Equal(t, uint64(1), b.Header.Number)
	require.Len(t, b.TxHashes, 3)
	require.NotNil(t, b.Withdrawals)
	require.Empty(t, b.Withdrawals)
	require.Empty(t, b.UnknownFields)
	require.Equal(t, block.Prague, b.Header.Era())
	h, err := b.Header.Hash()
	require.NoError(t, err)
	require.Equal(t, b.Hash, h, "a block decoded from anvil hashes to its reported hash")

	// Withdrawals, uncles, unknown fields.
	withExtras := patch(t, raw, func(m map[string]any) {
		m["withdrawals"] = []any{map[string]any{"index": "0x1", "validatorIndex": "0x2", "address": "0x00000000000000000000000000000000000000aa", "amount": "0x3"}}
		m["uncles"] = []any{"0x" + strings.Repeat("11", 32)}
		m["l1BlockNumber"] = "0x5"
	})
	b, err = DecodeBlock(withExtras)
	require.NoError(t, err)
	require.Equal(t, []block.Withdrawal{{Index: 1, Validator: 2, Address: keccak.Address{19: 0xaa}, Amount: 3}}, b.Withdrawals)
	require.Len(t, b.Uncles, 1)
	require.Equal(t, []string{"l1BlockNumber"}, b.UnknownFields)

	// Optional fields absent (a London-era block).
	london := patch(t, raw, func(m map[string]any) {
		for _, k := range []string{"withdrawalsRoot", "blobGasUsed", "excessBlobGas", "parentBeaconBlockRoot", "requestsHash", "withdrawals"} {
			delete(m, k)
		}
	})
	b, err = DecodeBlock(london)
	require.NoError(t, err)
	require.Equal(t, block.London, b.Header.Era())
	require.Nil(t, b.Withdrawals)
	nulls := patch(t, raw, func(m map[string]any) { m["requestsHash"] = nil })
	b, err = DecodeBlock(nulls)
	require.NoError(t, err)
	require.Nil(t, b.Header.RequestsHash, "null is absent")
}

func TestDecodeBlockRejects(t *testing.T) {
	raw := recorded(t, "verify-block-1", "eth_getBlockByNumber")
	cases := map[string]func(m map[string]any){
		"missing stateRoot":        func(m map[string]any) { delete(m, "stateRoot") },
		"short logsBloom":          func(m map[string]any) { m["logsBloom"] = "0x00" },
		"number with leading zero": func(m map[string]any) { m["number"] = "0x01" },
		"hash not a string":        func(m map[string]any) { m["hash"] = 7 },
		"full transactions":        func(m map[string]any) { m["transactions"] = []any{map[string]any{"hash": "0x00"}} },
		"bad transaction hash":     func(m map[string]any) { m["transactions"] = []any{"0x1234"} },
		"transactions not array":   func(m map[string]any) { m["transactions"] = "0x" },
		"bad uncle":                func(m map[string]any) { m["uncles"] = []any{"0x12"} },
		"bad withdrawal":           func(m map[string]any) { m["withdrawals"] = []any{map[string]any{"index": "0x1"}} },
		"withdrawal not an object": func(m map[string]any) { m["withdrawals"] = []any{"0x1"} },
		"bad baseFee":              func(m map[string]any) { m["baseFeePerGas"] = "0x" },
		"bad optional hash":        func(m map[string]any) { m["requestsHash"] = "0x12" },
		"bad optional uint":        func(m map[string]any) { m["blobGasUsed"] = "zz" },
		"bad miner":                func(m map[string]any) { m["miner"] = "0x12" },
		"bad extraData":            func(m map[string]any) { m["extraData"] = "0x1" },
		"bad difficulty":           func(m map[string]any) { m["difficulty"] = "1" },
	}
	for name, f := range cases {
		_, err := DecodeBlock(patch(t, raw, f))
		require.Error(t, err, name)
	}
	_, err := DecodeBlock(json.RawMessage(`null`))
	require.Error(t, err)
	_, err = DecodeBlock(json.RawMessage(`[1]`))
	require.Error(t, err)
}

func TestDecodeReceipts(t *testing.T) {
	raw := recorded(t, "verify-block-2", "eth_getBlockReceipts")
	rs, err := DecodeReceipts(raw)
	require.NoError(t, err)
	require.Len(t, rs, 1)
	require.Len(t, rs[0].Logs, 200)
	require.Equal(t, uint8(block.DynamicFeeTxType), rs[0].Type)
	require.Equal(t, block.LogsBloom(rs[0].Logs), rs[0].Bloom)

	editFirst := func(f func(m map[string]any)) json.RawMessage {
		var list []map[string]any
		require.NoError(t, json.Unmarshal(raw, &list))
		f(list[0])
		out, err := json.Marshal(list)
		require.NoError(t, err)
		return out
	}
	// A pre-Byzantium receipt: root instead of status, and no type field.
	pre, err := DecodeReceipts(editFirst(func(m map[string]any) {
		delete(m, "status")
		delete(m, "type")
		m["root"] = "0x" + strings.Repeat("ab", 32)
	}))
	require.NoError(t, err)
	require.Len(t, pre[0].PostState, 32)
	require.Equal(t, uint8(0), pre[0].Type)

	cases := map[string]func(m map[string]any){
		"type above 0x7f":       func(m map[string]any) { m["type"] = "0x80" },
		"no status or root":     func(m map[string]any) { delete(m, "status") },
		"removed log":           func(m map[string]any) { m["logs"].([]any)[0].(map[string]any)["removed"] = true },
		"removed not a bool":    func(m map[string]any) { m["logs"].([]any)[0].(map[string]any)["removed"] = "no" },
		"bad topic":             func(m map[string]any) { m["logs"].([]any)[0].(map[string]any)["topics"] = []any{"0x12"} },
		"log not an object":     func(m map[string]any) { m["logs"] = []any{"x"} },
		"bad log address":       func(m map[string]any) { m["logs"].([]any)[0].(map[string]any)["address"] = "0x12" },
		"missing logs":          func(m map[string]any) { delete(m, "logs") },
		"receipt is not object": nil,
	}
	for name, f := range cases {
		input := json.RawMessage(`["x"]`)
		if f != nil {
			input = editFirst(f)
		}
		_, err := DecodeReceipts(input)
		require.Error(t, err, name)
	}
	_, err = DecodeReceipts(json.RawMessage(`{}`))
	require.Error(t, err)
	ok, err := DecodeReceipts(editFirst(func(m map[string]any) { m["logs"].([]any)[0].(map[string]any)["removed"] = false }))
	require.NoError(t, err)
	require.Len(t, ok, 1)
}

func TestDecodeProof(t *testing.T) {
	raw := recorded(t, "verify-proof-contract", "eth_getProof")
	p, err := DecodeProof(raw)
	require.NoError(t, err)
	require.Len(t, p.StorageProof, 3)
	require.NotEmpty(t, p.AccountProof)

	short := patch(t, raw, func(m map[string]any) {
		m["storageProof"].([]any)[0].(map[string]any)["key"] = "0x0"
	})
	p, err = DecodeProof(short)
	require.NoError(t, err)
	require.Equal(t, keccak.Hash{}, p.StorageProof[0].Key, "quantity-style keys are left-padded")

	for name, f := range map[string]func(m map[string]any){
		"bad account node": func(m map[string]any) { m["accountProof"] = []any{"0x1"} },
		"bad storage key":  func(m map[string]any) { m["storageProof"].([]any)[0].(map[string]any)["key"] = "1" },
		"bad storage node": func(m map[string]any) { m["storageProof"].([]any)[0].(map[string]any)["proof"] = []any{"zz"} },
		"entry not object": func(m map[string]any) { m["storageProof"] = []any{"x"} },
		"missing balance":  func(m map[string]any) { delete(m, "balance") },
		"node not string":  func(m map[string]any) { m["accountProof"] = []any{1} },
		"negative balance": func(m map[string]any) { m["balance"] = "0x-5" },
		"signed nonce":     func(m map[string]any) { m["nonce"] = "0x+1" },
		"negative value":   func(m map[string]any) { m["storageProof"].([]any)[0].(map[string]any)["value"] = "0x-1" },
	} {
		_, err := DecodeProof(patch(t, raw, f))
		require.Error(t, err, name)
	}
}

// rpcServer answers JSON-RPC requests (single or batched) with handle.
func rpcServer(t *testing.T, handle func(method string, params []json.RawMessage) (any, *string)) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		type req struct {
			ID     json.RawMessage   `json:"id"`
			Method string            `json:"method"`
			Params []json.RawMessage `json:"params"`
		}
		answer := func(q req) map[string]any {
			res, errMsg := handle(q.Method, q.Params)
			out := map[string]any{"jsonrpc": "2.0", "id": q.ID}
			if errMsg != nil {
				out["error"] = map[string]any{"code": -32000, "message": *errMsg}
			} else {
				out["result"] = res
			}
			return out
		}
		w.Header().Set("Content-Type", "application/json")
		if strings.HasPrefix(strings.TrimSpace(string(body)), "[") {
			var qs []req
			_ = json.Unmarshal(body, &qs)
			var out []map[string]any
			for _, q := range qs {
				out = append(out, answer(q))
			}
			_ = json.NewEncoder(w).Encode(out)
			return
		}
		var q req
		_ = json.Unmarshal(body, &q)
		_ = json.NewEncoder(w).Encode(answer(q))
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

func TestClient(t *testing.T) {
	ctx := context.Background()
	var batches atomic.Int32
	boom := "boom"
	url := rpcServer(t, func(method string, params []json.RawMessage) (any, *string) {
		switch method {
		case "web3_clientVersion":
			return "fake/1.0", nil
		case "eth_getBlockByNumber", "eth_getBlockReceipts", "eth_getProof":
			return nil, nil // not found
		case "eth_getRawTransactionByHash":
			var h string
			_ = json.Unmarshal(params[0], &h)
			switch {
			case strings.HasSuffix(h, "ee"):
				return nil, nil
			case strings.HasSuffix(h, "ff"):
				return nil, &boom
			case strings.HasSuffix(h, "dd"):
				return "zz", nil
			}
			return "0xc0" + h[len(h)-2:], nil
		case "eth_getStorageAt":
			var s string
			_ = json.Unmarshal(params[1], &s)
			if strings.HasSuffix(s, "02") {
				return "0x" + strings.Repeat("00", 33), nil
			}
			return "0x2a", nil
		case "eth_blockNumber":
			batches.Add(1)
		}
		return nil, &boom
	})
	c, err := Dial(ctx, url)
	require.NoError(t, err)
	defer c.Close()

	v, err := c.ClientVersion(ctx)
	require.NoError(t, err)
	require.Equal(t, "fake/1.0", v)

	_, err = c.BlockByRef(ctx, Latest())
	require.ErrorIs(t, err, ErrNotFound)
	_, err = c.BlockReceipts(ctx, Number(1))
	require.ErrorIs(t, err, ErrNotFound)
	_, err = c.GetProof(ctx, keccak.Address{}, []keccak.Hash{{}}, Latest())
	require.ErrorIs(t, err, ErrNotFound)

	// More hashes than one batch holds: split into ceil(250/100) = 3 batches, order kept.
	hashes := make([]keccak.Hash, 250)
	for i := range hashes {
		hashes[i][31] = byte(i % 200)
	}
	raws, err := c.RawTransactions(ctx, hashes)
	require.NoError(t, err)
	for i, r := range raws {
		require.Equal(t, []byte{0xc0, byte(i % 200)}, r)
	}
	for _, last := range []byte{0xee, 0xff, 0xdd} {
		_, err := c.RawTransactions(ctx, []keccak.Hash{{31: last}})
		require.Error(t, err, "%x", last)
	}
	_, err = c.RawTransactions(ctx, []keccak.Hash{{31: 0xee}})
	require.ErrorIs(t, err, ErrNotFound)

	w, err := c.StorageAt(ctx, keccak.Address{}, keccak.Hash{31: 1}, Latest())
	require.NoError(t, err)
	require.Equal(t, keccak.Hash{31: 0x2a}, w)
	require.Equal(t, "42", Uint256(w).String())
	_, err = c.StorageAt(ctx, keccak.Address{}, keccak.Hash{31: 2}, Latest())
	require.ErrorIs(t, err, ErrBadHex)

	// RPC errors surface with the method name.
	var unused json.RawMessage
	_, err = c.call(ctx, "eth_blockNumber")
	require.ErrorContains(t, err, "eth_blockNumber")
	_ = unused
	require.Equal(t, int32(1), batches.Load())

	_, err = Dial(ctx, "ftp://nowhere")
	require.Error(t, err)
}

func TestClientDecodeErrors(t *testing.T) {
	ctx := context.Background()
	url := rpcServer(t, func(method string, params []json.RawMessage) (any, *string) {
		switch method {
		case "web3_clientVersion":
			return 42, nil
		case "eth_getStorageAt":
			return "nothex", nil
		case "eth_getProof", "eth_getBlockReceipts", "eth_getBlockByNumber":
			return map[string]any{"bogus": true}, nil
		}
		msg := fmt.Sprintf("unexpected %s", method)
		return nil, &msg
	})
	c, err := Dial(ctx, url)
	require.NoError(t, err)
	defer c.Close()
	_, err = c.ClientVersion(ctx)
	require.Error(t, err)
	_, err = c.StorageAt(ctx, keccak.Address{}, keccak.Hash{}, Latest())
	require.Error(t, err)
	_, err = c.GetProof(ctx, keccak.Address{}, nil, Latest())
	require.Error(t, err)
	_, err = c.BlockReceipts(ctx, Latest())
	require.Error(t, err)
	_, err = c.BlockByRef(ctx, Latest())
	require.Error(t, err)
	_, err = c.RawTransactions(ctx, []keccak.Hash{{}})
	require.ErrorContains(t, err, "unexpected eth_getRawTransactionByHash")
}

func TestClientRPCErrors(t *testing.T) {
	ctx := context.Background()
	url := rpcServer(t, func(method string, _ []json.RawMessage) (any, *string) {
		if method == "eth_getRawTransactionByHash" {
			return 42, nil // not a string
		}
		msg := "refused"
		return nil, &msg
	})
	c, err := Dial(ctx, url)
	require.NoError(t, err)
	defer c.Close()
	_, err = c.RawTransactions(ctx, []keccak.Hash{{}})
	require.ErrorIs(t, err, ErrBadHex)
	_, err = c.BlockReceipts(ctx, Latest())
	require.ErrorContains(t, err, "refused")
	_, err = c.GetProof(ctx, keccak.Address{}, nil, Latest())
	require.ErrorContains(t, err, "refused")
	_, err = c.StorageAt(ctx, keccak.Address{}, keccak.Hash{}, Latest())
	require.ErrorContains(t, err, "refused")
	_, err = c.ClientVersion(ctx)
	require.ErrorContains(t, err, "refused")
	_, err = parseFixed("zz", 1)
	require.ErrorIs(t, err, ErrBadHex)

	// A batch that cannot reach the node at all.
	dead := httptest.NewServer(http.NotFoundHandler())
	deadURL := dead.URL
	dead.Close()
	c3, err := Dial(ctx, deadURL) // HTTP dialing is lazy: the failure shows on the first call
	require.NoError(t, err)
	defer c3.Close()
	_, err = c3.RawTransactions(ctx, []keccak.Hash{{}})
	require.ErrorContains(t, err, "batch")

	stringy := rpcServer(t, func(string, []json.RawMessage) (any, *string) { return 7, nil })
	c2, err := Dial(ctx, stringy)
	require.NoError(t, err)
	defer c2.Close()
	_, err = c2.StorageAt(ctx, keccak.Address{}, keccak.Hash{}, Latest())
	require.ErrorIs(t, err, ErrBadHex)
}
