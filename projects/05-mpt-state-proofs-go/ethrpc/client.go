// SPDX-License-Identifier: MIT

// Package ethrpc fetches the raw material the verifiers need from an Ethereum JSON-RPC node
// and decodes it strictly into this module's own types. go-ethereum's rpc package is the
// transport; nothing the node returns is trusted beyond its syntax: the verification
// packages recompute every commitment.
package ethrpc

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"strconv"
	"strings"

	"github.com/ethereum/go-ethereum/rpc"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/block"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/stateproof"
)

// ErrNotFound is returned when the node does not know the requested block or transaction.
var ErrNotFound = errors.New("ethrpc: not found")

// BatchSize bounds the number of calls sent in one JSON-RPC batch.
const BatchSize = 100

// BlockRef names a block: a number or one of the tags latest, earliest, pending, safe and
// finalized.
type BlockRef struct {
	tag string
	num uint64
}

// Number returns a reference to block n.
func Number(n uint64) BlockRef { return BlockRef{num: n} }

// Latest returns a reference to the head block.
func Latest() BlockRef { return BlockRef{tag: "latest"} }

// ParseBlockRef parses a tag, a decimal number or a 0x-prefixed hex number.
func ParseBlockRef(s string) (BlockRef, error) {
	switch s {
	case "latest", "earliest", "pending", "safe", "finalized":
		return BlockRef{tag: s}, nil
	}
	var (
		n   uint64
		err error
	)
	if strings.HasPrefix(s, "0x") {
		n, err = strconv.ParseUint(s[2:], 16, 64)
	} else {
		n, err = strconv.ParseUint(s, 10, 64)
	}
	if err != nil {
		return BlockRef{}, fmt.Errorf("ethrpc: block %q is not a number or a tag (latest, earliest, pending, safe, finalized)", s)
	}
	return Number(n), nil
}

// Arg returns the JSON-RPC parameter form: the tag, or the number as a hex quantity.
func (r BlockRef) Arg() string {
	if r.tag != "" {
		return r.tag
	}
	return "0x" + strconv.FormatUint(r.num, 16)
}

// Num returns the block number, or false for a tag.
func (r BlockRef) Num() (uint64, bool) { return r.num, r.tag == "" }

// String implements fmt.Stringer.
func (r BlockRef) String() string {
	if r.tag != "" {
		return r.tag
	}
	return strconv.FormatUint(r.num, 10)
}

// Client is a JSON-RPC client. It is safe for concurrent use.
type Client struct {
	rpc *rpc.Client
}

// Dial connects to an HTTP(S) or WebSocket endpoint.
func Dial(ctx context.Context, url string) (*Client, error) {
	c, err := rpc.DialContext(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("ethrpc: dial %s: %w", url, err)
	}
	return &Client{rpc: c}, nil
}

// Close releases the connection.
func (c *Client) Close() { c.rpc.Close() }

func (c *Client) call(ctx context.Context, method string, args ...any) (json.RawMessage, error) {
	var raw json.RawMessage
	if err := c.rpc.CallContext(ctx, &raw, method, args...); err != nil {
		return nil, fmt.Errorf("ethrpc: %s: %w", method, err)
	}
	return raw, nil
}

// ClientVersion returns web3_clientVersion.
func (c *Client) ClientVersion(ctx context.Context) (string, error) {
	raw, err := c.call(ctx, "web3_clientVersion")
	if err != nil {
		return "", err
	}
	return jsonString(raw)
}

// Block is a block as reported by eth_getBlockByNumber, decoded into a header.
type Block struct {
	Header block.Header
	// Hash is the block hash the node reports; it is a claim to verify, not a fact.
	Hash        keccak.Hash
	TxHashes    []keccak.Hash
	Uncles      []keccak.Hash
	Withdrawals []block.Withdrawal // nil when the block has no withdrawals field
	// UnknownFields lists members of the block object this package does not know. A node
	// that adds a header field this package does not know produces a hash mismatch, and this
	// list says where to look.
	UnknownFields []string
}

