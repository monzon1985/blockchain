// SPDX-License-Identifier: MIT

package inspect

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/block"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/ethrpc"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
)

// BlockReport is the result of VerifyBlock.
type BlockReport struct {
	Number       uint64         `json:"number"`
	Hash         keccak.Hash    `json:"hash"`
	Era          string         `json:"era"`
	Transactions int            `json:"transactions"`
	TxTypes      map[string]int `json:"txTypes"`
	Logs         int            `json:"logs"`
	Checks       Checks         `json:"checks"`
}

// emptyRequestsHash is the EIP-7685 commitment to an empty request list: sha256 of nothing.
var emptyRequestsHash = keccak.Hash(sha256.Sum256(nil))

// VerifyBlock fetches block ref and recomputes its hash, transactionsRoot, receiptsRoot,
// logs bloom, gas used, withdrawalsRoot, blob gas and ommers hash from raw data. Transport
// errors are returned as errors; inconsistent data becomes failed checks in the report.
func VerifyBlock(ctx context.Context, src Source, ref ethrpc.BlockRef) (*BlockReport, error) {
	b, err := src.BlockByRef(ctx, ref)
	if err != nil {
		return nil, err
	}
	h := &b.Header
	rep := &BlockReport{Number: h.Number, Hash: b.Hash, Era: h.Era().String(), Transactions: len(b.TxHashes), TxTypes: map[string]int{}}
	c := &rep.Checks

	if want, ok := ref.Num(); ok && want != h.Number {
		c.add("block number", Fail, fmt.Sprintf("asked for block %d, the node returned block %d", want, h.Number))
	}
	checkHeader(c, b)
	pinned := ethrpc.Number(h.Number) // every later call targets this exact block

	raws, err := src.RawTransactions(ctx, b.TxHashes)
	if err != nil {
		return nil, err
	}
	types := checkTransactions(c, b, raws, rep.TxTypes)

	receipts, err := src.BlockReceipts(ctx, pinned)
	if err != nil {
		return nil, err
	}
	rep.Logs = checkReceipts(c, b, receipts, types)
	checkWithdrawals(c, b)
	checkBlobGas(c, b, raws, types)
	checkRequests(c, h)
	if len(b.Uncles) == 0 {
		c.compare("ommersHash", h.OmmersHash, keccak.EmptyList, "no ommers: keccak(rlp([]))")
	} else {
		c.add("ommersHash", Warn, fmt.Sprintf("%s not fetched; ommersHash not recomputed", plural(len(b.Uncles), "ommer")))
	}
	return rep, nil
}

// checkHeader verifies the block hash and the header's field set.
func checkHeader(c *Checks, b *ethrpc.Block) {
	h := &b.Header
	if err := h.Validate(); err != nil {
		c.add("header fields", Warn, err.Error())
	} else {
		c.add("header fields", Pass, fmt.Sprintf("exactly the fields of a %s header", h.Era()))
	}
	if len(b.UnknownFields) > 0 {
		c.add("unknown fields", Warn, "the node reports fields this tool does not hash: "+strings.Join(b.UnknownFields, ", "))
	}
	canonical, err := h.Hash()
	if err != nil {
		c.add("block hash", Fail, "header cannot be RLP-encoded: "+err.Error())
		return
	}
	if canonical == b.Hash {
		c.compare("block hash", b.Hash, canonical, "keccak256(rlp(header))")
		return
	}
	present, err := h.HashLayout(block.PresentOnly)
	if err == nil && present == b.Hash {
		*c = append(*c, Check{
			Name: "block hash", Status: Warn, Reported: b.Hash.Hex(), Computed: present.Hex(),
			Detail: fmt.Sprintf("matches only when absent optional fields are skipped (present-only layout); go-ethereum's canonical encoding gives %s", short(canonical)),
		})
		return
	}
	c.compare("block hash", b.Hash, canonical, "keccak256(rlp(header))")
}

