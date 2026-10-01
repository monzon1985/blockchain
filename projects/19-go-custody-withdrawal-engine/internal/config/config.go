// SPDX-License-Identifier: MIT

// Package config loads the engine's JSON configuration. Decoding is strict (unknown fields are
// errors) so a misspelt limit can never silently fall back to a default.
package config

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

// Duration is a time.Duration encoded as a Go duration string ("24h", "250ms").
type Duration struct{ time.Duration }

// UnmarshalJSON implements json.Unmarshaler.
func (d *Duration) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return fmt.Errorf("duration must be a string like \"24h\": %w", err)
	}
	v, err := time.ParseDuration(s)
	if err != nil {
		return err
	}
	d.Duration = v
	return nil
}

// MarshalJSON implements json.Marshaler.
func (d Duration) MarshalJSON() ([]byte, error) { return json.Marshal(d.String()) }

// Big is an arbitrary-precision non-negative integer encoded as a decimal string.
type Big struct{ *big.Int }

// UnmarshalJSON implements json.Unmarshaler.
func (b *Big) UnmarshalJSON(raw []byte) error {
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return fmt.Errorf("amounts must be decimal strings: %w", err)
	}
	v, ok := new(big.Int).SetString(s, 10)
	if !ok || v.Sign() < 0 {
		return fmt.Errorf("invalid amount %q", s)
	}
	b.Int = v
	return nil
}

// MarshalJSON implements json.Marshaler.
func (b Big) MarshalJSON() ([]byte, error) {
	if b.Int == nil {
		return []byte(`null`), nil
	}
	return json.Marshal(b.String())
}

// Principal is an authenticated caller identified by the SHA-256 of its bearer token.
type Principal struct {
	ID          string `json:"id"`
	TokenSHA256 string `json:"token_sha256"`
}

// Asset is a supported ERC-20 and its policy limits (base units).
type Asset struct {
	Symbol            string `json:"symbol"`
	Token             string `json:"token"`
	MaxPerTx          Big    `json:"max_per_tx"`
	Velocity24h       Big    `json:"velocity_24h"`
	ApprovalThreshold Big    `json:"approval_threshold"`
}

// Config is the whole configuration file.
type Config struct {
	Chain struct {
		RPCURL        string   `json:"rpc_url"`
		ChainID       uint64   `json:"chain_id"`
		Confirmations uint64   `json:"confirmations"`
		PollInterval  Duration `json:"poll_interval"`
	} `json:"chain"`
	Database struct {
		Path string `json:"path"`
	} `json:"database"`
	HTTP struct {
		Listen   string `json:"listen"`
		AddrFile string `json:"addr_file"`
	} `json:"http"`
	Audit struct {
		Path         string   `json:"path"`
		ShipInterval Duration `json:"ship_interval"`
	} `json:"audit"`
	HotWallet struct {
		Keystore     string `json:"keystore"`
		PasswordFile string `json:"password_file"`
	} `json:"hot_wallet"`
	Fees struct {
		HistoryBlocks    uint64  `json:"history_blocks"`
		RewardPercentile float64 `json:"reward_percentile"`
		MinTipWei        Big     `json:"min_tip_wei"`
		MaxFeeWei        Big     `json:"max_fee_wei"`
		BumpAfterBlocks  uint64  `json:"bump_after_blocks"`
		BumpBps          int64   `json:"bump_bps"`
		GasLimitBps      int64   `json:"gas_limit_bps"`
	} `json:"fees"`
	Nonces struct {
		GapGraceBlocks uint64 `json:"gap_grace_blocks"`
	} `json:"nonces"`
	NativeAsset string  `json:"native_asset"`
	Assets      []Asset `json:"assets"`
	Policy      struct {
		AllowlistCooldown Duration    `json:"allowlist_cooldown"`
		ApprovalsRequired int         `json:"approvals_required"`
		Approvers         []Principal `json:"approvers"`
	} `json:"policy"`
	Clients  []Principal `json:"clients"`
	Deposits struct {
		Factory        string   `json:"factory"`
		StartBlock     *uint64  `json:"start_block"`
		ScanInterval   Duration `json:"scan_interval"`
		MaxBlockRange  uint64   `json:"max_block_range"`
		SweepInterval  Duration `json:"sweep_interval"`
		SweepBatchSize int      `json:"sweep_batch_size"`
		SweepMinAmount Big      `json:"sweep_min_amount"`
	} `json:"deposits"`
	Reconcile struct {
		EveryRounds int `json:"every_rounds"`
	} `json:"reconcile"`
}

// Load reads, decodes, defaults and validates the configuration at path. Relative file paths
// inside it are resolved against the configuration file's directory.
func Load(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("config: %w", err)
	}
	c, err := Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("config %s: %w", path, err)
	}
	dir := filepath.Dir(path)
	for _, p := range []*string{&c.Database.Path, &c.Audit.Path, &c.HotWallet.Keystore, &c.HotWallet.PasswordFile, &c.HTTP.AddrFile} {
		if *p != "" && !filepath.IsAbs(*p) {
			*p = filepath.Join(dir, *p)
		}
	}
	return c, nil
}

