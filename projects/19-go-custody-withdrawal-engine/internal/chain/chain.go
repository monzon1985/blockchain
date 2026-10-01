// SPDX-License-Identifier: MIT

// Package chain defines the narrow view of an Ethereum node the engine depends on, an RPC
// implementation of it, and the classification of node errors into the outcomes the
// transaction manager acts on.
package chain

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/rpc"
)

// ErrNotFound is returned when a block, receipt or transaction does not exist (yet).
var ErrNotFound = errors.New("chain: not found")

// BlockRef identifies a block by number and hash, as reported by the node. The hash is read
// from the node's JSON rather than recomputed from header fields, so it stays correct across
// hard forks that add header fields.
type BlockRef struct {
	Number  uint64
	Hash    common.Hash
	BaseFee *big.Int
}

// Client is everything the engine needs from a node.
type Client interface {
	ChainID(ctx context.Context) (*big.Int, error)
	// Head returns the latest block.
	Head(ctx context.Context) (BlockRef, error)
	// BlockByNumber returns the canonical block at n, or ErrNotFound above the head.
	BlockByNumber(ctx context.Context, n uint64) (BlockRef, error)
	// SendTransaction submits a signed transaction.
	SendTransaction(ctx context.Context, tx *types.Transaction) error
	// TransactionReceipt returns the receipt of a canonical transaction, or ErrNotFound.
	TransactionReceipt(ctx context.Context, hash common.Hash) (*types.Receipt, error)
	// TransactionKnown reports whether the node knows the transaction (pending or mined).
	TransactionKnown(ctx context.Context, hash common.Hash) (bool, error)
	// NonceAt returns the account nonce at the latest block.
	NonceAt(ctx context.Context, account common.Address) (uint64, error)
	FeeHistory(ctx context.Context, blockCount uint64, lastBlock *big.Int, rewardPercentiles []float64) (*ethereum.FeeHistory, error)
	EstimateGas(ctx context.Context, msg ethereum.CallMsg) (uint64, error)
	// BalanceAtHash returns the native balance at a specific block (EIP-1898).
	BalanceAtHash(ctx context.Context, account common.Address, block common.Hash) (*big.Int, error)
	// CallContractAtHash executes a read-only call at a specific block (EIP-1898).
	CallContractAtHash(ctx context.Context, msg ethereum.CallMsg, block common.Hash) ([]byte, error)
	FilterLogs(ctx context.Context, q ethereum.FilterQuery) ([]types.Log, error)
}

// RPC implements Client over JSON-RPC.
type RPC struct {
	eth *ethclient.Client
	raw *rpc.Client
}

// Dial connects to a node.
func Dial(ctx context.Context, url string) (*RPC, error) {
	raw, err := rpc.DialContext(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("chain: dial %s: %w", url, err)
	}
	return &RPC{eth: ethclient.NewClient(raw), raw: raw}, nil
}

// Close closes the connection.
func (c *RPC) Close() { c.raw.Close() }

// Raw exposes the underlying RPC client (used by tests for anvil_* methods).
func (c *RPC) Raw() *rpc.Client { return c.raw }

// ChainID implements Client.
func (c *RPC) ChainID(ctx context.Context) (*big.Int, error) { return c.eth.ChainID(ctx) }

type rpcBlock struct {
	Number  *hexutil.Big `json:"number"`
	Hash    common.Hash  `json:"hash"`
	BaseFee *hexutil.Big `json:"baseFeePerGas"`
}

func (c *RPC) block(ctx context.Context, tag string) (BlockRef, error) {
	var raw json.RawMessage
	if err := c.raw.CallContext(ctx, &raw, "eth_getBlockByNumber", tag, false); err != nil {
		return BlockRef{}, fmt.Errorf("chain: get block %s: %w", tag, err)
	}
	if len(raw) == 0 || string(raw) == "null" {
		return BlockRef{}, ErrNotFound
	}
	var b rpcBlock
	if err := json.Unmarshal(raw, &b); err != nil {
		return BlockRef{}, fmt.Errorf("chain: decode block: %w", err)
	}
	if b.Number == nil {
		return BlockRef{}, fmt.Errorf("chain: block %s has no number", tag)
	}
	ref := BlockRef{Number: b.Number.ToInt().Uint64(), Hash: b.Hash}
	if b.BaseFee != nil {
		ref.BaseFee = b.BaseFee.ToInt()
	}
	return ref, nil
}

// Head implements Client.
func (c *RPC) Head(ctx context.Context) (BlockRef, error) { return c.block(ctx, "latest") }