// checkTransactions verifies each raw envelope against its hash and recomputes
// transactionsRoot. It returns the envelope type of each transaction (-1 if invalid).
func checkTransactions(c *Checks, b *ethrpc.Block, raws [][]byte, byType map[string]int) []int {
	types := make([]int, len(raws))
	var bad []string
	for i, raw := range raws {
		t, err := block.TxType(raw)
		if err != nil {
			types[i] = -1
			bad = append(bad, fmt.Sprintf("tx %d: %v", i, err))
			continue
		}
		types[i] = int(t)
		byType[block.TxTypeName(t)]++
		if got := block.TxHash(raw); got != b.TxHashes[i] {
			bad = append(bad, fmt.Sprintf("tx %d: keccak256(raw) = %s, block lists %s", i, short(got), short(b.TxHashes[i])))
		}
	}
	if len(bad) > 0 {
		c.add("transaction hashes", Fail, strings.Join(bad, "; "))
	} else {
		c.add("transaction hashes", Pass, fmt.Sprintf("%s: keccak256(raw envelope) = listed hash%s", plural(len(raws), "transaction"), typeSummary(byType)))
	}
	c.compare("transactionsRoot", b.Header.TxRoot, block.TransactionsRoot(raws), fmt.Sprintf("trie of %s keyed by rlp(index)", plural(len(raws), "raw envelope")))
	return types
}

func typeSummary(byType map[string]int) string {
	if len(byType) == 0 {
		return ""
	}
	names := make([]string, 0, len(byType))
	for n := range byType {
		names = append(names, n)
	}
	sort.Strings(names)
	parts := make([]string, len(names))
	for i, n := range names {
		parts[i] = fmt.Sprintf("%s %d", n, byType[n])
	}
	return " (" + strings.Join(parts, ", ") + ")"
}

// checkReceipts verifies that the receipts belong to the block's transactions, recomputes
// each receipt's bloom, the header bloom, gasUsed and receiptsRoot. It returns the log count.
func checkReceipts(c *Checks, b *ethrpc.Block, receipts []ethrpc.Receipt, types []int) int {
	h := &b.Header
	var bad []string
	if len(receipts) != len(b.TxHashes) {
		bad = append(bad, fmt.Sprintf("%d receipts for %d transactions", len(receipts), len(b.TxHashes)))
	}
	for i, r := range receipts {
		switch {
		case r.BlockHash != b.Hash:
			bad = append(bad, fmt.Sprintf("receipt %d belongs to block %s", i, short(r.BlockHash)))
		case r.TxIndex != uint64(i):
			bad = append(bad, fmt.Sprintf("receipt %d has transactionIndex %d", i, r.TxIndex))
		case i < len(b.TxHashes) && r.TxHash != b.TxHashes[i]:
			bad = append(bad, fmt.Sprintf("receipt %d is for transaction %s", i, short(r.TxHash)))
		case i < len(types) && types[i] >= 0 && int(r.Type) != types[i]:
			bad = append(bad, fmt.Sprintf("receipt %d has type %d, its transaction %d", i, r.Type, types[i]))
		}
	}
	if len(bad) > 0 {
		c.add("receipt identity", Fail, strings.Join(bad, "; "))
	} else {
		verb := "match"
		if len(receipts) == 1 {
			verb = "matches"
		}
		c.add("receipt identity", Pass, fmt.Sprintf("%s %s the block's transactions (hash, index, type)", plural(len(receipts), "receipt"), verb))
	}

	logs, badBlooms := 0, 0
	var union block.Bloom
	for _, r := range receipts {
		logs += len(r.Logs)
		if block.LogsBloom(r.Logs) != r.Bloom {
			badBlooms++
		}
		union.Or(r.Bloom)
	}
	if badBlooms > 0 {
		c.add("receipt blooms", Fail, fmt.Sprintf("%d of %d receipt blooms differ from the bloom of their logs", badBlooms, len(receipts)))
	} else {
		c.add("receipt blooms", Pass, fmt.Sprintf("%s rebuilt from %s", plural(len(receipts), "bloom"), plural(logs, "log")))
	}
	if union == h.Bloom {
		c.add("logsBloom", Pass, "header bloom = OR of the receipt blooms")
	} else {
		c.add("logsBloom", Fail, "MISMATCH: header bloom differs from the OR of the receipt blooms")
	}

	var cumulative uint64
	monotonic := true
	for _, r := range receipts {
		if r.CumulativeGasUsed < cumulative {
			monotonic = false
		}
		cumulative = r.CumulativeGasUsed
	}
	switch {
	case !monotonic:
		c.add("gasUsed", Fail, "cumulativeGasUsed decreases between receipts")
	case cumulative != h.GasUsed:
		c.add("gasUsed", Fail, fmt.Sprintf("MISMATCH: last cumulativeGasUsed %d, header gasUsed %d", cumulative, h.GasUsed))
	default:
		c.add("gasUsed", Pass, fmt.Sprintf("last cumulativeGasUsed = header gasUsed = %d", h.GasUsed))
	}

	root, err := block.ReceiptsRoot(blockReceipts(receipts))
	if err != nil {
		c.add("receiptsRoot", Fail, err.Error())
		return logs
	}
	c.compare("receiptsRoot", h.ReceiptRoot, root, fmt.Sprintf("trie of %s (type || rlp([status, cumulativeGas, bloom, logs]))", plural(len(receipts), "receipt")))
	return logs
}

