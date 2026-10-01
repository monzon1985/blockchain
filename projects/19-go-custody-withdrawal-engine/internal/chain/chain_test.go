// SPDX-License-Identifier: MIT

package chain_test

import (
	"bytes"
	"errors"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/chain"
)

func TestClassifySendError(t *testing.T) {
	cases := map[string]chain.SendOutcome{
		"":                                    chain.Accepted,
		"already known":                       chain.AlreadyKnown,
		"transaction already imported":        chain.AlreadyKnown, // anvil
		"known transaction: 0xabc":            chain.AlreadyKnown,
		"nonce too low":                       chain.NonceTooLow,
		"nonce too low: next nonce 5, tx 4":   chain.NonceTooLow,
		"replacement transaction underpriced": chain.Underpriced,
		"transaction underpriced":             chain.Underpriced,
		"max fee per gas less than block base fee: address 0x.., maxFeePerGas: 1, baseFee: 2": chain.Underpriced,
		"insufficient funds for gas * price + value":                                          chain.InsufficientFunds,
		"connection refused":        chain.Transient,
		"context deadline exceeded": chain.Transient,
	}
	for msg, want := range cases {
		var err error
		if msg != "" {
			err = errors.New(msg)
		}
		if got := chain.ClassifySendError(err); got != want {
			t.Errorf("%q: got %s want %s", msg, got, want)
		}
		if want.String() == "" {
			t.Errorf("empty name for %d", want)
		}
	}
}

func TestTransferCalldataMatchesABIEncoding(t *testing.T) {
	to := common.HexToAddress("0x00000000000000000000000000000000000000aa")
	amount, _ := new(big.Int).SetString("115792089237316195423570985008687907853269984665640564039457584007913129639935", 10)
	addrT, _ := abi.NewType("address", "", nil)
	uintT, _ := abi.NewType("uint256", "", nil)
	args := abi.Arguments{{Type: addrT}, {Type: uintT}}
	packed, err := args.Pack(to, amount)
	if err != nil {
		t.Fatal(err)
	}
	want := append(append([]byte{}, chain.TransferSelector...), packed...)
	if got := chain.EncodeTransfer(to, amount); !bytes.Equal(got, want) {
		t.Fatalf("encoding differs from go-ethereum's ABI encoder")
	}
	gotTo, gotAmt, err := chain.DecodeTransfer(want)
	if err != nil || gotTo != to || gotAmt.Cmp(amount) != 0 {
		t.Fatalf("round trip: %s %s %v", gotTo, gotAmt, err)
	}
}

func TestDecodeTransferRejectsNonCanonical(t *testing.T) {
	good := chain.EncodeTransfer(common.HexToAddress("0x01"), big.NewInt(5))
	dirty := bytes.Clone(good)
	dirty[4] = 0x01 // dirty high bits in the address word
	for name, data := range map[string][]byte{
		"short":          good[:67],
		"long":           append(bytes.Clone(good), 0),
		"wrong selector": append([]byte{0xde, 0xad, 0xbe, 0xef}, good[4:]...),
		"dirty address":  dirty,
		"empty":          nil,
	} {
		if _, _, err := chain.DecodeTransfer(data); !errors.Is(err, chain.ErrBadCalldata) {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestDecodeTransferLog(t *testing.T) {
	from, to := common.HexToAddress("0x0a"), common.HexToAddress("0x0b")
	l := &types.Log{Address: common.HexToAddress("0x70"), Topics: []common.Hash{chain.TransferTopic,
		common.BytesToHash(from.Bytes()), common.BytesToHash(to.Bytes())}, Data: common.LeftPadBytes([]byte{9}, 32)}
	tl, ok := chain.DecodeTransferLog(l)
	if !ok || tl.From != from || tl.To != to || tl.Amount.Int64() != 9 {
		t.Fatalf("decoded %+v %v", tl, ok)
	}
	l.Topics = l.Topics[:2]
	if _, ok := chain.DecodeTransferLog(l); ok {
		t.Fatal("ERC-721-style or malformed log accepted")
	}
}

// FuzzDecodeTransfer: decoding never panics, and whatever decodes re-encodes to the same bytes.
func FuzzDecodeTransfer(f *testing.F) {
	f.Add(chain.EncodeTransfer(common.HexToAddress("0x01"), big.NewInt(1)))
	f.Add([]byte{0xa9, 0x05, 0x9c, 0xbb})
	f.Fuzz(func(t *testing.T, data []byte) {
		to, amount, err := chain.DecodeTransfer(data)
		if err != nil {
			return
		}
		if !bytes.Equal(chain.EncodeTransfer(to, amount), data) {
			t.Fatalf("non-canonical input accepted: %x", data)
		}
	})
}
