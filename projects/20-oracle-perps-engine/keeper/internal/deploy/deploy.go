// SPDX-License-Identifier: MIT

// Package deploy deploys and wires the full system from Go, step for step like contracts/script/PerpsDeployment.sol.
// It is used by the in-process engine tests (geth simulated backend) and by the anvil integration test. Both this
// package and PerpsDeployment are checked against contracts/test/fixtures/deployment.json, so the keeper is tested
// against the configuration the Foundry script ships.
package deploy

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/bindings"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/report"
)

// Role identifiers, identical to PerpsDeployment.sol.
const (
	// AdminRole is the AccessManager admin role (ADMIN_ROLE = 0).
	AdminRole       uint64 = 0
	KeeperRole      uint64 = 1
	RiskAdminRole   uint64 = 2
	OracleAdminRole uint64 = 3
	GuardianRole    uint64 = 4
	// GovernanceDelay is the AccessManager execution delay of the governance roles and of the admin (1 day).
	GovernanceDelay uint32 = 86_400
)

// Backend is what deployment and transaction helpers need from a node.
type Backend interface {
	bind.ContractBackend
	bind.DeployBackend
}

// Config holds deployment inputs.
type Config struct {
	Signers      []common.Address
	MinSigners   uint8
	MaxReportAge uint32
	MaxSpreadBps uint16
	Keepers      []common.Address
	RiskAdmin    common.Address
	OracleAdmin  common.Address
	Guardian     common.Address
	// Governor ends up holding the AccessManager admin role with a GovernanceDelay execution delay (zero: the
	// deploying account). When it differs from the deployer, the deployer renounces the role.
	Governor   common.Address
	MarketName string
	Params     bindings.IPerpsMarketRiskParams
	// ReceiptPoll is the receipt polling interval (defaults to 100 ms).
	ReceiptPoll time.Duration
}

// System is a deployed and wired set of contracts.
type System struct {
	USD       common.Address
	Manager   common.Address
	Oracle    common.Address
	Market    common.Address
	OrderBook common.Address
	Vault     common.Address
	MarketID  [32]byte
}

func wad(v int64) *big.Int { return new(big.Int).Mul(big.NewInt(v), big.NewInt(1e18)) }

// DefaultRiskParams mirrors PerpsDeployment.defaultRiskParams().
func DefaultRiskParams() bindings.IPerpsMarketRiskParams {
	return bindings.IPerpsMarketRiskParams{
		MaxLongOpenInterest:  wad(50_000_000),
		MaxShortOpenInterest: wad(50_000_000),
		ReserveFactor:        800_000_000_000_000_000,
		MaxPnlFactor:         500_000_000_000_000_000,
		AdlThresholdFactor:   450_000_000_000_000_000,
		AdlTargetFactor:      400_000_000_000_000_000,
		PositionFeeBps:       5,
		InitialMarginBps:     500,
		MaintenanceMarginBps: 100,
		LiquidationFeeBps:    20,
		OrderTimeout:         120,
		MinCollateral:        wad(10),
		PositiveImpactFactor: big.NewInt(250_000_000),
		NegativeImpactFactor: big.NewInt(500_000_000),
		BorrowFactor:         15_854_895_991,
		MaxFundingVelocity:   4_018_775,
		MaxFundingRate:       277_777_777_777,
		SkewScale:            wad(10_000_000),
		MinExecutionFee:      new(big.Int).Div(wad(1), big.NewInt(10)),
	}
}

