// SPDX-License-Identifier: MIT

package signer

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/bindings"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/chain"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/clock"
)

// ErrPolicy wraps every firewall refusal.
var ErrPolicy = errors.New("signer: signing policy violation")

// Purpose says what a transaction is for; each purpose has its own shape rules.
type Purpose string

// Transaction purposes.
const (
	PurposeWithdrawal Purpose = "withdrawal" // ERC-20 transfer to a customer destination
	PurposeCancel     Purpose = "cancel"     // zero-value self-send replacing a stuck transaction
	PurposeFiller     Purpose = "filler"     // zero-value self-send filling a nonce gap
	PurposeSweep      Purpose = "sweep"      // ForwarderFactory.flushMany
)

// SelfSendGas is the gas limit of cancellation and gap-filling self-sends.
const SelfSendGas = 21_000

// Request is what the transaction manager asks the firewall to sign.
type Request struct {
	Purpose   Purpose
	AccountID string // customer whose allowlist applies (withdrawals)
	Asset     string // asset symbol (withdrawals, sweeps)
	Tx        *types.Transaction
}

// Asset is the firewall's view of a configured token.
type Asset struct {
	Token    common.Address
	MaxPerTx *big.Int
}

// AllowlistChecker answers whether a destination is allowlisted and past its cool-down.
type AllowlistChecker interface {
	IsActive(ctx context.Context, accountID string, addr common.Address, at time.Time) (bool, error)
}

// FirewallConfig is the policy enforced at signing time.
type FirewallConfig struct {
	ChainID   *big.Int
	Factory   common.Address
	MaxFeeCap *big.Int
	Assets    map[string]Asset
}

// Firewall validates transactions against policy and then signs them.
type Firewall struct {
	inner     Signer
	cfg       FirewallConfig
	allowlist AllowlistChecker
	clock     clock.Clock
	factory   *bindings.ForwarderFactory
}

// NewFirewall wraps inner.
func NewFirewall(inner Signer, cfg FirewallConfig, allowlist AllowlistChecker, clk clock.Clock) (*Firewall, error) {
	if cfg.ChainID == nil || cfg.ChainID.Sign() <= 0 {
		return nil, errors.New("signer: firewall needs a chain id")
	}
	if cfg.MaxFeeCap == nil || cfg.MaxFeeCap.Sign() <= 0 {
		return nil, errors.New("signer: firewall needs a max fee cap")
	}
	return &Firewall{inner: inner, cfg: cfg, allowlist: allowlist, clock: clk, factory: bindings.NewForwarderFactory()}, nil
}

// Address returns the hot-wallet address.
func (f *Firewall) Address() common.Address { return f.inner.Address() }

// ChainID returns the chain the firewall signs for.
func (f *Firewall) ChainID() *big.Int { return new(big.Int).Set(f.cfg.ChainID) }

// Sign checks req against policy and signs it.
func (f *Firewall) Sign(ctx context.Context, req Request) (*types.Transaction, error) {
	if err := f.Check(ctx, req); err != nil {
		return nil, err
	}
	return f.inner.SignTx(ctx, req.Tx, f.cfg.ChainID)
}

func refuse(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrPolicy, fmt.Sprintf(format, args...))
}

// Check runs the policy without signing.
func (f *Firewall) Check(ctx context.Context, req Request) error {
	tx := req.Tx
	if tx == nil {
		return refuse("no transaction")
	}
	if tx.Type() != types.DynamicFeeTxType {
		return refuse("only EIP-1559 transactions are signed, got type %d", tx.Type())
	}
	if tx.ChainId().Cmp(f.cfg.ChainID) != 0 {
		return refuse("chain id %s, expected %s", tx.ChainId(), f.cfg.ChainID)
	}
	if tx.GasFeeCap().Cmp(f.cfg.MaxFeeCap) > 0 {
		return refuse("max fee %s above cap %s", tx.GasFeeCap(), f.cfg.MaxFeeCap)
	}
	if tx.GasTipCap().Cmp(tx.GasFeeCap()) > 0 {
		return refuse("tip above max fee")
	}
	if tx.To() == nil {
		return refuse("contract creation is never signed")
	}
	if tx.Value().Sign() != 0 {
		return refuse("native value transfers are never signed (value %s)", tx.Value())
	}
	if len(tx.AccessList()) != 0 {
		return refuse("access lists are not used")
	}
	self := f.inner.Address()
	switch req.Purpose {
	case PurposeCancel, PurposeFiller:
		if *tx.To() != self || len(tx.Data()) != 0 || tx.Gas() != SelfSendGas {
			return refuse("%s must be a 21000-gas empty self-send", req.Purpose)
		}
		return nil
	case PurposeWithdrawal:
		return f.checkWithdrawal(ctx, req, self)
	case PurposeSweep:
		return f.checkSweep(req)
	default:
		return refuse("unknown purpose %q", req.Purpose)
	}
}

func (f *Firewall) checkWithdrawal(ctx context.Context, req Request, self common.Address) error {
	asset, ok := f.cfg.Assets[req.Asset]
	if !ok {
		return refuse("asset %q is not configured", req.Asset)
	}
	if *req.Tx.To() != asset.Token {
		return refuse("withdrawal of %s must call %s, not %s", req.Asset, asset.Token, req.Tx.To())
	}
	dest, amount, err := chain.DecodeTransfer(req.Tx.Data())
	if err != nil {
		return refuse("%v", err)
	}
	if amount.Sign() <= 0 {
		return refuse("zero-amount transfer")
	}
	if asset.MaxPerTx != nil && amount.Cmp(asset.MaxPerTx) > 0 {
		return refuse("amount %s above per-transaction maximum %s", amount, asset.MaxPerTx)
	}
	if dest == (common.Address{}) || dest == self || dest == asset.Token || dest == f.cfg.Factory {
		return refuse("destination %s is not a customer address", dest)
	}
	active, err := f.allowlist.IsActive(ctx, req.AccountID, dest, f.clock.Now())
	if err != nil {
		return fmt.Errorf("signer: allowlist lookup: %w", err)
	}
	if !active {
		return refuse("destination %s is not an active allowlist entry of account %s", dest, req.AccountID)
	}
	return nil
}

func (f *Firewall) checkSweep(req Request) error {
	asset, ok := f.cfg.Assets[req.Asset]
	if !ok {
		return refuse("asset %q is not configured", req.Asset)
	}
	if *req.Tx.To() != f.cfg.Factory {
		return refuse("sweeps must call the forwarder factory")
	}
	data := req.Tx.Data()
	method := f.factory.GetABI().Methods["flushMany"]
	if len(data) < 4 || !bytes.Equal(data[:4], method.ID) {
		return refuse("sweeps may only call flushMany")
	}
	args, err := method.Inputs.Unpack(data[4:])
	if err != nil || len(args) != 2 {
		return refuse("undecodable flushMany calldata")
	}
	salts, ok1 := args[0].([][32]byte)
	token, ok2 := args[1].(common.Address)
	if !ok1 || !ok2 || len(salts) == 0 {
		return refuse("malformed flushMany arguments")
	}
	if token != asset.Token {
		return refuse("flushMany token %s is not %s", token, req.Asset)
	}
	// Reject non-canonical encodings: what was checked must be byte-for-byte what executes.
	if canonical := f.factory.PackFlushMany(salts, token); !bytes.Equal(canonical, data) {
		return refuse("non-canonical flushMany encoding")
	}
	return nil
}