// knownBlockFields lists the members of a block object this package understands: the header
// fields of every known era, plus the block hash, derived values and the body.
var knownBlockFields = map[string]bool{
	"parentHash": true, "sha3Uncles": true, "miner": true, "stateRoot": true, "transactionsRoot": true,
	"receiptsRoot": true, "logsBloom": true, "difficulty": true, "number": true, "gasLimit": true,
	"gasUsed": true, "timestamp": true, "extraData": true, "mixHash": true, "nonce": true,
	"baseFeePerGas": true, "withdrawalsRoot": true, "blobGasUsed": true, "excessBlobGas": true,
	"parentBeaconBlockRoot": true, "requestsHash": true, "blockAccessListHash": true, "slotNumber": true,
	// Not header fields: the block hash, derived values and the block body.
	"hash": true, "size": true, "totalDifficulty": true, "transactions": true, "uncles": true, "withdrawals": true,
}

// BlockByRef fetches a block with transaction hashes (not full transactions).
func (c *Client) BlockByRef(ctx context.Context, ref BlockRef) (*Block, error) {
	raw, err := c.call(ctx, "eth_getBlockByNumber", ref.Arg(), false)
	if err != nil {
		return nil, err
	}
	if string(raw) == "null" {
		return nil, fmt.Errorf("%w: block %s", ErrNotFound, ref)
	}
	return DecodeBlock(raw)
}

// DecodeBlock decodes an eth_getBlockByNumber result (with transaction hashes).
func DecodeBlock(raw json.RawMessage) (*Block, error) {
	f, err := newFields(raw)
	if err != nil {
		return nil, err
	}
	b := &Block{}
	h := &b.Header
	h.ParentHash = f.hash("parentHash")
	h.OmmersHash = f.hash("sha3Uncles")
	h.Coinbase = f.address("miner")
	h.StateRoot = f.hash("stateRoot")
	h.TxRoot = f.hash("transactionsRoot")
	h.ReceiptRoot = f.hash("receiptsRoot")
	copy(h.Bloom[:], f.fixed("logsBloom", 256))
	h.Difficulty = f.big("difficulty")
	h.Number = f.uint64("number")
	h.GasLimit = f.uint64("gasLimit")
	h.GasUsed = f.uint64("gasUsed")
	h.Time = f.uint64("timestamp")
	h.Extra = f.data("extraData")
	h.MixDigest = f.hash("mixHash")
	copy(h.Nonce[:], f.fixed("nonce", 8))
	if f.has("baseFeePerGas") {
		h.BaseFee = f.big("baseFeePerGas")
	}
	h.WithdrawalsRoot = f.optHash("withdrawalsRoot")
	h.BlobGasUsed = f.optUint64("blobGasUsed")
	h.ExcessBlobGas = f.optUint64("excessBlobGas")
	h.ParentBeaconRoot = f.optHash("parentBeaconBlockRoot")
	h.RequestsHash = f.optHash("requestsHash")
	h.BlockAccessListHash = f.optHash("blockAccessListHash")
	h.SlotNumber = f.optUint64("slotNumber")
	b.Hash = f.hash("hash")

	for i, s := range f.stringArray("transactions") {
		th, err := parseHash(s)
		if err != nil {
			return nil, fmt.Errorf("transactions[%d] (full transaction objects are not supported): %w", i, err)
		}
		b.TxHashes = append(b.TxHashes, th)
	}
	if f.has("uncles") {
		for i, s := range f.stringArray("uncles") {
			uh, err := parseHash(s)
			if err != nil {
				return nil, fmt.Errorf("uncles[%d]: %w", i, err)
			}
			b.Uncles = append(b.Uncles, uh)
		}
	}
	if f.has("withdrawals") {
		b.Withdrawals = []block.Withdrawal{}
		for i, w := range f.array("withdrawals") {
			wf, err := newFields(w)
			if err != nil {
				return nil, fmt.Errorf("withdrawals[%d]: %w", i, err)
			}
			wd := block.Withdrawal{Index: wf.uint64("index"), Validator: wf.uint64("validatorIndex"), Address: wf.address("address"), Amount: wf.uint64("amount")}
			if wf.err != nil {
				return nil, fmt.Errorf("withdrawals[%d]: %w", i, wf.err)
			}
			b.Withdrawals = append(b.Withdrawals, wd)
		}
	}
	if f.err != nil {
		return nil, f.err
	}
	for name := range f.m {
		if !knownBlockFields[name] {
			b.UnknownFields = append(b.UnknownFields, name)
		}
	}
	sort.Strings(b.UnknownFields)
	return b, nil
}