// Deploy deploys MockUSD, AccessManager, OracleVerifier and PerpsMarket (which deploys its OrderBook and LPVault)
// from admin, then maps every restricted selector to its role and grants the roles.
func Deploy(ctx context.Context, b Backend, admin *bind.TransactOpts, cfg Config) (*System, error) {
	s := &System{MarketID: report.MarketID(cfg.MarketName)}
	w := waiter{b: b, poll: cfg.ReceiptPoll}

	var err error
	var tx *types.Transaction
	if s.USD, tx, _, err = bindings.DeployMockUSD(admin, b, 18); err != nil {
		return nil, fmt.Errorf("deploy MockUSD: %w", err)
	}
	if err := w.wait(ctx, tx); err != nil {
		return nil, err
	}
	if s.Manager, tx, _, err = bindings.DeployAccessManager(admin, b, admin.From); err != nil {
		return nil, fmt.Errorf("deploy AccessManager: %w", err)
	}
	if err := w.wait(ctx, tx); err != nil {
		return nil, err
	}
	if s.Oracle, tx, _, err = bindings.DeployOracleVerifier(
		admin, b, s.Manager, cfg.Signers, cfg.MinSigners, cfg.MaxReportAge, cfg.MaxSpreadBps,
	); err != nil {
		return nil, fmt.Errorf("deploy OracleVerifier: %w", err)
	}
	if err := w.wait(ctx, tx); err != nil {
		return nil, err
	}
	var market *bindings.PerpsMarket
	if s.Market, tx, market, err = bindings.DeployPerpsMarket(
		admin, b, s.Manager, s.USD, s.Oracle, s.MarketID, cfg.Params, "Perps LP Share", "PLP",
	); err != nil {
		return nil, fmt.Errorf("deploy PerpsMarket: %w", err)
	}
	if err := w.wait(ctx, tx); err != nil {
		return nil, err
	}
	call := &bind.CallOpts{Context: ctx}
	if s.OrderBook, err = market.OrderBook(call); err != nil {
		return nil, err
	}
	if s.Vault, err = market.Vault(call); err != nil {
		return nil, err
	}
	if err := configureRoles(ctx, b, admin, w, s, cfg); err != nil {
		return nil, err
	}
	if err := lockAdmin(ctx, b, admin, w, s, cfg); err != nil {
		return nil, err
	}
	return s, nil
}

// FunctionRole maps one restricted function to the role allowed to call it.
type FunctionRole struct {
	Target string // contract name: PerpsMarket, OrderBook, LPVault or OracleVerifier
	Method string
	Role   uint64
}

// FunctionRoles is the role table of PerpsDeployment.configureRoles.
func FunctionRoles() []FunctionRole {
	return []FunctionRole{
		{"OrderBook", "executeOrder", KeeperRole},
		{"LPVault", "executeRequest", KeeperRole},
		{"PerpsMarket", "liquidate", KeeperRole},
		{"PerpsMarket", "autoDeleverage", KeeperRole},
		{"PerpsMarket", "setRiskParams", RiskAdminRole},
		{"PerpsMarket", "setPaused", GuardianRole},
		{"OracleVerifier", "setSigners", OracleAdminRole},
		{"OracleVerifier", "setReportLimits", OracleAdminRole},
	}
}

// ContractMeta returns the binding metadata of a contract named in FunctionRoles.
func ContractMeta(name string) (*bind.MetaData, error) {
	switch name {
	case "PerpsMarket":
		return bindings.PerpsMarketMetaData, nil
	case "OrderBook":
		return bindings.OrderBookMetaData, nil
	case "LPVault":
		return bindings.LPVaultMetaData, nil
	case "OracleVerifier":
		return bindings.OracleVerifierMetaData, nil
	}
	return nil, fmt.Errorf("deploy: unknown contract %q", name)
}

// Address returns the deployed address of a contract named in FunctionRoles.
func (s *System) Address(name string) (common.Address, error) {
	switch name {
	case "PerpsMarket":
		return s.Market, nil
	case "OrderBook":
		return s.OrderBook, nil
	case "LPVault":
		return s.Vault, nil
	case "OracleVerifier":
		return s.Oracle, nil
	}
	return common.Address{}, fmt.Errorf("deploy: unknown contract %q", name)
}

func selector(meta *bind.MetaData, method string) ([4]byte, error) {
	parsed, err := meta.GetAbi()
	if err != nil {
		return [4]byte{}, err
	}
	m, ok := parsed.Methods[method]
	if !ok {
		return [4]byte{}, fmt.Errorf("method %s not in ABI", method)
	}
	return [4]byte(m.ID), nil
}

