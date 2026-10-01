// SPDX-License-Identifier: MIT

package block

import (
	"errors"
	"fmt"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/rlp"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/trie"
)

// ListRoot returns the root of the trie that maps RLP(i) to items[i]: the structure behind
// transactionsRoot, receiptsRoot and withdrawalsRoot. Keys are RLP-encoded indices, so index 0
// is the key 0x80 and the trie is not keyed by hashes (it is not a secure trie).
func ListRoot(items [][]byte) keccak.Hash {
	t := trie.New()
	for i, it := range items {
		t.Put(rlp.EncodeUint64(uint64(i)), it)
	}
	return t.Hash()
}

// ErrInvalidTx is returned for bytes that are not a transaction envelope.
var ErrInvalidTx = errors.New("block: invalid transaction envelope")

// TxType returns the EIP-2718 type of a raw transaction (its canonical, hash-committed
// encoding): 0 for a legacy transaction, which is an RLP list, and the leading type byte
// (0x00..0x7f) for a typed one, whose payload must be a single RLP list.
func TxType(raw []byte) (uint8, error) {
	if len(raw) == 0 {
		return 0, fmt.Errorf("%w: empty", ErrInvalidTx)
	}
	payload, typ := raw, uint8(LegacyTxType)
	switch {
	case raw[0] >= 0xc0:
	case raw[0] <= 0x7f:
		payload, typ = raw[1:], raw[0]
	default:
		return 0, fmt.Errorf("%w: leading byte 0x%02x is neither a type nor a list", ErrInvalidTx, raw[0])
	}
	_, rest, err := rlp.SplitList(payload)
	if err != nil {
		return 0, fmt.Errorf("%w: %w", ErrInvalidTx, err)
	}
	if len(rest) > 0 {
		return 0, fmt.Errorf("%w: %d trailing bytes", ErrInvalidTx, len(rest))
	}
	return typ, nil
}

// TxHash returns the transaction hash: Keccak-256 of the raw envelope.
func TxHash(raw []byte) keccak.Hash { return keccak.Sum256(raw) }

// TransactionsRoot returns transactionsRoot for raw transaction envelopes in block order.
func TransactionsRoot(raw [][]byte) keccak.Hash { return ListRoot(raw) }

// ReceiptsRoot returns receiptsRoot for receipts in block order.
func ReceiptsRoot(receipts []Receipt) (keccak.Hash, error) {
	items := make([][]byte, len(receipts))
	for i := range receipts {
		enc, err := receipts[i].Encode()
		if err != nil {
			return keccak.Hash{}, fmt.Errorf("receipt %d: %w", i, err)
		}
		items[i] = enc
	}
	return ListRoot(items), nil
}

// WithdrawalsRoot returns withdrawalsRoot for withdrawals in block order.
func WithdrawalsRoot(ws []Withdrawal) keccak.Hash {
	items := make([][]byte, len(ws))
	for i, w := range ws {
		items[i] = w.Encode()
	}
	return ListRoot(items)
}

// OmmersHash returns Keccak-256 of the RLP list of ommer (uncle) headers. Since the Merge
// blocks have no ommers and the value is keccak.EmptyList.
func OmmersHash(ommers []Header) (keccak.Hash, error) {
	items := make([][]byte, len(ommers))
	for i := range ommers {
		enc, err := ommers[i].Encode()
		if err != nil {
			return keccak.Hash{}, fmt.Errorf("ommer %d: %w", i, err)
		}
		items[i] = enc
	}
	return keccak.Sum256(rlp.EncodeList(items...)), nil
}

// GasPerBlob is the blob gas charged per blob (EIP-4844; unchanged through Osaka).
const GasPerBlob = 1 << 17

// BlobCount returns the number of blob versioned hashes in a raw EIP-4844 transaction:
// 0x03 || RLP([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gas, to, value, data,
// accessList, maxFeePerBlobGas, blobVersionedHashes, yParity, r, s]).
func BlobCount(raw []byte) (int, error) {
	if len(raw) == 0 || raw[0] != BlobTxType {
		return 0, fmt.Errorf("%w: not a blob transaction", ErrInvalidTx)
	}
	v, err := rlp.Decode(raw[1:])
	if err != nil {
		return 0, fmt.Errorf("%w: %w", ErrInvalidTx, err)
	}
	if v.Kind != rlp.List || len(v.Items) != 14 {
		return 0, fmt.Errorf("%w: a blob transaction has 14 fields", ErrInvalidTx)
	}
	hashes := v.Items[10]
	if hashes.Kind != rlp.List {
		return 0, fmt.Errorf("%w: blobVersionedHashes is not a list", ErrInvalidTx)
	}
	return len(hashes.Items), nil
}