// BlockByNumber implements Client.
func (c *RPC) BlockByNumber(ctx context.Context, n uint64) (BlockRef, error) {
	return c.block(ctx, hexutil.EncodeUint64(n))
}

// SendTransaction implements Client.
func (c *RPC) SendTransaction(ctx context.Context, tx *types.Transaction) error {
	return c.eth.SendTransaction(ctx, tx)
}

// TransactionReceipt implements Client.
func (c *RPC) TransactionReceipt(ctx context.Context, hash common.Hash) (*types.Receipt, error) {
	r, err := c.eth.TransactionReceipt(ctx, hash)
	if errors.Is(err, ethereum.NotFound) {
		return nil, ErrNotFound
	}
	return r, err
}

// TransactionKnown implements Client. It avoids decoding the transaction: presence is all the
// tracker needs.
func (c *RPC) TransactionKnown(ctx context.Context, hash common.Hash) (bool, error) {
	var raw json.RawMessage
	if err := c.raw.CallContext(ctx, &raw, "eth_getTransactionByHash", hash); err != nil {
		return false, fmt.Errorf("chain: get transaction: %w", err)
	}
	return len(raw) > 0 && string(raw) != "null", nil
}

// NonceAt implements Client.
func (c *RPC) NonceAt(ctx context.Context, account common.Address) (uint64, error) {
	return c.eth.NonceAt(ctx, account, nil)
}

// FeeHistory implements Client.
func (c *RPC) FeeHistory(ctx context.Context, blockCount uint64, lastBlock *big.Int, p []float64) (*ethereum.FeeHistory, error) {
	return c.eth.FeeHistory(ctx, blockCount, lastBlock, p)
}

// EstimateGas implements Client.
func (c *RPC) EstimateGas(ctx context.Context, msg ethereum.CallMsg) (uint64, error) {
	return c.eth.EstimateGas(ctx, msg)
}

// BalanceAtHash implements Client.
func (c *RPC) BalanceAtHash(ctx context.Context, account common.Address, block common.Hash) (*big.Int, error) {
	return c.eth.BalanceAtHash(ctx, account, block)
}

// CallContractAtHash implements Client.
func (c *RPC) CallContractAtHash(ctx context.Context, msg ethereum.CallMsg, block common.Hash) ([]byte, error) {
	return c.eth.CallContractAtHash(ctx, msg, block)
}

// FilterLogs implements Client.
func (c *RPC) FilterLogs(ctx context.Context, q ethereum.FilterQuery) ([]types.Log, error) {
	return c.eth.FilterLogs(ctx, q)
}

// SendOutcome classifies the result of SendTransaction.
type SendOutcome int

// Send outcomes.
const (
	// Accepted: the node took the transaction into its pool.
	Accepted SendOutcome = iota
	// AlreadyKnown: the node already has this exact transaction. Equivalent to Accepted.
	AlreadyKnown
	// NonceTooLow: the nonce is already used on chain, by this or another transaction.
	NonceTooLow
	// Underpriced: the fee is too low for the pool (replacement rule or current base fee).
	Underpriced
	// InsufficientFunds: the hot wallet cannot pay value + gas * fee cap.
	InsufficientFunds
	// Transient: anything else (connection errors, timeouts); retry later.
	Transient
)

// String implements fmt.Stringer.
func (o SendOutcome) String() string {
	switch o {
	case Accepted:
		return "accepted"
	case AlreadyKnown:
		return "already_known"
	case NonceTooLow:
		return "nonce_too_low"
	case Underpriced:
		return "underpriced"
	case InsufficientFunds:
		return "insufficient_funds"
	default:
		return "transient"
	}
}

// ClassifySendError maps node error messages (geth, anvil, reth and Nethermind wordings) to
// an outcome. Matching is on lower-cased substrings because error codes are not standardised.
func ClassifySendError(err error) SendOutcome {
	if err == nil {
		return Accepted
	}
	msg := strings.ToLower(err.Error())
	switch {
	case strings.Contains(msg, "already known"),
		strings.Contains(msg, "already imported"),
		strings.Contains(msg, "known transaction"),
		strings.Contains(msg, "alreadyknown"):
		return AlreadyKnown
	case strings.Contains(msg, "nonce too low"),
		strings.Contains(msg, "oldnonce"):
		return NonceTooLow
	case strings.Contains(msg, "underpriced"),
		strings.Contains(msg, "less than block base fee"),
		strings.Contains(msg, "fee cap less than"),
		strings.Contains(msg, "feetoolow"),
		strings.Contains(msg, "max fee per gas less than"):
		return Underpriced
	case strings.Contains(msg, "insufficient funds"):
		return InsufficientFunds
	default:
		return Transient
	}
}