// RawTransactions fetches the canonical encoding of each transaction with
// eth_getRawTransactionByHash, in batches.
func (c *Client) RawTransactions(ctx context.Context, hashes []keccak.Hash) ([][]byte, error) {
	out := make([][]byte, len(hashes))
	for start := 0; start < len(hashes); start += BatchSize {
		end := min(start+BatchSize, len(hashes))
		batch := make([]rpc.BatchElem, end-start)
		results := make([]json.RawMessage, end-start)
		for i := range batch {
			batch[i] = rpc.BatchElem{Method: "eth_getRawTransactionByHash", Args: []any{hashes[start+i].Hex()}, Result: &results[i]}
		}
		if err := c.rpc.BatchCallContext(ctx, batch); err != nil {
			return nil, fmt.Errorf("ethrpc: eth_getRawTransactionByHash batch: %w", err)
		}
		for i, el := range batch {
			h := hashes[start+i]
			if el.Error != nil {
				return nil, fmt.Errorf("ethrpc: eth_getRawTransactionByHash %s: %w", h, el.Error)
			}
			if len(results[i]) == 0 || string(results[i]) == "null" {
				return nil, fmt.Errorf("%w: raw transaction %s", ErrNotFound, h)
			}
			s, err := jsonString(results[i])
			if err != nil {
				return nil, err
			}
			if out[start+i], err = parseData(s); err != nil {
				return nil, fmt.Errorf("raw transaction %s: %w", h, err)
			}
		}
	}
	return out, nil
}

// Receipt is a receipt as reported by eth_getBlockReceipts: the consensus fields plus the
// position data used to check that the node answered for the right block.
type Receipt struct {
	block.Receipt
	TxHash    keccak.Hash
	TxIndex   uint64
	BlockHash keccak.Hash
}

// BlockReceipts fetches every receipt of a block with eth_getBlockReceipts.
func (c *Client) BlockReceipts(ctx context.Context, ref BlockRef) ([]Receipt, error) {
	raw, err := c.call(ctx, "eth_getBlockReceipts", ref.Arg())
	if err != nil {
		return nil, err
	}
	if string(raw) == "null" {
		return nil, fmt.Errorf("%w: receipts of block %s", ErrNotFound, ref)
	}
	return DecodeReceipts(raw)
}

// DecodeReceipts decodes an eth_getBlockReceipts result.
func DecodeReceipts(raw json.RawMessage) ([]Receipt, error) {
	var items []json.RawMessage
	if err := json.Unmarshal(raw, &items); err != nil {
		return nil, fmt.Errorf("ethrpc: receipts: expected an array: %w", err)
	}
	out := make([]Receipt, len(items))
	for i, it := range items {
		r, err := decodeReceipt(it)
		if err != nil {
			return nil, fmt.Errorf("receipt %d: %w", i, err)
		}
		out[i] = r
	}
	return out, nil
}

func decodeReceipt(raw json.RawMessage) (Receipt, error) {
	f, err := newFields(raw)
	if err != nil {
		return Receipt{}, err
	}
	var r Receipt
	if f.has("type") { // absent in pre-EIP-2718 nodes: legacy
		t := f.uint64("type")
		if t > 0x7f {
			return Receipt{}, fmt.Errorf("ethrpc: receipt type %d is not an EIP-2718 type", t)
		}
		r.Type = uint8(t)
	}
	switch {
	case f.has("status"):
		r.Status = f.uint64("status")
	case f.has("root"):
		r.PostState = f.fixed("root", 32)
	default:
		return Receipt{}, errors.New("ethrpc: receipt has neither status nor root")
	}
	r.CumulativeGasUsed = f.uint64("cumulativeGasUsed")
	copy(r.Bloom[:], f.fixed("logsBloom", 256))
	r.TxHash = f.hash("transactionHash")
	r.TxIndex = f.uint64("transactionIndex")
	r.BlockHash = f.hash("blockHash")
	logs := f.array("logs")
	if f.err != nil {
		return Receipt{}, f.err
	}
	r.Logs = make([]block.Log, len(logs))
	for j, l := range logs {
		lf, err := newFields(l)
		if err != nil {
			return Receipt{}, fmt.Errorf("logs[%d]: %w", j, err)
		}
		if lf.has("removed") {
			var removed bool
			if err := json.Unmarshal(lf.m["removed"], &removed); err != nil || removed {
				return Receipt{}, fmt.Errorf("logs[%d]: removed log (reorged out) in a block receipt", j)
			}
		}
		log := block.Log{Address: lf.address("address"), Data: lf.data("data")}
		for k, s := range lf.stringArray("topics") {
			topic, err := parseHash(s)
			if err != nil {
				return Receipt{}, fmt.Errorf("logs[%d].topics[%d]: %w", j, k, err)
			}
			log.Topics = append(log.Topics, topic)
		}
		if lf.err != nil {
			return Receipt{}, fmt.Errorf("logs[%d]: %w", j, lf.err)
		}
		r.Logs[j] = log
	}
	return r, nil
}