// Parse decodes and validates configuration bytes.
func Parse(raw []byte) (*Config, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	c := &Config{}
	if err := dec.Decode(c); err != nil {
		return nil, err
	}
	c.applyDefaults()
	c.normalize()
	return c, c.Validate()
}

// normalize lowercases the token hashes, so a hash pasted in upper-case hex still matches the
// lowercase output of HashToken; Validate then rejects anything that is not 64 hex digits.
func (c *Config) normalize() {
	for i := range c.Clients {
		c.Clients[i].TokenSHA256 = strings.ToLower(strings.TrimSpace(c.Clients[i].TokenSHA256))
	}
	for i := range c.Policy.Approvers {
		c.Policy.Approvers[i].TokenSHA256 = strings.ToLower(strings.TrimSpace(c.Policy.Approvers[i].TokenSHA256))
	}
}

// isSHA256Hex reports whether s is a SHA-256 digest in lowercase hex.
func isSHA256Hex(s string) bool {
	b, err := hex.DecodeString(s)
	return err == nil && len(b) == sha256.Size && s == strings.ToLower(s)
}

func (c *Config) applyDefaults() {
	def := func(d *Duration, v time.Duration) {
		if d.Duration == 0 {
			d.Duration = v
		}
	}
	def(&c.Chain.PollInterval, time.Second)
	def(&c.Audit.ShipInterval, time.Second)
	def(&c.Deposits.ScanInterval, 2*time.Second)
	def(&c.Deposits.SweepInterval, 30*time.Second)
	if c.Chain.Confirmations == 0 {
		c.Chain.Confirmations = 12
	}
	if c.HTTP.Listen == "" {
		c.HTTP.Listen = "127.0.0.1:8080"
	}
	if c.Fees.HistoryBlocks == 0 {
		c.Fees.HistoryBlocks = 10
	}
	if c.Fees.RewardPercentile == 0 {
		c.Fees.RewardPercentile = 50
	}
	if c.Fees.BumpAfterBlocks == 0 {
		c.Fees.BumpAfterBlocks = 3
	}
	if c.Fees.BumpBps == 0 {
		c.Fees.BumpBps = 1250
	}
	if c.Fees.GasLimitBps == 0 {
		c.Fees.GasLimitBps = 12_500
	}
	if c.Nonces.GapGraceBlocks == 0 {
		c.Nonces.GapGraceBlocks = 2
	}
	if c.NativeAsset == "" {
		c.NativeAsset = "ETH"
	}
	if c.Deposits.MaxBlockRange == 0 {
		c.Deposits.MaxBlockRange = 2000
	}
	if c.Deposits.SweepBatchSize == 0 {
		c.Deposits.SweepBatchSize = 50
	}
	if c.Deposits.SweepMinAmount.Int == nil {
		c.Deposits.SweepMinAmount.Int = new(big.Int)
	}
	if c.Reconcile.EveryRounds == 0 {
		c.Reconcile.EveryRounds = 10
	}
}

// Validate checks required fields and consistency.
func (c *Config) Validate() error {
	var errs []string
	req := func(ok bool, msg string) {
		if !ok {
			errs = append(errs, msg)
		}
	}
	req(c.Chain.RPCURL != "", "chain.rpc_url is required")
	req(c.Chain.ChainID != 0, "chain.chain_id is required")
	req(c.Database.Path != "", "database.path is required")
	req(c.Audit.Path != "", "audit.path is required")
	req(c.HotWallet.Keystore != "" && c.HotWallet.PasswordFile != "", "hot_wallet.keystore and hot_wallet.password_file are required")
	req(c.Fees.MinTipWei.Int != nil && c.Fees.MaxFeeWei.Int != nil, "fees.min_tip_wei and fees.max_fee_wei are required")
	req(c.Fees.BumpBps >= 1250, "fees.bump_bps must be at least 1250 (12.5%)")
	req(c.Fees.GasLimitBps >= 10_000, "fees.gas_limit_bps must be at least 10000")
	req(common.IsHexAddress(c.Deposits.Factory), "deposits.factory must be an address")
	req(len(c.Assets) > 0, "at least one asset is required")
	req(len(c.Clients) > 0, "at least one client is required")
	seen := map[string]bool{strings.ToUpper(c.NativeAsset): true}
	for _, a := range c.Assets {
		req(a.Symbol != "" && !seen[strings.ToUpper(a.Symbol)], fmt.Sprintf("asset symbol %q is empty or duplicated", a.Symbol))
		seen[strings.ToUpper(a.Symbol)] = true
		req(common.IsHexAddress(a.Token), fmt.Sprintf("asset %s: token must be an address", a.Symbol))
		req(a.MaxPerTx.Int != nil && a.Velocity24h.Int != nil && a.ApprovalThreshold.Int != nil,
			fmt.Sprintf("asset %s: max_per_tx, velocity_24h and approval_threshold are required", a.Symbol))
	}
	for _, p := range append(append([]Principal{}, c.Clients...), c.Policy.Approvers...) {
		req(p.ID != "" && isSHA256Hex(p.TokenSHA256), fmt.Sprintf("principal %q needs an id and a token_sha256 of 64 hex digits", p.ID))
	}
	if len(errs) > 0 {
		return errors.New(strings.Join(errs, "; "))
	}
	return nil
}
