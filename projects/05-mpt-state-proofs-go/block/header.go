// SPDX-License-Identifier: MIT

// Package block recomputes the commitments in an Ethereum block header from raw data: the
// block hash from the header fields of every fork era, transactionsRoot from raw transaction
// envelopes, receiptsRoot from consensus-encoded receipts, the logs bloom, withdrawalsRoot and
// the ommers hash.
package block

import (
	"errors"
	"fmt"
	"math/big"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/rlp"
)

// Era identifies the header layout: each era appends fields to the previous one's list.
type Era uint8

const (
	// Frontier is the original 15-field header (Frontier through Berlin, and the Merge).
	Frontier Era = iota
	// London adds baseFeePerGas (EIP-1559).
	London
	// Shanghai adds withdrawalsRoot (EIP-4895).
	Shanghai
	// Cancun adds blobGasUsed, excessBlobGas (EIP-4844) and parentBeaconBlockRoot (EIP-4788).
	Cancun
	// Prague adds requestsHash (EIP-7685).
	Prague
	// Amsterdam adds blockAccessListHash (EIP-7928) and slotNumber (EIP-7843), following
	// go-ethereum 1.17's header layout.
	Amsterdam
)

var eraNames = [...]string{"frontier", "london", "shanghai", "cancun", "prague", "amsterdam"}

// String implements fmt.Stringer.
func (e Era) String() string {
	if int(e) < len(eraNames) {
		return eraNames[e]
	}
	return fmt.Sprintf("Era(%d)", uint8(e))
}

// ErrMixedEras is returned by Validate for a header whose optional fields do not form the
// field list of exactly one era: a field is missing while a later one is present.
var ErrMixedEras = errors.New("block: header mixes fields of different fork eras")

// Header is an execution-layer block header. The pointer fields are optional: nil means the
// field does not exist in the header's era.
type Header struct {
	ParentHash  keccak.Hash
	OmmersHash  keccak.Hash // "sha3Uncles"
	Coinbase    keccak.Address
	StateRoot   keccak.Hash
	TxRoot      keccak.Hash // "transactionsRoot"
	ReceiptRoot keccak.Hash // "receiptsRoot"
	Bloom       Bloom
	Difficulty  *big.Int // nil encodes as 0
	Number      uint64
	GasLimit    uint64
	GasUsed     uint64
	Time        uint64
	Extra       []byte
	MixDigest   keccak.Hash // prevRandao since the Merge
	Nonce       [8]byte

	BaseFee             *big.Int     // London
	WithdrawalsRoot     *keccak.Hash // Shanghai
	BlobGasUsed         *uint64      // Cancun
	ExcessBlobGas       *uint64      // Cancun
	ParentBeaconRoot    *keccak.Hash // Cancun
	RequestsHash        *keccak.Hash // Prague
	BlockAccessListHash *keccak.Hash // Amsterdam
	SlotNumber          *uint64      // Amsterdam
}

// optional lists the presence of the optional fields, in encoding order, with the era that
// introduced each.
func (h *Header) optional() [8]struct {
	present bool
	era     Era
} {
	return [8]struct {
		present bool
		era     Era
	}{
		{h.BaseFee != nil, London},
		{h.WithdrawalsRoot != nil, Shanghai},
		{h.BlobGasUsed != nil, Cancun},
		{h.ExcessBlobGas != nil, Cancun},
		{h.ParentBeaconRoot != nil, Cancun},
		{h.RequestsHash != nil, Prague},
		{h.BlockAccessListHash != nil, Amsterdam},
		{h.SlotNumber != nil, Amsterdam},
	}
}

// Era returns the era of the last optional field present (Frontier if there is none).
func (h *Header) Era() Era {
	era := Frontier
	for _, f := range h.optional() {
		if f.present {
			era = f.era
		}
	}
	return era
}

// Validate checks that the optional fields are exactly those of h.Era(): every field up to
// the last present one exists, and the fields an era introduces together come together.
func (h *Header) Validate() error {
	era := h.Era()
	for i, f := range h.optional() {
		if !f.present && f.era <= era {
			return fmt.Errorf("%w: %s header without field %s", ErrMixedEras, era, optionalNames[i])
		}
	}
	return nil
}

