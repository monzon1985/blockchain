// SPDX-License-Identifier: MIT

package block

import (
	"errors"
	"fmt"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/rlp"
)

// Bloom is the 2048-bit logs bloom filter of a receipt or a block (Yellow Paper, 4.3.1).
type Bloom [256]byte

// Add sets the three bits selected by Keccak-256(data): for each of the first three byte
// pairs of the hash, the low 11 bits pick a bit, counted from the end of the filter.
func (b *Bloom) Add(data []byte) {
	h := keccak.Sum256(data)
	for i := 0; i < 6; i += 2 {
		bit := (uint(h[i])<<8 | uint(h[i+1])) & 2047
		b[255-bit/8] |= 1 << (bit % 8)
	}
}

// Or sets every bit that is set in other.
func (b *Bloom) Or(other Bloom) {
	for i := range b {
		b[i] |= other[i]
	}
}

// Log is an event emitted by a contract.
type Log struct {
	Address keccak.Address
	Topics  []keccak.Hash
	Data    []byte
}

// Encode returns RLP([address, [topic, ...], data]).
func (l Log) Encode() []byte {
	topics := make([][]byte, len(l.Topics))
	for i, t := range l.Topics {
		topics[i] = rlp.EncodeString(t[:])
	}
	return rlp.EncodeList(rlp.EncodeString(l.Address[:]), rlp.EncodeList(topics...), rlp.EncodeString(l.Data))
}

// LogsBloom returns the bloom of a list of logs: each address and each topic is added.
func LogsBloom(logs []Log) Bloom {
	var b Bloom
	for _, l := range logs {
		b.Add(l.Address[:])
		for _, t := range l.Topics {
			b.Add(t[:])
		}
	}
	return b
}

// Transaction (and receipt) envelope types, EIP-2718.
const (
	LegacyTxType     = 0x00
	AccessListTxType = 0x01 // EIP-2930
	DynamicFeeTxType = 0x02 // EIP-1559
	BlobTxType       = 0x03 // EIP-4844
	SetCodeTxType    = 0x04 // EIP-7702
)

// TxTypeName returns a short name for a transaction type.
func TxTypeName(t uint8) string {
	switch t {
	case LegacyTxType:
		return "legacy"
	case AccessListTxType:
		return "access-list"
	case DynamicFeeTxType:
		return "dynamic-fee"
	case BlobTxType:
		return "blob"
	case SetCodeTxType:
		return "set-code"
	default:
		return fmt.Sprintf("type-0x%02x", t)
	}
}

// Receipt holds the consensus fields of a transaction receipt: the ones receiptsRoot commits
// to. (Fields such as gasUsed, contractAddress or blobGasPrice are derived and not hashed.)
type Receipt struct {
	Type uint8
	// PostState is the intermediate state root of a pre-Byzantium receipt. When it is nil the
	// receipt carries Status instead (EIP-658).
	PostState         []byte
	Status            uint64 // 1 = success, 0 = failure
	CumulativeGasUsed uint64
	Bloom             Bloom
	Logs              []Log
}

// ErrInvalidStatus is returned for a status other than 0 or 1.
var ErrInvalidStatus = errors.New("block: receipt status must be 0 or 1")

// Encode returns the consensus encoding that receiptsRoot commits to:
// RLP([statusOrPostState, cumulativeGasUsed, bloom, logs]) for a legacy receipt, prefixed with
// the type byte for a typed one (EIP-2718). A status of 1 encodes as the byte 0x01 and 0 as
// the empty string.
func (r *Receipt) Encode() ([]byte, error) {
	var first []byte
	switch {
	case r.PostState != nil:
		first = rlp.EncodeString(r.PostState)
	case r.Status == 1:
		first = []byte{0x01}
	case r.Status == 0:
		first = rlp.EncodeString(nil)
	default:
		return nil, fmt.Errorf("%w, got %d", ErrInvalidStatus, r.Status)
	}
	logs := make([][]byte, len(r.Logs))
	for i, l := range r.Logs {
		logs[i] = l.Encode()
	}
	body := rlp.EncodeList(first, rlp.EncodeUint64(r.CumulativeGasUsed), rlp.EncodeString(r.Bloom[:]), rlp.EncodeList(logs...))
	if r.Type == LegacyTxType {
		return body, nil
	}
	return append([]byte{r.Type}, body...), nil
}

// Withdrawal is a validator withdrawal pushed by the consensus layer (EIP-4895).
type Withdrawal struct {
	Index     uint64
	Validator uint64
	Address   keccak.Address
	Amount    uint64 // in gwei
}

// Encode returns RLP([index, validatorIndex, address, amount]).
func (w Withdrawal) Encode() []byte {
	return rlp.EncodeList(rlp.EncodeUint64(w.Index), rlp.EncodeUint64(w.Validator), rlp.EncodeString(w.Address[:]), rlp.EncodeUint64(w.Amount))
}