// GetProof calls eth_getProof for an account and storage slots at a block.
func (c *Client) GetProof(ctx context.Context, addr keccak.Address, slots []keccak.Hash, ref BlockRef) (*stateproof.GetProofResult, error) {
	keys := make([]string, len(slots))
	for i, s := range slots {
		keys[i] = s.Hex()
	}
	raw, err := c.call(ctx, "eth_getProof", addr.Hex(), keys, ref.Arg())
	if err != nil {
		return nil, err
	}
	if string(raw) == "null" {
		return nil, fmt.Errorf("%w: proof for %s at block %s", ErrNotFound, addr, ref)
	}
	return DecodeProof(raw)
}

// DecodeProof decodes an eth_getProof result.
func DecodeProof(raw json.RawMessage) (*stateproof.GetProofResult, error) {
	f, err := newFields(raw)
	if err != nil {
		return nil, err
	}
	r := &stateproof.GetProofResult{
		Address:     f.address("address"),
		Balance:     f.big("balance"),
		CodeHash:    f.hash("codeHash"),
		Nonce:       f.uint64("nonce"),
		StorageHash: f.hash("storageHash"),
	}
	r.AccountProof = decodeNodes(f, "accountProof")
	for i, it := range f.array("storageProof") {
		sf, err := newFields(it)
		if err != nil {
			return nil, fmt.Errorf("storageProof[%d]: %w", i, err)
		}
		sr := stateproof.StorageResult{Value: sf.big("value"), Proof: decodeNodes(sf, "proof")}
		key := sf.str("key")
		if sf.err == nil {
			sr.Key, sf.err = parseSlot(key)
		}
		if sf.err != nil {
			return nil, fmt.Errorf("storageProof[%d]: %w", i, sf.err)
		}
		r.StorageProof = append(r.StorageProof, sr)
	}
	if f.err != nil {
		return nil, f.err
	}
	return r, nil
}

func decodeNodes(f *fields, name string) [][]byte {
	strs := f.stringArray(name)
	nodes := make([][]byte, 0, len(strs))
	for i, s := range strs {
		b, err := parseData(s)
		if err != nil {
			f.wrap(fmt.Sprintf("%s[%d]", name, i), err)
			return nil
		}
		nodes = append(nodes, b)
	}
	return nodes
}

// StorageAt returns eth_getStorageAt as a 32-byte word.
func (c *Client) StorageAt(ctx context.Context, addr keccak.Address, slot keccak.Hash, ref BlockRef) (keccak.Hash, error) {
	raw, err := c.call(ctx, "eth_getStorageAt", addr.Hex(), slot.Hex(), ref.Arg())
	if err != nil {
		return keccak.Hash{}, err
	}
	s, err := jsonString(raw)
	if err != nil {
		return keccak.Hash{}, err
	}
	b, err := parseData(s)
	if err != nil {
		return keccak.Hash{}, err
	}
	if len(b) > 32 {
		return keccak.Hash{}, fmt.Errorf("%w: storage word of %d bytes", ErrBadHex, len(b))
	}
	var w keccak.Hash
	copy(w[32-len(b):], b)
	return w, nil
}

// Uint256 converts a word to an integer (for display).
func Uint256(w keccak.Hash) *big.Int { return new(big.Int).SetBytes(w[:]) }