var optionalNames = [8]string{
	"baseFeePerGas", "withdrawalsRoot", "blobGasUsed", "excessBlobGas",
	"parentBeaconBlockRoot", "requestsHash", "blockAccessListHash", "slotNumber",
}

// Layout selects how a header with gaps in its optional fields (see Validate) is encoded. For
// a valid header both layouts produce the same bytes.
type Layout uint8

const (
	// Canonical appends the optional fields up to the last one present and encodes an absent
	// field before it as the empty string. This is go-ethereum's rule.
	Canonical Layout = iota
	// PresentOnly appends only the fields that are present, closing the gaps. This is what
	// alloy-based nodes (anvil 1.8.3) hash for pre-Cancun hardforks, whose headers they
	// populate with blobGasUsed and excessBlobGas.
	PresentOnly
)

// String implements fmt.Stringer.
func (l Layout) String() string {
	if l == PresentOnly {
		return "present-only"
	}
	return "canonical"
}

// Encode returns the RLP encoding of the header in the Canonical layout.
func (h *Header) Encode() ([]byte, error) { return h.EncodeLayout(Canonical) }

// EncodeLayout returns the RLP encoding of the header in the given layout.
func (h *Header) EncodeLayout(layout Layout) ([]byte, error) {
	items := make([][]byte, 0, 23)
	items = append(items,
		rlp.EncodeString(h.ParentHash[:]),
		rlp.EncodeString(h.OmmersHash[:]),
		rlp.EncodeString(h.Coinbase[:]),
		rlp.EncodeString(h.StateRoot[:]),
		rlp.EncodeString(h.TxRoot[:]),
		rlp.EncodeString(h.ReceiptRoot[:]),
		rlp.EncodeString(h.Bloom[:]),
	)
	difficulty, err := rlp.EncodeBig(h.Difficulty)
	if err != nil {
		return nil, fmt.Errorf("block: difficulty: %w", err)
	}
	items = append(items,
		difficulty,
		rlp.EncodeUint64(h.Number),
		rlp.EncodeUint64(h.GasLimit),
		rlp.EncodeUint64(h.GasUsed),
		rlp.EncodeUint64(h.Time),
		rlp.EncodeString(h.Extra),
		rlp.EncodeString(h.MixDigest[:]),
		rlp.EncodeString(h.Nonce[:]),
	)

	empty := []byte{0x80}
	hashItem := func(p *keccak.Hash) []byte {
		if p == nil {
			return empty
		}
		return rlp.EncodeString(p[:])
	}
	uintItem := func(p *uint64) []byte {
		if p == nil {
			return empty
		}
		return rlp.EncodeUint64(*p)
	}
	baseFee := empty
	if h.BaseFee != nil {
		if baseFee, err = rlp.EncodeBig(h.BaseFee); err != nil {
			return nil, fmt.Errorf("block: baseFeePerGas: %w", err)
		}
	}
	optional := [8][]byte{
		baseFee,
		hashItem(h.WithdrawalsRoot),
		uintItem(h.BlobGasUsed),
		uintItem(h.ExcessBlobGas),
		hashItem(h.ParentBeaconRoot),
		hashItem(h.RequestsHash),
		hashItem(h.BlockAccessListHash),
		uintItem(h.SlotNumber),
	}
	present := h.optional()
	last := -1
	for i, f := range present {
		if f.present {
			last = i
		}
	}
	for i := 0; i <= last; i++ {
		if present[i].present || layout == Canonical {
			items = append(items, optional[i])
		}
	}
	return rlp.EncodeList(items...), nil
}

// Hash returns the block hash: Keccak-256 of the header's RLP encoding (Canonical layout).
func (h *Header) Hash() (keccak.Hash, error) { return h.HashLayout(Canonical) }

// HashLayout returns Keccak-256 of the header's encoding in the given layout.
func (h *Header) HashLayout(layout Layout) (keccak.Hash, error) {
	enc, err := h.EncodeLayout(layout)
	if err != nil {
		return keccak.Hash{}, err
	}
	return keccak.Sum256(enc), nil
}
