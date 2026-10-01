// SPDX-License-Identifier: MIT

package chain

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
)

// ERC-20 selectors and the Transfer event topic.
var (
	TransferSelector  = crypto.Keccak256([]byte("transfer(address,uint256)"))[:4]
	BalanceOfSelector = crypto.Keccak256([]byte("balanceOf(address)"))[:4]
	TransferTopic     = crypto.Keccak256Hash([]byte("Transfer(address,address,uint256)"))
)

// ErrBadCalldata is returned when calldata is not a canonical ERC-20 transfer.
var ErrBadCalldata = errors.New("chain: not a canonical transfer(address,uint256) call")

// EncodeTransfer returns the calldata of transfer(to, amount).
func EncodeTransfer(to common.Address, amount *big.Int) []byte {
	out := make([]byte, 0, 68)
	out = append(out, TransferSelector...)
	out = append(out, common.LeftPadBytes(to.Bytes(), 32)...)
	out = append(out, common.LeftPadBytes(amount.Bytes(), 32)...)
	return out
}

// DecodeTransfer parses transfer(to, amount) calldata strictly: exact length, the right
// selector and a zero-padded address word. Anything a lenient ABI decoder would accept but
// that encodes differently (dirty high bits, trailing bytes) is rejected, so what the signing
// firewall checks is exactly what the token contract will execute.
func DecodeTransfer(data []byte) (to common.Address, amount *big.Int, err error) {
	if len(data) != 68 || !bytes.Equal(data[:4], TransferSelector) {
		return common.Address{}, nil, ErrBadCalldata
	}
	if !bytes.Equal(data[4:16], make([]byte, 12)) {
		return common.Address{}, nil, ErrBadCalldata
	}
	return common.BytesToAddress(data[16:36]), new(big.Int).SetBytes(data[36:68]), nil
}

// TransferLog is a decoded ERC-20 Transfer event.
type TransferLog struct {
	Token  common.Address
	From   common.Address
	To     common.Address
	Amount *big.Int
}

// DecodeTransferLog decodes a standard Transfer(address indexed, address indexed, uint256).
func DecodeTransferLog(l *types.Log) (TransferLog, bool) {
	if len(l.Topics) != 3 || l.Topics[0] != TransferTopic || len(l.Data) != 32 {
		return TransferLog{}, false
	}
	return TransferLog{
		Token:  l.Address,
		From:   common.BytesToAddress(l.Topics[1].Bytes()),
		To:     common.BytesToAddress(l.Topics[2].Bytes()),
		Amount: new(big.Int).SetBytes(l.Data),
	}, true
}

// TokenBalanceAtHash reads balanceOf(holder) at a specific block.
func TokenBalanceAtHash(ctx context.Context, c Client, token, holder common.Address, block common.Hash) (*big.Int, error) {
	data := append(append([]byte{}, BalanceOfSelector...), common.LeftPadBytes(holder.Bytes(), 32)...)
	out, err := c.CallContractAtHash(ctx, ethereum.CallMsg{To: &token, Data: data}, block)
	if err != nil {
		return nil, fmt.Errorf("chain: balanceOf: %w", err)
	}
	if len(out) != 32 {
		return nil, fmt.Errorf("chain: balanceOf returned %d bytes", len(out))
	}
	return new(big.Int).SetBytes(out), nil
}