func blockReceipts(rs []ethrpc.Receipt) []block.Receipt {
	out := make([]block.Receipt, len(rs))
	for i, r := range rs {
		out[i] = r.Receipt
	}
	return out
}

func checkWithdrawals(c *Checks, b *ethrpc.Block) {
	h := &b.Header
	switch {
	case h.WithdrawalsRoot == nil && len(b.Withdrawals) > 0:
		c.add("withdrawalsRoot", Fail, fmt.Sprintf("block lists %s but the header has no withdrawalsRoot", plural(len(b.Withdrawals), "withdrawal")))
	case h.WithdrawalsRoot == nil:
		// Pre-Shanghai: nothing to check.
	case b.Withdrawals == nil:
		c.add("withdrawalsRoot", Fail, "header commits to withdrawals but the block has no withdrawals field")
	default:
		c.compare("withdrawalsRoot", *h.WithdrawalsRoot, block.WithdrawalsRoot(b.Withdrawals), fmt.Sprintf("trie of %s", plural(len(b.Withdrawals), "withdrawal")))
	}
}

func checkBlobGas(c *Checks, b *ethrpc.Block, raws [][]byte, types []int) {
	h := &b.Header
	if h.BlobGasUsed == nil {
		return
	}
	blobs := 0
	for i, raw := range raws {
		if types[i] != block.BlobTxType {
			continue
		}
		n, err := block.BlobCount(raw)
		if err != nil {
			c.add("blobGasUsed", Fail, fmt.Sprintf("tx %d: %v", i, err))
			return
		}
		blobs += n
	}
	want := uint64(blobs) * block.GasPerBlob
	if want != *h.BlobGasUsed {
		c.add("blobGasUsed", Fail, fmt.Sprintf("MISMATCH: %s x %d gas = %d, header says %d", plural(blobs, "blob"), block.GasPerBlob, want, *h.BlobGasUsed))
		return
	}
	c.add("blobGasUsed", Pass, fmt.Sprintf("%s x %d gas = %d", plural(blobs, "blob"), block.GasPerBlob, want))
}

func checkRequests(c *Checks, h *block.Header) {
	switch {
	case h.RequestsHash == nil:
	case *h.RequestsHash == emptyRequestsHash:
		c.add("requestsHash", Pass, "no execution-layer requests: sha256 of the empty list")
	default:
		c.add("requestsHash", Warn, "the block carries requests, which JSON-RPC does not expose; not recomputed")
	}
}

// WriteText renders the report for a terminal.
func (r *BlockReport) WriteText(w io.Writer) {
	fmt.Fprintf(w, "block %d %s\n", r.Number, r.Hash)
	fmt.Fprintf(w, "  %s header, %s, %s\n", r.Era, plural(r.Transactions, "transaction"), plural(r.Logs, "log"))
	writeChecks(w, r.Checks)
}