func configureRoles(ctx context.Context, b Backend, admin *bind.TransactOpts, w waiter, s *System, cfg Config) error {
	manager, err := bindings.NewAccessManager(s.Manager, b)
	if err != nil {
		return err
	}
	for _, m := range FunctionRoles() {
		meta, err := ContractMeta(m.Target)
		if err != nil {
			return err
		}
		sel, err := selector(meta, m.Method)
		if err != nil {
			return err
		}
		target, err := s.Address(m.Target)
		if err != nil {
			return err
		}
		tx, err := manager.SetTargetFunctionRole(admin, target, [][4]byte{sel}, m.Role)
		if err != nil {
			return fmt.Errorf("setTargetFunctionRole %s.%s: %w", m.Target, m.Method, err)
		}
		if err := w.wait(ctx, tx); err != nil {
			return err
		}
	}
	grants := []struct {
		role  uint64
		who   common.Address
		delay uint32
	}{
		{RiskAdminRole, cfg.RiskAdmin, GovernanceDelay},
		{OracleAdminRole, cfg.OracleAdmin, GovernanceDelay},
		{GuardianRole, cfg.Guardian, 0},
	}
	for _, k := range cfg.Keepers {
		grants = append(grants, struct {
			role  uint64
			who   common.Address
			delay uint32
		}{KeeperRole, k, 0})
	}
	for _, g := range grants {
		tx, err := manager.GrantRole(admin, g.role, g.who, g.delay)
		if err != nil {
			return fmt.Errorf("grantRole %d: %w", g.role, err)
		}
		if err := w.wait(ctx, tx); err != nil {
			return err
		}
	}
	return nil
}

// lockAdmin mirrors PerpsDeployment.lockAdmin: the governor holds the admin role behind GovernanceDelay, so every
// admin operation (granting a role, remapping a function) must be scheduled a day ahead and the risk and oracle
// timelocks cannot be bypassed by the admin.
func lockAdmin(ctx context.Context, b Backend, admin *bind.TransactOpts, w waiter, s *System, cfg Config) error {
	manager, err := bindings.NewAccessManager(s.Manager, b)
	if err != nil {
		return err
	}
	governor := cfg.Governor
	if governor == (common.Address{}) {
		governor = admin.From
	}
	tx, err := manager.GrantRole(admin, AdminRole, governor, GovernanceDelay)
	if err != nil {
		return fmt.Errorf("grant admin to governor: %w", err)
	}
	if err := w.wait(ctx, tx); err != nil {
		return err
	}
	if governor == admin.From {
		return nil
	}
	if tx, err = manager.RenounceRole(admin, AdminRole, admin.From); err != nil {
		return fmt.Errorf("renounce admin: %w", err)
	}
	return w.wait(ctx, tx)
}

// Waiter blocks until a transaction is mined and fails if it reverted.
type waiter struct {
	b    bind.DeployBackend
	poll time.Duration
}

// ErrReverted is returned for mined transactions with a failed status.
var ErrReverted = errors.New("transaction reverted")

func (w waiter) wait(ctx context.Context, tx *types.Transaction) error {
	_, err := WaitMined(ctx, w.b, tx.Hash(), w.poll)
	return err
}

// WaitMined polls for the receipt of hash every poll (default 100 ms) and returns ErrReverted on a failed status.
func WaitMined(ctx context.Context, b bind.DeployBackend, hash common.Hash, poll time.Duration) (*types.Receipt, error) {
	if poll <= 0 {
		poll = 100 * time.Millisecond
	}
	t := time.NewTicker(poll)
	defer t.Stop()
	for {
		receipt, err := b.TransactionReceipt(ctx, hash)
		if err == nil && receipt != nil {
			if receipt.Status != types.ReceiptStatusSuccessful {
				return receipt, fmt.Errorf("%w: %s", ErrReverted, hash)
			}
			return receipt, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-t.C:
		}
	}
}

// ABI returns the parsed ABI of a binding (small helper for callers decoding custom errors).
func ABI(meta *bind.MetaData) (*abi.ABI, error) { return meta.GetAbi() }
