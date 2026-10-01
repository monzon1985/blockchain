// SPDX-License-Identifier: MIT

package config_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/config"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/policy"
)

const valid = `{
  "chain": {"rpc_url": "http://127.0.0.1:8545", "chain_id": 31337},
  "database": {"path": "data/custody.db"},
  "audit": {"path": "data/audit.jsonl"},
  "hot_wallet": {"keystore": "hot.json", "password_file": "hot.pass"},
  "fees": {"min_tip_wei": "1000000000", "max_fee_wei": "500000000000"},
  "assets": [{"symbol": "tUSD", "token": "0x5FbDB2315678afecb367f032d93F642f64180aa3",
              "max_per_tx": "1000", "velocity_24h": "5000", "approval_threshold": "500"}],
  "policy": {"allowlist_cooldown": "24h", "approvals_required": 1,
             "approvers": [{"id": "a", "token_sha256": "` + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" + `"}]},
  "clients": [{"id": "gw", "token_sha256": "` + "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" + `"}],
  "deposits": {"factory": "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"}
}`

func TestParseAppliesDefaults(t *testing.T) {
	c, err := config.Parse([]byte(valid))
	if err != nil {
		t.Fatal(err)
	}
	if c.Chain.Confirmations != 12 || c.Fees.BumpBps != 1250 || c.Fees.GasLimitBps != 12_500 || c.NativeAsset != "ETH" ||
		c.Chain.PollInterval.Duration != time.Second || c.Deposits.SweepBatchSize != 50 || c.Reconcile.EveryRounds != 10 {
		t.Fatalf("defaults not applied: %+v", c)
	}
	if c.Policy.AllowlistCooldown.Duration != 24*time.Hour || c.Assets[0].MaxPerTx.Int64() != 1000 {
		t.Fatal("values not decoded")
	}
}

func TestParseRejects(t *testing.T) {
	cases := map[string]string{
		"unknown field":    strings.Replace(valid, `"chain_id"`, `"chainid": 1, "chain_id"`, 1),
		"bad duration":     strings.Replace(valid, `"24h"`, `"a day"`, 1),
		"numeric amount":   strings.Replace(valid, `"max_per_tx": "1000"`, `"max_per_tx": 1000`, 1),
		"negative amount":  strings.Replace(valid, `"max_per_tx": "1000"`, `"max_per_tx": "-1"`, 1),
		"bump below 12.5%": strings.Replace(valid, `"max_fee_wei": "500000000000"`, `"max_fee_wei": "500000000000", "bump_bps": 1000`, 1),
		"missing rpc":      strings.Replace(valid, `"rpc_url": "http://127.0.0.1:8545", `, ``, 1),
		"bad factory":      strings.Replace(valid, `"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"`, `"nope"`, 1),
		"duplicate symbol": strings.Replace(valid, `"symbol": "tUSD"`, `"symbol": "eth"`, 1),
		"short token hash": strings.Replace(valid, `"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`, `"aa"`, 1),
		"non-hex client hash": strings.Replace(valid, `"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"`,
			`"replace-with-output-of-custodyd-hash-token-000000000000000000000"`, 1),
		"non-hex approver hash": strings.Replace(valid, `"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`, `"`+strings.Repeat("g", 64)+`"`, 1),
		"missing keystore":      strings.Replace(valid, `"keystore": "hot.json", `, ``, 1),
		"gas bps below 100%":    strings.Replace(valid, `"max_fee_wei": "500000000000"`, `"max_fee_wei": "500000000000", "gas_limit_bps": 9000`, 1),
	}
	for name, raw := range cases {
		if _, err := config.Parse([]byte(raw)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestLoadResolvesRelativePaths(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "custody.json")
	if err := os.WriteFile(p, []byte(valid), 0o600); err != nil {
		t.Fatal(err)
	}
	c, err := config.Load(p)
	if err != nil {
		t.Fatal(err)
	}
	if c.Database.Path != filepath.Join(dir, "data", "custody.db") || c.HotWallet.Keystore != filepath.Join(dir, "hot.json") {
		t.Fatalf("paths not resolved: %s %s", c.Database.Path, c.HotWallet.Keystore)
	}
	if _, err := config.Load(filepath.Join(dir, "missing.json")); err == nil {
		t.Fatal("missing file accepted")
	}
	b, _ := c.Assets[0].MaxPerTx.MarshalJSON()
	d, _ := c.Chain.PollInterval.MarshalJSON()
	if string(b) != `"1000"` || string(d) != `"1s"` {
		t.Fatalf("marshal: %s %s", b, d)
	}
}

// The shipped example must stay loadable as the schema evolves.
func TestExampleConfigLoads(t *testing.T) {
	c, err := config.Load(filepath.Join("..", "..", "custody.example.json"))
	if err != nil {
		t.Fatal(err)
	}
	if c.Chain.Confirmations != 12 || c.Policy.AllowlistCooldown.Duration != 24*time.Hour || len(c.Policy.Approvers) != 3 {
		t.Fatalf("unexpected example values: %+v", c)
	}
}

// A hash pasted in upper-case hex is the same digest: it is accepted and normalised to the
// lowercase form HashToken produces, so it authenticates (regression: it used to load and then
// silently never match).
func TestParseNormalisesTokenHashCase(t *testing.T) {
	upper := strings.ToUpper(policy.HashToken("gateway-secret"))
	raw := strings.Replace(valid, `"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"`, `" `+upper+` "`, 1)
	raw = strings.Replace(raw, `"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`, `"`+strings.Repeat("A", 64)+`"`, 1)
	c, err := config.Parse([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	if c.Clients[0].TokenSHA256 != policy.HashToken("gateway-secret") || c.Policy.Approvers[0].TokenSHA256 != strings.Repeat("a", 64) {
		t.Fatalf("hashes not normalised: %q %q", c.Clients[0].TokenSHA256, c.Policy.Approvers[0].TokenSHA256)
	}
	if id, ok := policy.Authenticate("gateway-secret", []policy.Principal{{ID: c.Clients[0].ID, TokenSHA256: c.Clients[0].TokenSHA256}}); !ok || id != "gw" {
		t.Fatal("normalised client hash does not authenticate")
	}
}
